# Alta-blessed mgmt-path pattern — MACVLAN child on eth4 (DEPLOYED 2026-05-25)

*Replacement for `/cfg/scripts/stick-mgmt.sh`. A MACVLAN child interface on eth4 coexists with PPPoE on the same parent. Deployed at `/cfg/post-cfg.sh`; idempotent; verified via 4 clean odi-health cycles. User chose Level-1 restriction — reachable ONLY from Route10 root (no lan→ont_mgmt forwarding).*

**Deployment verified 2026-05-25:** `/cfg/post-cfg.sh` is live; re-running it is idempotent (exits 0, no flap); `ont_mgmt0@eth4` carries `192.168.1.2/24`; `firewall.ont_mgmt` zone present with input/output ACCEPT and forward REJECT; WAN3 PPPoE unaffected during/after deploy; stick reachable at 0.7–1.5ms ping. odi-health.sh's `restore_mgmt()` was simplified to a 2-line self-heal that re-runs `/cfg/post-cfg.sh` only if `ont_mgmt0` is missing.

**Script-writing gotcha (caused the first deploy to half-fail):**
With `set -e`, the line `uci -q delete firewall.ont_mgmt.network` returns non-zero when the list doesn't exist yet (even with `-q`), aborting the script and leaving the firewall zone half-configured (only `name` field saved). Fix: append `2>/dev/null || true`. Pattern is in the deployed file.


**Source:** Alta staff `Alta-MikeD` in [forum.alta.inc/t/4589 (Was-110 setup on Route10)](https://forum.alta.inc/t/was-110-setup-on-route10/4589), posts 36/45/48/51. Confirmed working alongside PPPoE by jcolp #49, Jerky_san #50. Secondary thread: [/t/5158](https://forum.alta.inc/t/static-route-for-wan2-for-192-168-11-0/5158) (staff explicitly recommends against `ip rule + /32` hack).

**Why this replaces the current setup:**
The homegrown `/cfg/scripts/stick-mgmt.sh` does `route-swd stop` + pppd kill + IP alias on eth4 + /32 host route + `ip rule pri 100` + iptables punches, then needs `tcppipe.py` to re-add the host route on every connect because configd wipes it. Net effect: WAN3 internet drops every time we want mgmt access. The MACVLAN pattern fixes all of it:
- No `route-swd stop` — MACVLAN doesn't touch SerDes; route-swd keeps running.
- No pppd kill — child MACVLAN coexists with PPPoE on parent eth4. **Critical for this user — single fiber, see the single-fiber internet-path note.**
- No /32 hack, no `ip rule` — `ont_mgmt0` is its own netdev with its own subnet; routing is unambiguous.
- No tcppipe re-add — `/cfg/post-cfg.sh` is the hook Alta's configd respects, so device/IP persist.

**User's decision (2026-05-25): Level-1 restriction.** Stick UI reachable only from Route10's own root shell. Reasons recorded in conversation: Boa httpd from 2008 runs as root, has shell-injection in `formPing`; want zero exposure to LAN even from trusted devices; the `ssh stick` ProxyCommand pattern already provides that access shape.

**Concrete UCI to put in `/cfg/post-cfg.sh`** (NOT YET DEPLOYED — confirm with user before applying):
```sh
# MACVLAN child device on eth4 (untagged, parent's MAC + 1)
uci set network.ont_mgmt_dev=device
uci set network.ont_mgmt_dev.type='macvlan'
uci set network.ont_mgmt_dev.ifname='eth4'
uci set network.ont_mgmt_dev.mode='bridge'
uci set network.ont_mgmt_dev.name='ont_mgmt0'

# Static IP in stick's mgmt subnet
uci set network.ont_mgmt=interface
uci set network.ont_mgmt.device='ont_mgmt0'
uci set network.ont_mgmt.proto='static'
uci set network.ont_mgmt.ipaddr='192.168.1.2'
uci set network.ont_mgmt.netmask='255.255.255.0'

# Own firewall zone, FORWARD=REJECT, no lan→ont_mgmt rule (Level 1)
uci set firewall.ont_mgmt=zone
uci set firewall.ont_mgmt.name='ont_mgmt'
uci add_list firewall.ont_mgmt.network='ont_mgmt'
uci set firewall.ont_mgmt.input='ACCEPT'
uci set firewall.ont_mgmt.output='ACCEPT'
uci set firewall.ont_mgmt.forward='REJECT'

uci commit network; uci commit firewall
ifup ont_mgmt; /etc/init.d/firewall reload
```
**Do NOT add** `firewall.lan_to_ont_mgmt` forwarding (that would be Level 3 — any LAN client can reach stick UI; user explicitly rejected this).

**Prerequisites that are now satisfied (2026-05-25):**
- User deleted the legacy VLAN 2 (`br-lan_2`) that had 192.168.1.0/24 — verified post-reboot, no addr, no route, no device. No subnet collision.

**Retired and archived 2026-05-25** (kept findable, not deleted):
- `stick-mgmt.sh` → moved to `/cfg/scripts/_archive/` on Route10 and `archive/superseded-scripts/` locally.
- `tcppipe.py` → same two `_archive/` paths.
- `Host stick` block in `~/.ssh/config` → commented out with an ARCHIVED header pointing at the macvlan path and the script archives. The block never actually worked for `ssh stick` (stick's dropbear isn't running), so this is purely a cleanup.
- `restore_mgmt()` in `/cfg/scripts/odi-health.sh` → reduced in place to a 2-line self-heal (re-runs `/cfg/post-cfg.sh` only if `ont_mgmt0` missing).

**Staff caveat I logged but doesn't bite us:** "don't put a mgmt VLAN in the same address space as LAN." Currently fine — LAN is on a different subnet, ont_mgmt is on 192.168.1.0/24, no collision after VLAN-2 delete.
