# Route10 ↔ ODI DFP-34X-2C3 cutover — session 2026-05-24

Third attempt. Companion to `ROUTE10_CUTOVER.local.md` (2026-04-25) and `ROUTE10_CUTOVER_2026-05-13.local.md` (2026-05-13). To be consolidated later.

## End-of-session state

- **Internet restored via Huawei.** Fiber back in Huawei, WAN1 PPPoE dialing on `eth3` (untagged, persistent from session 2). Got `100.68.16.171` CGNAT, default route via `pppoe-wan` proto static.
- **Stick stays in W2 cage** with no fiber. Mode: `sgmii_fiber`, `route-swd` running, MAC TX/RX cycling normally.
- **Route10 cleanly reverted** — no leftover iptables, no IP aliases on eth4, no `/cfg/scripts/` calls in progress. The two scripts (`stick-mgmt.sh`, `cutover-monitor.sh`) are persisted in `/cfg/scripts/` updated to **W2-only** (L4 fenced off — see below).
- **`stick-mgmt.sh` and `cutover-monitor.sh` are now W2-only.** L4 (eth5, ssdk port 6, ssdk i2c bus 0) is the office switch 10G BiDi as of today; reconfiguring it would take the office offline. New `detect_cage()` / presence check uses i2c bus 1 0x50 EEPROM readability (real physical presence — the host-side ENABLE bit and carrier are downstream signals and don't reflect "module inserted").

## What was new this session vs 5/13

### 1. The L4 topology change

L4 is now a 10G BiDi SFP+ to the office switch (vendor `OEM`, model `SFP-10G-BXU2`, SN `2601230242`, member of `br-lan`/`br-lan_2`/`br-lan_7`). The 2026-04 and 2026-05-13 scripts assumed L4 was a free stick test cage and would set `port interfaceMode set 6 sgmii_fiber` — which would break the office BiDi. Both `stick-mgmt.sh` and `cutover-monitor.sh` were rewritten to W2-only and the `l4` arg explicitly refuses with exit 2. Documented in `route10-scripts/pre-fiber-map-2026-05-24.md` and in memory.

### 2. Pre-fiber observability map (new doc)

`route10-scripts/pre-fiber-map-2026-05-24.md` is the canonical reference now. Highlights:

- **`/var/run/.route-swd.json`** is route-swd's pre-cooked identity for every cage it has polled — one-shot per-cage SFP info (vendor/model/SN/date/OUI). JSON key `"5"` = our stick.
- **`/var/run/.sfp1.bin`** = route-swd's 256-byte cache of the stick's 0x50 EEPROM. No DDM file because the stick doesn't implement DDM.
- **`ssdk_sh sfp Data get <port>` SEGFAULTS** on every port we tried (4, 5, 6). `sfp diag get` also segfaults. Do not run.
- **`ethtool -m eth4`** → "Not supported" — Alta's `nss-dp` driver does not expose SFF-8472 via netdev. I²C is the only path.
- **`/usr/sbin/black`** is a multi-call binary with applets `route-swd`, `cfg`, `fwcheck`, `filter`, `stats`, `pbj`. `pbj` (`pbj [-i INPUT] [-o OUTPUT] URL`) is a protobuf-JSON client — unexplored but likely the path to richer Alta-side state. Save for later.
- **Host SerDes does NOT come up pre-fiber on this stick.** `ssdk_sh port autoNeg restart 5` returns "The item is not initialized". Without GPON activity the stick won't power its host SerDes. Consequence: no L2/L3/ICMP/HTTP UI access pre-fiber — i2c is the only window.

### 3. The actual cutover — the new diagnostic data

Fiber moved from Huawei → stick at ~16:03:00. Timeline (from `/tmp/cutover-20260524-160102.log`):

| Time | Event | Meaning |
|---|---|---|
| 16:03:10 | eth4 carrier UP @ **10000 Mb/s** | Stick host SerDes negotiated, but at the wrong speed |
| 16:03:30 | carrier DOWN | 20 s up window |
| 16:04:36 | carrier UP @ 10000 Mb/s | Second window |
| 16:04:55 | carrier DOWN | 19 s |
| 16:05:00 | I stopped `route-swd` + locked `port interfaceMode 5 sgmii_fiber` + `ifdown wan` | |
| 16:06:42 | carrier UP @ **1000 Mb/s** | First time at correct speed |
| 16:07:08..16:07:35 | 10 samples carrier=1, link=ENABLE, no flap | Stable for ~3 min |
| 16:08:10 | First ping success: 0.35 ms; stick MAC `e0:da:90:c4:f8:85` ARPed | Looks healthy |
| 16:08–16:10 | `pgrep` says pppd dialing, but `tcpdump` capture: **1 PADI sent, then "interface went down"** | Carrier drops mid-capture, pppd dies (maxfail=1) |
| 16:09:35+ | All TCP probes (22/80/443/etc.) timed out | Stick's userland TCP stack not serving |
| 16:11+ | Carrier flapping every ~2 s on its own (route-swd already stopped, so this is stick-internal) | Wedge progressing |
| 16:14:00 | User re-seated the stick (~30 s wait) | |
| 16:14:44–16:15:12 | 15 samples consecutive carrier=DOWN | Re-seat made it *worse* initially |
| 16:16:15+ | Carrier back UP @ 1 Gb/s, stable for ~5 s; ICMP 80% success, but all TCP still 0 | LED blue (per Antonio) but management plane dead |

### 4. Root cause of fast 20 s ↔ 60 s flap (pre-intervention) = `route-swd`'s mode-flip recovery

Strings in `/usr/sbin/black`:

```
sfp%d: crc reset attempt %u/%u on %s (rx_packets_delta=%llu rx_crc_delta=%llu), switching %s -> %s
sfp%d: restoring mode to %s after crc reset attempt %u
```

Route-swd watches rx CRC delta on each cage. If it sees CRC errors during the stick's noisy SerDes startup, it "recovers" by flipping `port interfaceMode` between `sgmii_fiber` and `10gbase_r`. For a 1G GPON stick, `10gbase_r` is invalid — every flip kills the link, then the next 15 s poll flips back. Hence the ~60–90 s flap cycle.

**Fix for any future stick attempt: stop `route-swd` *before* fiber moves to the stick.** The pre-fiber map / monitor still work fine — route-swd's pre-cached JSON is good enough for cage identity, you don't need it polling.

### 5. Stick wedge characterization (post-route-swd-stop)

Even with route-swd stopped and mode locked to `sgmii_fiber`, the stick exhibits:

- **L1**: carrier brings up to 1 Gb/s briefly (seconds to a few minutes), then drops on its own. Re-seat got us one ~3-min window, but subsequent windows progressively shorter.
- **L2**: ARP responds intermittently during the carrier-up window. MAC `e0:da:90:c4:f8:85` matches the Huawei (correct).
- **L3 ICMP**: ~75–80% success during stable windows, ~0.5 ms RTT.
- **L4 TCP**: 0% success on ports 22/23/53/80/443/4567/7547/8080/8000. Even when ARP+ICMP work, TCP gets ICMP destination-unreachable or hard timeout. **Stick's userland TCP stack is broken, not just the HTTP daemon.**
- **PPPoE**: pppd sends 1 PADI before the carrier flap kills the session; with `maxfail=1` in pppd cmdline, it gives up. No PADO ever seen — but inconclusive because the stick may simply never get a frame to the OLT (stuck pre-O5) regardless.

**Conclusion: stick is not just "not ranging" — its host-side IP stack is dying. This is a different failure mode than 5/13 (where host SerDes never even came up). Either the wedge deepened, or this is a different facet of the same underlying problem (Realtek GPON firmware corrupting its own data plane).**

## Pivot to custom firmware (next session)

Stock V5R022C00S265 has reproducibly failed across three sessions with progressively richer diagnosis. The pre-fiber map confirms there's no observability path into the GPON state machine from outside (no DDM, no useful ssdk_sh, no UART exposed). The only way to actually see what the chip is doing is to put a firmware on it that gives us telnet to the RTL9601.

Research agent is running on this — see `route10-scripts/custom-firmware-research.md` once it lands. Key questions it should answer:

1. Is DFP-34X-2C3 explicitly supported (vs the close-relative 2C2)?
2. Can we flash a custom image through the stock HTTP upload page, or is telnet-then-mtd-write required first?
3. What UART hardware to buy *before* attempting flash (brick-recovery insurance)?
4. Does anyone else in the community report the same intermittent ICMP-only / TCP-dead / SerDes-flap pattern on this stick?

---

## 🎯 CURE FOUND — 2026-05-24 evening session

After all this — the stick was already running community firmware (`M110_sfp_ODI_220923`), already had `admin/admin` telnet on port 23 and admin web UI on port 80, and the actual root cause was a single broken field.

### The actual root cause

`omci_app` calls `hsgqMacKeyCheck` at startup. The check is:

```
MD5("hsgq1.9a" + UPPERCASE_HEX(ELAN_MAC_ADDR))  ==  MAC_KEY  ?
```

If mismatch → prints `GPON mac_check fail !!!!!!` and exits. Without `omci_app`, no OMCI/PLOAM, ONU never auths with OLT, stays at O0 forever, laser never fires (Tx=-inf, Bias=0). Every "wedge" symptom flowed from this.

Our stick's stored `MAC_KEY` was `0903625421575fc3fc86cc7565c35451` — **junk** (didn't match any valid MAC under the algorithm). Almost certainly set by a previous owner who cloned the Huawei MAC into `ELAN_MAC_ADDR` and pasted some random hex into `MAC_KEY` instead of regenerating it.

### The fix (90 seconds)

```sh
# On the Mac, compute the correct value:
printf '%s' 'hsgq1.9aE0DA90C4F885' | md5sum
#   -> 4b17b17d6b04f12e16cfad0e8a62895e

# Telnet to the stick (admin/admin), then:
flash set MAC_KEY 4b17b17d6b04f12e16cfad0e8a62895e

# Reboot. omci_app starts, ranges with OLT, reaches O5.
```

Verified post-reboot — all HS values persist:

```
ELAN_MAC_ADDR  e0da90c4f885
MAC_KEY        4b17b17d6b04f12e16cfad0e8a62895e
OUI            e0,da,90
GPON_SN        HWTC370F0BAE
HW_HWVER       343D.D
```

PON status: `ONU State O5`, `Tx Power 2.26 dBm`, `Bias 12.85 mA`, `Rx Power -17.3 dBm`.

### Why all prior debugging missed this

- The 2026-05-13 "host SerDes flaps every ~2 s, ICMP works, TCP dead" symptom was a **routing artifact on Route10**, not a stick problem. eth4 had no IP because `ifup wan3` had wiped our `192.168.1.3/24` alias; the kernel sent TCP SYNs via `br-lan_2` (Alta's) which has no path to the stick. ARP worked because `arping -I eth4` bypasses the IP stack. Once we re-added the `/32 dev eth4` route, all TCP came alive instantly — including the **HTTP admin UI we'd been assuming was dead for two sessions**. The stick was not "wedged at L4". It was unreachable because of OUR routing.
- The 5/13 "carrier flap every 2 s caused by route-swd CRC-flip" was real (route-swd switches `port interfaceMode 5` between `sgmii_fiber` and `10gbase_r` — the latter is invalid for 1G GPON), but stopping route-swd only got us a stable host link; it never explained the deeper O0. With `mac_check` failing, `omci_app` exits no matter how stable the SerDes is.
- The 2C2-vs-2C3 hardware distinction, the firmware-flash plan, the CH341A insurance order — all still useful preparation, but not what was wrong.

### What needs no further attention

- **`europa_drv.ko` — red herring**, confirmed. It's leftover from a multi-platform template. The DFP-34X-2C3 GPON ASIC (RTL9601D) is driven by `omcidrv.ko` + `pf_rtk.ko` (loaded by `insdrv.sh` from `rc3`) + the dynamically-loaded BDP/RDP/ME `.so` modules in `/lib/features/internal/` (loaded by `omci_app` once it starts). `insert_europa.sh` is referenced from zero `rcN` scripts. The earlier `omci_wrapper_activateGpon ioctl failed` and `europacli get laser → Fail (18)` were transient warnings, not the cause of anything.
- The `flash all hs` snapshots in `/var/config/lastgood_hs.xml`, `lastgood_hs.xml_bak`, and especially `lastgood_mp_hs2.xml` (manufacturing/factory backup with the original ODI identity: ELAN_MAC `38:3a:21:28:06:81`, HW_SERIAL `XPON20200681`, MANUF `HSGQ`, PRODUCT `M111`, OUI `11:11:11`) confirm the stick was cloned from HSGQ-OEM-default to Huawei-spoofed by someone before us. We don't need to revert anything; we just needed the correct `MAC_KEY` for the *current* (Huawei) MAC.

### Operational notes from this session

- **Stick HTTP UI:** `http://192.168.1.1/admin/login.asp` — admin/admin. Realtek Boa 0.93.15 webserver. IP-based session (no cookies).
- **Stick telnet:** port 23 — admin/admin. BusyBox 1.12.4 ash. Limited binaries (no `dmesg`/`uname`/`head`/`tail`/`od`/`strings`/`wc`/`tr`/`sort`/`pkill`/`grep -B`). Tools that DO exist: `flash get/set`, `mib get/set`, `xmlconfig`, `omcicli`, `nc`, `wget`, `curl`, `dd`, `python3`. The stick's telnetd has a low session cap — leaving interactive tools (`omci_app`, `ShowStatus`, `pondetect` standalone) running blocks new logins; clean up with `exit`.
- **`flash set`:** writes through to flash immediately (verified by reboot persistence). Syntax is `flash set MIB-NAME MIB-VALUE` — do NOT pass `hs` or `cs` as a third arg, that breaks the parser.
- **Useful config-export endpoint:** POST `/boaform/formSaveConfig` with `save_cs=Backup...` returns `config.xml` (the MIB_TABLE export — what we already had via `config-fixed.xml`); `save_hs` returns the HS export (includes `MAC_KEY`, `ELAN_MAC_ADDR`, `OUI`, etc. — we never grabbed this in prior sessions). Always grab both when documenting an ODI stick state.
- **Anime4000/RTL960x firmware drop site:** https://github.com/Anime4000/RTL960x/tree/main/Firmware/DFP-34X-2C2 — our stick is on `M110_sfp_ODI_220923.tar`. Mods under `/Firmware_Mod/DFP-34X-2C2/` include `fix_speed.sh`, `fix_sw_ver.sh`, `fix_vlan_tag.sh` — none of which we need (the `fix_speed.sh` story was a Realtek host-side SGMII issue, unrelated to our actual problem).

### Saved diagnostic dumps in this repo

- `route10-scripts/stick-current-cfg-2026-05-24.xml` — MIB_TABLE export
- `route10-scripts/stick-flash-recon-2026-05-24.log` — `flash get` of all key fields
- `route10-scripts/stick-mac-recon-2026-05-24.log` — HW_MIB_TABLE dump (with MAC_KEY)
- `route10-scripts/stick-hs-snapshots-2026-05-24.log` — all HS snapshots including the MP/factory backup
- `route10-scripts/stick-omci_app-V1.0-220923` — binary copy of `/bin/omci_app` (133456 B) — has the `hsgqMacKeyCheck` function
- `route10-scripts/stick-{status,gpon,vlan,saveconf,tcpiplan,rebootTime,code,upgrade}_*.html` — UI pages
- `route10-scripts/stick-shell-recon-2026-05-24.log`, `stick-deep-recon-2026-05-24.log`, `stick-omci-recon-2026-05-24.log`, `stick-tamper-recon-2026-05-24.log` — shell session dumps

### WAN3 PPPoE attempt — second wall

With stick at O5 and WAN3 dialing PPPoE on eth4, **PADIs leave Route10 but no PADO ever returns.** Initially looked like an OLT-side provisioning gap, but a fresh 547 KB OMCI debug log (captured by running `omci_app -f console` and `cat /tmp/omci.log | nc 192.168.1.3 9998` to Route10, saved as `route10-scripts/stick-omci.log-2026-05-24`) proves the OLT IS actively pushing real provisioning. The smoking gun from the log:

```
0x5b74 OntData MibReset(0x0000)               ← OLT initiates fresh MIB push
0x5d7e MacBriServProf Create(0x0000,...)
0x5d89 MacBriPortCfgData Create(0x0001,...TPType=0x05,...)   ← TPType=0x05 = VEIP
0x5d96 MacBriPortCfgData Create(0x0002,...TPType=0x05,...)   ← VEIP
TP type is not supported in mac_bridge_port_pmhd_pm_handler: MacBriPortCfgData, 0x1
TP type is not supported in mac_bridge_port_pmhd_pm_handler: MacBriPortCfgData, 0x2
set veip gem flow [0] failed!
set veip gem flow [1] failed!
```

**OLT is pushing HGU-style provisioning using VEIP** (ME 329, Virtual Ethernet Interface Point — TPType=0x05) because our spoofed identity says "Huawei EG8145X6" which is an HGU device in ISP records. **M110_220923 is SFU-only firmware — it cannot process VEIP.** That's why `/proc/omci/wanInfo`, `wanData`, `mb`, `veip`, etc. all stay empty even at O5: the OLT's Create commands NACK at our stick's bridge handler, the GEM port flow never gets wired up, and Route10's PADIs are flooded back out eth0 (only member of `br0`) instead of being bridged to `pon0`.

Things tried this session that did NOT help:
- `OMCI_OLT_MODE` 0 → 1 (Huawei) → 3 (custom): same result.
- `OMCI_FAKE_OK` 1 → 0: made SerDes flap (OLT NACKs without fake-OK trigger something stick-side); reverted to 1.
- `DEVICE_TYPE=1` (router/HGU mode) + `OMCI_VEIP_SLOT_ID=1`: M110 is SFU-only, this caused `/proc/omci/*` to disappear entirely; reverted to bridge mode.
- `omcicli mib reset`: counters reset, state unchanged. Same provisioning failure.
- Re-cycling fiber Huawei→stick to trigger OLT re-provision: OLT pushed again, same VEIP failure.

### Hot-swap M110→M114 attempt (kernel-stack mismatch)

Tried staging M114_hybrid's userland binaries (7 files: `omci_app` + 6 `lib*.so`) at `/var/run/m114/` on the stick and launching with `LD_LIBRARY_PATH=/var/run/m114`. The other agent set up an SSH proxy (`ssh stick` via `tcppipe.py` on Route10) for clean file transfer. Hot-swap launch exits with `Aborted` (SIGABRT, exit 134) and `<fMgmtInit:601> is the so is not a regular file.` printed 3 times.

Diagnosis — M114 needs significantly more than userland swap:

| Component | M110 (stick) | M114 |
|---|---|---|
| Userland binary `omci_app` | md5 `3ab8ee05277014f9a06f4c0855192f47` | md5 `0eceb820eb5beada338bc0ca6142e58a` |
| Kernel platform driver | `pf_rtk.ko` (switch fabric) | **`pf_rg.ko` (router gateway)** |
| Kernel modules used | `omcidrv.ko` + `pf_rtk.ko` + `igmp_drv.ko` | `omcidrv.ko` + `pf_rg.ko` + `rtk_tr142.ko` + `europa_drv.ko` |
| `/lib/modules/features/` | (empty, no kernel feature modules) | `bdp_*.ko`, `me_*.ko`, `rdp_*.ko` (loaded by omci_app via insmod) |
| `/lib/features/internal/` userland MEs | 16 .so | +`me_00001000.so` (M114-only) |
| `libigmpipc.so` | present | absent (different IGMP IPC scheme) |

The M114 omci_app expects its companion kernel modules (especially `pf_rg.ko`) to be loaded, and `/lib/features/internal/me_00001000.so` to exist. `/lib` on the stick is squashfs read-only. Adding modules requires either a bind-mount overlay of `/lib/features/internal/` (risky — running M110 omci_app holds fds; respawn-on-bind-mount race) or replacing the booted kernel modules at runtime (impossible without taking down the whole PON stack).

**Conclusion: hot-swap is not viable. The realistic paths forward are full firmware flash to M114_hybrid, or ISP `rerangear` call.**

### Firmware flash plan (when ready)

The stick has dual-image partitions (`mtd4 k0` / `mtd5 r0` and `mtd6 k1` / `mtd7 r1`). `M114_sfp_ODI_hybrid_221209.tar` ships with `fwu.sh` that writes a chosen slot (0 or 1) and leaves the other intact. Boa UI at `/admin/upgrade.asp` performs this via the standard upload form. Currently active slot is 0 (per nv `sw_version0`); flashing slot 1 with M114 keeps M110 on slot 0 as fallback.

**Risk:** without bootloader/UART access (PCB pads not publicly documented for DFP-34X), if the new image fails to boot AND the bootloader can't fall back to slot 0, the stick is unrecoverable until the CH341A + SOIC-8 clip arrive. The CH341A is in transit; with it, any flash state is dump-restorable.

**Recommendation:** wait for CH341A, then flash. Until then, stick stays at "O5 reached, mgmt fully accessible, but no data plane" — Huawei remains the working internet path.

### Final state of stick (handed off in this state)

- ELAN_MAC `e0da90c4f885`, MAC_KEY `4b17b17d6b04f12e16cfad0e8a62895e` (correct per HSGQ algorithm)
- GPON_SN `HWTC370F0BAE`, OUI `e0:da:90`, HW_HWVER `343D.D` — Huawei spoof intact
- OMCI_OLT_MODE=1 (Huawei), OMCI_FAKE_OK=1, OMCI_VEIP_SLOT_ID=255, DEVICE_TYPE=0 — reverted to known-good
- omci_app running, stick at O5, laser firing, HTTP UI + telnet both reachable
- M114 binaries staged at `/var/run/m114/` (in tmpfs — wiped on reboot, can re-stage from `/tmp/m114-extract/` on Mac)
- `/cfg/scripts/tcppipe.py` (created by the SSH-proxy agent) is persistent on Route10; `ssh stick` via Mac's `~/.ssh/config` proxies through it. ssh-to-stick currently hangs (dropbear session cap from debug runs); telnet works. Will recover after stick reboot.

---

## 🔥 Evening session — M114 flash + PPPoE wall

### Flash succeeded

M114_sfp_ODI_hybrid_221209.tar uploaded via Boa UI (`POST /boaform/admin/formUpload`, multipart form, field `binary`). 3.8 MB upload in ~5 s. Stick auto-rebooted, came back in ~75 s as **V1.2.2-221209**. MAC_KEY survived the flash (HS partition `mtd3` untouched). Confirmed:

```
ELAN_MAC_ADDR=e0da90c4f885
MAC_KEY=4b17b17d6b04f12e16cfad0e8a62895e
OUI=e0,da,90
GPON_SN=HWTC370F0BAE
HW_HWVER=343D.D
```

Kernel stack swap is real — M114 boot shows `lsmod`: `pf_rg.ko` (router-gateway platform, replacing M110's `pf_rtk.ko`), `rtk_tr142.ko`, `omcidrv.ko`, `bdp_*.ko`. Confirms M114 hybrid runs the HGU code path we needed for VEIP.

PON status post-flash: ONU State O5, Tx 2.26 dBm, Bias 12.85 mA, Rx -17.3 dBm. Same as before — auth path unchanged.

### M114 UI is dramatically richer

`/code.asp` menu now exposes (vs. M110's bare 11): `multi_wan_generic.asp`, `omci_info.asp`, `pon-stats.asp`, `dhcpd.asp`, `bridging.asp`, `acl.asp`, `arptable.asp`, `routing.asp`, `fw-*.asp`, `tcpiplan.asp`, `vlan.asp`, `stats.asp` — full HGU/router UI. All saved as `route10-scripts/m114-*.asp`.

The critical page: **`multi_wan_generic.asp`** — POST `/boaform/admin/formWanEth`. Form is messy. Calling out the gotchas because they cost real time tonight:

| Field | Meaning | Notes |
|---|---|---|
| `lkname` | "new" for new entry, else existing link name (e.g. `nas0_0`) | Existing-link options are injected by runtime JS reading `var links = new Array(...)` |
| `lst` | Same as lkname for existing, empty for new | |
| `vlan` | `ON` or omit (off) | Stick adds VLAN tag to upstream when ON |
| `vid` | VLAN ID | 1011 for our ISP |
| `vprio` | 802.1p PCP | **OFF-BY-ONE in form.** `vprio=0` = "no priority mark", `vprio=1` displays as "0" (actual priority 0), `vprio=2` = "1", etc. For PCP=0 you POST `vprio=1` |
| `adslConnectionMode` | Channel mode | `0`=Bridged, `1`=IPoE (1483mer), `2`=PPPoE, `6`=DS-Lite, `8`=6rd |
| `ctype` | Connection class | `1`=TR069, `2`=INTERNET, `3`=INTERNET_TR069, `4`=Other |
| `chEnable` | Channel enable | `1` |
| `mtu` | MTU | `1500` (form auto-flips to 1492 for PPPoE) |
| `IpProtocolType` | IPv4/IPv6 | `1`=IPv4, `2`=IPv6, `3`=dual |
| `droute` | Default route via this WAN | `0`=no, `1`=yes |
| `chkpt` | Port mapping checkbox | `ON` for the LAN port slot. 4 inputs total (1 visible, 3 hidden) → only the first (LAN_1) is usable in the SFU build |
| `itfGroup` | Computed from chkpt | We set `1` directly (= LAN_1 bit) |
| `apply` | Submit button | `apply=Apply Changes` is required — without it the server replies `Please select one vc!` |
| `delete` | Delete an entry | `delete=Delete` (replace `apply` with this; keep lkname+lst pointing at the entry) |
| `naptEnabled`, `igmpEnabled`, `qosEnabled` | Optional | Bridge mode disables these via JS — don't need to set |

The HTML-commented-out `<input type="submit" name="submitwan">` block is dead — don't waste time on it. **The action is `formWanEth`, the submit is `apply=Apply Changes`.**

### What we tried after M114 to make PPPoE actually flow

Every combination produced the same outcome: **PADIs leave Route10, reach the PON (we even saw other-customer broadcast frames coming back through, confirming OLT is forwarding downstream to us), but BNG never sends PADO back.** Each retry cycle ends in `tcpdump: pcap_loop: The interface went down` (which is netifd recreating `eth4.1011` for each pppd retry, NOT actual carrier loss — `cat /sys/class/net/eth4/carrier` consistently stays 1 during these "down" events).

Specifically these matrices were tested:

| stick `DEVICE_TYPE` | stick `OMCI_VEIP_SLOT_ID` | stick WAN entry | Route10 `wan3.device` | Result |
|---|---|---|---|---|
| 2 (hybrid) | 1 (VEIP on) | `nas0_0` vlan=ON vid=1011 vprio=1, LAN_1 | `eth4` untagged | PADIs out, no PADO. /proc/omci/* mostly empty. Other-customer broadcasts visible briefly post-boot |
| 2 (hybrid) | 1 (VEIP on) | none (let OLT auto-bridge) | `eth4` untagged | PADIs out, no PADO. Stick has no bridge wiring |
| 2 (hybrid) | 1 (VEIP on) | `nas0_0` vlan=OFF (transparent) | `eth4.1011` (Route10 tags) | PADIs out (correctly VLAN-1011 tagged), no PADO. NO downstream — stick stopped bridging in this mode |
| 0 (bridge SFU) | 255 (VEIP off) | `nas0_0` vlan=ON vid=1011 | `eth4` untagged | PADIs out, no PADO |
| 0 (bridge SFU) | 255 (VEIP off) | none | `eth4` untagged | Stick acts like there's no bridge — no downstream observed |

Also tested: `OMCI_VENDOR_PRODUCT_CODE` 15→0 (to look less Huawei-spoof'd), `OMCI_OLT_MODE` 1→3, deleting all WAN entries, multiple reboots between attempts. None changed the PADO behavior.

### Root cause is now narrower but not solved

Combining everything:
1. Stick auth is fine (O5, laser firing, OMCI_FAKE_OK works).
2. Stick host SerDes is fine (carrier stable 30/30 polls when no netifd interference).
3. Stick bridges DOWNSTREAM (other-customers' DHCP/ARP/PADI broadcasts visible on eth4 in some configurations).
4. Stick bridges UPSTREAM at least partially (PADIs reach OLT — confirmed because BNG is the only thing that could "drop or ignore" them at our specific MAC/SN).
5. **But BNG never replies to OUR PADIs.** 

**The pivotal observation:** the user reports that plugging a TP-Link ONU into the same fiber, with only the SN cloned (`HWTC370F0BAE`), gets PPPoE working immediately. That's our oracle: **OLT and BNG accept our SN and would push provisioning, but our specific stick presents OMCI identity (vendor_id=HWTC, product_class=EG8145X6-10, OUI=e0:da:90, software_version=V5R022C00S265) that triggers Huawei-HGU code paths on OLT — pushing a VEIP-flavored bridge config that our M114 hybrid still doesn't apply correctly enough for BNG to recognize our upstream PPPoE as the authorized session.**

TP-Link probably presents simpler OMCI identity (not Huawei-strings everywhere) → OLT pushes generic SFU-style bridge → TP-Link auto-bridges → works.

This means **the next thing to try is desp-spoof selectively** — keep `GPON_SN` (needed for OLT auth) but strip / generalize:
- `HW_CWMP_MANUFACTURER` (currently `HWTC` — try blank or `Realtek` or whatever TP-Link reports)
- `HW_CWMP_PRODUCTCLASS` (currently `EG8145X6-10` — try blank or generic)
- `GPON_ONU_MODEL` (currently `EG8145X6-10`)
- `OMCI_SW_VER1`/`OMCI_SW_VER2` (currently `V5R022C00S265` — try blank or generic Realtek string)
- `OMCI_VENDOR_PRODUCT_CODE` (0 vs 15)

We tried the last one alone tonight, didn't move the needle — but the OMCI ME 256/257 attribute fields probably matter more than the vendor code. **Open question for next session: what exactly does the OLT see when TP-Link is plugged in?** If we can sniff or otherwise capture TP-Link's OMCI fingerprint, we can mimic it.

### Other things learned tonight

- **Boa session is IP-based, single-source.** Only one login per source IP at a time. Our Route10 curls (from src=192.168.1.3) lock the Mac out and vice versa. Always `curl /admin/logout.asp` when done from Route10 if the Mac will be using the UI.
- **mwan3 will blackhole forward packets** without an `ip rule add to 192.168.1.0/24 lookup main priority 100`. Without this rule, Mac→stick traffic via Route10's forward path returns `!H` (host unreachable). This rule survives reboot of stick but probably not Route10.
- **The `/32 dev eth4` route to 192.168.1.1 keeps getting wiped** by Alta's configd. Tcppipe.py re-adds on every connection. Manual workflows need `ip route replace 192.168.1.1/32 dev eth4 src 192.168.1.3` immediately before each operation.
- **`eth4.1011` is auto-created/destroyed by netifd** when `wan3.device=eth4.1011`. tcpdump on eth4 sees these as "interface went down". Sniff on `eth4.1011` directly to avoid noise. Sniff on `eth4` with `vlan 1011` filter to see what's actually on the wire.
- **eth4 MAC-spoof to stick's MAC breaks L2** (ARP collision/loop filter on the bridge). The Huawei WAN MAC `e0:da:90:c4:f8:86` would be safer but we didn't get to test it as a Route10-side spoof.
- **`omcicli` non-interactive output is unreliable** — many subcommands segfault, especially `sfp Data get <port>` (don't run, it crashes ssdk_sh).
- **`stickshell.py` daemon idea** (persistent telnet via screen on Route10) was prototyped but stick's busybox telnetd is too unreliable to sustain — sessions drop, dropbear ssh refuses connections after enough debug runs. Reboots recover briefly. For next session: invest in this daemon hardening (auto-reconnect, command timeout, capture stderr) so we don't lose state every probe.

### Files left in place

- `/cfg/firmware/M114_sfp_ODI_hybrid_221209.tar` on Route10 — persistent across reboot, can be re-flashed.
- `/cfg/scripts/{stick-mgmt.sh, cutover-monitor.sh, tcppipe.py, oneshot.py}` on Route10 — persistent.
- `~/.ssh/config` Host entries `route10` and `stick` (with tcppipe.py ProxyCommand) on Mac — set up by sibling agent earlier in session.
- `/tmp/m114-extract/` on Mac — full M114 squashfs extracted for binary comparison/inspection.
- `route10-scripts/stick-omci.log-2026-05-24` (547 KB) — captured M110 OMCI exchange with OLT (showed VEIP push + failures). This is the irreplaceable evidence of what OLT actually sends.
- `route10-scripts/m114-{multi_wan_generic,omci_info,status_pon,bridging,vlan,...}.asp` — all key M114 UI pages cached.
- `route10-scripts/stick-omci_app-V1.0-220923` — binary copy of M110's omci_app (where MAC_KEY check lives).
- `/tmp/m114-extract/squashfs-root/bin/omci_app` on Mac — M114's omci_app (md5 `0eceb820eb5beada338bc0ca6142e58a`) for comparison.

### Final state at end of session

- Stick in W2 cage, **no fiber attached** (fiber moved back to Huawei for internet)
- Stick state: M114_hybrid_221209, MAC_KEY correct, DEVICE_TYPE=2, OMCI_VEIP_SLOT_ID=1, OMCI_VENDOR_PRODUCT_CODE=15, OMCI_OLT_MODE=1, no WAN entries (we deleted all). On next fiber attach, this is the "closest-working" state we reached.
- Internet via **Huawei → Route10 eth3 (untagged) → pppoe-wan → IP 100.68.x.x**. Working as before all this.
- WAN3 is `ifdown`'d on Route10 (so pppd doesn't keep dialing into an empty W2 cage).
- Route10 mgmt punches for 192.168.1.0/24 on eth4 + ip rule priority 100 still in place — when stick gets fiber again, mgmt UI is reachable.
- LED on W2 cage stays blue/lit even after stick removal — Alta firmware cosmetic glitch, no operational impact. `echo 0 > /sys/class/leds/led10g_p5/brightness` should turn it off but didn't visibly.
- `/cfg/firmware/M114_sfp_ODI_hybrid_221209.tar` saved on Route10 for next session.
- CH341A + SOIC-8 clip still in transit. M110 image is gone from the stick now (M114 took both slots after the flash) — so we're committed to M114 until either CH341A arrives or M114 problems force us to RMA.

### For next session

In priority order:
1. **Find TP-Link's OMCI fingerprint** and mimic it on our stick. The OLT's behavior diff between TP-Link and us is the highest-signal lead we have. If user can plug TP-Link back in briefly while we sniff at OLT/upstream level (won't work — we don't have PON tap) OR check Huawei's OLT-side debug (won't work — admin access), OR look online for documented TP-Link XPON SFP+ OMCI ME 256/257 values for similar setups.
2. **Build a real persistent stickshell daemon** — running 24/7 in screen on Route10, auto-recovery on telnet/dropbear failure, log file of every command. Without this we lose 10+ min per session just on session management.
3. **Try desp-spoof selectively** — first strip just `OMCI_SW_VER` to a generic Realtek build string; if OLT still pushes Huawei provisioning, escalate to stripping `HW_CWMP_PRODUCTCLASS` (set to "RTL960x" or similar).
4. **If 1-3 fail**, the brick-recovery CH341A path: bin-patch M114's omci_app to fix whatever's failing in VEIP→bridge wiring. Requires real reverse engineering of the .so files. High risk, high reward.
5. **ISP rerangear request** (`Pode rerangear a ONU? SN HWTC370F0BAE`) — cheap to attempt but TP-Link working suggests it's our stick at fault, not OLT state. Probably won't help.

## Persistence map (refreshed)

| Location | Backed by | Survives reboot? | Notes |
|---|---|---|---|
| `/cfg/` | NAND ext4 | ✓ | Alta config + our scripts. `/cfg/scripts/{stick-mgmt,cutover-monitor}.sh` chmod'd, W2-only |
| `/cfg/config.json` | NAND | ✓ | Alta UI saves go here. WAN1=`eth3` untagged is persistent. WAN3 PPPoE on `eth4` pre-armed for stick |
| `/etc/`, `/usr/`, `/bin/` | tmpfs overlay | ✗ | Reverts on reboot |
| `/var/run/.route-swd.json`, `.sfp*.bin`, `sfp*.txt` | tmpfs | ✗ | Re-populated by `route-swd` on every boot |
| `/var/run/route-swd.pid` | tmpfs | ✗ | |

## Open questions / things to try next session

1. **`pbj` protobuf-JSON client** — `/usr/sbin/pbj [-i INPUT] [-o OUTPUT] URL`. URL scheme unknown. Strings in `/usr/sbin/black` mention `SPACE_X__API__*` protobuf paths. Likely targets local Alta API daemon. Could expose more cage state than ubus does. Cheap to explore (read-only).

2. **GPIO diff method** to identify W2-specific LOS/MOD_ABS/TX_DISABLE pins. Dump `/sys/kernel/debug/gpio` before and after a fiber insert; diff. The current `gpio25=W2-LOS, gpio31=L4-LOS` assumption in older scripts is probably wrong (today's readings contradicted both polarities).

3. **ISP-side**: call provider, ask to `rerangear a ONU` with SN `HWTC370F0BAE`. Cheap, eliminates OLT-side state as a variable.

4. **Custom firmware**: see research agent output. If feasible without brick risk, this is the path.

5. **Different pppd config**: stock Alta WAN3 has `maxfail=1`. If we ever get the stick stable enough that PPPoE *might* work, bump `maxfail=10` so pppd survives a few PADI retries while the GPON state machine catches up.
