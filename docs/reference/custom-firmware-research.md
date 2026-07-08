# ODI DFP-34X-2C3 — custom firmware path research (2026-05-24)

Background and reference for the firmware flash/diagnostic attempt. Companion to `pre-fiber-map-2026-05-24.md` and `ROUTE10_CUTOVER_2026-05-24.local.md`.

## Hardware reality

| Fact | Source |
|---|---|
| **2C2 ≡ 2C3** — only optics differ (SC/UPC vs SC/APC). Same PCB, same RTL9601D SoC, same firmware base. Community 2C2 firmware drops onto 2C3 unchanged. | [Anime4000/RTL960x issue #310](https://github.com/Anime4000/RTL960x/issues/310) |
| Our stick's `HWTC370F0BAE` SN + Huawei EG8145X6 masquerade is **expected behavior** of `realtek-libohwtc` shim that enables Huawei OMCI ME 350/370/373 emulation on Realtek Luna-SDK ONUs. Not a corruption symptom. | [tripleoxygen/realtek-libohwtc](https://github.com/tripleoxygen/realtek-libohwtc) |
| Stock firmware on this family has **telnet/SSH enabled out of the box**, default credentials `admin/admin`. No UART unlock needed to enable shell access. | [Setup_Stick.md](https://github.com/Anime4000/RTL960x/blob/main/Docs/Setup_Stick.md) |
| Stock UI accepts community-built `.tar` firmware images. No signature bypass required for flashing. | Inferred from absence of header-munging discussion in firmware READMEs + cross-flash reports. |
| Most-recommended firmware for this stick (2026): `M110_sfp_ODI_220923.tar` — SDK 1.0, considered more stable than SDK 1.1. | [Anime4000 discussion #328](https://github.com/Anime4000/RTL960x/discussions/328) |
| `fix_speed.sh` (bundled in M110 firmware ≥ 220817) addresses **RTL9601 host-side SGMII/1000BASE-X negotiation pathologies** — directly applicable to our flap symptom. | [Firmware/DFP-34X-2C2 README](https://github.com/Anime4000/RTL960x/blob/main/Firmware/DFP-34X-2C2/README.md) |

## Repos and resources

- **[Anime4000/RTL960x](https://github.com/Anime4000/RTL960x)** — primary, active hub (2025–2026). Firmware images, OMCI/keygen tooling, WebGUI mods. Pull from `main`, no tagged releases.
- **[andrewz1/DFP-34X-2C2](https://github.com/andrewz1/DFP-34X-2C2)** — dormant secondary mirror. Has `/firmwares/` dump + `setmac_hex.c`. Superseded by Anime4000 for active work.
- **[hack-gpon.org DFP-34X-2C2 page](https://hack-gpon.org/ont-odi-realtek-dfp-34x-2c2/)** — wiki companion, ONT auth/PLOAM/OMCI setup reference.
- **[tripleoxygen.net firmware mirror](https://www.tripleoxygen.net/files/devices/odi/dfp-34x-2c2/firmware/)** — stock dumps + custom builds.

## Flashing methods (ranked by recoverability, safest first)

| Method | Procedure | Brick risk | Recovery if broken |
|---|---|---|---|
| **a. `fix_speed.sh` via existing telnet** | Login `admin/admin` over telnet/SSH → run patch script. Affects host SerDes config only. | Very low | Reboot stick |
| **b. Stock HTTP UI upload** | Browser → stick UI → firmware-upload page → upload `.tar`. Stock format check accepts community images. | Low–medium (depends on stock retaining recovery partition) | Re-upload via UI or telnet |
| **c. Telnet + `mtd_write`** | SSH/SCP image up, then `mtd_write <partition>`. Manual control. | Medium | Re-flash same way if telnet still answers |
| **d. UART YMODEM/TFTP via BootROM** | Solder UART pads, CP2102 + SFP breakout board for VCC/GND (CP2102 cannot power the stick alone), 3.3V TTL, std 115200 baud (assumed). | Recovers most boot-fail scenarios | Requires UART hardware on hand |
| **e. SPI clip + CH341A** | Power down stick, clip on SPI flash, dump/re-flash directly. | Recovers from any silent boot. | Needs CH341A + SOIC-8 clip — **ordered, ships in days**. |

UART pad locations for DFP-34X are not officially published — chip-side pinout in [UART.md](https://github.com/Anime4000/RTL960x/blob/main/Docs/UART.md) (RTL9601D pin 16 RX, pin 15 TX) but PCB pads need to be probed. SPI flash chip part number not published either — typical for the SoC family is W25Q64/GD25Q64/MX25L64 8 MiB SOIC-8 SPI NOR.

## What custom firmware unlocks

- Persistent telnet/SSH (already on stock for this family, so marginal gain).
- Editable `/etc/runomci.sh`, OMCI ME table tweaks via `libohwtc`.
- **`fix_speed.sh`** — most relevant for our wedge.
- `fix_sw_ver.sh`, VLAN-fix scripts.
- `omcicli`, GPON state machine introspection, network syslog.

## Match against our symptoms

| Our symptom | Best community match | Likelihood |
|---|---|---|
| Host SerDes flaps every 2 s, brief 1G stable windows | `fix_speed.sh`'s existence implies host-SGMII flap is a **known firmware-level class of bug** on the M110 line | High [INFERRED] |
| ICMP works intermittently during stable window | Hypothesis: Linux netstack survives, `omci_app`/bridge daemon resets dataplane | Plausible [INFERRED] |
| TCP completely dead (all ports) even during stable window | Same hypothesis — dataplane reset breaks established TCP, ICMP/ARP go through fast path | Plausible [INFERRED] |
| Exact triple (flap + ICMP-only + TCP-dead) reported by others on 2C2/2C3 | No exact match in Anime4000 issue tracker | — |

No exact-symptom matches in the tracker, but related issues: [#218 (O5/Initial wedge)](https://github.com/Anime4000/RTL960x/issues/218), [#248 (VLAN instability)](https://github.com/Anime4000/RTL960x/issues/248), [#419 (2C3 brick recovery via CH341A)](https://github.com/Anime4000/RTL960x/issues/419).

## Plan (revised after research)

1. ✅ Order CH341A + SOIC-8 clip — **done, in transit**.
2. **Pre-arm Route10** (route-swd stop + mode lock W2) so the cutover doesn't get killed by Alta's CRC-flip recovery. Done before fiber swap.
3. **Fiber to stick** → wait for the stable carrier-up window we observed (~ minutes).
4. **`telnet admin@192.168.1.1`** during that window. If it answers:
   - `cat /proc/kmsg`, `dmesg | tail -200` — kernel-level errors
   - `omcicli mib get` — OMCI state
   - `ifconfig`, `ip a`, `ps` — userland health
   - Look for `fix_speed.sh` and try running it (or check `/etc/init.d/`)
5. If in-place fix doesn't take, **upload `M110_sfp_ODI_220923.tar`** via stock HTTP UI.
6. If UI fails or stick bricks → CH341A path once it arrives.

Don't reach for UART unless step 6 is needed and CH341A is also non-recoverable.

## Pre-flash backups to take while telnet is open

- Dump current SPI flash partitions: `cat /dev/mtd0 > /tmp/mtd0.bin` etc. for every partition. SCP off to Route10 or Mac. **Especially `Config` / `Bootloader` partitions.**
- Export current UI config XML (we already have this from session 2: `config-fixed.xml`).
- `cat /etc/runomci.sh`, `/etc/runonu.sh` — startup scripts.
- `cat /proc/mtd` — partition map.
- Note the exact stock firmware build (`/proc/version`, version files in `/usr/local/version/`).
