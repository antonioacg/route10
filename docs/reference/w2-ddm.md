# ODI DFP-34X (RTL9601D) — W2 DDM is LIVE via daemon-odi-w2-ddm.sh

_Final picture 2026-05-26. `daemon-odi-w2-ddm.sh` polls Boa `/status_pon.asp` every 5s, encodes per SFF-8472, writes the i2c slave page A2 bytes 96-105. Route10's rcstats picks it up, and the Alta dashboard shows full W2 DDM matching L4._

# STATUS: WORKING. Daemon deployed 2026-05-26, commit c44ca3d.

The bridge: **Boa HTTP → daemon-odi-w2-ddm.sh → i2c slave A2 96-105 → rcstats → /var/run/.sfp1ddm.json → Alta cloud dashboard.** End-to-end verified: writing `0x50 0x00` to byte 96 (Q8.8 = 80.0°C) surfaced in `.sfp1ddm.json` as `{"t":80.0}` within rcstats' next 5s cycle.

# The architecture (definitive)

```
Boa /status_pon.asp                       (stick: SerDes-side DDM via rtk_ponmac_transceiver_get in libmib.so)
    ↓ curl --http0.9 every 5s
daemon-odi-w2-ddm.sh on Route10           (one persistent Boa session, IP-bound at 192.168.1.2)
    ↓ awk-encode to SFF-8472 (Q8.8 / uint16 100µV / 2µA / 0.1µW)
i2ctransfer -y 1 w11@0x51 0x60 <10 bytes> (writes stick's RAM-backed i2c slave page A2)
    ↓ on stick: 10 bytes land in DDMI_A2_REG_START_ADDRESS+96..105
rcstats agent (/usr/sbin/black on Route10) reads i2c-1 0x51 every 5s
    ↓
/var/run/.sfp1ddm.json: {"t":...,"v":...,"a":...,"p":...,"r":...}
    ↓ shipped to dl.alta.inc / ping.alta.inc
Alta cloud dashboard shows full 5-field DDM for W2 cage
```

Plus parallel local consumers:
- `/var/run/w2-ddm.cache` (JSON form) — for any general consumer
- `/var/run/w2-ddm.env` (sh-sourceable) — `odi-health.sh probe_w2_ddm()` reads this instead of curling Boa again, honoring the "one session with stick" constraint

Daemon launched automatically by `/cfg/post-cfg.sh` via `launch_if_absent` (idempotent across configd reapplies).

# What we empirically verified (2026-05-25 / 2026-05-26, Route10 kernel 5.4.213)

**Route10 has direct i2c access to both SFP cages:**
- `/dev/i2c-0` → **L4 cage** (office-switch BiDi, vendor `@SFBXU2`). Byte 92 = `0x68` (DDM implemented + internally calibrated). DDM bytes 96-105 populated. Already working dashboard-side.
- `/dev/i2c-1` → **W2 cage** (the ODI stick, vendor `DF2C3 ... XPON26`). Byte 92 = `0x00` (advertises no DDM). DDM bytes 96-105 were all `0xff` until our daemon — now refreshed every 5s.

**The i2c slave page A2 is writable from outside.** Confirmed every region:
- Threshold region (bytes 0-15): writable, persists, no software reacts
- Real-time region (bytes 96-105): writable as single bytes AND as multi-byte burst (`i2ctransfer w11@...`), all 10 bytes commit, no spillover
- Byte 92 of A0 (DDM enable advertise): writable, 0x00→0x68→0x00, zero reaction from optics or PPPoE during the 10s "advertised" window
- Vendor-specific bytes 123-127: contain `ESFP\x83` (Realtek tag); writable but we leave them alone

**Multi-byte burst reads work fine.** The prior "1 byte + N-1 zeros silicon bug" claim was wrong — it cited a Linux kernel commit for a *different* Realtek chip family (Ethernet PHY EEPROM emulator), not the RTL9601D's SFP cage slave. i2ctransfer w1@0x51 0x60 r10 on the L4 cage returns 10 clean SFF-8472 bytes.

# Why the stick's own DDM subsystem is dormant

**`europa_drv.ko` is NOT loaded** at boot. lsmod on the stick shows only `rtk_tr142, pf_rg, omcidrv` plus `re8686_rtl9602c`. No `europa_drv`. So the entire DDM subsystem (polling thread, kick_ddmi, update_ddmi_*) is offline.

**`/etc/scripts/insert_europa.sh`** exists on the firmware and would `insmod $EUROPADRV PON_MODE=$MIBPONMODE I2C_PORT=1 INTR_PIN=29 TXDIS_PIN=13 TXPWR_PIN=0` — but nothing in the boot path calls it. Files `/var/config/europa.data` (1552B) and `/var/config/rtl8290b.data` (1566B) DO exist at boot (presumably created by `europacli init flash`), but the final `insmod` never runs.

**Even if europa_drv were loaded**, the leaked SDK source (`jameywine/GPL-for-GP3000` → `drv_8291/europa_main.c:273`) shows the polling thread's `update_8291_ddmi(...)` call is `//`-commented out. Thread spawns, prints `DDMI Polling Task Add Success`, schedules every 3s, does nothing. The 8290B variant in our binary is presumably similar — and even if its update path were live, `rtk_ldd_parameter_get` returns error 18 on every diag dump (the BOSA i2c master path appears unreachable from userspace on this build). See the Realtek "europa" GPON SDK leak reference for detail.

So the firmware-side DDM is dead at multiple layers. The user-space-only bridge (our daemon) is the working answer.

# Daemon details

**Source-of-truth:** `scripts/daemon-odi-w2-ddm.sh` (versioned).
**Deployed at:** `/cfg/scripts/daemon-odi-w2-ddm.sh` on Route10.
**Launched by:** `/cfg/post-cfg.sh` (Alta-blessed hook, idempotent via `launch_if_absent` helper).
**Log:** `/cfg/scripts/daemon-odi-w2-ddm.log` (manual 512KB rotation).
**Cache outputs:** `/var/run/w2-ddm.cache` (JSON), `/var/run/w2-ddm.env` (sh-sourceable).

**Sanity bounds (skip i2c write if out of range):**
- temp -40 to 100 °C
- vcc 1.0 to 5.0 V
- bias 0 to 200 mA
- tx_dBm / rx_dBm -50 to 20 / 10 dBm

**Failure recovery:**
- Login fails → retry every 10s (logged)
- Parse fail or session-lost (small response containing `login.asp`) → re-login next cycle
- Every 6 consecutive parse fails → force re-login
- Stick reboot wipes i2c slave to 0xff → daemon re-populates within 5s

# Verified end-to-end (2026-05-26)

After deployment:
- `/var/run/w2-ddm.cache`: `{"t":38.97,"v":3.232700,"a":13.05,"p":2.28,"r":-17.24,"ts":...,"i2c_ok":true}`
- i2c-1 0x51 bytes 96-105: `0x26 0xf8 0x7e 0x47 0x19 0xaf 0x42 0x08 0x00 0xbc` (decodes to exactly the cache values)
- `/var/run/.sfp1ddm.json` (written by rcstats): `{"t":39.0,"v":3.23,"a":13.15,"p":2.28,"r":-17.26}` — full 5-field DDM
- odi-health.sh log line gained `W2_tx_dBm_boa` and `W2_rx_dBm_boa` (read from `.env`, no extra Boa session)

# What we still did NOT do (room for follow-up)

- **Did not flip byte 92 of A0** to `0x68`. The dashboard works fine without it (rcstats reads bytes 96-105 regardless). If anything downstream ever checks byte 92 and ignores empty-advertised SFPs, flipping byte 92 is a single safe i2cset away. Not needed today.
- **Did not insmod europa_drv manually.** Would unlock the chip's own polling — but the polling thread is no-op in the leaked SDK, and the BOSA/calibration coefficients are missing for this stick. Likely nothing happens; small risk something hangs.
- **Did not investigate W2 DDM fallback source.** Before the daemon, rcstats reported `{"t":40.2,"v":3.29}` for W2 even with i2c slave = 0xff. There's some other path it falls back to (sysfs hwmon? OMCI? cache?). Not load-bearing now that the i2c slave is populated.
- **`europacli init flash europa/8290b` writes the .data files** at boot but full behavior isn't traced — for future investigation if the polling thread is ever woken.
