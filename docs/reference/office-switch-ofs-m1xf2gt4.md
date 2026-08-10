# Office switch — OptFocus OFS-M1XF2GT4 (RTL8372) research (2026-08-10)

The far end of the L4/eth5 10G BiDi fibre. Everything below the "Community and
firmware" section is **first-party, measured on the unit** — it will not be found
by searching, which is the point of writing it down.

Reached during the 2026-08-10 session that started from "we collect no metrics
from the office switch". Companion to `eth5-lan-fiber-crc.md` (the fibre itself)
and `custom-firmware-research.md` (same shape, for the ODI stick).

## Why we care

`.200` (opi5pro), `.241` (AdGuard VIP) and `.242` (syslog collector) all sit on the
office side of this fibre. Every metrics scrape, every syslog line and every LAN
DNS query to AdGuard crosses this switch. When it degrades it presents as "route10
is unreachable" — the exact ambiguity the dead-man beat pair exists to resolve.

## Identity

| Fact | Value | Source |
|---|---|---|
| Model | `OFS-M1XF2GT4` | `info.cgi`, and the `<title>` on every page |
| Brand | OptFocus (Shenzhen OptFocus Technology Co., Ltd) | Alta portal client list, "Make" field |
| **SoC** | **Realtek `RTL8372`** | **`strings` on its own config backup** — see below. Not inferred from port count. |
| Firmware | `V100.9.9.1.7`, dated June 7 2025 | `info.cgi` |
| Hardware | `V2.1` | `info.cgi` |
| MAC | `cc:52:89:0a:d5:8e` (OUI `CC:52:89`) | ARP, Alta portal |
| Ports | 6: **4x 2.5G copper** (1-4, offer 10/100/1000/2500) + **2x 10G SFP+** (5-6, offer 100/1000/2500/10G) | `port.cgi` |
| Uplink | **Port 5 = 10GFull** = route10 `eth5` / L4 cage. Port 6 empty (`Link Down`). | `port.cgi` cross-referenced with eth5 |
| Factory defaults | `192.168.1.168`, `admin`/`admin` | observed after it reset itself |
| Current address | `192.168.10.153` by DHCP, hostname `OFS-M1XF2GT4` | `/cfg/dhcp.leases`, 2026-08-10 |

**Finding the SoC:** `GET /config_back.cgi?cmd=conf_backup` returns a 2,669-byte
binary. `strings` on it yields `RTL8372`. That is how the chipset was established —
no teardown, no FCC filing, no guessing from the port layout.

## Management surface — the whole of it

**Only TCP/80 is open.** No telnet, no SSH, no debug port. Verified with real TCP
connects across 19 ports; the only remaining shell path would be a physical UART
header inside the case.

⛔ **busybox `nc -z` on route10 reports every port closed, including port 80 while
HTTP was demonstrably serving.** It is unusable for this. Use python3 `socket.connect`
or curl. This wasted a cycle and produced a confidently wrong "no ports open".

### Auth is trivially scriptable

```js
// from login.cgi
Response = hex_md5(username + password);
document.cookie = "admin=" + Response;
```

The session cookie is a **constant** `MD5(username+password)`. For `admin`/`admin`
that is `f6fdffe48c908deb0f4c3bd36c032e72`. No nonce, no expiry, no CSRF token, sent
in cleartext over HTTP on every request.

⚠ **Every CGI also requires a `Referer` header.** Without it the page returns
**`404 Not found` with a 2-byte body** — which looks exactly like an empty page or a
rate limit and sent this investigation chasing a phantom "one session at a time"
theory. With `-b cookie -e http://<ip>/` everything works.

```sh
CK=$(python3 -c "import hashlib;print(hashlib.md5(b'adminadmin').hexdigest())")
curl -s -b "admin=$CK" -e "http://192.168.10.153/" http://192.168.10.153/info.cgi
```

Because auth is a static hash rather than a server-side session, **scripted polling
does not evict a logged-in browser session.**

### Every page the firmware has

`config_back.cgi` `eee.cgi` `fwd.cgi` (`?page=jumboframe`, `?page=storm_ctrl`)
`fwug.cgi` `igmp.cgi` `info.cgi` `ip.cgi` `logout.cgi` `loop.cgi` (`?page=stp_global`,
`?page=stp_port`) `mac.cgi` `mac_constraint.cgi` `port.cgi` `qos.cgi` `reboot.cgi`
`reset.cgi` `save.cgi` `trunk.cgi` `user.cgi` `vlan.cgi`

Config backup is `GET /config_back.cgi?cmd=conf_backup`; restore is a multipart
`POST` to `?cmd=conf_restore`.

## Telemetry — what is actually reachable

⚠ **An earlier version of this doc said there were no counters at all. That was
wrong**, and the way it was wrong is the lesson: the menu plainly shows a
`?page=` idiom (`fwd.cgi?page=jumboframe`, `igmp.cgi?page=dump`,
`loop.cgi?page=stp_port`) and the first pass only probed page *filenames*, never
`?page=` *parameters* on an existing page. The counters were one query string away.

| Reachable | Endpoint |
|---|---|
| per-port link state, negotiated speed, duplex, flow control | `port.cgi` |
| **per-port `TxGoodPkt` / `TxBadPkt` / `RxGoodPkt` / `RxBadPkt`** | **`port.cgi?page=stats`** (unlinked from the menu) |
| MAC forwarding table | `mac.cgi?page=fwd_tbl` |
| model / firmware / MAC / IP | `info.cgi` |

| Confirmed ABSENT | Evidence |
|---|---|
| **SFP DDM / optical power** | `transceiver.cgi` → **404**. Present on sibling models (see below), not on this firmware. |
| SNMP | no agent, no menu page, no udp/161 reply with `public` (probed from route10, with a TCP control proving reachability) |
| byte counters (packets only) | `stats` page exposes packet counts, not octets |
| temperature, uptime | no field anywhere |

**Counter encoding:** values render as `high-low` and the page's own JS reassembles
them as `high * 4294967296 + low`. So `0-8095089` is 8,095,089. Any scraper must do
the same or it will read a 64-bit counter as a string.

⛔ **`?page=` probing needs a control.** Unknown values silently render the DEFAULT
page rather than 404ing: `port.cgi`, `port.cgi?page=zzzznonsense` and
`port.cgi?page=ddm` are all byte-identical at 3437 bytes. A size- or status-based
probe therefore reports EVERY guessed name as a hit. Only `?page=stats` (3954 bytes)
differs. Always diff against a deliberately nonsensical parameter.

### The fibre blind spot is now PARTIALLY closed

`RxBadPkt` on **port 5** is the far-direction error counter — corruption travelling
route10 → office, which route10 itself structurally cannot see (at 10G it is dropped
at the far end's PCS). First reading, 2026-08-10:

| Port | TxGood | TxBad | RxGood | **RxBad** |
|---|---|---|---|---|
| 1 | 8,095,089 | 0 | 13,163,301 | 0 |
| 2 | 367,465 | 0 | 1,279,100 | 0 |
| 3 | 4,159,776 | 0 | 3,211,437 | 0 |
| 4 | 6,228,364 | 0 | 3,770,405 | 0 |
| **5 (10G → route10 eth5)** | 19,880,567 | 0 | 16,508,185 | **1,239** |
| 6 (empty SFP) | 0 | 0 | 0 | 0 |

**Port 5 is the only non-zero, and route10's own `rx_crc_err` on eth5 reads 0** — so
this is a genuinely one-directional signal that nothing has ever observed here.
⚠ Do not over-read it: counters reset on switch reboot (last one ~14:08 that day),
`RxBad` is not necessarily CRC (it lumps error causes together), and 1,239 against
16.5 M good is ~0.0075%. Trend it; do not diagnose from one sample.

**Still unobtainable:** far-end Rx *optical power*. That needs DDM, which this
firmware does not expose, so degradation still shows only as errors after the fact
rather than as light level beforehand.

## Config persistence — `save.cgi` is a separate step

Settings pages **Apply** to the running config. `save.cgi` is a distinct page that
writes to the startup config. Apply without Save survives until the next reboot and
no further.

This explains the 2026-08-10 "it reset itself" episode — lost admin password *and*
lost DHCP setting *and* back on `192.168.1.168`/`admin`:`admin` — without needing a
hardware fault. It rebooted (see below) with an unsaved config.

**Do not conclude "failing NVRAM" until you have done Apply → Save → deliberate
power cycle → verify.**

## Reboot history, and how to date it

route10's own uptime spanned all of these, so **every transition is the far end**:

| When (local) | eth5 transitions |
|---|---|
| 2026-08-09 08:54–08:55 | 6 — one down, then 3 rapid up/down cycles |
| 2026-08-10 09:01–09:03 | 4 |
| 2026-08-10 14:02–14:08 | 10 in six minutes |

Source: `/a/obs/kernel-ring.log` (obs-collect persists the kernel ring; the volatile
ring would have lost this). `nss-dp 3a514000.dp6 eth5: PHY Link is down/up`.

⚠ **The device exposes no uptime field**, so the switch cannot date its own reboots —
the router's kernel ring is the only clock. `route10_eth_carrier_changes_total{iface="eth5"}`
(added 2026-08-10) is the counter for this going forward; it read 29 vs eth4's 1.

## Addressing — and the trap

It shipped/reset onto `192.168.1.168/24` gw `192.168.1.1`. ⛔ **That collides with
route10's ONT management MACVLAN** (`ont_mgmt0` = `192.168.1.2/24` on eth4, ODI stick
at `192.168.1.1`). While it sat there, `ip route get 192.168.1.168` resolved to
`dev ont_mgmt0` — the router sent office-switch traffic out the WAN stick interface.

Reaching it in that state needs a **`/32` host route, never a `/24`** (a /24 would
add a second connected route for the same prefix and fight ont_mgmt0):

```sh
ip addr add 192.168.1.9/32 dev br-lan
ip route add 192.168.1.168/32 dev br-lan src 192.168.1.9
```

Now on **DHCP at `192.168.10.153`**, which removes the collision entirely. Prefer a
**portal DHCP reservation** to pin it (portal-first rule: local dnsmasq edits are
wiped on cloud reapply).

**Reset detector:** anything answering on `192.168.1.168` again means it factory-reset.

## ⛔ Security posture — treat the management plane as UNAUTHENTICATED

- Session cookie is a constant `MD5(user+pass)`, cleartext, no expiry. Observe one
  request, replay forever. It is password-equivalent and offline-crackable back to
  the plaintext. Our computed `MD5("adminadmin")` = `f6fdff…2e72` matches the hash
  published in the community reverse-engineering table for this ODM — same firmware.
- **A hidden vendor account `hengrui`** (published hash `81d57ea79621e8887914f40ee4122185`)
  served by a separate `login_ft.cgi`. Not removable from the UI.
- **Factory CGI pages are reachable with ORDINARY ADMIN CREDENTIALS**, unlinked from
  the menu. Verified present on our unit 2026-08-10 (distinct sizes, not the
  fallback page): `login_ft.cgi` 2306 B, `menu_ft.cgi` 5270 B, `ftlogo.cgi` 452 B,
  `ftcolor.cgi` 4751 B.
- ⛔ **`ftdft.cgi` factory-resets the switch from a single URL, and this UI has no
  CSRF tokens.** Deliberately NOT requested during this research. Do not fetch it
  to "see what it does" — that is the config-wipe button.
- The bootloader password for the v100.x line is a **published shared constant**
  (`Lx+2035&asp`; XOR-obfuscated with key `0x5a` in the image).
- No CVE, no advisory, no security contact exists for this family. There will never
  be a fix.
- Config backup contains the username plus an obfuscated credential blob. **Never
  commit a backup file to git.**

Practical: keep it off anything untrusted, never reuse that password, and if the LAN
is ever segmented this belongs on an isolated management VLAN.

## Community and firmware (researched 2026-08-10)

### Who actually makes it

| Fact | Source |
|---|---|
| ODM is **HRUI / hongyavision**, board family `SWTG###AS`; our 4x2.5G + 2xSFP+ managed unit is the **`SWTG024AS`** board | [up-n-atom/SWTG118AS](https://github.com/up-n-atom/SWTG118AS) |
| Same-PCB siblings: **Horaco ZX-SWTG124AS**, **Sodola SL-SWTG124AS-D**, **XikeStor SKS3200M-4GPY2XF** | as above + vendor manuals |
| OptFocus and Horaco ship **MD5-identical firmware** (`b06c8b3f1882573b2927bdbc2a0ee8bf`, PCB `SWTG024AS-A-V2.0.1`) | [RTLPlayground #40](https://github.com/logicog/RTLPlayground/issues/40) |
| `V100.x`/`V200.x` is the **newer, hardened** HRUI generation; the older line is `v1.9.x`. The AES/UID algorithm and bootloader password both changed at the boundary. | up-n-atom |

So community documentation for this hardware lives under **Horaco / Sodola / HRUI**,
not OptFocus. Search those names.

### ⛔ OpenWrt: architecturally impossible, not merely unsupported

**RTL8372/8373 is a DW8051 microcontroller at 125 MHz with 64 KB XRAM.** It cannot
boot Linux. OpenWrt's `realtek` target covers RTL838x/839x/930x/931x MIPS SoCs — a
different silicon family. There is no port, no branch, no patch series, and none is
coming. In modern designs (e.g. GL.iNet Flint 3) the RTL8372N appears as a dumb
switch chip hanging off a real host SoC over MDIO — that is its intended role.

Do not spend another minute on this question.

### RTLPlayground — the only open firmware, and it is BROKEN ON THIS EXACT MODEL

[logicog/RTLPlayground](https://github.com/logicog/RTLPlayground) is an active
from-scratch 8051 firmware for RTL8372/8373 targeting our exact port layout. It
would give everything we want: `/status.json` with full SFP DDM (temp, Vcc, Tx/Rx
power, Tx bias, LOS, vendor/model/serial) and `/counters.json?port=N` with 104+ MIB
counters including CRC, fragments, jabbers and queue drops, plus remote syslog.

⛔ **[Issue #61 is titled with our exact model, `OPTFOCUS OFS-M1XF2GT4`.** Someone
already flashed it: it boots and initialises, then **every port stays Down with zero
counters and it never gets an IP**. Open, no maintainer response.](https://github.com/logicog/RTLPlayground/issues/61)

That converts flashing from a calculated risk into a known-bad outcome. Also note it
ships **no STP and no DHCP client** — we currently address this switch *by DHCP*, so
even a working flash would change how we reach it.

Getting *in* needs no soldering (`rtlplayground_oem_upgrade.bin` installs from the
stock firmware-upgrade page). Getting *out* does: **SOIC-8 clip + CH341A** on the
flash chip. The project's own README says do not install unless you can dump the
original flash first.

### Vendor firmware: none exists, anywhere

- `optfocusfiber.com`'s download page hosts **5 industrial-switch PDFs and zero
  firmware** — and no datasheet for our model.
- Its contact page is an **unfilled site-builder template** (invented executives, a
  Kyoto address under city "Melbourne", placeholder emails). There is no real
  support channel; the live ones are their Alibaba/AliExpress stores.
- **No image newer than `V100.9.9.1.7` exists publicly**, no changelog for any
  `V100.x` build, and the literal string does not appear on the indexed web. Our
  running image may be the only copy outside the vendor.
- ⛔ **Do NOT flash Sodola's published `1.9` images.** That crosses the generation
  boundary where the AES/UID gating and bootloader password changed. No first-person
  cross-flash success *or* brick report exists in this family — unverified, not
  known-safe.

**SNMP will never arrive**: an 8-bit 8051 core with ≤2 MB SPI flash has no room for
an SNMP stack. This is a hardware-class ceiling, not a vendor oversight.

### The spontaneous factory reset is a documented complaint on this exact model

CNX Software, reviewing this class, names *"the OPTFOCUS OFS-MX1F2GT4 with four
2.5GbE ports and two 10GbE SFP+ cages"* and reports complaints about **"settings
going back to factory settings in case of power loss"**.

Mechanism (inference from the documented flash map, not a vendor statement, but it
fits our symptom exactly): **all user settings live in a single 0xA42-byte region at
`0x001FE000`.** A power cut or reboot during the erase/write of that one sector
leaves it blank and the firmware falls back to factory defaults — losing the admin
password and the DHCP setting *together*, which a forgotten `Save` would not do.

Both explanations are real and not exclusive: `Tools > Save` genuinely is a separate
commit step that bites people. But whole-block loss points at the sector write.

⚠ **No corroboration found anywhere for repeated spontaneous reboots** on this
family — that remains our own observation, not a known defect. The nearest adjacent
report is management-interface instability tied to **specific SFP+ transceiver
modules** on sibling hardware. If the reboots are real they are almost certainly the
*cause* of the config loss, not a separate fault.

### Serial console (read-only poking is zero-risk)

Header `T5` on the SWTG024AS board: pin 1 TX, 2 GND, 3 RX, 4 3V3. **57600 8N1** on
web-managed units. Gives a real `RTL8372:` shell with `fiber`, `showip`, `regget`.
Reading is safe; `regset` and bootloader entry are where risk starts. The loader
also has a **failsafe firmware-upload page at `192.168.1.1`** if the runtime fails,
forced by holding ESC at power-on.

### If we ever want true optical telemetry, it means new hardware

OpenWrt 25.12 with working 2.5G copper — best candidate **Zyxel XGS1210-12**
(RTL9302B, 8x1G + 2x2.5G + 2xSFP+). ⚠ Two caveats that undercut the idea: SFP DDM on
the `rtl930x` target is **not cleanly verified** by anyone, and on OpenWrt DSA the
`/proc/net/dev` counters for switch ports only count CPU-port traffic, so naive
SNMP IF-MIB would undercount hardware-forwarded traffic badly. We could spend money
and land somewhere worse than a working `port.cgi?page=stats`.

### Verdict

**Keep the stock firmware. Flash nothing.** Build the exporter on
`port.cgi?page=stats`, accept that far-end optical power is unavailable, and treat
`RxBadPkt` on port 5 as the far-direction signal we did not previously have.

## Local artifacts

- Config backup: kept out of the repo (credential material). Re-take any time with
  the `conf_backup` GET above.
