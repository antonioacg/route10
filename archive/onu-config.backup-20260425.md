# ONU Migration — Huawei EG8145X6 → SFP+ Stick

Captured values for the SFP+ stick to clone. Keep this file gitignored.

## Topology
- Huawei EG8145X6 at `192.168.18.1` (management subnet, reachable from the Orange Pi at 192.168.0.100, **not** from the Mac — Alta Labs routes it only to the Pi).
- Huawei is in **bridge mode**. PPPoE runs on the **TP-Link** at `192.168.0.1` (current router; Alta Labs Route 10 is the planned replacement), not on the ONT.
- Single VLAN (`1011`) carries all internet traffic.

## Huawei ONT values — captured 2026-04-17

Source: `ont-monitor dump` as `Epadmin:adminEp`, parsed from raw HTML in `ont-monitor-identity/ont-dump/`.

| Field | Value | Source |
|---|---|---|
| **GPON SN (ASCII, 12-char)** | `HWTC370F0BAE` | deviceinfo.asp, via `conv16to12Sn()` |
| **GPON SN (hex, 16-char)** | `48575443370F0BAE` | deviceinfo.asp `stDeviceInfo.SerialNumber` |
| Vendor ID | `HWTC` (= `0x48575443`) | deviceinfo.asp |
| Hardware version | `343D.D` | deviceinfo.asp |
| Software version | `V5R022C00S265` | deviceinfo.asp |
| Model | `EG8145X6-10` | deviceinfo.asp |
| Release | `2023-06-29_16:58:37` | deviceinfo.asp |
| LAN MAC | `E0:DA:90:C4:F8:85` | deviceinfo.asp |
| WAN MAC (PPPoE leg, unused in bridge mode) | `E0:DA:90:C4:F8:86` | getwanlist.asp |
| Product ID | `2150086688HYPB038862` | deviceinfo.asp Description |
| **WAN VLAN (INTERNET, bridge)** | `1011` | getwanlist.asp `2_INTERNET_B_VID_1011` |
| **802.1p priority** | `0` | getwanlist.asp |
| WAN mode (bridge connection) | `IP_Bridged` / DHCP | getwanlist.asp |
| PPPoE username (server-stored, unused) | `410563@btt` | getwanlist.asp |
| **PPPoE password** | `410563@btt` (same as PPPoE username — Antonio confirmed) | out-of-band; Huawei redacts for Epadmin |
| PLOAM password | **not exposed to Epadmin** | GPON-config pages 404 without `telecomadmin` |
| LOID / LOID password | **not exposed to Epadmin** | same |

### What this means for the SFP+ stick

Minimum to register on the OLT:
- **GPON SN: `HWTC370F0BAE`** — clone this into the stick.
- **Equipment ID: `HWTC`**, **Vendor ID: `HWTC`** — automatic once SN is cloned; some sticks ask explicitly.
- **HW/SW version strings** — clone if the stick firmware accepts custom strings *and* the ISP fingerprints ONTs (rare for residential). Safe to clone: `343D.D` / `V5R022C00S265`.

After the OLT authenticates the stick by SN, the router behind it must send/receive tagged **VLAN 1011** frames on the PPPoE interface. Current TP-Link presumably already does this (link is up today). When swapping to the Alta Labs Route 10, replicate: PPPoE on `vlan 1011`, priority 0, user `410563@btt`, password TBD.

PLOAM / LOID almost certainly **not required** — Brazilian residential GPON (Oi, Vivo, TIM Live, Claro/Net) typically auths by SN only. If registration fails anyway, the next step is capturing PLOAM from the Huawei as `telecomadmin`; that account's default password is ISP-specific and I won't guess it.

## PPPoE password — resolved

Same as the PPPoE username: `410563@btt` — Antonio confirmed out-of-band.
Huawei firmware redacts this field to Epadmin (`***sensitive data replaced***`
in `getwanlist.asp`); only `telecomadmin` would see it via the web UI.
No TP-Link scrape needed.


## Files

Raw scraper output: `../ont-monitor-identity/ont-dump/`
- `html_ssmp_deviceinfo_deviceinfo.asp.html` — device info
- `html_bbsp_common_getwanlist.asp.html` — WAN connection list with VLANs
- `html_bbsp_wan_wan.asp.html` — WAN UI page (mostly JS)
- `html_amp_opticinfo_opticinfo.asp.html` — optical telemetry (not needed for migration, but captured)
- `html_bbsp_common_wan_settings.asp.html`, `wan_list_info.asp`, `wan_pageparse.asp`, `wanaddressacquire.asp`, `wandns.asp` — WAN UI helpers

Scraper branch/worktree: `feat/onu-identity-scraper` at `/Users/antoniocasagrande/dev/ont-monitor-identity`.

Huawei credentials used: `Epadmin` / `adminEp` (password Antonio's).
