# route10

Operational home for the **Route10** edge router (Alta IPQ9574) — the Brazilian-residential
GPON path, its boot-fixup scripts, monitoring daemons, and incident post-mortems.

## Layout
- `scripts/` — scripts deployed to Route10 under `/cfg/...`.
  - `post-cfg.sh` (→ `/cfg/`) runs after every Alta cloud-config reapply — idempotent
    boot-fixup + daemon launcher (the cloud master overwrites local `uci`/`config.json` on
    boot, so persistent fixes live here).
  - Daemons launched by `post-cfg.sh` (→ `/cfg/scripts/`): `odi-health.sh` (5-min health:
    PPP/RTT/thermals/DDM), `flap-hunt.sh` (2 s sub-minute event catcher), `lcp-watch.sh`
    (PPPoE LCP-echo headroom telemetry), `daemon-odi-w2-ddm.sh` (Boa→i2c bridge that surfaces
    the W2 stick DDM in the Alta dashboard), `dhcp-watchdog.sh` (detects & restarts a mute
    dnsmasq — the 2026-06-24 surge mode).
  - `route-defaultroute-hook.sh` (`post-cfg.sh` symlinks it into `/etc/ppp/ip-up.d/` + a
    1-min cron backstop) re-asserts the WAN default route (v4+v6) netifd drops on a PPPoE
    reconnect (the 2026-07-08 mode) — no daemon.
  - `stick-exec.py` (→ `/cfg/scripts/`) — clean-exit telnet wrapper for OMCI commands on the
    ODI stick (`ssh route10 'python3 /cfg/scripts/stick-exec.py --json "omcicli …"'`).
- `tools/` — local dev tooling (not deployed). `deploy-preflight.sh` validates a script
  against Route10's busybox **ash** before you copy it to `/cfg` (authoritative `sh -n` runs
  on the router itself). `dhcp-probe.py` injects a DHCP DISCOVER on `br-lan` to test for a mute
  dnsmasq. `diag-drive.py`, `stick-relay.py`, `oneshot.py`, `cutover-monitor.sh`,
  `poke-monitor.sh` — stick-debug / cutover helpers from the fiber-migration effort.
- `docs/postmortems/` — incident write-ups. `docs/reference/` — ODI-stick / mwan3 / IPv6 /
  hardware reference notes. `docs/runbooks/` — step-by-step procedures (e.g. the ODI PPPoE
  bring-up recipe).
- `archive/` — one-time recon captures, cutover logs, and pre-reboot backups from the
  2026-05 stick-flashing effort (kept for provenance, not maintained).

## Quick facts
- LAN `192.168.10.0/24`; gateway + DNS = `192.168.10.1` (dnsmasq). WAN = PPPoE `wan3` via the
  ODI GPON stick in the W2 cage (eth4). LAN uplink to the office = `eth5` (10G fiber).
- Reach it: `ssh route10`. Persistent logs: `/cfg/scripts/*.log`. DHCP leasefile:
  `/cfg/dhcp.leases`.
- Post-mortems: [`2026-06-24-power-surge-dhcp.md`](docs/postmortems/2026-06-24-power-surge-dhcp.md)
  (topology, power domains, the dnsmasq-mute incident) and
  [`2026-07-08-wan3-route-loss.md`](docs/postmortems/2026-07-08-wan3-route-loss.md)
  (netifd drops the default route on PPPoE reconnect → whole-LAN blackhole).
