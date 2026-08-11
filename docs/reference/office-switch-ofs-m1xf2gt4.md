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
| **SoC** | **Realtek RTL837x**, almost certainly `RTL8372` | `strings` on its own config backup. ⚠ See the confidence note below — this is FIRMWARE-reported, not silicon-verified. |
| Firmware | `V100.9.9.1.7`, dated June 7 2025 | `info.cgi` |
| Hardware | `V2.1` | `info.cgi` |
| MAC | `cc:52:89:0a:d5:8e` (OUI `CC:52:89`) | ARP, Alta portal |
| Ports | 6: **4x 2.5G copper** (1-4, offer 10/100/1000/2500) + **2x 10G SFP+** (5-6, offer 100/1000/2500/10G) | `port.cgi` |
| Uplink | **Port 5 = 10GFull** = route10 `eth5` / L4 cage. Port 6 empty (`Link Down`). | `port.cgi` cross-referenced with eth5 |
| Factory defaults | `192.168.1.168`, `admin`/`admin` | observed after it reset itself |
| Current address | `192.168.10.153` by DHCP, hostname `OFS-M1XF2GT4` | `/cfg/dhcp.leases`, 2026-08-10 |

**Finding the SoC:** `GET /config_back.cgi?cmd=conf_backup` returns a 2,669-byte
binary. `strings` on it yields `RTL8372`.

⚠ **How much that proves — an honest grading.** That string is *firmware-reported*,
the same class of evidence as a boot banner, and banners in this family are
documented to lie: a TrendNet TEG-S562 announces `RTL8373` over an `RTL8372` die.
Vendors also swap N / non-N silicon silently under one model number.

| Claim | Confidence |
|---|---|
| RTL837x family (not Marvell/Econet, not RTL930x) | **Very high** — our string, plus boot logs, the 8051/CGI architecture, and independent surveys all agree |
| Specifically RTL8372 (vs 8373) | **High** — RTLPlayground's runtime profiles report `isRTL8373 = 0` on these boards |
| The `N` suffix (`RTL8372N`) | **Unconfirmed for our board.** No teardown photo or FCC filing exists for any model in this class; nobody has ever quoted a silkscreen suffix |

The decisive test is reading chip-ID register `0x0004` over MDIO (a confirmed-good
read on a 4+2 board in this family returned `0x83727000`) — which needs the serial
console, so **we cannot do it without opening the case**. Nothing in the published
record substitutes for it. This matters only if we ever flash: **brand and model
prefix do NOT predict silicon** (Hasivo `S600WP-4GT` is RTL8372 but `S600WP-5GT-SE`
is RTL9303; Horaco `HR-SWTGW124AS` is RTL8372 but `ZX-SWTG3424S` is RTL9301).
⛔ Treat AliExpress and vendor listings as worthless for chip ID — a community table
lists six units as RTL8373 from vendor pages while runtime code says RTL8372.

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

**Still unobtainable:** far-end Rx *optical power*. That needs DDM, which **this
firmware version** does not expose, so degradation shows only as errors after the
fact rather than as falling light beforehand. ⚠ Not a silicon limit — the `V200.x`
firmware generation reportedly has a DDM tab, and the SoC's I2C controller is wired
to the SFP module. See the firmware section; the upgrade path is real but carries
two documented brick modes.

## Port map — what is actually plugged into it (2026-08-11)

From `mac.cgi?page=fwd_tbl` joined with `port.cgi`. We had never had this before;
the office side was previously an unlit box.

| Port | Device | Negotiated |
|---|---|---|
| 1 | `e6:35:01:bf:dd:b7` — **opi5pro** (`.200` / `.241` AdGuard / `.242` syslog) | **1000Full** |
| 2 | `ce:56:a2:6d:75:93` (`.17`) | 100Full |
| 3 | `00:e0:4c:68:01:25` — operator's Mac | 2500Full |
| 4 | `a0:ce:c8:a8:ae:5f` (`.72`) | 2500Full |
| 5 | 11 MACs incl. route10 `bc:b9:23:81:97:14` and `eth5` `be:b9:23:84:97:14` | **10GFull** — the BiDi fibre uplink |
| 6 | — | empty SFP cage |

**Replacement sizing:** only **4 copper + 1 SFP+** is actually required, and only two
of the copper links run at 2.5G. Any future "what do we buy" question starts here,
not from the current unit's 4+2 layout.

⚠ **opi5pro negotiates 1000Full on a 2.5G-capable port.** The Orange Pi 5 Pro has
2.5GbE and the Mac on port 3 gets 2500Full through the same switch, so the switch is
not the limit — suspect cable (Cat5e / bad run) or NIC-side negotiation. Unrelated to
the fibre work; recorded because it is free performance nobody was looking at.

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
| Our board is **`PCB-SWTG024AS-V2.1.x_19023`** — matches the `V2.1` this unit reports | up-n-atom + RTLPlayground device docs |
| **Closest twins (same PCB rev): XikeStor `SKS3200-4E2X` (V2.1.0) and Sodola `SL902-SWTGW124AS` (V2.1.1)** — search under these, not under OptFocus | RTLPlayground issue #15 (carries a flash dump + stock firmware for the XikeStor — our recovery baseline) |
| Wider same-design family: Horaco ZX-SWTG124AS, Sodola SL-SWTG124AS-D, MokerLink `2G040210GSM`, Binardat `2G06-04210GSM`, YuLinca `2G06210GSMN`, Lianguo `LG-SWTG124AS`, keepLiNK. **No AmpCom 4+2 managed exists.** | brand sweep |
| ODM confirmed by a hidden `/Hengrui_mp_cfg` admin page on V2.1 boards, plus HRUI's catalogue entry `HR903-SWTG024AS` | up-n-atom / HRUI |
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

### ⚠ `V200.x` reportedly ADDS the SFP+ DDM tab — the one real path to far-end optics

`V100.x` (ours) and `V200.x` are two generations of the same HRUI firmware, and the
successor is reported to add the **SFP+ DDM tab this firmware lacks**. So far-end
optical power is *not* a silicon limit — the I2C controller is wired to the SFP
MOD-DEF lines and reads the SFF-8472 EEPROM. It is a firmware-version limit.

That is the only credible route to the reading we actually wanted. It is also the
riskiest thing in this document, and **not recommended without a flash dump first**:

1. **Cross-flash can lock you out of the web UI.** Sodola V200 onto a XikeStor —
   same design, one PCB rev apart — booted fine over serial but `admin/admin` and
   manual cookie-setting both failed. No recovery documented.
2. **Strapping differs between boards of the same design**: *"the 'reset factory
   default' pin is pulled down in some hardware and will cause reset loop."* Same
   ODM design, different resistors.
3. **No V200 image for our model is published anywhere**, so any attempt means a
   sibling's image — and our exact silicon suffix is unverified (see above).

Both recorded failure modes leave a device that **boots and is useless**, on a
switch carrying opi5pro, AdGuard and the syslog collector. If this is ever
attempted: dump the flash with a SOIC-8 clip + CH341A first, and do it at a planned
maintenance window, never opportunistically.

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

### If we ever want true optical telemetry, it means new hardware — and it WOULD work

⚠ **Corrected 2026-08-11.** An earlier revision said SFP DDM on OpenWrt's `rtl930x`
target was "not cleanly verified by anyone". **That was wrong** — see the note on how
it was wrong, below, because the failure mode is reusable.

**DDM on rtl930x is confirmed working**, with a real user's decoded `ethtool -m`
output on real hardware ([openwrt#19505](https://github.com/openwrt/openwrt/issues/19505),
TP-Link TL-ST1008F v2, RTL9303):

```
Laser output power                    : 0.2799 mW / -5.53 dBm
Receiver signal average optical power : 0.0000 mW / -inf dBm
```

The `-inf dBm` Rx is the proof: no fibre was plugged in, so that is a live read of
the SFF-8472 **A2h diagnostic page**, not a static EEPROM string. Corroborated by an
hwmon `temp1_input` channel appearing on module insertion, an upstream-merged
`sfp-thermal` zone with a 110 °C trip, and the source path (`i2c_block_size = 16`
clears the hwmon gate in `sfp.c`; the cages hang off the SoC SMBus via
`i2c-rtl9300.c`).

⛔ **THE CAVEAT THAT MATTERS FOR US — it is about BiDi specifically.** The rtl9300
SFP i2c bus ran too fast for some cages, and the reported victim was a **10G BiDi
module** (`ATS SFP-10G-BX`) flapping with `failed to read SFP soft status: -EIO`
([#21665](https://github.com/openwrt/openwrt/issues/21665) — body contains `Bidi`,
`-EIO`, `soft status`, `transmit fault`). Fixed by dropping the SFP i2c buses to
50 kHz — PRs [#22209](https://github.com/openwrt/openwrt/pull/22209) and
[#22210](https://github.com/openwrt/openwrt/pull/22210). **The fix is main/snapshot
ONLY**, verified first-hand against raw sources rather than relayed:

| Check | Result |
|---|---|
| `v25.12.0` tag date | **2026-03-03T00:16:17Z** |
| PRs merged | **2026-03-07** and **2026-03-14** — both AFTER the tag |
| `clock-frequency` in `rtl9303_xikestor_sks8300-8x.dts` | branch `openwrt-25.12`: **0** · `main`: **8** |
| i2c bus-speed patch in `realtek/patches-6.18` | `openwrt-25.12`: **0** · `main`: **1** |

Re-check those four before any purchase — once a stable release carries the fix,
this whole caveat evaporates and the decision changes. Since LOS and TX-fault are
read over that same bus, i2c flakiness presents as **link flapping**, not just absent
telemetry — on the fibre carrying opi5pro, AdGuard and the syslog collector. We run a
BiDi module. Any purchase here means running **snapshot** firmware, or verifying the
backport first.

Candidates (every row tied to a DTS filename whose prefix states the SoC):

| Model | Ports | Status | Note |
|---|---|---|---|
| **Zyxel XGS1210-12** | 8x1G + 2x2.5G + 2xSFP+ | stable 25.12 | Matches our real mix exactly. All four SFP signals wired (`los`, `tx-fault`, `mod-def0`, `tx-disable`). ⚠ open, unresolved [#21205](https://github.com/openwrt/openwrt/issues/21205): a 2.5G port dies after days of uptime, recurred on 25.12 HEAD |
| Zyxel XMG1915-10E | 8x2.5G + 2xSFP+ | snapshot | Headroom option; `led_set0` has no 10M bit — no 10BASE-T devices |
| Hasivo S600WP-5GT-2SX-SE | 5x2.5G + 2xSFP+ | snapshot | Smallest sensible box |

Clear negatives: **Hasivo S1100W-8XGT-SE has no SFP cage at all** despite being in
stable; XikeStor SKS8300-8X/8310-8X and TP-Link TL-ST1008F v2 have **zero copper**;
Horaco ZX-SWTGW2C8F, NicGiga S100-0800S-M and Vimin VM-S100-0800MS likewise (verified
by grepping their DTS for `mdio_bus`/`PHY_C45` — no matches, despite model names
implying copper). Nothing smaller than ~7 ports exists with a genuine SFP+ cage.

Remaining true caveat: on OpenWrt DSA, `/proc/net/dev` counters for switch ports
count only CPU-port traffic, so a naive SNMP IF-MIB undercounts hardware-forwarded
traffic badly. Use `ethtool -S`.

### Buying: the answer is a Zyxel from Amazon Brazil, not AliExpress

Every AliExpress-buyable OpenWrt 2.5G+SFP+ unit is **snapshot-only**; everything in a
**stable** release is retail channel with **zero** AliExpress presence (Zyxel
confirmed absent across four models and multiple query variants — clean negative, not
a search artifact).

⚠ **I briefly argued that fork collapses because "we need snapshot regardless for the
BiDi module". THAT WAS WRONG, and the error is instructive: the i2c fix is
BOARD-SPECIFIC, not target-wide.** Checked in `main`:

| DTS | `clock-frequency` entries |
|---|---|
| `rtl9303_xikestor_sks8300-8x.dts` | **8** |
| `rtl9302_zyxel_xgs1x10-12-common.dtsi` | **0** |
| `rtl9302_zyxel_xgs1250-12.dts` | **0** |

The bug was reported on XikeStor/ONTi cages and fixed there. Zyxel boards never
carried the workaround, so there is no reason to avoid stable on a Zyxel. *(Inference
worth naming: absence of a fix means the board was never reported broken — not proof
it cannot be. But it removes the known blocker.)*

**So the snapshot constraint applies to the AliExpress candidates and NOT to Zyxel**,
which inverts the conclusion: buy retail, run stable.

**Amazon Brazil carries Zyxel with domestic stock — no import markup:**

| Model | Ports | OpenWrt | Amazon.com.br |
|---|---|---|---|
| **Zyxel XGS1250-12** | 8x1G + 3x10GBASE-T + **1x SFP+** | **stable since 22.03** — longest-supported rtl930x device | **R$1,768 (~US$347)**, direct BR listing |
| Zyxel XGS1010-12 | 8x1G + 2x2.5G + 2xSFP+ | 25.12 (A1) | R$938–1,157 (~US$184–227) |
| Zyxel XGS1210-12 | 8x1G + 2x2.5G + 2xSFP+ | stable 25.12 | not clearly listed on .com.br; ~US$199–248 on .com, BR shipping unconfirmed |

**XGS1250-12 fits us**: one SFP+ is all the BiDi uplink needs, its 10GBASE-T ports
cover the two 2.5G clients, and the 1G ports cover the rest. ⚠ Verify NBASE-T
negotiates 2.5G and that the 1G ports still do 100M (port 2 runs a device at
`100Full`). ⚠ A1/B1 revisions exist here too — check which you receive.

At **~US$347 domestic** against the Hasivo F1100W's **~US$367 landed**, the retail
route is cheaper *and* avoids snapshot firmware, blind revision roulette and import
tax. The AliExpress path is the worse deal on every axis.

Leading candidate on that logic: **Hasivo F1100W-4SX-4XGT**, 4x SFP+ + 4x RJ45
multi-gig, RTL9303 rev B, chipset known by teardown (the support commit names the RAM
and flash part numbers). Better port fit than the Zyxel XGS1210-12, which is 8x1G
with only two 2.5G ports.

⛔ **PRICE THE LANDED COST, NOT THE STICKER.** Import markup to Brazil runs
**1.5–1.8x**, measured across six official-store listings with ship-to Brazil set:
SKS8310-8X +51%, ZX-SWTGW2C8F +55%, SR-ST3408F +64%, **F1100W-4SX-4XGT +74%**,
SKS8300-12E2T2X +81%, S1100W-8XGT-SE +82%. So the F1100W is **~US$365 landed**, not
~US$211. Every AliExpress price in any research on this topic must be multiplied
before it enters a decision.

⛔ **Two buying traps, both about silicon/variant drift under an unchanged model
number** — the same disease as everything else in this document:

1. **F1100W ships in EIGHT variants under one model number** — v1.02 has 512 MB RAM,
   v1.03 has 256 MB, plus optional PoE daughterboard and optional RJ45 console.
   OpenWrt ships **separate images**, and the 256 MB image runs on a 512 MB board but
   **not the reverse**. Marketplace listings are silent on all four axes. Confirm the
   revision with the seller in writing before buying.
2. **Zyxel XGS1210-12 changed silicon without changing its name** — A1 uses RTL8226
   PHYs, B1 uses RTL8221B, separate OpenWrt profiles, wrong image = wrong link speeds.

⚠ **MUST VERIFY BEFORE BUYING, and it comes from our own port map:** the F1100W's
copper ports are documented as 10G/5G/2.5G/1G — **100M is not listed**, and port 2 of
our current switch runs a device at `100Full`. A switch whose copper will not
negotiate 100M would strand that host. Check the PHY's supported speeds (RTL8261BE)
before committing.

⚠ DDM is confirmed on the **RTL9303 family** (the TP-Link artifact above), but there
is **no model-specific confirmation** for the F1100W, SKS7300-4X4T, SKS8300-8X,
SKS8310-8X or S600WP-5GT-2SX-SE. A targeted sweep using ethtool's output field labels
returned zero hits for those exact boards. Same driver stack ⇒ inferred-likely, not
verified-in-practice.

⛔ **How the "not verified" error happened, because it will happen again.** Three
independent sweeps returned a clean negative and one found the artifact. The
negatives searched the wrong *surface* — one used GitHub **code** search when the
evidence was in an **issue** thread; another was HTTP-429'd off the OpenWrt forum for
its whole run and correctly logged that as *unreached* rather than *absent*.
**A single quoted artifact outweighs any number of absence-of-evidence sweeps.**
Treat "nobody has posted X" as a hypothesis about your search coverage, never as a
finding — and name the surfaces actually searched.

### A page we deliberately did NOT fetch

`/Hengrui_mp_cfg` — the hidden ODM manufacturing page that would have confirmed the
HRUI attribution on our own unit. Skipped on purpose: this firmware is *proven* to
have state-changing GET endpoints (`ftdft.cgi` wipes the config), "mp" means mass
production, and this switch carries opi5pro, AdGuard and the syslog collector. The
attribution is already established from the board string and the 12/12 web-UI
fingerprint match; confirming it locally was not worth an unknown vendor action on
production infrastructure. **Do not fetch it casually either.**

### Verdict

**Keep the stock firmware. Flash nothing** — not RTLPlayground (broken on this exact
model), not a sibling's V100 image, and not a V200 image without a flash dump and a
maintenance window. Build the exporter on `port.cgi?page=stats` and treat `RxBadPkt`
on port 5 as the far-direction signal we did not previously have.

If far-end optical power ever becomes worth real risk, the ranked options are:
1. **V200.x firmware** from a same-PCB twin — cheapest, two documented brick modes,
   needs a SOIC-8 dump first.
2. **Replace the switch** with an OpenWrt-supported RTL930x unit — but DDM there is
   unproven and DSA counters undercount hardware-forwarded traffic.
3. Accept the limit and rely on `RxBadPkt` + our own `eth5` CRC and flap counters.

Option 3 is where we are, and it is a defensible place to stay.

## Local artifacts

- Config backup: kept out of the repo (credential material). Re-take any time with
  the `conf_backup` GET above.
