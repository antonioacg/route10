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
  thermal zones, L4 BiDi DDM, W2 stick DDM (read from cache, no Boa session).
  Log: `/cfg/scripts/odi-health.log`. Source: `scripts/odi-health.sh`.
- `/cfg/scripts/flap-hunt.sh` — 2 s tick, EVENT-only log + 5 min heartbeat.
  Catches sub-minute events `odi-health` misses: eth4 carrier flap, PPP
  reconnect, mwan3 track-loss windows, switch-MIB CRC growth (30 s sample),
  stick Boa liveness fail (30 s probe), **LCP miss streaks** (consumes
  `/var/run/.lcp-state.env` from `lcp-watch.sh`). Log:
  `/cfg/scripts/flap-hunt.log` (rotates at 5 MiB). Source:
  `scripts/flap-hunt.sh`.
- `/cfg/scripts/lcp-watch.sh` — event-driven `pppoe-wan3` LCP-echo headroom
  monitor. tcpdump filters protocol `0xc021` only; near-zero CPU under
  load thanks to `lcp-echo-adaptive`. State at `/var/run/.lcp-state.env`
  (constant-size, atomically overwritten — no log growth). Tracks
  `LCP_SENT / LCP_REPLIED / LCP_MISSED / LCP_CUR_STREAK / LCP_MAX_STREAK`.
  flap-hunt.sh emits `EVENT lcp_miss_streak=N` when streak grows. Source:
  `scripts/lcp-watch.sh`.
- `/cfg/scripts/daemon-odi-w2-ddm.sh` — every 5s: polls stick `/status_pon.asp`
  via Boa, encodes per SFF-8472, writes to i2c-1 0x51. Surfaces W2 stick DDM in
  Alta dashboard. See `reference_odi_ddm_blocker.md`.
- `/cfg/scripts/lan-prefix-track.sh` — hotplug `ifupdate` event (instant) +
  `* * * * *` cron backstop, no daemon. State-diffs br-lan's GUA /64 in
  `/var/run/.lan-prefix.env`; on an ISP prefix rotation it deprecates the OUTGOING
  /64 to all LAN nodes via `ra-deprecate.py` (multicast RA, preferred **and** valid
  lifetime 0 per RFC 9096). The event hook is `/etc/hotplug.d/iface/89-lan-prefix`
  → `scripts/hotplug-lan-prefix.sh`. dnsmasq stops advertising a rotated-away prefix but
  never deprecates it (the rotation coincides with a dnsmasq restart that wipes
  its memory), so clients would otherwise stay stuck on the dead /64 as a
  *preferred* address for up to 24 h. Quiet when healthy. Log:
  `/cfg/scripts/prefix-track.log`. Sources: `scripts/lan-prefix-track.sh` +
  `scripts/ra-deprecate.py`. See `project_route10_stale_ipv6_prefix.md`.
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
     `daemon-odi-w2-ddm.sh`, `lcp-watch.sh`, `flap-hunt.sh`. Uses
     `setsid nohup … </dev/null` so the daemons survive SSH disconnect.
  6. **Reinstalls the event/cron self-heals** each boot (`/` is tmpfs): the
     `route-defaultroute-hook.sh` ip-up.d symlink + `* * * * *` cron, and the
     `lan-prefix-track.sh` hotplug hook (`/etc/hotplug.d/iface/89-lan-prefix`,
     fires on `ifupdate`) + `* * * * *` cron backstop (stale-IPv6-prefix deprecation).

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
(info), `event` (notice — a state change), `warn`, `err`. Scripts that own a
special file format (flap-hunt's ms lines) call `obs_syslog <sev> "msg"` for the
syslog side only. **hotplug.d hooks must NOT source the lib** (they are SOURCED
into the dispatcher — defining functions would leak into sibling hooks); they
call `logger` inline with the same `route10.<component>` tag.

Tag convention `route10.<component>`. On the standard: `prefix-track`, `route-hook`,
`odi-health`, `dhcp-watchdog`, `flap-hunt`, `w2-ddm` (`lcp-watch` writes only a
state file, no log). Check: `ssh route10 'grep route10. /var/log/messages | tail'`.

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

**Monitor:** `/cfg/scripts/flap-hunt.sh` (persistent). EVENT-only logging at
`/cfg/scripts/flap-hunt.log`. Tail with `ssh route10 'tail -F /cfg/scripts/flap-hunt.log'`.

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
- **`lcp-watch.sh`** event-driven LCP miss telemetry consumed by
  flap-hunt.sh. Will catch any future near-disconnect (streak ≥ 1) before
  pppd actually terminates. `LCP_MAX_STREAK` is the persistent watermark
  for "how close did we ever come."

See: `project_mwan3_anycast_false_drop.md`,
`project_pppoe_stale_session_mac_swap.md`.

### eth4 flap history

dmesg shows ~7 down events over 74h. User confirms most were us debugging in
prior sessions. Most recent flap was the `[248132 → 248198]` event during this
session. **None since** (verified by `carrier_changes` counter). If new flaps
appear, the monitor will catch them as `EVENT eth4_carrier_changed`.

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

# Tail the flap monitor
ssh route10 'tail -F /cfg/scripts/flap-hunt.log'

# LCP-echo headroom snapshot — "how close did we come to disconnect?"
ssh route10 'cat /var/run/.lcp-state.env'
#   LCP_SENT=N        # total Echo-Requests pppd has emitted on pppoe-wan3
#   LCP_REPLIED=N     # total Echo-Replies received
#   LCP_MISSED=N      # cumulative misses (request-without-reply pairs)
#   LCP_CUR_STREAK=N  # current consecutive misses (0 = healthy)
#   LCP_MAX_STREAK=N  # all-time peak streak (≥5 would have killed pppd)

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
ssh route10 'grep " route10\.flap-hunt" /var/log/messages | tail'   # one component

# LAN prefix-rotation self-heal — last-seen /64 + any deprecation events
ssh route10 'cat /var/run/.lan-prefix.env; tail -3 /cfg/scripts/prefix-track.log 2>/dev/null'

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
| flap-hunt | running | `/cfg/scripts/flap-hunt.log`, includes LCP telemetry |
| lcp-watch | running | `/var/run/.lcp-state.env`, near-zero CPU |
| odi-health | running | `/cfg/scripts/odi-health.log`, 5 min cadence |
| W2 DDM daemon | running | populates Alta dashboard DDM |
| lan-prefix-track | cron (`* * * * *`) | deprecates a rotated-away LAN /64; state `/var/run/.lan-prefix.env`, log `/cfg/scripts/prefix-track.log` |

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
