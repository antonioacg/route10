# ODI DFP-34X-2C3 — Pre-Fiber Observability

*This stick keeps its host SerDes powered down without fiber; only I²C and route-swd JSON give data pre-fiber. Several common diagnostics either are not implemented or crash ssdk_sh.*

What pre-fiber observability is available for the ODI DFP-34X-2C3 in Route10 (Alta IPQ9574, OpenWrt-derived). Verified 2026-05-24 in W2 cage (eth4, ssdk port 5).

**Why:** wasted real-session time before on probes that were never going to yield data. Knowing what's a dead-end saves repeating dumps that segfault or return all-`0xff`.

**How to apply:**

Works pre-fiber:
- `i2cdump -y 1 0x50 b` — full SFF-8472 base page (vendor=ODI, PN=DFP-34X-2C3, SN, date, BR, wavelength, etc.). Bus 1 = W2; bus 0 = L4 (now office BiDi).
- `i2cdump -y 1 0x51 b` upper area (bytes 128–255) — static vendor magic + "GLC-BX-U" Cisco compat ID. No live data.
- `cat /var/run/.route-swd.json` — pre-cooked identity for every cage route-swd has seen. JSON key "5" = stick in W2.
- `cat /var/run/.sfp1.bin` — 256-byte raw EEPROM cache route-swd writes (same content as i2cdump 0x50).
- `cat /var/run/sfp1.txt` — last interfaceMode route-swd set on the cage.
- `ubus call network.device status '{"name":"eth4"}'` — confirms presence, carrier, autoneg, link-supported speeds.

Does NOT work pre-fiber:
- **Host SerDes** — port 5 stays `linkstatus=DISABLE` and `eth4 carrier=0` even after enabling port + MAC TX/RX. `ssdk_sh port autoNeg restart 5` returns "The item is not initialized". This stick keeps its host SerDes powered down until the GPON side wakes. So no ping, ARP, or HTTP UI to `192.168.1.1` pre-fiber.
- **DDM (0x51 bytes 0–127)** — all `0xff`. Stick declares DDM in 0x50:0x5C but does not back it. Tx/Rx/bias/temp/voltage **not retrievable via I²C** on this stick; you have to go through the stick's HTTP UI (which itself requires fiber for host link).
- **Vendor I²C extensions** at 0x52–0x5F — all NACK. No deeper buses.
- `ethtool -m eth4` — "Not supported" (Alta `nss-dp` driver does not expose SFF-8472 to netdev).

CRASHES — do not run:
- `ssdk_sh sfp Data get <any-port>` — segfaults. Affects port 4, 5, 6.
- `ssdk_sh sfp diag get <any-port>` — segfaults.

Reference doc with full captures and reproducer: `pre-fiber-map.md`.

Unexplored / future:
- `/usr/sbin/pbj` (Alta protobuf-JSON client). Usage: `pbj [-i INPUT] [-o OUTPUT] URL`. Likely targets the SPACE_X local protobuf API and may expose more cage state than ubus does.
- Diff `/sys/kernel/debug/gpio` before/after fiber insert to identify the real W2-LOS pin — the assumption in older scripts that `gpio25=W2-LOS` and `gpio31=L4-LOS` is probably wrong.
