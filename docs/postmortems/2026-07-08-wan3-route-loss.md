# Post-mortem — 2026-07-08 wan3 default-route loss on PPP reconnect (whole-LAN blackhole)

**Status:** root cause **CONFIRMED** (netifd `proto_set_keep`); **fixed at the source path** with
an `/etc/ppp/ip-up.d/` hook + cron backstop (`scripts/route-defaultroute-hook.sh`), installed by
`post-cfg.sh`; validated end-to-end (v4 + v6). No daemon.

**One-line:** Each time the PPPoE session (`wan3`) reconnects — which the ISP forces every
~25–45 min on a bad day — netifd fails to reinstall the IPv4/IPv6 **default route** into the
`main` table, so every LAN client loses internet even though the WAN/PPP is up. A small hook
re-asserts the route on every link-up (with a 1-min cron backstop); mwan3 then repopulates its
own forwarding table.

Sibling incident on the same box: [`2026-06-24-power-surge-dhcp.md`](2026-06-24-power-surge-dhcp.md)
(different failure — a mute dnsmasq).

---

## 1. Symptom

- Internet drops for the **whole LAN** (WiFi + wired), recurring. Each outage coincides with a
  PPPoE reconnect (new public IP).
- Route10's **WAN is healthy** throughout: `pppoe-wan3` up, byte counters ticking, `ping -I
  pppoe-wan3 1.1.1.1` 0% loss, Alta portal shows the router online.
- But **no default route** in `main` (v4 *or* v6), and mwan3's per-interface table (fwmark
  `0x300` → table 3) is empty → forwarded LAN traffic hits mwan3's `unreachable` fallback rule.
- Recovered only by re-adding the route by hand (`ip route add default …`) or a reboot.
  `ifup wan3` does **not** fix it.

Tell-tale: a router-sourced `ping -I pppoe-wan3` succeeds (uses the interface peer route) while a
LAN-sourced / forwarded ping fails — the WAN is fine, forwarding is blackholed.

---

## 2. Timeline (2026-07-08, from `/cfg/scripts/flap-hunt.log` — logread is volatile/empty here)

| Time (BRT) | Event | Evidence |
|---|---|---|
| ≤13:11 | `wan3` up **13.7 days** continuous, healthy | `pppup=1184870` climbing |
| **13:14:45** | ISP burst: 100% loss to all 4 mwan3 track IPs → PPP reset | `EVENT mwan_track_loss_begin loss%=100`; `pppup→93` |
| 13:30, 13:59 | Two more ISP bursts → PPP resets (new public IPs each time) | `pppup` resets `1476→71` @14:01 |
| this session | After each reset: `main` + mwan3 table 3 **empty**; LAN blackholed; re-add default → restored | `ip route show table all \| grep default` empty |
| | Root cause traced to netifd `proto_set_keep` (see §3); fix built + deployed + validated | — |

The ISP flapping is **upstream and out of our control**; the fixable defect is that the reconnect
leaves no default route.

---

## 3. Root cause — CONFIRMED (netifd `proto_set_keep`)

netifd runs pppd with `ip-up-script /lib/netifd/ppp-up`, which on every IPv4CP-up does
`proto_init_update … ; proto_set_keep 1 ; proto_add_ipv4_route 0.0.0.0 0 $IPREMOTE ;
proto_send_update`. So netifd **is** told to add the default route on every link-up. Yet the
kernel route is missing after a reconnect. Why (confirmed in netifd source):

- With **`keep=1`**, `interface_update_start()` **skips** `interface_ip_update_start()`, so
  netifd does **not** mark its cached routes stale across the update.
- On reconnect the kernel had already purged the default route (the ppp device dropped →
  `RTM_DELROUTE`), but netifd's **cache still says it's installed**.
- When `ppp-up` re-declares the *byte-identical* route, the diff sees `old == new`
  (`nexthop`/`mtu` match, and our peer gateway is the **stable** `168.195.103.5`), sets its local
  `keep=true`, and **skips `system_add_route()`**. Cache and kernel diverge; the route stays gone.

This exactly matches the fingerprint: **works on fresh boot** (empty cache), **missing after
reconnect**, and **not fixed by `ifup wan3`** (re-runs with `keep=1`; only `ifdown+ifup` or a
manual `ip route` clears it). The precondition is a *stable* peer gateway — which is why we hit
it and dynamic-peer PPPoE users don't. Same class as pfSense #6495, OpenWrt forum "lose default
route with PPPoE upstream", netifd #20688.

**IPv6 is the same family:** no v6 default route after reconnect either (peer LL
`fe80::2e4:6ff:fe8a:3f10`), so LAN clients lose their v6 gateway.

---

## 4. Why the *whole LAN* dies (mwan3 is a mirror, not the cause)

mwan3 (2.11.16) routes forwarded LAN traffic by fwmark `0x300` → table 3 (wan3). `mwan3rtmon`
(running) **mirrors `main` → table 3** and owns that table per its tracker. With `main` empty,
mwan3rtmon has nothing to mirror → table 3 empty → forwarding blackholed. So **the `main`-table
miss is the whole bug**; fix `main` and mwan3rtmon repopulates table 3 on its own (~6 s,
verified). Forcing table 3 by hand fights mwan3 (it flushes manual edits while its tracker is
down), so the fix touches `main` only.

---

## 5. What it is NOT

- **Not the ISP** (beyond triggering the reconnect): WAN/PPP healthy each time.
- **Not mwan3's fault**: it faithfully mirrors an empty `main`.
- **Not fixable by firmware**: box is on Alta **1.5b** / OpenWrt 21.02.1 / netifd 2021 — already
  past Alta's 1.4x "multi-WAN not adding default routes" fix; the bug persists (it's fundamental
  netifd behavior Alta hasn't changed). Reported-worthy to Alta (staff engage and even deploy
  persisted SSH scripts themselves), but not a fix we can wait on.
- **Not our `post-cfg` `network reload`**: post-cfg only runs at boot/cloud-reapply, not on
  runtime reconnects. (An earlier hypothesis that `network reload` tore down wan3 was a
  *confounded* observation — a coincident ISP flap; a plain `network reload` reconfigures only
  the changed interface.)

---

## 6. The fix — `scripts/route-defaultroute-hook.sh` (hook + cron, no daemon)

ONE stateless script, installed two ways by `post-cfg.sh` on every boot (`/` is tmpfs):

1. **`/etc/ppp/ip-up.d/50-route10-defaultroute`** (symlink) — pppd runs it on **every** link-up
   (v4 via `/lib/netifd/ppp-up`, v6 via `ppp6-up`), instantly, with the gateway in env
   (`IPREMOTE` / `LLREMOTE`). It runs **after** `proto_send_update`, and netifd will **not**
   clobber it (netifd believes the route exists, so issues no add/del for the session).
2. **cron `* * * * *`** — the same script as a backstop; with no env it discovers the active
   `pppoe-*` iface and derives the gateway itself.

It does `ip route replace default via <gw> dev <if>` for **`main` only** (v4 + v6), acting only
when the route is actually missing (idempotent, silent when healthy). Log:
`/cfg/scripts/route-hook.log` (`(link-up)` vs `(backstop)` records which caller fired — telemetry
for whether the pppd path ever misses).

**Why this shape:** event-driven = instant recovery; no long-running daemon to supervise; cron
reuses the crond already running; `main`-only lets mwan3rtmon own table 3 (its job). This
replaced an earlier polling `route-watchdog.sh` daemon (built mid-investigation, then retired to
cut footprint — one stateless hook beats a while-loop daemon).

### Validation (2026-07-08)
- Delete `main`+table3+v6 → hook restores `main`+v6 instantly → mwan3rtmon repopulates table 3 in
  ~6 s → LAN→internet **0% loss**.
- Both callers proven: manual env-mode (link-up) and no-env (backstop) both restore.
- Cron proven **live** — a `(backstop)` log entry fixed the real, currently-missing v6 default on
  schedule.

---

## 7. IPv6

- **Default route: FIXED** by the hook (`::/0 via fe80::2e4:6ff:fe8a:3f10 dev pppoe-wan3`). LAN
  RA is served by **dnsmasq** here (odhcpd not running), which then advertises us as the v6
  gateway again.
- **Stale `/64`s** accumulating on `br-lan` are **cosmetic**: they're already `deprecated` and
  age out; the current PD's `/64` is the active one. Truly *withdrawing* old prefixes from
  clients needs newer odhcpd (RFC 9096 + `piodir`) — a **firmware limit**, not scriptable here.
  Not worth chasing.

---

## 8. Action items

| # | Action | Status |
|---|---|---|
| 1 | `route-defaultroute-hook.sh` (ip-up.d + cron) fixes v4+v6 default on reconnect | ✅ deployed + validated 2026-07-08 |
| 2 | `post-cfg.sh` installs the hook symlink + cron line each boot | ✅ deployed |
| 3 | Retire the interim `route-watchdog.sh` daemon | ✅ killed + removed |
| 4 | Report the netifd `proto_set_keep` PPPoE-reconnect bug to Alta (forum.alta.inc) | TODO (optional) |
| 5 | IPv6 stale-prefix client withdrawal | ⛔ firmware limit (newer odhcpd) — not pursued |
| 6 | Watch `route-hook.log` — if only `(link-up)` entries appear (never `(backstop)`), the pppd hook is sufficient and cron could be dropped | monitor |

---

## 9. Playbook

```sh
# Is the default route missing after a reconnect? (the failure signature)
ssh route10 'ip route show default; ip -6 route show default'         # empty = blackholed
# Manual fix (or just run the hook in backstop mode):
ssh route10 '/cfg/scripts/route-defaultroute-hook.sh'
ssh route10 'ip route replace default via 168.195.103.5 dev pppoe-wan3'   # raw v4
# Prove a LAN client (not just the router) reaches the net — router-sourced ping lies:
sudo route -n add 1.1.1.1 192.168.10.1 && ping -c3 1.1.1.1 && sudo route -n delete 1.1.1.1
# When did the hook fire, and which caller?
ssh route10 'tail /cfg/scripts/route-hook.log'
# PPP flap history (persistent; logread is volatile):
ssh route10 'grep EVENT /cfg/scripts/flap-hunt.log | tail -20'
```
