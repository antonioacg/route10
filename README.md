# route10

Operational home for the **Route10** edge router (Alta IPQ9574) — the Brazilian-residential
GPON path, its boot-fixup scripts, monitoring daemons, and incident post-mortems.

> **Migration in progress.** This repo starts with the 2026-06-24 power-surge / DHCP effort
> (post-mortem + the `post-cfg.sh` fix). More Route10 scripts, daemons, and notes land here
> as they're migrated in.

## Layout
- `scripts/` — scripts deployed to Route10 under `/cfg/...`. `post-cfg.sh` (→ `/cfg/`) runs
  after every Alta cloud-config reapply (idempotent boot-fixup + daemon launcher; the cloud
  master overwrites local `uci`/`config.json` on boot, so persistent fixes live here).
  `dhcp-watchdog.sh` (→ `/cfg/scripts/`) detects & auto-restarts a mute dnsmasq (the
  2026-06-24 surge failure mode) by watching `br-lan` for the "many requests, zero replies"
  signature; launched by `post-cfg.sh`.
  `route-defaultroute-hook.sh` (→ `/cfg/scripts/`; `post-cfg.sh` symlinks it into
  `/etc/ppp/ip-up.d/` and adds a 1-min cron backstop) re-asserts the WAN default route (v4+v6)
  that netifd drops on a PPPoE reconnect (the 2026-07-08 failure mode) — no daemon.
- `tools/` — local dev tooling (not deployed). `deploy-preflight.sh` validates a script
  against Route10's busybox **ash** before you copy it to `/cfg` — the authoritative check
  runs `sh -n` on the router itself (macOS `/bin/sh` accepts bashisms ash rejects).
  Run: `tools/deploy-preflight.sh scripts/post-cfg.sh`. `dhcp-probe.py` injects a DHCP DISCOVER
  on `br-lan` from the router to test for a mute dnsmasq (`ANSWERED` / `NO_REPLY`).
- `docs/postmortems/` — incident write-ups.

## Quick facts
- LAN `192.168.10.0/24`; gateway + DNS = `192.168.10.1` (dnsmasq). WAN = PPPoE `wan3` via the
  ODI GPON stick in the W2 cage (eth4). LAN uplink to the office = `eth5` (10G fiber).
- Reach it: `ssh route10`. Persistent logs: `/cfg/scripts/*.log`. DHCP leasefile:
  `/cfg/dhcp.leases`.
- Post-mortems: [`2026-06-24-power-surge-dhcp.md`](docs/postmortems/2026-06-24-power-surge-dhcp.md)
  (topology, power domains, the dnsmasq-mute incident) and
  [`2026-07-08-wan3-route-loss.md`](docs/postmortems/2026-07-08-wan3-route-loss.md)
  (netifd drops the default route on PPPoE reconnect → whole-LAN blackhole).
