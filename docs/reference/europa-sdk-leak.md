# Realtek "europa" GPON SDK source — leaked at jameywine/GPL-for-GP3000

_Complete source for the europa SDK that built our stick's `diag` / `europa_drv.ko`, found 2026-05-25. Includes `europa_cli.c` (diag command tree), `europa_8291.c` (RTL8291 calibration math), and 8290b/8290c variants. Resolves the reverse-engineering questions about DDM commands, parameter formats, and calibration polynomial fit._

**Repo:** github.com/jameywine/GPL-for-GP3000 — Cudy GP3000 GPL drop (16 Jun 2025). The GP3000 is a RTL9615 xPON router but ships with the same `europa` SDK tree that built our DFP-34X-2C3's `/bin/diag` and `europa_drv.ko`.

**Path inside repo:**
```
linux-5.10.x/drivers/net/ethernet/realtek/rtl86900/sdk/src/app/europa/src/
```

**Key files (verified 2026-05-25, present at /tmp/ as working copies):**
- `europa_cli.c` (~20k lines) — the diag interactive shell's command tree. `cliRoot[]` defines `init / reset / set / get / cal / gen / dump / clear / close / delete / gpon / epon / ...`. Sub-trees at `cliRootDump` (line 526), `cliRootCal` (line 617), `cliRootSet` (line 1159).
- `europa_8291.c` (~8k lines) — RTL8291 (= RTL8290B family = our chip) calibration math. `_8291_cal_regression` at line 130 (3-point quadratic regression for Rx DDM coefficients), `_8291_cal_shift` / `_8291_cal_shift2` for fixed-point scaling.
- Sibling `europa_8290c.c` exists for the 8290C variant.

**Resolves these previously-mysterious points:**

1. **`diag` command syntax:** the symbol name `cparser_cmd_debug_europa_dump_all_a0_a2_a4_a5_ddmi` is an OMNIBUS handler — the actual command at the RTK.0> prompt is `debug europa dump <subkey>` where subkey ∈ `{a0, a2, a4, a5, all, flash, page, efuse, sram}`. Not all 5 keywords on one line.

2. **Dump output format:** `_europa_cli_flashBlock_get` (line 8884) prints 16 bytes per row as `0x%04x  0x%02x 0x%02x …`. Plain ASCII hex. Parser regex: `^0x([0-9a-f]{4})\s+((?:0x[0-9a-f]{2}\s+)+)`.

3. **`set` parameter format:** parameters are raw hex 16-bit values parsed via `strtol(temp, NULL, 16)`. Temperature = signed Q8.8 hex like `0x2840` (NOT decimal float). Tx power = uint16 in 0.1µW units. Etc.

4. **Calibration math:**
   - Rx (3-point quadratic): `power = a·rssi² + b·rssi + c`. Falls back to linear if only 2 points.
   - Tx: similar 3-point fit, separate addresses.
   - Stored in flash at `RTL8291_RX_{A,B,C}_ADDR + RTL8291_PARAMETER_BASE_ADDR` and Tx counterparts.
   - Units: Power = 0.01 µW, Irssi = µA/32.
   - Output coefficients shifted (`_cal_shift2` with shft_a≈30, shft_b≈15, shft_c≈6) → cast to int16 → flash.

5. **Calibration command flow (Rx, same shape for Tx):**
   - `debug europa cal rxddmi 0` → reset measurement buffer
   - `debug europa cal rxddmi 1 <power_uW> <irssi>` → save measurement point 1
   - `debug europa cal rxddmi 2 <power_uW> <irssi>` → point 2
   - `debug europa cal rxddmi 3 <power_uW> <irssi>` → point 3 (optional, fits quadratic)
   - `debug europa cal rxddmi calc` → run regression, write coefficients to flash

6. **rtk_ldd_parameter_get(length, offset, ptr_data):** this is the chip-register read primitive used by all the dump functions. `offset` selects an A0/A2/A4/A5 page or an internal config register. The first arg `0xFF` is the device id.

**Why this is invaluable:**
- Removes all guesswork from non-interactive `diag` driving.
- Tells us EXACTLY what calibration coefficients are expected, in what format, at what flash addresses.
- Confirms our europa_drv.ko symbols are real production code paths, not vestigial.

**Risk caveats:**
- The leak is a recent GPL drop and may get DMCA'd. Mirror locally if you want long-term access. The two files are at `/tmp/europa_cli.c` (594KB) and `/tmp/europa_8291.c` (272KB) right now — consider moving into our own private archive if you want them preserved.
- The leaked SDK is for the GP3000 (RTL9615). Our stick is RTL9601D running the "8290B" variant. Differences likely exist in the `europa_8291.c` vs whatever our binary actually links — but the cli tree and most of the math should match.

**Related references:**
- The W2 DDM blocker writeup — what made the DDM hunt necessary; the leaked SDK confirmed the firmware-dormant (not silicon-blocked) reality and the no-op polling thread.
- The ODI cli.pid single-CLI lock — how to drive `diag` without orphaning the CLI lock.
