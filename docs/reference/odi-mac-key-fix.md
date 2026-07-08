# ODI DFP-34X-2C3 — the MAC_KEY fix that resolves the O0 wedge

_The root cause across all "stuck at O0" sessions. omci_app's `hsgqMacKeyCheck` validates MAC_KEY = MD5("hsgq1.9a" + UPPERCASE_ELAN_MAC). Junk MAC_KEY → omci_app exits → no PLOAM → forever O0._

**Definitive root cause of the ODI DFP-34X-2C3 "stuck at O0" wedge (multi-session 2026-04 → 2026-05-24).**

The stick runs M110_sfp_ODI_220923 firmware (Realtek SDK V1.0). On startup, `/etc/runomci.sh` calls `omci_app`, which calls `hsgqMacKeyCheck` (visible string in `/bin/omci_app`). That function computes `MD5("hsgq1.9a" + UPPERCASE_HEX_OF_ELAN_MAC_ADDR)` and compares against `MAC_KEY` from the HW MIB table. If mismatch → prints `GPON mac_check fail !!!!!!` and exits. Without `omci_app`, no OMCI/PLOAM with OLT → ONU stays O0 → laser never fires (Tx=-inf, Bias=0).

Our stick had `MAC_KEY=0903625421575fc3fc86cc7565c35451`, which **doesn't match any valid MAC under the algorithm** — set by a previous owner (likely manually pasted a wrong value when cloning the MAC). The cure:

```sh
# Compute correct key for the current ELAN_MAC_ADDR
printf '%s' 'hsgq1.9aE0DA90C4F885' | md5sum
# -> 4b17b17d6b04f12e16cfad0e8a62895e

# Set it on the stick via telnet (admin/admin on port 23)
flash set MAC_KEY 4b17b17d6b04f12e16cfad0e8a62895e

# Reboot — omci_app starts, ranges with OLT, reaches O5
```

**Why:** weeks of misdiagnosis (kept blaming firmware wedge, OLT, fiber, host SerDes flap, route-swd, etc.). All wrong. It was a single field of pre-computed junk that the firmware's integrity check correctly rejected. With correct MAC_KEY the stick goes straight to O5.

**How to apply:**
- For any future DFP-34X-2C2/2C3 (HSGQ M110 firmware) "stuck at O0" symptom, **check MAC_KEY first**. `flash get MAC_KEY` then verify `MD5("hsgq1.9a" + upper(ELAN_MAC))` equals it. If not — set it.
- This algorithm is specific to **HSGQ-OEM firmware**. Other RTL9601D firmware uses `VS_AUTH_KEY` (same purpose, possibly different secret prefix).
- Source: https://github.com/Anime4000/RTL960x/blob/main/Docs/Setup_Stick.md (DFP-34X-2C2 section, "If using V1.0-220304 or newer firmware, changing ELAN_MAC_ADDR require to update MAC_KEY").
- Full debug trail in `archive/captures-2026-05/stick-flash-recon-2026-05-24.log`, `stick-mac-recon-2026-05-24.log`, `stick-tamper-recon-2026-05-24.log`, `stick-hs-snapshots-2026-05-24.log`.

**Side facts learned:**
- Stick HTTP UI at `http://192.168.1.1/admin/login.asp` — admin/admin (Realtek Boa webserver).
- Telnet on port 23 — admin/admin (busybox 1.12.4 ash shell).
- HSGQ-specific function names visible in `omci_app`: `hsgqMacKeyCheck`. Realtek calls: `MD5Init/Update/Final/toString`.
- Pre-cooked diagnostics: `/var/config/lastgood_hs.xml` (current HS), `/var/config/lastgood_mp_hs2.xml` (factory MP backup with original ODI identity: ELAN_MAC `38:3a:21:28:06:81`, HW_SERIAL `XPON20200681`, MANUF `HSGQ`, PRODUCT `M111`, OUI `11:11:11`).
- The "previous owner" overwrote ELAN_MAC, OUI, GPON_SN, vendor strings — but failed to regenerate MAC_KEY for the new MAC.

**Note:** the `flash set` persistence behavior described here applies to M110. On M114 firmware, `flash set` is runtime-only — see the M114 MIB persistence model reference. Don't assume cross-firmware.
