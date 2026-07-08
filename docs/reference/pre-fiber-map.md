# ODI DFP-34X-2C3 — pre-fiber state map (Route10, W2 cage)

Snapshot taken 2026-05-24 with the ODI stick in W2 (`eth4`, ssdk port 5), **no fiber connected to the stick**. L4 (ssdk port 6) was occupied by an "OEM SFP-10G-BXU2" BiDi to the office switch and was never touched.

Goal of this doc: enumerate every layer that yields data pre-fiber so a future session can baseline quickly and know which probes are dead-ends.

## TL;DR

| Layer | Pre-fiber data available? | Method |
|---|---|---|
| Route10 ssdk port state | partial (mode setting only) | `ssdk_sh port {linkstatus,interfaceMode,txmacstatus,rxmacstatus} get 5` |
| Host SerDes link | **NO** — does not negotiate without fiber | `eth4` stays `NO-CARRIER` even with port 5 enabled + MAC TX/RX enabled |
| ethtool transceiver dump | **NO** | `ethtool -m eth4` → "Not supported" (Alta's `nss-dp` driver does not expose SFF-8472) |
| I2C bus 1 EEPROM (0x50) | **YES** | `i2cdump -y 1 0x50 b` — full SFF-8472 base page |
| I2C bus 1 DDM (0x51 low) | **NO** — stick does not implement DDM | bytes 0–127 = all `0xff` |
| I2C bus 1 vendor area (0x51 high) | YES, static | bytes 128–255 — magic + Cisco compat ID, no live data |
| I2C bus 1 other addrs (0x52–0x5F) | none | scanned, all NACK |
| route-swd pre-cooked JSON | YES | `/var/run/.route-swd.json` (per-cage identity) |
| route-swd EEPROM cache | YES | `/var/run/.sfp1.bin` (256-byte copy of 0x50 EEPROM) |
| route-swd DDM cache | N/A for this stick | `/var/run/.sfp1ddm.json` does not exist (no DDM) |
| ssdk_sh `sfp Data get 5` | **NO — segfault** | crashes ssdk on port 5 |
| ssdk_sh `sfp diag get 5` | **NO — segfault** | also crashes |
| Stick management UI (`http://192.168.1.1`) | **NO** | requires host SerDes which doesn't come up pre-fiber |
| ubus `network.device status eth4` | YES | confirms `up=false, carrier=false, autoneg=false`, link-advertising = 100/1000/10000baseT-F |
| `pbj` (Alta protobuf-JSON client) | unexplored | `/usr/sbin/pbj`: `pbj [-i INPUT] [-o OUTPUT] URL` — usable but URL scheme unknown |

**The single biggest pre-fiber constraint:** with this stick in W2, the host-side SerDes does not come up. No carrier, no autoneg, no link partner advertising. So nothing built on top of the L2 link (ping, ARP, HTTP UI) works pre-fiber. The only pre-fiber observability is **I²C of the inserted module + Route10-side cage state** — no view *inside* the stick's firmware.

The prior-session strategy of "stick in L4 for UI access pre-fiber" worked only because L4 was on the `br-lan_2` bridge and the L4 SFP cage *did* carry host-side link with the previous stick (or fiber was actually attached during those tests). L4 is now the office BiDi and unusable for the stick. W2 has no bridge membership; even if it brought host link up we'd have to do the L3 + firewall punch (which `stick-mgmt.sh on` already automates).

---

## Captured data

### Stick identity (i2c bus 1, addr 0x50, SFF-8472 base page)

Raw dump captured to `/var/run/.sfp1.bin` (256 B; first 128 B identity, rest 0xff). Decoded fields:

| Byte range | Field | Value |
|---|---|---|
| 0x00 | Identifier | `0x03` (SFP) |
| 0x01 | Ext identifier | `0x04` |
| 0x02 | Connector | `0x01` (SC) |
| 0x03–0x0A | Transceiver | `00 00 00 02 22 00 01` — sets `BR_min/max`, includes "GBASE-BX10" hint |
| 0x0B | Encoding | `0x01` (8B/10B) |
| 0x0C | BR nominal (×100 Mbd) | `0x0d` = 1300 Mbd → 1.25 GBd → 1G PON |
| 0x0E | Length SMF (km) | `0x14` = 20 km |
| 0x0F | Length SMF (×100 m) | `0xc8` = 200 → 20 km |
| 0x14–0x23 | Vendor name | `ODI             ` |
| 0x24–0x27 | Vendor OUI | `00 00 00 00` (not registered) |
| 0x28–0x37 | Vendor PN | `DFP-34X-2C3     ` |
| 0x38–0x3B | Vendor rev | (spaces) |
| 0x3C–0x3D | Wavelength (nm) | `05 1e` = 1310 nm Tx |
| 0x3F | CC_BASE | `0x71` |
| 0x40 | Options | `00 1a` — TX disable, TX fault, LOS implemented |
| 0x44–0x53 | Vendor SN | `XPON26020216    ` |
| 0x54–0x5B | Date code | `260207  ` (2026-02-07) |
| 0x5C–0x5F | Diagnostic monitoring | `00 00 00 e3` — type byte says DDM internally calibrated, but bytes at 0x51 are 0xff (lying) |
| 0x60–0x7F | "vendor specific" | random-looking 32 B — possibly a vendor signature / serial-bound HMAC. Same byte pattern across power cycles. |
| 0x80–0xFF | (unused) | all `0xff` |

This matches the prior-session snapshot exactly — the I²C EEPROM is static and survives reboots / power cycles.

### Vendor area on 0x51 (static, bytes 128–255 of upper page)

Bytes 0x7B–0xFF held:

- `7B–7F`: `ESFP\x83` magic — Cisco-compatibility signature used by ODI to allow the stick to be inserted in Cisco gear pretending to be a `GLC-BX-U`.
- `80–97`: `IPUIAG5RAB10-2094-02V02 ` — internal product/firmware tag.
- `C0–CF`: `GLC-BX-U        ` — Cisco compat name.
- `D4–D5`: `16`.
- `DF`: `0x37`.
- `E0–E5`: `\x1e(..14)6`.

None of this updates dynamically. No vendor-extension I²C addresses (0x52–0x5F) respond.

### DDM (0x51 bytes 0–127)

All `0xff`. Stick declares "DDM implemented, internally calibrated" in byte 0x5C of 0x50, but does not actually back it up. Tx/Rx/Bias/Temp/Voltage are **not** retrievable via I²C on this hardware.

To get optical telemetry on this stick you have to go through the stick's HTTP UI — which means fiber must be present (host link only comes up post-fiber as established below).

### Route10 SerDes / cage state with port enabled, no fiber

After `stick-mgmt.sh on`:

```
ssdk port linkstatus get 5  -> DISABLE
ssdk port interfaceMode get 5  -> sgmii_fiber
ssdk port txmacstatus get 5  -> ENABLE
ssdk port rxmacstatus get 5  -> ENABLE
ssdk port speed get 5  -> UNKNOWN VALUE
ssdk port duplex get 5  -> UNKNOWN VALUE
ssdk port autoNeg restart 5  -> "The item is not initialized"
eth4 /sys/class/net/eth4/carrier  -> 0
ethtool eth4: Speed Unknown!, Duplex Unknown!, Link detected: no
ubus network.device status eth4: present=true, up=false, carrier=false, autoneg=false,
  link-advertising=[100/1000/10000baseT-F], link-partner-advertising=[] (empty)
```

`ssdk port autoNeg restart 5` returning **"The item is not initialized"** is the smoking gun: the SerDes/PHY for port 5 has no remote partner to negotiate with, even though the module is electrically present and 0x50 EEPROM reads fine. This stick keeps its host-side SerDes powered down until something on the GPON side wakes it.

Confirms: no L2/L3 path to the stick is possible pre-fiber.

### route-swd pre-cooked observability

Alta's `route-swd` (part of the `/usr/sbin/black` multi-call binary) polls the i2c buses every ~15 s and writes:

```
/var/run/.route-swd.json   — { "4": {n,m,r,s,d,o}, "5": {n,m,s,d,o} }  — per-cage identity
/var/run/.sfp0.bin         — 256-byte raw EEPROM dump of cage 0 (L4 = office BiDi)
/var/run/.sfp1.bin         — 256-byte raw EEPROM dump of cage 1 (W2 = stick)
/var/run/.sfp0ddm.json     — { "t":°C, "v":V, "a":mA, "p":txdBm, "r":rxdBm }  — only for cages that implement DDM
/var/run/sfp0.txt          — last-set interfaceMode (e.g. "sgmii_fiber" or "10gbase_r")
/var/run/sfp1.txt          — same, cage 1
```

There is **no** `/var/run/.sfp1ddm.json` because the stick does not implement DDM. Reading `.route-swd.json` is the cleanest single-call way to enumerate what's in each cage:

```sh
$ cat /var/run/.route-swd.json
{"4":{"n":"OEM","m":"SFP-10G-BXU2","r":"V02","s":"2601230242","d":"260123","o":"000b40"},
 "5":{"n":"ODI","m":"DFP-34X-2C3","s":"XPON26020216","d":"260207","o":"000000"}}
```

JSON keys `"4"` and `"5"` are how route-swd numbers the cages. They match the ssdk port indices for the SFP cages (port 5 = W2, port 4 = an additional internal mapping for the L4 BiDi; the L4 cage is *also* reachable via ssdk port 6 with mode `10gbase_r` — route-swd's "4" and ssdk's "6" both refer to the same L4 physical cage but at different abstraction layers). For our purposes:

- **route-swd JSON key `"5"` = our stick.**
- **ssdk port 5 = our stick.**

### ssdk_sh capability map (top-level `?`)

```
port vlan portVlan fdb acl qos igmp leaky mirror rate sec stp mib led cosmap
misc ip flow nat trunk interface vsi qm ctrlpkt servcode rsshash policer
shaper bm debug device ptp sfp vport tunnel vxlan geneve mapt
tunnelprogramconfig athtag help quit
```

The `sfp` submenu exists but:
- `sfp Data get 5` (note capital D) → "Illegal parameter(s)" on port 4, **segfault** on port 5.
- `sfp diag get 5` → **segfault**.
- `sfp eeprom get` not a valid form.

So ssdk's SFP submenu is unusable for the stick. The i2c path is the only working route.

### `black` multi-call binary applets

`/usr/sbin/route-swd` and friends are symlinks/calls to `/usr/sbin/black`. Applets discovered via `strings`:

- `route-swd` — the SFP polling daemon (running).
- `cfg` — Alta config tool (`cfg --reload <name>`).
- `fwcheck` — firmware verification.
- `filter` — hostname-based parental control.
- `stats` — telemetry (permission-restricted, won't run via symlink trick).
- `pbj` — protobuf-over-JSON client (`pbj [-i INPUT] [-o OUTPUT] URL`). URL scheme unknown; likely targets the local SPACE_X protobuf API. Worth investigating in a future session — could expose more cage state and would not need root-of-trust I²C.

### Local Alta services

```
tcp 0.0.0.0:80, 443   — Alta UI (uhttpd on /www, returns 307 on api paths — auth required)
tcp 0.0.0.0:22        — dropbear SSH
tcp 0.0.0.0:2604/06/08 — FRR vty (ospfd/bgpd/etc.)
tcp 127.0.0.1:2601/2623 — FRR zebra
tcp 127.0.0.1:53      — dnsmasq
unix /var/run/ubus/ubus.sock — OpenWrt ubus RPC (rich queryable state)
```

Best of these for stick-related state pre-fiber: **ubus** for network.device queries, and **`.route-swd.json`** for identity. Nothing else.

### GPIO map (potentially relevant)

`/sys/kernel/debug/gpio` shows pinctrl0 with 64 GPIOs. Relevant clusters (func0, 2 mA, pull-down — typical for low-bandwidth SFP control signals):

Inputs in the `gpio19–32` range: 19(low), 20(high), 21(low), 22(low), 24(low), 25(low), 26(low), 27(low), 29(low), 30(low), 32(low), and 31(high).

Outputs: gpio23, 28 (both `out low`, pull-down).

The previous session's scripts treated `gpio25` (`in low`) and `gpio31` (`in high`) as W2-LOS and L4-LOS respectively, with the convention "low = signal present". With the current state (stick in W2 no fiber, BiDi in L4 with fiber):
- gpio25 = low — should mean "no signal" if convention holds, but it reads low when no fiber present. Polarity attribution is **uncertain** without a deliberate fiber-insert experiment to record before/after deltas.
- gpio31 = high — with the BiDi carrying real fiber traffic, "high" would mean LOS-active = no signal, which contradicts reality.

Conclusion: the prior `gpioN → LOS` mapping in `cutover-monitor.sh` is **probably wrong** for at least one cage. It hasn't broken anything because the script only reads + logs these and uses link/carrier (which are reliable) for phase decisions. Worth re-validating after fiber goes in: capture all 64 GPIOs before and after fiber insert, diff, identify the cage-specific LOS pin from what flipped.

Also: there are 0 `out` GPIOs currently in the `gpio23/28` candidate set that we could *prove* are TX_DISABLE for W2 without risking the office BiDi. **Do not toggle blindly.** A safer characterization would be done at a maintenance window when the office BiDi is unplugged.

---

## Reproducing this snapshot

```sh
# From Mac (auto-routes via Route10 LAN, no internet impact)
ssh -i ~/.ssh/route10_debug root@192.168.10.1 <<'EOF'
echo === route-swd JSON ===
cat /var/run/.route-swd.json
echo === stick EEPROM (bus 1 0x50) ===
i2cdump -y 1 0x50 b
echo === stick DDM page (bus 1 0x51) ===
i2cdump -y 1 0x51 b
echo === ubus eth4 ===
ubus call network.device status '{"name":"eth4"}'
echo === ssdk port 5 ===
for c in linkstatus interfaceMode txmacstatus rxmacstatus speed duplex; do
  printf "port $c get 5\nquit\n" | ssdk_sh 2>&1 | grep -E ':' | head -1
done
EOF
```

Do **not** run `ssdk_sh sfp Data get 5` or `sfp diag get 5` — both segfault.

## What to do differently next time

- Skip ethtool `-m` on Route10 (driver doesn't support it).
- Skip ssdk `sfp` submenu (segfaults on port 5).
- Skip trying to bring up host SerDes pre-fiber on this stick.
- Read `/var/run/.route-swd.json` first — gives identity for both cages in one byte and confirms whether route-swd is actually seeing the module.
- Diff GPIO dumps pre/post fiber to map cage-specific LOS pins correctly.
- Explore `pbj` URL targets — may expose more Alta-side observability without root flash inspection.
