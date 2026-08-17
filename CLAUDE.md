# ont-monitor — repo context for Claude

Tools, scripts and ongoing investigations around the Brazilian-residential GPON path:
**Mac → Route10 (Alta IPQ9574) → eth4/W2 cage → ODI DFP-34X-2C3 SFP+ stick → fiber → ISP OLT**.

Memory (persistent across sessions) lives at
`/Users/antoniocasagrande/.claude/projects/-Users-antoniocasagrande-git-route10/memory/`
(see `MEMORY.md` index). This file is for in-flight context that doesn't belong in long-term memory.

## How to reach the stick safely

```sh
ssh route10 'python3 /cfg/scripts/stick-exec.py --json "omcicli mib get 262"'
```

Clean-exit telnet (no `/var/run/cli.pid` orphan). See
`reference_stick_exec_playbook.md` for the OMCI cheatsheet, or
`project_odi_cli_pid_lock.md` for the lock mechanism. **Never** do banner-only
telnet probes — they orphan the lock too.

## Deployed daemons on Route10

- `/cfg/scripts/odi-health.sh` — every 5 min: PPP state, ping 1.1.1.1 RTT, 13
  thermal zones, L4 BiDi DDM, W2 stick DDM (read from cache, no Boa session), and
  **switch-MIB Rx-error/CRC counters on port 5** (absorbed from flap-hunt on its
  retirement; warns on any growth). File gets the full verbose line; the syslog
  copy is a compact subset (tz_max + optical Rx + CRC state) because busybox
  syslogd truncates ~256 B. Log: `/cfg/scripts/odi-health.log`. Source:
  `scripts/odi-health.sh`.
- **RETIRED 2026-07-15 — `flap-hunt.sh` + `lcp-watch.sh`** (deletion test). flap-hunt
  was ~95% redundant: eth4 carrier flap → kernel log, PPP reconnect → pppd log,
  Boa-liveness probe duped the DDM daemon's 5 s poll (578 noise fails/30 d), 5-min
  heartbeat duped odi-health; its one unique signal (switch CRC) is folded into
  odi-health above. lcp-watch never fired (`lcp-echo-adaptive` ⇒ `LCP_SENT=0` for
  the link's life) and its only consumer was flap-hunt; the LCP-disconnect failure
  mode is already mitigated by the `5 5` keepalive. Recoverable from git history.
- `/cfg/scripts/daemon-odi-w2-ddm.sh` — every 5s: polls stick `/status_pon.asp`
  via Boa, encodes per SFF-8472, writes to i2c-1 0x51. Surfaces W2 stick DDM in
  Alta dashboard. See `reference_odi_ddm_blocker.md`.
- `/cfg/scripts/lan-prefix-track.sh` — hotplug `ifupdate` event (instant) +
  `* * * * *` cron backstop, no daemon. State-diffs br-lan's GUA /64 in
  **`/cfg/scripts/.lan-prefix.env`** (persistent, NOT `/var/run` — tmpfs state was
  blind to a rotation spanning a reboot, which is exactly when clients are most
  stranded; that cost a real outage 2026-08-09); on an ISP prefix rotation it
  deprecates the OUTGOING
  /64 to all LAN nodes via `ra-deprecate.py` (multicast RA, preferred **and** valid
  lifetime 0 per RFC 9096). The event hook is `/etc/hotplug.d/iface/89-lan-prefix`
  → `scripts/hotplug-lan-prefix.sh`. dnsmasq stops advertising a rotated-away prefix but
  never deprecates it (the rotation coincides with a dnsmasq restart that wipes
  its memory), so clients would otherwise stay stuck on the dead /64 as a
  *preferred* address for up to 24 h. Quiet when healthy. Log:
  `/cfg/scripts/prefix-track.log`. Sources: `scripts/lan-prefix-track.sh` +
  `scripts/ra-deprecate.py`. See `project_route10_stale_ipv6_prefix.md`.
  **Also owns the ONLY WAN→LAN v6 accept we have** (2026-08-12): a *prefix-relative*
  inbound pinhole for the ops p2p listener, `<current /64>:<IID>` on one port,
  TCP+UDP, stateful — approved against `ops/NETWORK-CONTRACT.md` §"IPv6 inbound
  perimeter", which requires a contract entry to exist *before* any such rule. It
  lives here because only the IID is stable and the /64 rotates: the same tick that
  re-points it **deletes the stale one**, so a rotation can never leave an accept
  into a prefix somebody else now owns. ⭐ **Warn-only by operator decision** —
  `RT10_P2P6` logs `route10.p2p6 warn:` (total conns to the listener) and
  `route10.p2p6 srcwarn:` (one remote /64 over-connecting) and then ACCEPTs; nothing
  rejects. A cap guessed wrong on a first exposure throttles real peers silently, and
  "slow torrent" is the last symptom anyone traces to a firewall counter — so measure
  first, bound later on data. Values `P2P6_IID`/`P2P6_PORT` come from `/cfg/seam.env`;
  **removing them tears the hole down on the next tick** (the revocation sweep runs
  unconditionally — verified live, closes to 0 jumps and reopens).
- **Observability stack on `/a` (2026-08-08, post-wedge)** — Alta's firmware
  `rcstats` daemon writes per-minute load/mem/temp (min-avg-max), per-switch-port
  and per-client DPI counters to the SQLite DB **`/a/stats.sql`** (`/a` = 3.1 G
  persistent ext4, survives reboots AND firmware updates; on-box `sqlite3` 3.40
  with JSON1). Its `minutes` table is a rolling ~60-min window, so:
  - `/cfg/scripts/stats-archive.sh` (`*/30` cron) — copies rows into
    `/a/obs/stats-archive.sql`; **30-day** minute retention, hours/days rollups kept
    ~2 y (fine-grained recent + downsampled long-term). Also the single **hard-cap
    janitor** for all of `/a/obs` (500 MB byte budget, trims oldest + VACUUMs on
    breach). Source: `scripts/stats-archive.sh`.
  - `/cfg/scripts/obs-collect.sh` (`* * * * *` cron, ~250 ms; up to ~8 s if every
    DNS hop is dead) — per-minute samples
    of the CPU-side counters rcstats can't see (CPU/softirq, softnet, br-lan/
    pppoe-wan3/tailscale0/eth4/eth5 counters + carriers, br-lan addr presence,
    conntrack, L4+W2 DDM) → `/a/obs/rt.sql`, 30-day retention. Also carries the
    **DNS resolver ladder** (`route10_dns_up` / `route10_dns_query_ms`, labels
    `resolver=adguard|doh|routedns|dnsmasq`, added 2026-08-10) — four independent
    `timeout 2 drill` probes, one per hop, so the metric NAMES the broken hop.
    Reads the 2026-08-10 outage as `adguard=0` while the rest stay 1, and
    `routedns` latency jumping to ~1000 ms is a **direct readout that the DoH
    fallback is active, i.e. ad-blocking is currently OFF** — no log parsing.
    ⚠ `dnsmasq=1` does NOT mean LAN DNS is healthy (it serves the stable probe
    name from cache with a dead upstream); the `adguard` rung is the honest one.
    ⚠ `timeout 2` is load-bearing — bare `drill` retries 3×5 s and would run the
    collector past its own cron. No new staleness guard: these ride
    `route10_rt_sample_timestamp_seconds`. Also drains the
    kernel ring persistently to `/a/obs/kernel-ring.log` and harvests pstore
    crash records to `/a/obs/pstore/` with an `err` line (alertable ops-side).
    Also carries the **wedge tripwire**: 2 consecutive min of zero br-lan rx with
    carrier up ⇒ sysrq `w`+`l` into the (now-persisted) ring, so a repeat of the
    IP-stack wedge names its own stuck task. NEVER touches stick telnet/Boa.
    Source: `scripts/obs-collect.sh`.
  - `/cfg/scripts/pon-collect.sh` (`* * * * *` cron) — PON-layer telemetry from
    the ODI stick via `stick-exec` clean-telnet (PLOAM state, LOS/LOF/SD alarms,
    BIP/FEC error counters, rogue-SD, stick uptime, plus activation / upstream /
    OMCI / BWMAP counters) → `/a/obs/rt.sql` `pon` table → 23 `route10_pon_*`
    metric **names** (30 series — quote names, series churn with labels). The **leading** fibre-degradation signal the SFF-8472 DDM can't
    show. Diag batch goes through `diag` **stdin + `exit`**
    (never bare `diag <subcmd>`, which strands the interactive prompt and wedges
    the single CLI); atomic `mkdir` overlap lock; raw blob kept on a parse
    anomaly **or any non-O5 row** (a bad PON is the window worth full context
    for). Sole stick-CLI user, so 1-min is safe.
    - **`onu_state` parses O1–O7**, not just O5. Before 2026-08-11 every other
      state read `null`/NaN, so **O7 (the OLT deliberately disabling us via
      `Disable_Serial_Number`) was indistinguishable from O2 (harmless
      standby)**. O5→O2 is `Deactivate_ONU-ID` — a *soft* refusal where the OLT
      still accepts our SN. Those need opposite responses; warns on O7.
    - **`ranging_req` is the loop detector** — a healthy ONU ranges ONCE and
      stays in O5, so a sustained rate IS the "OLT admits us then drops us"
      fault. Warns ≥3/cycle. ⛔ **Never alert on `sn_req`** — that is the OLT's
      broadcast discovery window, 30–38/min even when healthy.
    - **UPSTREAM LOSS, measured** (`omci_tx.req`/`retx`): the OLT re-sends a
      request with the SAME transaction ID on a ~1 s timeout when our reply
      doesn't arrive, so duplicate request TCIs read the one direction DDM
      **structurally cannot** see (it reports light we EMIT, never what the OLT
      receives). Warns >5% with a ≥20 sample gate. 2026-08-11 outage = 18.3%.
    - **OMCI log drain** → `omci` table, **7-day** retention (raw text is
      ~9.6 KB/min while faulting; 30 d would be ~415 MB of a 500 MB `/a/obs`
      budget and would make the janitor evict the 2-y rollups). The *signal* is
      already at 30 d as `omci_tx.*`. ⛔ **Parsed mode writes to
      `/tmp/omcilog.par`, NOT the `/tmp/omcilog` that `omcicli get logfile`
      reports** — the reported path stays 0 bytes forever; that cost hours on
      2026-08-11. Logger is runtime-only (`omci_app -f off 0`), so pon-collect
      re-arms it on its reboot detection.
      ⭐ **The bytes move over `nc`, not telnet (2026-08-12).** The log is ~99%
      NUL hole and the hole equals every byte `omci_app` has written **since
      stick boot** (~2.5 MB/day at mask `0x3FFFFFFF`) — only an `omci_app`
      restart clears it, so **a stick reboot is NOT a fix**: it resets the offset
      and hits the same wall inside a day, for an ~80 s WAN outage. Measured at
      2.5 MB: `sed` 10.4 s (over stick-exec's 10 s ⇒ orphaned session ⇒ the CLI
      wedge *we* were manufacturing), `grep` 8.8 s, **`nc` 1.8 s** + 1 ms to
      filter on route10. ⛔ **route10 LISTENS, the stick dials out** — the
      inverse was measured and is unsafe: an `nc -l` nobody connects to outlives
      its session and holds the single CLI. Port 9099 is fenced by the
      **`RT10_OMCIPULL`** chain (ACCEPT `192.168.1.1` on `ont_mgmt0`, DROP else)
      because `nc -s` binds an *address*, not an interface — a LAN host was
      verified able to inject into the capture, which feeds the write-verb
      pager. ⚠ That ACCEPT is **load-bearing for stick safety**: the kernel must
      answer RST so a missing listener refuses instantly; a DROP would hang the
      stick's `nc` past the timeout and orphan the session. Truncate is gated on
      `received >= reported` — now genuinely comparable, since nc moves the whole
      file (it was not comparable while we filtered stick-side).
    - **Raw OMCI lines → syslog tag `route10.omci`** (`daemon.info`, separate
      from `route10.pon-collect` so a firehose never rides the alert stream).
      Gated to non-O5 by default (~164 lines/min while faulting). busybox
      syslogd truncates the payload at **221 B** (measured, not the "~256 B" in
      the observability note), so over-long lines are split `c<seq>.<i>/<n>|…`
      and rejoin byte-identically; verified by round trip.
    **Self-heals a wedge**: on a
    detected wedge it runs `stick-unwedge.sh` once (rate-limited 1/5min) and
    re-polls, so a wedge costs ~1 cycle (<90 s staleness), not an open-ended
    stall — only a wedge that needs a stick reboot stays stale. Source:
    `scripts/pon-collect.sh`. Manual recovery: `scripts/stick-unwedge.sh` (no
    reboot; kills the orphaned login/sh session, not just cli.pid). See
    `reference_odi_stick_arch_no_ssh.md`.
  - `/cfg/scripts/lan-probe.sh` (`* * * * *` cron) — per-client LAN RTT/loss for the
    **user-experience** half (the infra metrics never caught the chronic "last images
    don't load / I switch to 5G" complaint). Targets in **`/cfg/lan-probe.targets`**
    (`<ip> <name> <medium> [dhcp_name]`, **not in git** — it holds the device→label
    map; `dhcp_name` is chased across MAC/IP rotations, family-matched). Controls:
    `present` (gate loss on it or a sleeping phone fakes a nightly outage), `medium`
    (wifi vs wired/ap), `rtt_min` floor, `dup`, `lease_seconds_remaining` (NaN = static
    host, NOT stale). ⛔ **Cannot characterise a phone** — measured 2026-08-10: an
    iPhone answered every echo in all 11 minutes it passed traffic and lost all 5 in
    all 5 idle minutes, so ICMP reports iOS power-save, not the link. Valid only for
    the vacuum/AP/wired controls. Source: `scripts/lan-probe.sh`.
  - `/cfg/scripts/ax73-scrape.sh` (`* * * * *` cron, 2026-08-16) — caches the AX73
    WiFi AP's Prometheus page (`http://192.168.10.11:9100/metrics`, static IP on the
    AP, owned by the **wifi-ap agent** — seam `~/git/agent-seam-wifi`) to
    `/tmp/ax73-metrics.prom`; metrics-cgi appends it verbatim so ops's single scrape
    of route10:9100 carries WiFi telemetry (route10 fronts ALL networking — one seam,
    operator decision). Closes the "route10 has no radios" AP blind spot lan-probe
    couldn't: per-station RSSI/rates/retries, per-BSS clients, radio noise/channel,
    driver `wl` counters. **Format-filtered on `^ax73_` + numeric value** — one
    malformed AP line would make Prometheus reject route10's ENTIRE exposition, so
    WiFi must never be able to take down router metrics. On failure serves the last
    good cache; consumers gate on `route10_ax73_up` +
    `route10_ax73_scrape_timestamp_seconds`. Log: transitions only. Source:
    `scripts/ax73-scrape.sh`.
  - **Passive experience signal** (in `obs-collect.sh`'s existing conntrack pass) —
    `route10_host_tcp_flows` / `_unanswered` per host: SYN_SENT that never
    established, i.e. the reported symptom itself. Inverts the probe's flaw — a
    sleeping device opens no connections, so idleness gives NO signal, not a false
    one. ⚠ Both numbers exported so the consumer can gate (`flows >= 10`); a ratio
    alone is vacuous. ⚠ p2p makes SYN_SENT normal (`.200` sits ~27-37% while
    healthy) — read a host against ITS OWN baseline, never an absolute threshold.
    ⚠ ~2-min smear (`nf_conntrack_tcp_timeout_syn_sent`=120s > 60s sampling): a fast
    burst cannot be missed, but it names a window, never which burst.
  - **`/metrics` exporter** — second uhttpd on **`192.168.10.1:9100`** (LAN-only
    bind, relaunched by post-cfg), CGI at `/cfg/scripts/metrics-www/metrics`
    serving newest stats.sql + rt.sql rows **+ the AX73 `ax73_*` cache** (no live
    probing in the request path) **+ `route10_client_info{mac,ip,host,name}`**
    (live local read of dhcp.leases + lan-probe.targets — the name half of the
    WiFi join: `ax73_sta_*` joins `on(mac) group_left(name)`; mac UPPERCASED to
    byte-match ax73 labels, `host` byte-matches `route10_host_flows`). Shared value — governed by ops
    `NETWORK-CONTRACT.md` §"route10 metrics scrape"; ops scrapes every 2 min,
    trending telemetry ONLY (dies with the LAN; the `/cfg` + `/a` records are
    the outage complement). Source: `scripts/metrics-cgi.sh`.
  - Syslog app names **`route10.odi-health` and `route10.dhcp-watchdog` are
    FROZEN** — ops's `Route10SyslogSilent` dead-man alert keys on their absence
    (contract-recorded). Never rename/retire them without telling ops first.
  - The connlimit log prefixes **`route10.connlimit warn: v4|v6` and
    `block: v4|v6` are FROZEN** (2026-08-10) — four ops rules key on the family
    tag; drop or rename it and all four match nothing, never fire, never error.
    Same class as the app names above. **Extend, never rename in place**: the
    family was appended AFTER the colon precisely so `route10.connlimit warn: `
    stayed an intact substring and ops could migrate with no coverage gap.
  - `route10_host_flows{family,host,ip}` on `/metrics` carries **verbatim,
    uncurated DHCP hostnames** (operator decision 2026-08-10 — private LAN, and a
    masked offender list is worth less than an honest one). They reach ops's
    Prometheus labels and phone notifications. Query on `host`, not `ip`: v6
    label values churn as SLAAC privacy addresses rotate.
- `/cfg/scripts/tailscale-reconcile.sh` — single owner of the **firmware-native
  Tailscale** integration (Alta's 2026-07-22 firmware auto-update ships
  `/usr/sbin/tailscaled` 1.98.4-1 + uci `/etc/config/tailscale`; NOT cloud-modeled,
  NOT rc.d-enabled — nothing runs it unless we do). Converges: uci (state under
  `/cfg/tailscaled.state`, **`login_url` from seam.env `TS_LOGIN_URL`** — the
  2026-08-07 firmware added that option defaulting to Tailscale SaaS and the init
  LOGS THE NODE OUT whenever live `.ControlURL` != uci value, so we must set it in
  the uci-intent pass *before* the daemon is started; absent ⇒ warn, don't guess,
  exit-node + routes = LAN /24 derived from br-lan + ULA
  /64 from seam.env, daemon logs silenced — the Alta build dumps its full verbose
  stream to stderr), daemon via the FIRMWARE init (stop/settle/start for
  daemon-level changes; `reload` for routes), tailscale0 firewall accepts + NAT
  both families (fw3 reloads flush them; our inserted v6 MASQUERADE shadows the
  pinned-GUA SNAT Alta's daemon appends), br-lan GRO off, **and the dnsmasq
  tailscale0 listener** (`dhcp.@dnsmasq[0].interface` — off-LAN split-DNS; the
  entry is ours, so an Alta apply that regenerates `/etc/config/dhcp` drops it
  and restarts dnsmasq AFTER post-cfg completed, which killed off-LAN split-DNS
  for ~20 h on 2026-08-14). Idempotent, quiet,
  **no connectivity gate / no revert** (the retired sideload hook's one-ping
  revert caused the 2026-07-22 outage). Called by post-cfg (every boot/reapply)
  and mesh-health (heal). The old sideload (`/a/tailscale` + fork
  `alta-route10-tailscale`) is RETIRED. Log: `/cfg/scripts/ts-reconcile.log`.
  Source: `scripts/tailscale-reconcile.sh`. See `project_route10_native_tailscale.md`.
- `/cfg/scripts/heartbeat.sh` — `*/2` cron, no daemon. **External dead-man → healthchecks.io**
  (LIVE 2026-08-09, verified green both ends). Sends **two** checks: *Router + internet*
  (unconditional) and *Router's home network* (`lan_ok`). Counterpart to ops's *Home server
  + alerting*: theirs alone stopping means their cluster, both stopping means router/WAN.
  **The emitter is UNCONDITIONAL by design** — gating a send on health turns a bug in the
  health logic into a page saying everything is dead, so the verdict selects only WHICH
  endpoint: `lan_ok=1`→success, `0`→`/fail` (pages at once), `unknown`→`/log` (recorded, no
  page). `lan_ok` = br-lan holds a v4 address AND br-lan rx advancing, read from `/sys`
  directly (never via obs-collect's DB — a dead collector must not be able to make the
  heartbeat lie); rx baseline is in tmpfs, so **the first beat after every reboot is
  honestly `unknown`**. Beats over IPv6 by curl's happy-eyeballs default: v4 has a
  demonstrated CGNAT brownout mode that would manufacture false "everything is dead" pages.
  Warns locally (once, on transition) if its own send fails, so neither side infers health
  from silence. **Ping URLs are CREDENTIALS** — `HC_URL_ALIVE`/`HC_URL_LAN` in
  `/cfg/seam.env` only, never git/contract/seam-channel, passed to curl via **stdin config**
  (`curl -K -`) so they reach neither argv nor disk; absent ⇒ inert + hourly warn.
  ⚠ **It cannot report our own death** — `lan_ok` rides inside our own beat, so the
  2026-08-08 shape (IP stack dark, ASIC still forwarding) sends nothing at all and is
  indistinguishable from a power cut. Closing that needs an observer off route10 (ops, on
  opi5pro); it is forensics, not detection. Log: `/cfg/scripts/heartbeat.log`. Source:
  `scripts/heartbeat.sh`. **ntfy.sh RETIRED 2026-08-09** — 720/day per beat against a
  250/day free cap, ~3× over on its own; the topic was itself the credential and Kuma
  rendered it into every notification.
- `/cfg/scripts/mesh-health.sh` — `*/5` cron, no daemon. Tailscale mesh DRIFT smoke
  tests + SELF-HEAL (quiet when healthy; WARN + heal via tailscale-reconcile.sh
  where route10-local): (1) tailscaled running, not a stale/DELETED binary,
  running-version == on-disk; (2) live `AdvertiseRoutes` == intended set, derived
  INDEPENDENTLY of prefs (br-lan + seam.env) — catches the firmware-init
  boot-time route reset (2026-07-22 class); (3) compiled ACL filter admits every
  advertised subnet route, asserted on DSTs never SRCs (2026-07-20 stale-daemon
  class; QUIET on Alta's slimmed build — `debug netmap` is compiled out/404);
  (4) tailscale0 firewall accepts + NAT present in both families (fw3-flush
  class); (5) node still carries its ops ACL tag (2026-08-07 untagged-rejoin
  class; server-side, WARN only); (6) dnsmasq BOUND on `:53` at the tailnet
  addresses — asserts the outcome, not the uci entry (2026-08-14 cloud-regen
  class: ~20 h of dead off-LAN split-DNS that every other assertion on both
  sides missed; heal via reconcile step 5).
  Log: `/cfg/scripts/mesh-health.log`. Source: `scripts/mesh-health.sh`.
  See `project_route10_tailscale_stale_binary_filter.md`, `project_route10_native_tailscale.md`.
- `/cfg/post-cfg.sh` — runs after every Alta cloud-config reapply. Source:
  `scripts/post-cfg.sh`. **Idempotent**. Jobs:
  1. **MACVLAN mgmt-path** (`ont_mgmt0` on eth4, `192.168.1.2/24`,
     `ont_mgmt` firewall zone forward=REJECT) — see
     `reference_alta_macvlan_mgmt_pattern.md`.
  2. **eth4 MAC override** to `02:11:22:33:44:56` — locally-administered MAC
     that the ISP BNG has never seen, used to dodge stale-session-by-MAC
     wedges. See `project_pppoe_stale_session_mac_swap.md`.
  3. **pppd LCP-echo loosened** for `wan` (eth3 / Huawei underlay) and `wan3`
     (eth4 / ODI stick underlay) from upstream OpenWrt default `5 1` (5 s
     tolerance) to `5 5` (25 s tolerance). Stops a brief downstream-loss
     burst from killing the PPPoE session.
  4. **mwan3 `flush_conntrack` minimised** on `wan`, `wan2`, `wan3` from
     Alta's `['ifup','ifdown','connected','disconnected']` to upstream-style
     `['ifup','ifdown']` only. Stops mwan3 false-alarms (already rare with
     4-host `reliability=1` track_ip) from nuking live TCP via `conntrack
     -F`. We're effectively single-WAN, so `connected`/`disconnected`
     entries served no defensive purpose.
  5. **Launches daemons** if not running: `odi-health.sh`,
     `daemon-odi-w2-ddm.sh`, `dhcp-watchdog.sh`. Uses
     `setsid nohup … </dev/null` so the daemons survive SSH disconnect.
  6. **Reinstalls the event/cron self-heals** each boot (`/` is tmpfs): the
     `route-defaultroute-hook.sh` ip-up.d symlink + `* * * * *` cron, and the
     `lan-prefix-track.sh` hotplug hook (`/etc/hotplug.d/iface/89-lan-prefix`,
     fires on `ifupdate`) + `* * * * *` cron backstop (stale-IPv6-prefix deprecation).
  7. **Per-host connlimit guard** (`RT10_CONNLIMIT` chain, per-family): caps concurrent
     NEW connections per LAN host on the `br-lan → pppoe-wan3` path (internet-bound
     only; `--ctstate NEW`, so established/LAN/mesh traffic is untouched). REJECT is TCP
     `tcp-reset` / else ICMP `port-unreachable` → client sees "Connection refused", not
     the misleading "Host unreachable". **Per-family thresholds** (two families, two
     jobs): **v4 WARN 300 / BLOCK 500** — tight, the real fix: stops a rogue client
     (torrent swarm) from exhausting the ISP CGNAT NAT-session table and starving
     everyone else's v4 (EHOSTUNREACH); keep BLOCK <~900 (800 caused an outage, CGNAT
     starved at ~1400). **v6 WARN 1000 / BLOCK 2000** — loose, a pure anomaly *smell*
     (route10 conntrack is 500k, never the bottleneck; v6 has no CGNAT): WARN logs a
     wildly abnormal host, BLOCK is a runaway stop that ~never fires; per-/128 so SLAAC
     privacy addresses evade it — fine for a smell, not a hard cap. Thresholds tunable at
     the top of the block. Direct iptables (no fw3 reload → no eth4 flap); `-w` on every
     call (the backgrounded tailscale hook also edits iptables); a per-family marker rule
     gates the rebuild so a re-run doesn't reset the cap mid-flood. See
     `project_route10_cgnat_torrent_exhaustion.md`.
  8. **LAN DNS — route10 as the sole resolver** (`dhcp.@dnsmasq[0]`): forwards
     `strict-order` (allservers off) **AdGuard `.241`/`::241` first → encrypted DoH
     (`127.0.0.1#505x`, Cloudflare/Google/OpenDNS) fallback**. ⚠ **That ordering lives
     in routedns, not in dnsmasq** — dnsmasq's only general upstream is
     `127.0.0.1#5300` (routedns), whose `fail-back` group holds AdGuard as PRIMARY.
     Reading `uci show dhcp` alone therefore makes AdGuard look domain-pinned and
     out of the general path; it is not, and ops misdiagnosed a router incident that
     way on 2026-08-10. **AdGuard is in the path for every LAN query, so an
     opi5pro outage DOES degrade general LAN DNS.** Its blast radius is set by
     `query-timeout`, which must stay STRICTLY below the client stub's total budget
     (musl gives ~5 s): at the old 5 s the fallback answer arrived after the client
     had already given up, i.e. the first query of each retry window was LOST, not
     slow. Now 1 s (AdGuard's measured cache-miss max is 32 ms). Pins `/net.aac.gd/` to
     AdGuard only (inside names SERVFAIL, never leak the `192.0.2.1` stub, if AdGuard is
     down); `add-subnet` (ECS, via a `/tmp/dnsmasq.d` drop-in — no uci mapping on this
     build) so single-box AdGuard keeps per-client identity through the forwarder.
     WAN-safe (`dnsmasq reload` only). Values `$LAN_DNS4`/`$LAN_DNS6`/`$SPLIT_DOMAIN`
     come from `/cfg/seam.env` (contract §LAN DNS delegation), never hardcoded — absent
     ⇒ clean no-op. Clients are pointed here via the **Alta portal DNS-Servers field left
     BLANK** ⇒ router advertises v4 `.1` + v6 **link-local** (`fe80::…`, MAC-derived,
     rotation-proof — NOT the GUA). Tailscale `accept-dns` devices bypass this (MagicDNS:
     split `net.aac.gd`→AdGuard, global→Cloudflare). See `project_route10_dns_resolver.md`.
  9. **LAN NTP server** (`system.ntp.enable_server=1` + `interface='lan'`) — serves
     udp/123 on `192.168.10.1` / the LAN ULA for clients with no battery-backed RTC.
     **LAN-only via two guards**: busybox ntpd binds the server socket to br-lan
     (`-I br-lan`, so it never listens on `pppoe-wan3` — verified: the router's own
     WAN IP and loopback get no answer) *and* the wan zone stays `input=DROP`.
     Side effect of the bind: **mesh (tailscale0) clients are not served** — a host
     that routes the LAN ULA over the tailnet times out; that is deliberate.
     No DHCP option 42 — consumers point at `.1` explicitly. Route10 has **no RTC**
     (`/dev/rtc*` absent), so it serves time only once its own client has synced over
     the WAN. Requested via the seam (contract §LAN time source).

## Observability standard

All `/cfg/scripts` helpers log through `scripts/lib-observability.sh` (deployed to
`/cfg/scripts/lib-observability.sh`). Every message is **dual-sunk**:
- **syslog** — `logger -t route10.<component> -p daemon.<sev>`. busybox syslogd
  writes it to `/var/log/messages` and can forward to the homelab collector via
  `syslogd -R host:port` (uci `system.@system[0].log_ip` — not set yet). This is
  the capture surface for the observability stack.
- **file** — `/cfg/scripts/<component>.log`, size-rotated. Persistent on-box
  forensics (the volatile syslog ring `log_size` is only 64 KiB).

Usage: `. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init <comp> [log] [rotate]`
(with a file-only fallback so a missing lib never breaks a daemon), then `log`
(info), `event` (notice — a state change), `warn`, `err`. Scripts whose file line
exceeds syslog's ~256 B cap (odi-health) send the full line to the file and a
compact subset via `obs_syslog <sev> "msg"` for the syslog side. **hotplug.d hooks
must NOT source the lib** (they are SOURCED into the dispatcher — defining
functions would leak into sibling hooks); they call `logger` inline with the same
`route10.<component>` tag.

**Clocks disagree — always state which you mean.** syslog stamps in
`/var/log/messages` are **UTC**; `date`, `ls -l` and script `date '+%F %T'` output
are **local (UTC-3)**. Reading an `ls -l` mtime and quoting it as UTC is a 3-hour
error — it produced a bogus timeline in the 2026-08-07 mesh incident and an
apparent contradiction with ops's control-plane logs. For an incident timeline
use `/proc/uptime` for boot and `date -u -d @$(stat -c %Y <file>)` for mtimes.

Tag convention `route10.<component>`. On the standard: `prefix-track`, `route-hook`,
`odi-health`, `dhcp-watchdog`, `w2-ddm`, `mesh-health`, `ts-reconcile`, `post-cfg`
(completion heartbeat / ABORTED line — set -e failures are not silent), `routedns`
(daemon stdout piped to logger). crond runs at `cronloglevel 9` (post-cfg asserts
it): busybox level 5 logged every cron exec at cron.err (~4.3k fake-ERROR
lines/day to Loki). tailscaled is SILENCED via uci log flags (its full verbose
stream went to syslog as daemon.err; mesh-health is the health signal). Check:
`ssh route10 'grep route10. /var/log/messages | tail'`.

## Current open investigations

### Perceived intermittent "drops" on wan3 — likely ICMP-only loss to ping.alta.inc

**Status:** active monitor running, evidence captured 2026-05-28 ~21:00 BRT.

**Hypothesis:** Alta's mwan3 tracks `ping.alta.inc` over wan3. The path
ISP→Cloudflare/Alta cache rate-limits ICMP (we already saw this independently:
30–40% loss to 1.1.1.1, clean TCP via the same path). When that ICMP loss
burst lasts >2 mwan3 cycles (~5–8 s), mwan3 marks wan3 as "tracking failed"
(score drops 10→6, lost+=N) and the Alta dashboard fires a "WAN dropped"
alert — **but eth4 byte counters keep ticking, PPP uptime keeps growing, and
the user's actual TCP/UDP traffic is unaffected.**

**Live captured event** (`/tmp/flap-hunt.log` on Route10):
```
20:59:15.271 EVENT mwan_track_loss now=100 lat=999999 (mscore 10→9, lost 0→1)
20:59:17.963                                          (mscore 9→8, lost 1→2)
20:59:20.639                                          (mscore 8→7, lost 2→3)
20:59:23.312                                          (mscore 7→6, lost 3→4)
20:59:25.984 EVENT mwan_lost_changed prev=4 now=0     (full recovery)
```
During those 8 seconds, eth4 RX/TX grew by ~600 MB and PPP uptime kept ticking.
No L1 flap (`carrier_changes` unchanged), no CRC errors, no PPP teardown.

**Monitor (historical):** this was caught by `flap-hunt.sh`, **retired 2026-07-15**
(deletion test — the investigation is resolved). PPP reconnects / mwan3 track-loss
now surface in syslog (`/var/log/messages`); mwan3 state is queryable via
`ubus call mwan3 status`. Old evidence: `/cfg/scripts/flap-hunt.log`.

**Known noise we filtered out:** mwan3's `turn` field ticks every ~5 s — it's a
heartbeat counter, not a state change. flap-hunt.sh ignores it; only enters a
"loss window" when `lost > 0` (real track failure).

**Confirmed root cause (2026-05-28 21:13 capture):**

`ping.alta.inc` resolves to `75.2.70.75` (AWS CloudFront anycast) and IPv6
`2606:4700:4700::1111` (Cloudflare anycast). Both endpoints **aggressively
ICMP-rate-limit** from this ISP path — we measured 40–100% ICMP loss to all
public anycast targets including 1.1.1.1 and 8.8.8.8 during a drop window,
while the PPP gateway (168.195.103.5) stayed 0% loss. The mwan3 config
(via `uci show mwan3`) compounds this:

```
mwan3.wan3.track_ip       = 'ping.alta.inc'
mwan3.wan3.timeout        = 1     # 1s ping timeout
mwan3.wan3.failure_loss   = 10    # >10% loss = failure
mwan3.wan3.down           = 5     # 5 consecutive failures → "down"
mwan3.wan3.flush_conntrack = 'ifup' 'ifdown' 'connected' 'disconnected'
```

At 40% loss rate, P(5 consecutive misses) ≈ 1% per poll cycle = roughly one
false "down" every ~8 minutes. When mwan3 declares wan3 "disconnected", it
**flushes conntrack** — every TCP session on the user's devices dies, even
though eth4/PPP never moved. **That is the perceived "drop".**

Some windows also include a *real* upstream blip (TCP to Cloudflare dropped
from 230–520 Mbit/s to 5 Mbit/s during the 21:13 event; iperf3 control TCP
was reset mid-handshake). So these are not pure measurement artefacts — but
the destructive piece (NAT flush killing existing TCP) comes from mwan3's
false alarm, not the upstream blip.

**Actionable fixes (all require Alta dashboard — config is cloud-mastered):**

| Lever | Effect |
|---|---|
| **Change `track_ip` to `168.195.103.5` (PPP gateway)** | Best fix; only marks down when real L3-to-ISP is gone |
| **Drop `'disconnected'` from `flush_conntrack`** | Existing TCP sessions survive false alarms |
| Raise `down: 5 → 10` or `failure_loss: 10 → 50` | Tolerates ICMP bursts but doesn't fix root |

If Alta dashboard doesn't expose these, the only local path is a watchdog
that re-writes `/var/etc/mwan3.conf` post-cloud-sync — which fights the cloud
reload on every boot. See `project_route10_cloud_config_overwrite.md`.

### 2.5GBASE-X feasibility on W2 (ODI stick) — research phase, no writes yet

Goal: ~1G/500M plan, bufferbloat reduction. Stick & SoC both *capable*.

**Stick:** `flash get LAN_SDS_MODE = 0` (default 1G). Setting to `6`
(2500BASE-X) is the documented path per
https://github.com/Anime4000/RTL960x/blob/main/Docs/2.5Gb.md. FW V1.2.2-221209
is newer than 220923 → auto-revert safety net exists.

**Route10:** `/usr/sbin/route-swd` is a symlink to `black` (multi-purpose
Alta binary). Its mode table contains `sgmii_plus`, `sgmii_fiber`, `10gbase_r`,
`sgmii_baset` — confirmed via `strings`. Decision tree reads
`/cfg/config.json` `.portsCfg.ports.5.speed` (currently `"1000"`) + the cached
SFP EEPROM at `/var/run/.sfp1.bin`. Alta dashboard surface is unconfirmed —
staff publicly say "1G/10G fiber only" but the binary disagrees.

**Bufferbloat reality:** with proper CAKE on `pppoe-wan3` the 1G→2.5G win is
sub-10 µs serialization vs ~1 ms GPON DBA jitter floor. Bigger wins live in
`ethtool -K eth4 gso off tso off gro off lro off` + CAKE `overhead 44 mpu 84
nat ack-filter`. Treat 2.5G as a fun experiment, not a fix.

### 2026-05-28 BNG stale-session outage — RESOLVED via fresh MAC swap

**Sequence:**
1. Early evening: many small `mwan_track_loss` events on the original
   `ping.alta.inc` track-IP (Alta-default cloud config) → conntrack flushes
   killed live TCP sessions (felt like "drops").
2. User changed `monitor.trackIP[0]` in Alta dashboard from `ping.alta.inc`
   to `168.195.103.5` (PPP gateway). Single-host clean from then on. Note: a
   3-IP set with `reliability=1` would be even safer (recommended:
   `168.195.103.5,200.147.67.142,9.9.9.9` — see
   `project_mwan3_anycast_false_drop.md`). Did not happen because Alta UI
   exposure of that field was unclear.
3. At **22:16:40 BRT**, a downstream-loss burst (40–100% to anycast targets,
   plus brief gateway lossiness) caused pppd's `lcp-echo-failure 5 1` to fire
   after 5 missed echoes (5 s threshold) → PPP session terminated **without
   PADT**. The BNG retained the session keyed by `eth4` MAC
   `bc:b9:23:81:97:16` + GPON SN `HWTC370F0BAE` → every pppd redial got
   `AUTH_TOPEER_FAILED`.
4. **Wedge lasted ~2 hours** through stick reboots, MAC clone to Huawei WAN
   MAC, and `ifup` retries. The BNG was too freshly-wedged to release.
5. User swapped fibre to Huawei (eth3 / `wan` interface). Different
   underlying physical ONU re-ranging at the OLT (different RTT, equipment
   ID) + different dialing MAC (`bc:b9:23:81:97:15`, Route10 native eth3 MAC,
   never used before) presented a brand-new subscriber tuple to the BNG.
   PPPoE auth succeeded — public IP `100.68.69.106` / `100.68.129.176` via
   the Huawei.
6. ~1 h after that, the original BNG-side stale session had finally timed
   out. With eth4 MAC set to a fresh locally-administered
   `02:11:22:33:44:56` (provably never seen) and stick re-ranging, swapping
   fibre back to the ODI stick succeeded **in under 10 s** — clean PADO →
   PADS → LCP → CHAP → IP `100.68.86.123`.

**The lessons baked into `post-cfg.sh`:**
- `keepalive='5 5'` (25 s tolerance) on both `wan` and `wan3` so a similar
  loss burst won't kill the PPP session next time.
- Fresh locally-administered eth4 MAC so even if a session does get wedged,
  the BNG never has stale state for our identity.

**Subsequent fixes (2026-05-29) that closed the remaining holes:**
- **4-host `track_ip` with `reliability=1`** in Alta dashboard:
  `168.195.103.5, 200.147.67.142, 9.9.9.9, ping.alta.inc`. All four must
  fail in the same cycle to count as a failure. False-disconnect
  probability collapsed from ~1× per 8 min to ~1× per 19 years.
- **mwan3 `flush_conntrack='ifup','ifdown'`** on all three wan interfaces
  via post-cfg.sh — drops the destructive `'connected'/'disconnected'`
  entries. Belt-and-suspenders against the now-vanishing false alarm
  scenario.
- **`lcp-watch.sh`** LCP miss telemetry (consumed by flap-hunt) — **both retired
  2026-07-15**. In practice it never fired: `lcp-echo-adaptive` suppresses echoes
  on a busy link, so `LCP_SENT` stayed 0 for the link's life. The LCP-disconnect
  failure mode is mitigated by the `5 5` keepalive above; an actual PPP teardown
  still shows in pppd's syslog + odi-health's `pppup` regression.

See: `project_mwan3_anycast_false_drop.md`,
`project_pppoe_stale_session_mac_swap.md`.

### eth4 flap history

dmesg shows ~7 down events over 74h. User confirms most were us debugging in
prior sessions. Most recent flap was the `[248132 → 248198]` event during this
session. **None since** (verified by `carrier_changes` counter). New flaps now
surface in the kernel log / syslog (`eth4: PHY Link is down/up` via klogd →
`/var/log/messages`); odi-health also logs `carrier` each 5-min cycle.

## Useful one-liners

```sh
# Read all stick OMCI MEs + dumps in one telnet session
ssh route10 'python3 /cfg/scripts/stick-exec.py --json \
    "omcicli mib get 262" "omcicli mib get 268" "omcicli mib get 280" \
    "omcicli dump qmap" "omcicli dump conn" "omcicli mib getalm"'

# Latest stick DDM (from i2c slave the daemon writes)
ssh route10 'cat /var/run/.sfp1ddm.json'

# Quick mwan3 wan3 health snapshot
ssh route10 "ubus call mwan3 status" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps(d["interfaces"]["wan3"],indent=2))'

# Switch Rx-error/CRC watch (folded into odi-health; warns on growth)
ssh route10 'tail -2 /cfg/scripts/odi-health.log | grep -oE "crc_[a-z]+=[^ ]+"'

# Verify all four post-cfg.sh overrides are sticky
ssh route10 'echo "eth4_mac:        $(cat /sys/class/net/eth4/address)"
             echo "wan_keepalive:   $(uci -q get network.wan.keepalive)"
             echo "wan3_keepalive:  $(uci -q get network.wan3.keepalive)"
             echo "wan_flush:       $(uci -q get mwan3.wan.flush_conntrack)"
             echo "wan2_flush:      $(uci -q get mwan3.wan2.flush_conntrack)"
             echo "wan3_flush:      $(uci -q get mwan3.wan3.flush_conntrack)"'

# Reboot stick (~80s blip — kills internet, see feedback_internet_path_single_fiber.md before doing)
ssh route10 'curl --http0.9 -s --interface 192.168.1.2 -m 5 -u admin:admin -X POST http://192.168.1.1/boaform/admin/formReboot'

# All script observability in one place (syslog, route10.* tags → homelab stack)
ssh route10 'grep " route10\." /var/log/messages | tail -20'
ssh route10 'grep " route10\.odi-health" /var/log/messages | tail'   # one component

# LAN prefix-rotation self-heal — last-seen /64 + any deprecation events
ssh route10 'cat /cfg/scripts/.lan-prefix.env; tail -3 /cfg/scripts/prefix-track.log 2>/dev/null'

# Manually deprecate a stale LAN /64 to every device (what the cron does on rotation)
ssh route10 'python3 /cfg/scripts/ra-deprecate.py 2804:2488:XXXX:YYYY::/64 br-lan 3'

# Check a client (macOS) for a deprecated/stale prefix
ifconfig en13 inet6 | grep -E "deprecated|inet6 2"   # `deprecated` flag = router told it to stop
```

## Current operational state (as of 2026-05-29)

| Item | Value | Notes |
|---|---|---|
| WAN path | wan3 via ODI stick in W2 | Stick is primary; Huawei is the manual swap-target backup |
| Public IP | dynamic via PPPoE | PPP uptime stable since 2026-05-28 23:22 BRT |
| eth4 MAC | `02:11:22:33:44:56` | locally-administered, BNG-fresh; persisted via post-cfg.sh |
| Stick spoofed SN | `HWTC370F0BAE` (Huawei) | persisted in stick flash; see `project_odi_mac_key_fix.md` |
| Stick optical | Tx +2.3 dBm, Rx −17.3 dBm | healthy |
| pppd LCP keepalive | 5 misses × 5 s = 25 s tolerance | wan + wan3 both |
| mwan3 track_ip | 4 hosts, `reliability=1` | 168.195.103.5, 200.147.67.142, 9.9.9.9, ping.alta.inc |
| mwan3 flush_conntrack | `ifup`, `ifdown` | `connected`/`disconnected` removed via post-cfg.sh |
| odi-health | running | `/cfg/scripts/odi-health.log`, 5 min cadence; carries switch CRC (flap-hunt folded in) |
| W2 DDM daemon | running | populates Alta dashboard DDM |
| flap-hunt / lcp-watch | RETIRED 2026-07-15 | deletion test — redundant; CRC folded into odi-health |
| lan-prefix-track | cron (`* * * * *`) | deprecates a rotated-away LAN /64; state `/cfg/scripts/.lan-prefix.env`, log `/cfg/scripts/prefix-track.log` |

## Cross-repo seam with `ops` (homelab)

This router is co-managed by two repos with two agents: **this one** (`route10`)
and the homelab GitOps platform **`~/git/ops`**. They share exactly one seam.

- **Shared source of truth: `ops/NETWORK-CONTRACT.md`** (in the `ops` repo root)
  — LAN VIPs, the site ULA prefix, advertised mesh routes, Headscale ACL tags.
  Don't duplicate those values here; reconcile the router to them.
- **Contract-first:** to move any shared value, change `NETWORK-CONTRACT.md`
  first, then reconcile the router. Never move the seam unilaterally, and never
  edit `ops` manifests from here (the ops side likewise never writes router
  config — only read-only inspection, respecting the hard rules below).
- **Router-side asks land via Alta dashboard or `post-cfg.sh`** (not bare `uci` —
  cloud sync wipes it). Router work is tracked on *this* side, not ops `INFRA-*`.
- Full mirror rule: [`docs/reference/mesh-seam.md`](docs/reference/mesh-seam.md)
  (mirrors `ops/.claude/rules/mesh-seam.md`). Design rationale:
  [`docs/reference/declarative-config-and-coordination.md`](docs/reference/declarative-config-and-coordination.md).
- **Pending router-side asks live in the contract, not here** — as of
  2026-07-14: a LAN-ULA RA on br-lan and a DHCP-pool reservation for the VIP
  range. Values in `ops/NETWORK-CONTRACT.md` only; never mirror them into
  committed files (a second copy is a second authority). Working detail may
  live in session memory. INFRA-68 (Route10 joins the Headscale mesh as
  subnet-router) is the ops-side umbrella.

## Hard rules (don't break)

- Never call the ISP. (`feedback_no_isp_calls.md`)
- Never write to ssdk port 6 — L4 BiDi is production office uplink. (`project_route10_cage_layout.md`)
- Ask before killing pppd / rebooting stick / running `stick-mgmt.sh on` —
  single fiber, WAN3 is the only internet path. (`feedback_internet_path_single_fiber.md`)
- Use `stick-exec.py`, never raw telnet, never banner-only probes. (`project_odi_cli_pid_lock.md`)
- Local `/cfg/config.json` edits are ephemeral — cloud overwrites on boot.
  Persistent changes must go through Alta dashboard or a watchdog.
  (`project_route10_cloud_config_overwrite.md`)
- Never edit `ops` repo config, and never move a shared LAN/mesh value without
  changing `ops/NETWORK-CONTRACT.md` first. (see "Cross-repo seam with `ops`"
  above / `docs/reference/mesh-seam.md`)
