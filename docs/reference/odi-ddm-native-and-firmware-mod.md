# ODI stick — native DDM (self-populating host-A2) & the firmware-mod dead end

_Research note, 2026-07-09. Investigation: can the ODI DFP-34X-2C3 (RTL9601D +
RTL8290B) self-populate its host-facing SFF-8472 A2 page from the 8290B's DDMI —
the software equivalent of what the **V08** hardware revision does with a
dedicated DDM chip — so we can delete `daemon-odi-w2-ddm.sh` from Route10?
Conclusion: the mechanism exists in Realtek's SDK, but it is **not deployable on
this V06 stick** (no toolchain/source for the Lexra core + a stubbed HAL), and
the real fix is a **V08 stick**. Companion to
[odi-wedge-recovery-and-ddm-source.md](odi-wedge-recovery-and-ddm-source.md)
and [w2-ddm.md](w2-ddm.md)._

## TL;DR

- **What works today (the wins):** `diag i2c get port 1 dev 0x51 reg <r>` reads
  the 8290B's DDMI **directly** and is **richer than Boa** (thresholds + status
  flags + measured values). `diag-drive.py` is live-validated. The Rx floor is
  measured: low-alarm −30 dBm, low-warning −28.9 dBm; current Rx ≈ −26 dBm ≈ 3 dB
  of headroom, no alarm asserted.
- **Can the stick self-populate host-A2 (delete the daemon)?** Architecturally
  **yes** — Realtek's SDK already contains the bridge (`lan_sds` kthread →
  `rtk_i2c_eepMirror_write` → slave SRAM). But it's blocked on this V06 stick by
  a **stubbed HAL function** (`0x12`), and filling it requires **building** —
  which is **impossible**: the RTL9601D is a Realtek **Lexra LX5280** (not MIPS),
  kernel 2.6.30.9, no public toolchain, no 8290B source. Community-confirmed
  unbuildable.
- **The real fix is hardware:** the **V08 stick** (`DFP-34X-2CY3` / `DFP-34X-2IY3`)
  has native active DDM. V06 (ours) cannot get native DDM via firmware — the DDM
  difference is hardware, firmware is cross-compatible between revs.
- **Recommendation:** keep `daemon-odi-w2-ddm.sh` (lock-free, working) for V06;
  buy a V08 if you want to delete the daemon. Do **not** pursue a firmware mod.

---

## The goal

Delete `daemon-odi-w2-ddm.sh` from Route10 by making the stick self-populate its
host-facing A2 from the 8290B — so from the outside (Route10's `i2c-1`, rcstats,
Alta dashboard) the stick looks like a proper DDM-capable SFP, exactly like the
V08 hardware revision does with a dedicated DDM chip. "1 less script on Route10."

## The win: `diag i2c get port 1` — verified, richer than Boa

Driven via [tools/diag-drive.py](../../tools/diag-drive.py) (the `RTK.0>` diag
shell — **live-validated 2026-07-09, first run, no wedge**). The command is
single-register: `i2c get port <port> dev <dev_id> reg <reg>` (this diag build
has no `count`/multi-byte variant).

**Port 1 is the transceiver/BOSA bus** (matches `insert_europa.sh`'s `I2C_PORT=1`);
port 0 is unused (NACK, "chip not found"). Port 1 reads the 8290B's DDMI directly:

| Read (port 1) | Value | Meaning |
|---|---|---|
| `0x50 reg 0x5c` (A0 byte 92) | **0x68** | Source advertises DDM implemented + internally calibrated (host buffer reads 0x00 here) |
| `0x51 reg 0x00/0x02` (temp thresholds) | 0x64 / 0xd8 | hi-alarm ≈ +100 °C, lo-alarm ≈ −40 °C — **real thresholds Boa doesn't expose** |
| `0x51 reg 0x60/0x61` (temp measured) | 0x27/0xa6 → 0x27a6 | 39.6 °C — matches Boa/cache |
| `0x51 reg 0x68/0x69` (Rx measured) | 0x00/0x19 → 25 | 2.5 µW = −26.0 dBm — matches Boa |
| `0x51 reg 0x6e/0x6f` (alarm flags) | 0x00/0x00 | no alarm asserted |
| `0x51 reg 0x22/0x23` (Rx low-alarm) | 0x00/0x0a → 10 | 1.0 µW = **−30.0 dBm** (the hard floor) |
| `0x51 reg 0x26/0x27` (Rx low-warning) | 0x00/0x0d → 13 | 1.3 µW = **−28.9 dBm** (soft floor) |

SFF-8472 Rx power is uint16, 0.1 µW, big-endian; dBm = 10·log10(raw/10000).

**Rx health read:** current Rx ≈ −26 dBm is ~3 dB above the warning floor (−28.9)
and ~4 dB above alarm (−30); the 8290B asserts **no alarm/warning**. Not critical
yet, but Rx dropped ~9 dB since May (−17.28 → −26; Tx stable at +2.1) — the
receive path (connector/fiber/OLT-Tx) is worth investigating while there's
headroom.

So `diag i2c port 1` is the **diagnostic** tool for richer DDM (thresholds +
flags). It does not, by itself, populate the host-facing A2.

## Why the daemon can't move onto the stick (three dead SoC-side write paths)

The host-facing A2 (`0x51`) is a **RAM buffer inside the RTL9601D** — the SoC's
i2c-*slave* backing store, presented to Route10 over the SFP pins. It's writable
from the host (Route10 as i2c-master → SoC slave receive — what the daemon does).
For the stick to self-populate, the SoC must write that same RAM. Three candidate
paths, all dead:

1. **i2c loopback** ("same path as Route10" — SoC i2c-master → own slave).
   **Tested 2026-07-09: NO.** `i2c get/set port 0 dev 0x51` → "chip not found"
   (NACK); port 1 → the 8290B (a *different* 0x51 on the internal bus). The SoC's
   i2c-master ports don't reach the slave-SRAM bus. The slave SRAM is not
   i2c-loopback-writable.
2. **diag `eeprom-mirror`** (`i2c set eeprom-mirror-reg <reg> data <data>` →
   `rtk_i2c_eepMirror_write`). **Tested: dead.** The mirror *config* API returns
   `Error 0x12 "driver is not found"` (HAL mapper NULL on RTL9601D). A mirror-reg
   write read back fine *within the mirror's own storage* but **did not propagate**
   to the host-facing A2 (wrote 0xAB to mirror byte 0x00; Route10 still read 0xff).
3. **The firmware-intended bridge** (the `europa_drv` DDMI polling thread / the
   `lan_sds` kthread). Exists in SDK source but: `europa_drv`'s thread writes the
   **8290B internal** DDMI (via i2c-master), not the slave SRAM; the `lan_sds`
   slave-SRAM bridge depends on the stubbed `rtk_i2c_eepMirror_write` (→ `0x12`);
   `europa_drv` **is not loaded at boot** (live `lsmod` = `rtk_tr142, pf_rg,
   omcidrv`); and the LDD/BOSA path errors 18.

## The firmware-mod mechanism (it genuinely exists)

In the leaked europa SDK ([jameywine/GPL-for-GP3000](https://github.com/jameywine/GPL-for-GP3000),
cloned at `/tmp/europa-sdk/`), the "software V08" is already written:

- A kthread in **`lan_sds`** (`module/lan_sds/lan_sds_main.c`) does, every 50 ms,
  `sfp_update_statistic()` — copies A2[96-119] (the DDMI block) **from the LDD
  EEPROM into the slave SRAM**, and every 10 ms `sfp_relay_gpio()` — mirrors
  LOS/TxDis/TxFault status into A2[110]. **Every slave-SRAM write funnels through
  `rtk_i2c_eepMirror_write()`.** This is Realtek's intended software-DDM path for
  non-V08 sticks.
- The slave SRAM **is** SoC-writable via a register path (not i2c): the
  `EEPROM_DOWNLOADr` register (offset 0x40) with per-range SRAM write-enable bits,
  driven through `I2C_IND_*` registers in **`WREN=3`** mode (vs `WREN=1` for a
  normal i2c-master write). Proven by the **rtl9601b** reference implementation
  (`dal/rtl9601b/dal_rtl9601b_i2c.c:903-953`).
- **The sole blocker:** on **RTL9601D** (a sub-type of RTL9602C —
  `hal/mac/mac_probe.c:259-267`), `i2c_eepMirror_write` is a **referenced-but-
  never-defined symbol** in the rtl9602c DAL (`dal/dal_rtl9602c/dal_rtl9602c_mapper.c:1081-1082`),
  so the mapper pointer is NULL and every SRAM write returns `0x12`
  (`RT_ERR_DRIVER_NOT_FOUND`). That is exactly the runtime error observed.

So the **code** change is small: port the ~50-line rtl9601b `eepMirror_write` to
the rtl9602c/9601d register block (the decisive unknown being whether RTL9601D's
`I2C_IND_*` offsets/fields match rtl9601b's). **Not reverse-engineering** — the
registers are documented and a sibling chip has working code.

**Important: waking `europa_drv`'s `#if 0` polling thread is the *wrong* fix.**
That thread writes the 8290B's *internal* DDMI (via `rtl8291_setReg` → i2c-master
to 0x51 on port 1 — `drv_8291/rtl8291_reg_acc.c`), not the slave SRAM. The
`lan_sds` bridge is the right mechanism, and it needs no un-commenting — it
already runs, it just no-ops on `0x12`.

## Why it's a dead end anyway (can't deploy)

Filling the stub requires **building**, and the RTL9601D cannot be built against
from public materials:

- **Wrong core.** RTL9601D is Realtek **Lexra LX5280** (vermagic
  `2.6.30.9 mod_unload RLX 32BIT`), not vanilla MIPS. The leaked SDK is
  linux-5.10.x / MIPS32_R2. The prebuilt `europa_8290b_drv.ko` in the SDK is built
  for RTL9607C big-endian — triple mismatch (kernel + SMP/UP + RLX/MIPS). No
  `insmod -f` bridges that.
- **No toolchain.** No `mips-*-gcc` / `asdk` / buildroot shipped. Building needs
  the closed **Realtek RSDK-1.5.6p2 (RLX gcc 4.4.6)**.
- **No source.** No `drv_8290b/` source dir in the leak (only 8291/8290c source +
  the 8290b prebuilt blob); closed SDK headers (`<rtk/ldd.h>`, `<hal/chipdef/allreg.h>`);
  no 2.6.30.9 kernel source.
- **Community-confirmed impossible.** Anime4000 maintainer
  ([#367](https://github.com/Anime4000/RTL960x/issues/367)): *"no GCC compiler
  understand RTL960B/RTL9601CI/RTL9601D — a modified MIPS (Lexra LX5280), can't
  compile hello world."* The repo ships only prebuilt vendor `.tar`s + a
  rootfs-repack flow (`unsquashfs` → edit → `mksquashfs -comp lzma`), not a build.

**Two nuances that make the no-build escape hatches fail too:**

- The **shipped** `/lib/modules/europa_drv.ko` **already carries the DDMI code
  live** (Agent verified `.rel.text.update_ddmi_*` relocations — called, not dead;
  plus the live printk `"DDMI Polling Task Add Success."`). So the A2 gate is
  runtime, not a missing source line. But loading it wouldn't help host-A2 (it
  writes the 8290B internal, not the slave SRAM), it **isn't loaded at boot**, it
  needs calibration (`/var/config/rtl8290b.data`, likely zeroed) + correct GPIO
  params, and the LDD path it depends on returns **error 18**.
- The likely runtime lever — the `FREEZE_DDMI_UPDATE` bit
  (`RTL8290C_REG_CONTROL1[4]`, `drv_8291/ddmi.c:406-409`) — lives behind that same
  error-18 LDD wall. Unreachable.

**Reflash risk** (were a build possible): closed stick; a brick kills WAN3 (only
internet path); recovery is **CH341A SPI** on the Macronix MX25L6433F (8 MiB,
SOIC-8) — community procedure [Anime4000 Discussion #286](https://github.com/Anime4000/RTL960x/discussions/286),
model-specific [issue #419](https://github.com/Anime4000/RTL960x/issues/419).
Auto-revert is real (dual-image `sw_commit`/`sw_active` U-Boot env, confirmed in
`omci_app`/`eponoamd` strings; `fwu.sh` writes one slot, md5-only, no signature)
but doesn't help if you can't build the image. Mitigation you already have: the
Huawei eth3 backup path.

## V06 vs V08 — DDM is hardware

Decisive, from the Anime4000 maintainer ([#367](https://github.com/Anime4000/RTL960x/issues/367),
[#403](https://github.com/Anime4000/RTL960x/issues/403)):

- **V06 = no DDM, V08 = yes (active) DDM.** V08 also dropped TTL UART and the
  discrete `24C04F` EEPROM (now SoC-emulated, read-only). Shipped as
  `DFP-34X-2CY3` / `DFP-34X-2IY3`.
- Firmware is **cross-compatible** between revs. The DDM difference is
  **hardware**, not firmware. **No firmware change gives V06 native DDM.**

## Conclusion + recommendation

| Path | Verdict |
|---|---|
| Firmware mod on V06 | **Dead end.** Mechanism exists (lan_sds/eepMirror bridge) but unbuildable (Lexra/no-source) + stubbed HAL + wrong-target/error-18 runtime paths. |
| **Keep `daemon-odi-w2-ddm.sh`** | **Pragmatic winner** for V06 — lock-free, working, consolidated (odi-health reads its cache). |
| **Buy a V08 stick** | **The real "1 less script" fix** — native DDM, no daemon. |
| `diag i2c port 1` for ad-hoc diagnostics | **Keep** — richer-than-Boa read (thresholds/flags) for checks like the Rx-floor measurement. |

Do not pursue a firmware mod without either a V08 stick or a Lexra toolchain that
does not exist publicly.

## Sources

**SDK (jameywine/GPL-for-GP3000, at /tmp/europa-sdk/):** `module/lan_sds/lan_sds_main.c` (the live bridge: `sfp_update_statistic`, `sfp_relay_gpio`, `sfp_sram_byte_write`); `dal/rtl9601b/dal_rtl9601b_i2c.c:903-953` (portable `eepMirror_write` reference, `WREN=3`); `dal/dal_rtl9602c/dal_rtl9602c_mapper.c:1081-1082` (the 9601D-family stub, never defined); `rtk/i2c.c:547-657` (the `0x12` guard pattern); `hal/chipdef/rtl9601b/rtk_rtl9601b_reg_list.c` (`EEPROM_DOWNLOADr` @ 0x40, SRAM write-enable bits); `hal/mac/mac_probe.c:259-267` (RTL9601D = RTL9602C sub-type); `app/europa/drv_8291/ddmi.c:406-409` (`FREEZE_DDMI_UPDATE`); `app/europa/drv_8291/rtl8291_reg_acc.c` (europa thread writes LDD internal, not slave SRAM); `app/diag_rtk/src/diag_i2c.c:570-607` (`eeprom-mirror-reg` CLI).

**Repo:** [w2-ddm.md](w2-ddm.md) (the working daemon + why firmware DDM is dormant); [odi-wedge-recovery-and-ddm-source.md](odi-wedge-recovery-and-ddm-source.md) (DDM source path, `diag`/`omcicli` reads); [custom-firmware-research.md](custom-firmware-research.md) (flash methods, CH341A ordered); [tools/diag-drive.py](../../tools/diag-drive.py) (diag-shell driver); fwu.sh (md5-only, one-slot, no signature — confirmed).

**External:** Anime4000/RTL960x — [#367](https://github.com/Anime4000/RTL960x/issues/367) (Lexra unbuildable + V06/V08 DDM table), [#403](https://github.com/Anime4000/RTL960x/issues/403) (V08 has active DDM), [#419](https://github.com/Anime4000/RTL960x/issues/419) + [Discussion #286](https://github.com/Anime4000/RTL960x/discussions/286) (CH341A SPI recovery), [Discussion #129](https://github.com/Anime4000/RTL960x/discussions/129) (no source from Realtek).

**Live verification 2026-07-09:** `diag i2c get port 1` richer-DDM read + the Rx threshold/floor measurement; `diag-drive.py` first live run (no wedge); i2c-loopback test (port 0 NACK); `eeprom-mirror` propagation test (no propagate). Stick left clean and un-wedged.
