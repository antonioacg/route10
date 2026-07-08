# ODI M114 — MIB persistence model (and what doesn't survive reboot)

_On M114, `flash set` is runtime-only. UI form POSTs persist to lastgood.xml. But some fields (OMCI_SW_VER1/2) are hardcoded in libmib.so and re-pinned on every boot regardless. Verify persistence via `save_cs` dump, NOT `flash get`._

M114_sfp_ODI_hybrid_221209 firmware has a different MIB persistence model than M110, and previous-session memory (see the ODI MAC_KEY fix reference) about `flash set` writing immediately to flash is **WRONG for M114**.

**Layers, from bottom to top:**
1. **libmib.so defaults** — hardcoded compiled-in. `/lib/libmib.so` contains baked defaults (e.g. `OMCI_SW_VER1=V1R007C00S001`). Loaded by `xmlconfig -def_mib` at boot.
2. **/etc/config_default.xml** — firmware default overlay. Loaded with `xmlconfig -def`.
3. **/var/config/lastgood.xml** — persistent user config (MTD-backed via `mnt_cfgfs.sh` mounting the "config" mtd partition to `/var/config`). Loaded with `xmlconfig -if`.
4. **Runtime in-memory MIB** — used by `omci_app`, `flash get` reads from here.

**flash set (telnet)**: M114's `etc/scripts/flash` script DOES call `xmlconfig -of $LASTGOOD_FILE` after the set, BUT in practice the set never made it to lastgood.xml on the stick we tested (2026-05-25). Could be a permissions/lock thing. Either way: `flash set` cannot be trusted for persistence on M114.

**UI form POST (e.g. `/boaform/admin/formOmciInfo`)**: DOES write to lastgood.xml — verified by the `save_cs` config dump endpoint showing the new value post-POST. BUT specific fields including `OMCI_SW_VER1/2` get RE-PINNED on every boot by libmib.so defaults overriding lastgood — the runtime MIB after boot shows `V1R007C00S001` even when lastgood.xml has `V5R022C00S265`. So persistence to disk ≠ persistence at runtime for these fields.

**Verification gotcha (cost us a session loop):** `flash get FIELD` reads runtime in-memory MIB, NOT lastgood.xml. After a form POST, `flash get` showing the new value tells you nothing about whether it persisted. The correct check is:
```sh
# from Mac, via Route10:
curl --http0.9 -X POST -d "save_cs=Backup..." http://192.168.1.1/boaform/formSaveConfig -o cfg.xml
grep -i FIELD_NAME cfg.xml
```
That dumps lastgood.xml content directly. If FIELD is in there with the right value, the form POST persisted. (Whether it survives boot is a separate question — depends on whether libmib.so re-pins it.)

**Why this matters:**
- The prior session's "selective de-spoof" plan (strip `OMCI_SW_VER1/2` to non-Huawei strings) is **not feasible on stock M114** without binary-patching libmib.so. The field gets pinned to `V1R007C00S001` regardless of what we set.
- Other OMCI form fields (`omci_vendor_id`=HWTC, `cwmp_productclass`=EG8145X6-10, `cwmp_hw_ver`=343D.D, `omcc_ver`, `omci_tm_opt`) may or may not be hardcoded — needs same test per field. The grep `V1R007C00S001` only found libmib.so as the source; HWTC and EG8145X6-10 don't have similar hardcoded values in the firmware (per `grep -rl HWTC /lib/`), so they MAY persist via UI POST → lastgood.xml.

**How to apply:**
- For any persistence experiment on M114: POST via UI, then verify via `save_cs` dump immediately, then reboot, then verify via `save_cs` dump again. Both must show the new value for true persistence.
- If a field reverts at boot only (in dump pre-reboot is correct, post-reboot is wrong), it's libmib-pinned and needs binary patching to override.
- Note on the ODI MAC_KEY fix reference: M110 `flash set` persisted, M114 `flash set` is runtime-only. Don't assume cross-firmware.
