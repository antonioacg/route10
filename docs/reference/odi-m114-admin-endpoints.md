# ODI M114 — admin HTTP endpoints + form quirks (curl-callable)

_Working admin URLs on M114_hybrid_221209, correct login form fields (`password` not `psd`), the HTTP/0.9 requirement, and persistence verification via the `save_cs` dump._

**Login (correct field name — `password`, not `psd`):**
```sh
curl --http0.9 -X POST --interface 192.168.1.2 \
  -d "username=admin&password=admin&challenge=&save=Login&submit-url=%2Fadmin%2Flogin.asp" \
  http://192.168.1.1/boaform/admin/formLogin
```
- Field is `password`, NOT `psd`. (An earlier reverse-engineered POST used `psd` — wrong on M114, likely also on M110 — which may have silently failed, contributing to the long PPPoE wall.)
- All curl calls need `--http0.9` (stick speaks HTTP/0.9, modern curl rejects by default).
- Login response: 200 or 301 (redirect to `/`) both = success.
- Session is IP-bound but bound at boa-side per-source-IP; multiple curl calls from same source IP share session.
- "Change setting successfully!" response from form POSTs is a generic Boa message. **Does not prove the underlying MIB layer accepted the values.** Verify via save_cs (below).

**Working admin URLs on M114 (verified 2026-05-25):**
| URL | Purpose | Notes |
|---|---|---|
| `/admin/login.asp` | login form | open, no auth |
| `/admin/status.asp` | device status (uptime, fw ver, memory) | post-login |
| `/admin/pon-stats.asp` | PON byte/packet counters | all zeros pre-O5 (definitive "not ranged" signal) |
| `/admin/multi_wan_generic.asp` | WAN entries list | post `formWanEth` from here |
| `/admin/omci_info.asp` | OMCI identity fields (vendor, sw_ver, product_class, hw_ver) | post `formOmciInfo` |
| `/admin/saveconf.asp` | backup/restore/reset | only `save_cs` is active; reset/restore commented out |
| `/admin/rebootTime.asp` | reboot | post `formReboot` with `reboot_now=Reboot` |

**Dead URLs on M114 (404):** `/admin/status_pon.asp` (M110 only), `/admin/omci_info.asp` only works post-login.

**Persistence verification (the critical trick):**
```sh
# After any form POST, dump the on-disk lastgood.xml via save_cs:
curl --http0.9 -X POST --interface 192.168.1.2 \
  -d "save_cs=Backup..." \
  http://192.168.1.1/boaform/formSaveConfig -o cfg.xml
grep -iE "FIELD_NAME" cfg.xml
```
The dump returns the literal `/var/config/lastgood.xml` content (~11KB). If FIELD has the new value → form POST persisted. **DO NOT** use `flash get` to verify — it reads runtime in-memory MIB only and lies about disk state.

**Persistence ≠ runtime persistence:**
Even if `save_cs` shows the new value, some fields (e.g. `OMCI_SW_VER1/2`) get re-pinned from `/lib/libmib.so` defaults on every boot. To check: reboot stick, run `save_cs` again, see if value survived. See the M114 MIB persistence model reference.

**formOmciInfo full field list (POST to `/boaform/admin/formOmciInfo`):**
- `omci_vendor_id` (text, maxlen 4) — e.g. `HWTC`
- `omci_sw_ver1` (text, maxlen 14) — e.g. `V5R022C00S265`
- `omci_sw_ver2` (text, maxlen 14)
- `omcc_ver` (select; common: `128`=0x80)
- `omci_tm_opt` (select; values 0/1/2)
- `cwmp_productclass` (text, maxlen 20) — e.g. `EG8145X6-10`
- `cwmp_hw_ver` (text, maxlen 14) — e.g. `343D.D`
- `apply=Apply Changes` (required, or server replies error)
- `submit-url=/omci_info.asp`

**formWanEth WAN-entry quirks (POST to `/boaform/admin/formWanEth`, from `/admin/multi_wan_generic.asp`) — absorbed from a now-retired WAN-form memory:**
- `apply=Apply Changes` required — without it the server replies `Please select one vc!`.
- **`vprio` is off-by-one and critical:** `vprio=1` → the UI displays "0" = PCP=0 explicit (CORRECT); `vprio=0` = NO 802.1p priority field in the tag at all → malformed for the BNG.
- `chkpt=ON` for LAN_1 port mapping.

## Boa "Change setting successfully!" lies

**Boa's "Change setting successfully!" HTML response is generic and lies.** It returns 200 + the success page even when:
- The form params were silently rejected by the MIB layer (e.g., a missing required field, wrong encoding)
- The change was applied to runtime MIB but NOT written to `/var/config/lastgood.xml` (won't survive reboot)
- The change was written to lastgood.xml but a separate layer (libmib defaults, switch-fabric data plane) wasn't updated

This cost ~10 hours across two sessions (2026-04 → 2026-05-25). A prior agent assumed POSTs worked because Boa said so, then chased the wrong root cause (OLT-side, BNG-side, frame format) for an entire session before realizing the stick's bridge data path simply hadn't been wired because the nas0_0 entry was only in runtime MIB, not in the boot-time config.

**How to apply:**

1. **After any form POST that matters: verify with `save_cs` dump:**
   ```sh
   curl --http0.9 -X POST --interface 192.168.1.2 \
     -d "save_cs=Backup..." \
     http://192.168.1.1/boaform/formSaveConfig -o cfg.xml
   grep -iE "FIELD_NAME.*Value" cfg.xml
   ```
   If the value isn't in lastgood.xml, the POST didn't actually persist — re-POST or find the missing field.

2. **For data-plane changes (bridge entries, OMCI identity, VLAN setup): reboot the stick** after the POST + verify, then test functionality. The data path doesn't pick up new MIB entries until boot.

3. **`flash get FIELD` reads runtime MIB only** — useless for verifying persistence. Some fields (like OMCI_SW_VER1) read from libmib.so defaults at runtime regardless of lastgood.xml, so `flash get` lies in both directions.

4. **Sequence that worked for PPPoE wiring** (see the ODI PPPoE working recipe):
   ```
   formOmciInfo POST → save_cs verify
   formWanEth POST   → save_cs verify
   formReboot POST   → wait 60-90s
   then dial PPPoE   → PADO returns first try
   ```
   Skipping the reboot = no PADO, no matter how perfect the config looks in the UI.
