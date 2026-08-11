# WiFi 7 AP selection — OpenWrt vs Alta, and Brazil's 6 GHz reality

Research date **2026-08-11**. Written so nobody repeats it. Everything below is
from primary sources — driver source, package feeds, ANATEL act text, vendor
datasheets, Alta forum posts with staff attribution. Inferences are labelled.

⚠ **Standing evidence caveat.** `forum.openwrt.org` (HTTP 429) and
`lore.kernel.org` / `w1.fi` (bot-walls) were unreachable to every agent, and
AliExpress + Mercado Livre were captcha-blocked. So this file contains **no forum,
mailing-list, or AliExpress-pricing evidence**. Code presence and vendor
documentation are established; **real-hardware behaviour is not** — 6 GHz
association, 320 MHz throughput and MLO stability are unverified by anyone here.

Sibling research: [`office-switch-ofs-m1xf2gt4.md`](office-switch-ofs-m1xf2gt4.md)
(same buying criteria, learned the expensive way).

---

## The finding that dissolves the question

**Alta APs are OpenWrt APs.** The choice everyone frames as "vendor ecosystem vs
OpenWrt" does not exist here.

Confirmed from a user-posted `/etc/openwrt_release` on Alta hardware:

```
DISTRIB_ID='OpenWrt'   DISTRIB_RELEASE='21.02.1'
DISTRIB_TARGET='ipq95xx/generic'
DISTRIB_ARCH='aarch64_cortex-a73_neon-vfpv4'
```

- **Root SSH is official and documented** — portal → Settings → System → SSH
  Keys, then `ssh root@<device>`. Key-only, lands as root. Alta publishes a
  help-centre article for it. The login banner discourages, it does not restrict.
- **`/cfg/post-cfg.sh` runs on APs too**, staff-confirmed: *"the file will return
  after reboot, but `/cfg/post-cfg.sh` will run after every configuration
  (including the configuration right at boot)"*. Same persistence model we already
  operate on route10. Must be `chmod +x`.
- `touch /cfg/.persistent.log` enables persistent logging on an AP.
- GPL source is **not published** but is available on request to support@alta.inc.

So the "prefer a box you can run your own code on" criterion from the office-switch
research is **satisfied by Alta**, not only by third-party OpenWrt.

---

## Brazil 6 GHz — the regulatory picture

Primary source: **ANATEL Ato nº 14448/2017 §11.7**, inserted by Ato nº 1306/2021,
revised by Ato nº 423/2022. (ANATEL's site 403s WebFetch; fetches fine with curl +
browser UA.)

**The full 5925–7125 MHz is open.** Not a lower portion. 320 MHz channels legal.

| Class | Max EIRP | Max PSD | Indoor/outdoor |
|---|---|---|---|
| Indoor AP (LPI) | **30 dBm** | 5 dBm/MHz | indoor only |
| Client device | **24 dBm** | −1 dBm/MHz | indoor only |
| Very Low Power (VLP) | 17 dBm | −5 dBm/MHz | either |

LPI and client figures are **identical to the FCC's**. Brazil's VLP is 3 dB more
generous.

- **No AFC / no standard-power tier exists** — confirmed by exhaustive grep of the
  act for AFC, "coordenação automática", "potência padrão", geolocation terms. Zero
  hits.
- **Antennas must be permanently integrated** (§11.7.7). ⚠ This binds *homologated
  equipment*, i.e. what may be sold. What it implies for a DIY build is
  **unestablished** — do not state it as a blanket constraint.
- Indoor APs: mains-powered, batteries prohibited, non-weatherproof enclosure
  (§11.7.6). Whether PoE satisfies "mains-powered" is **unknown**.
- Listen-before-talk mandatory (§11.7.11).

### Two non-obvious consequences

1. **The limit is per-MHz, so wide channels get MORE total power.** At 320 MHz you
   reach the full 30 dBm; at 20 MHz only 18 dBm. 320 MHz is power-*favoured*.
2. **The client is capped 6 dB below the AP** (−1 vs 5 dBm/MHz). **The uplink is
   the limiting direction**, and the uplink governs real coverage. Directly
   relevant to the "last images don't load" complaint — that is an uplink-shaped
   symptom.

### ⛔ The 12 dBm regdb trap (DIY path only)

The Linux `wireless-regdb` entry OpenWrt ships:

```
country BR: DFS-FCC
	(5925 - 7125 @ 320), (12), NO-OUTDOOR
```

**12 dBm, against ANATEL's 30 dBm** — an ~18 dB gap, roughly 60× power. The regdb
number is **identical to the US entry** and **no commit rationale exists**. It is
NOT ANATEL's number and regdb is not encoding a Brazilian rule.

`NO-IR` (which blocks AP-mode beaconing entirely) was present through **2025.02.20**
and removed by **2025.07.10**. All three supported OpenWrt branches (24.10, 25.12,
main) pin **2026.05.30**, safely past it. `country=US` still carries `NO-IR` — so
stock OpenWrt can beacon on 6 GHz in Brazil where it cannot in the US. (The
circulating US "fix" is a third-party patched regdb rewriting US 6 GHz from
`(12), NO-OUTDOOR, NO-IR` to `(30), NO-OUTDOOR` — that is an explicit **compliance
override**, not a bug fix. Named here so it isn't mistaken for one.)

**Brazil's spectrum position is genuinely better than the EU's.** EU 6 GHz is
5945–6425 — **480 MHz total**, room for exactly *one* 320 MHz channel placement, so
two EU APs cannot get non-overlapping 320 MHz channels. Brazil's full 1200 MHz can.

**Does this bite an Alta AP?** Almost certainly **not** — INFERRED. Alta APs run
Qualcomm's proprietary WiFi stack (evidenced by `qcawifi-scanner` on the AP and
users driving radios with `wlanconfig`), which carries its own regulatory tables in
driver/board data, independent of `wireless-regdb`. QCA's internal number for BR is
then governing and is **unknown**. Settle it on day one with `iw reg get` /
`wlanconfig` on the actual unit.

⚠ Nobody in this research found a single field report of anyone running a 6 GHz AP
under `country=BR` on OpenWrt. Absence of evidence, not a negative result.

---

## OpenWrt WiFi 7 — software state

- **Current stable is 25.12** (25.12.0 2026-03-05, point releases through
  25.12.5 2026-07-01), kernel 6.12.71, mac80211 backports **6.18.39**. 24.10 carries
  backports 6.12.96 — a full generation behind on EHT plumbing.
- **MediaTek mt76 is the only realistic open path.** One driver (`mt7996e`) covers
  MT7996 / MT7992 / MT7990.
- **Qualcomm ath12k: do not buy expecting support.** Target is `source-only` with
  no prebuilt images, two dev boards merged, zero retail devices. Board-data (BDF)
  sourcing is broken for retail hardware. The GL.iNet Flint 3 port is out-of-tree
  community work with unreproducible MLO failures reported as of 2026-08-11.
- **Broadcom: nonexistent.** No EHT code in brcmfmac at all.
- **Firmware is freely redistributable**, in-tree, no vendor extraction. ⚠ One gap:
  the MT7992 **"2+4" antenna variant**'s firmware files are referenced by driver
  code but absent from both openwrt/mt76 and linux-firmware — that variant fails to
  load firmware.

### Feature reality

| Feature | State |
|---|---|
| 320 MHz | Mature — `CMD_CBW_320MHZ` since Jan 2023 |
| 6 GHz | Present (MT7996 only, see below) |
| MLO | **Usable-but-maturing.** AP capability 2025-08-27, client 2025-09-01, eMLSR 2026-02-03, still bug-fixed 2026-08-01. A data-path black-hole bug was fixed 2026-07-26. Genuinely **STR + EMLSR** across up to 3 links (`IEEE80211_EML_CAP_EMLSR_SUPP`, `MT7996_MAX_RADIOS 3`), not single-radio MLO. ⚠ The config path depends on an **OpenWrt-local hostapd patch** — upstream hostapd has no config-file way to pin a link id |
| EPCS | **Absent** — explicitly disabled by a MediaTek engineer 2025-09-04 ("not yet ready"), never re-enabled |
| 4K-QAM | EHT-MCS **12/13** (mt7996 advertises 13). ⚠ MCS 14/15 are DUP/MRU modes — a common misstatement |

⚠ **6 GHz is not reachable from LuCI.** Hand-edit `/etc/config/wireless`:
`band=6g`, a valid country, a **PSC channel** (5, 21, 37 … 229), and encryption
`sae` or `owe`.

### ⛔ Only MT7996 is tri-band

**MT7992 and MT7990 can never do 6 GHz or 320 MHz.** Hard-gated: `mt7996_band_valid()`
returns `band <= MT_BAND1` for anything that isn't MT7996; default EEPROMs are
`2i5i` with no `6i`; every such board's DTS carries `ieee80211-freq-limit` stopping
at 5835 MHz. Nothing downstream widens it. **Safe to rule out without hedging.**

| Chip | 25.12 devices |
|---|---|
| **MT7996 (6 GHz-capable)** | BPI-R4 (+BE14 card), ASUS ZenWiFi BT8, Arcadyan Mozart, SmartRG SDG-8733/8733A/8734, Zbtlink Z8803BE |
| **MT7992/MT7990 (dual-band forever)** | TP-Link BE450, GL.iNet GL-MT3600BE, Keenetic KN-1812, Routerich BE7200, Hiveton H5000M |

⚠ **The positive claim is weaker than the negative.** "MT7996 board X does 6 GHz"
is verified only as *nothing blocks the path* (silicon capable + no DTS
restriction). Real behaviour depends on that unit's EEPROM. Proof this matters:
BPI-R4 had a **zeroed-TX-power EEPROM bug** fixed only in 25.12.3 — chip said yes,
unit transmitted nothing. **BPI-R4 + BE14 is the best-evidenced** (wiki documents
6 GHz working); **ASUS ZenWiFi BT8 is the best retail form factor** but inferred.

⚠ **None of the MT7996 devices is a ceiling AP. None takes PoE.** The OpenWrt path
to tri-band WiFi 7 means running a router as a dumb AP on a barrel jack.

### ⛔ 6 GHz roaming is broken on OpenWrt — three independent causes

Decisive for a **multi-AP** deployment, which is what "a second AP beats a faster
one" implies. All three confirmed from source:

1. **`dawn` cannot represent 6 GHz.** `enum dawn_bands` has exactly two members,
   `max_band_freq[] = { 2500, 5925 }`. A 6 GHz frequency exceeds the last band,
   falls through the loop, logs a warning, and is **steered using 5 GHz
   parameters**. Every per-band tunable (`rssi`, `chan_util`, `initial_score`) is a
   two-element array — there is nowhere to put 6 GHz values. (HEAD 2026-08-10,
   actively maintained.)
2. **`usteer` cannot distinguish 5 from 6 GHz.** `struct sta_info` carries only
   `seen_2ghz`/`seen_5ghz`, and band classification is a bare `freq < 4000` /
   `freq > 4000` threshold. 5↔6 GHz band steering is impossible. (Pinned
   2026-05-19.)
3. **FT-SAE is broken on MT7996** by an open unmerged driver bug, and the
   hostapd-side FT+SAE fix merged **three weeks after** the current release — it is
   in no shipped tag. SAE is *mandatory* on 6 GHz.

Neither daemon has any MLD/link awareness.

**Guidance:** put the roaming SSID on 2.4/5 GHz where FT-PSK works; let 6 GHz be an
SAE-only bonus link. A single mixed-mode SSID produces exactly that, since OpenWrt
auto-upgrades 6 GHz to SAE.

**Alta plausibly sidesteps all three** — INFERRED. It runs QCA's stack with its own
`qcawifi-scanner`, min-RSSI and 11k neighbour reports rather than dawn/usteer, and
802.11 r/k/v is on the AP7 Pro datasheet. The three failures above are specific to
the OpenWrt userspace daemons and the mt76 driver.

### Two more traps

- **`hostapd-mini` has 802.11be compiled out.** Right chip, right driver, no 11be,
  no error message. Confirm the image ships full hostapd.
- **Devicetree node names lie.** TP-Link BE450's node is literally `mt7996@0,0`
  while running MT7992 silicon. The trustworthy signal is which
  `kmod-mt799x-firmware` variant `filogic.mk` pulls for that device.
- **GL-MT3600BE and Hiveton H5000M landed in 25.12 AFTER 25.12.0 shipped**
  (2026-06-23 / 2026-07-11). Flashing 25.12.0 itself gets an unsupported device;
  needs 25.12.3+.

### "Vendor SDK is faster" is a default, not a codebase

MediaTek's `mtk-openwrt-feeds` pulls the **identical upstream mt76** — pinned
slightly *older* than 25.12 ships. The delta is 108 out-of-tree patches, chiefly
**WED hardware offload enabled by default** (`wed_enable=1`) where upstream leaves
it off. A knob, not a moat.

---

## Hardware shortlist (Brazil, Aug 2026)

⛔ **There is no WiFi 7 access point running OpenWrt today.** None. "WiFi 7 on
OpenWrt" means a router in dumb-AP mode, on a barrel jack, on a shelf.

⚠ AliExpress and Mercado Livre were captcha-blocked all session, so "no price"
below means *unreachable*, not *unavailable*. Landed estimates use 1.6× and
5.4 BRL/USD.

### The three that survive

| Role | Device | Price | Why |
|---|---|---|---|
| **House AP** | TP-Link **EAP660 HD v1** | R$1,799 domestic (Kabum/Amazon.br) | 4x4:4 radio, 2.5 GbE, PoE+, no EOL flag, real BR retail |
| **Cheap lab** | **Cudy AP3000 v1** | **R$676.61** Kabum | MT7981B, 2.5 GbE, 802.3af/at. Cheapest route to an open mac80211 radio |
| **Bleeding edge** | **Zbtlink ZBT-Z8803BE** | no price reached | The only MT7996 + 2.5 GbE + **10G SFP+** box |

### Zbtlink ZBT-Z8803BE — the experimenter's pick

Silicon verified via the **firmware package the build pulls**
(`kmod-mt7996-firmware`), not the DTS node name — its node is `mt7996@0,0` and so
is the BE450's, which is MT7992. **Node names lie; package selection doesn't.**

- **MT7988A** (Filogic 880, quad A73), **1 GB RAM**
- **MT7996** tri-band, dedicated EEPROM nvmem cell
- **1x 2.5 GbE**, **1x 10G SFP+ cage** (`phy-mode = "10gbase-r"`), 3x 1 GbE,
  2x USB3, PWM fan with a 100 °C thermal trip

A BPI-R4-class machine in a retail chassis *with* a PSU and case — arguably a
better experiment target than the bare board, and the SFP+ cage is directly
relevant given route10 already runs an SFP+ stick.

⚠ **Not in `openwrt-25.12` at all** — main/SNAPSHOT only. No stable images, no
upgrade-path guarantee, **no wiki page and therefore no documented
broken-functions list**. Unknown unknowns, not known-and-accepted.
⚠ 6 GHz is capability-inferred, not unit-confirmed — it has its own EEPROM nvmem
cell and so carries the same risk class as BPI-R4's zeroed-TX-power bug.

### Cudy AP3000 v1 — the PHY swap is a CLOSED issue

In Jan 2026 Cudy **silently swapped the 2.5 GbE PHY** from Realtek RTL8221B to
Motorcomm YT8821 with **no model-number or revision change**. Not detectable before
purchase — no SKU, packaging or date-code tell.

**But `DEVICE_PACKAGES` for `cudy_ap3000-v1` includes `kmod-phy-motorcomm`
unconditionally in both `main` and `openwrt-25.12`.** The stock official image
drives both variants. Not a lottery.

Residual risk, entirely avoidable:
- Cudy **transition image must be ≥ 20260224** (older ones can't flash YT8821)
- OpenWrt image must be **≥ 24.10.6 / 25.12.0-rc5**

⚠ If either bites, the AP3000 has **only one Ethernet port** — no PHY driver means
no network, and recovery is **UART-only** (case open, USB-TTL, 115200, 3.3 V).

### Ruled out, and why

| Device | Reason |
|---|---|
| TP-Link **EAP670** | **Zero OpenWrt support** in any revision — absent from snapshot, 25.12.5 and 24.10.8; wiki 404s |
| **GL-MT3600BE**, TP-Link **BE450**, **Routerich BE7200**, **Tenda BE12 Pro**, **Hiveton H5000M**, **Keenetic KN-1812** | `kmod-mt7992-firmware` ⇒ **dual-band forever**, permanent silicon grounds |
| **ipTIME AX7800M-6E** | 6 GHz **TX power broken** on OpenWrt |
| **Zyxel NWA50AX Pro** | 2.5 GbE link-flapping; the only workaround **disables 2.5 GbE** |
| **ASUS ZenWiFi BT8** | No price obtainable anywhere; absent from BR retail |
| **BPI-R4 + BE14** | Grey market only, no price; DIY parts list (PSU, storage, BE14, SFPs, antennas, case). Best-*evidenced* 6 GHz, worst buying path |
| Netgear **WAX220 / WAX630 / WAX218** | Discontinued or non-orderable at source |
| TP-Link **EAP683-LR** | Manufacturer-confirmed **EOL** |

## Telemetry — the actual reason to buy an AP

The unresolved complaint ("last images don't load, I switch to 5G") has no
router-side evidence. ICMP probing was measured useless for a phone — it reports
iOS power-save, not link quality (see
[`project_route10_wifi_client_identity.md`](../../../../.claude/projects/-Users-antoniocasagrande-git-route10/memory/project_route10_wifi_client_identity.md)).
The missing evidence is radio-layer, per client.

### What mt76 gives (confirmed from driver source)

Per client: `tx_retries`, `tx_failed`, **per-chain RSSI across 4 chains**, TX/RX
airtime (`ieee80211_sta_register_airtime` is really called), ACK signal + avg,
MCS/NSS/bandwidth, expected throughput, connected/inactive time.
Per radio: survey dump with busy / rx / tx time and noise floor.

⚠ mt7996 (WiFi 7) was **not observed** setting `RX_BITRATE` where mt7915 does —
INFERRED gap, verify on hardware.

⚠ debugfs is a red herring: per-station it exposes only `fixed_rate` and
`hw-queues`. Everything useful is on the nl80211 path already.

### ⭐ The capability no vendor sells

`ubus call hostapd.<iface> rrm_beacon_req` asks an **802.11k client (iOS is one)
to report what IT hears** — RCPI/RSNI per BSSID. That measures her phone's view of
the radio, the exact inversion the ICMP probe failed at.

### Association / deauth events

hostapd ubus notifications distinguish `deauth` (client left), `local-deauth` (we
kicked it), `inactive-deauth` (idle timeout), plus `probe`/`auth`/`assoc` carrying
`signal` and `freq`, `beacon-report`, `bss-transition-response`.
Reason codes are logged at `MSG_DEBUG` only — **raise hostapd log level**. Note the
upstream typo `disassocation` when writing the grep.

### ⛔ The stock exporter drops the fields that matter

`prometheus-node-exporter-lua` (v2026.06.05-1) `wifi_stations.lua` calls
`iw.assoclist()` — which already parses `tx_retries`, `tx_failed`, `signal_avg`,
`noise`, `mcs`/`nss`/`mhz` — and **exports none of them**. Nine other fields only.
The retry-storm and rate-collapse signals are available and simply not wired up.
~30 lines of Lua, or a textfile collector over `iw station dump`.

### Vendor comparison

| Signal | OpenWrt/mt76 | UniFi | Omada | Alta |
|---|---|---|---|---|
| Per-client RSSI | Yes (+avg) | Yes | Yes | Portal only |
| Per-chain RSSI | **Yes (4)** | No | No | No |
| MCS / NSS | Yes | MCS+NSS | No | Unknown |
| **TX retries** | **Yes** | **Yes** | No | Unknown |
| Per-client airtime | **Yes** | No | No | Unknown |
| Channel busy/util | Yes | Yes | Yes | Per-AP load |
| Deauth reason codes | **Yes** | No | No | Unknown |
| 802.11k beacon req | **Yes** | No | No | No |
| Maintained exporter | Partial (gap above) | **unpoller v3.4.1** | RCooLeR | **None** |

**UniFi is the best closed ecosystem** and sets the bar — `unpoller` is genuinely
maintained and exposes `tx_retries`, `tx_mcs`, `roam_count` per client.

### Alta's telemetry — better than the table suggests

- **`rcstats-mon`** — staff-documented: SSH to the AP and run it to see the **raw
  JSON sent to the controller, once per second, per client**. Same `rcstats` daemon
  as route10. Our exporter pattern ports directly.
- **SNMP** on APs since firmware 2.0q (2024-05-15). MIB coverage undocumented.
- **Remote syslog** since 1.1i — the portal Syslog Host field we already point at
  Loki. AP logs land in the existing pipeline for free.
- Portal shows per-client signal (with a **Raw dBm** mode), TX/RX rate, DPI usage;
  per-AP channel load, CPU, client counts, temperature history.
- ⛔ **No public API.** A Home Assistant developer has had one built **under NDA
  since January 2026**, still unreleased. Zero Prometheus results across the entire
  Alta forum.
- ⚠ Per-client airtime / retries / MCS **not confirmed** exposed anywhere. The QCA
  driver has them (`wlanconfig ... list sta`) — inference, not evidence.

---

## Alta AP7 Pro

Shipping since ~2026-06-16. Firmware 3.0f → 3.0i (2026-08-06), four releases in six
weeks. ~£249 ex-VAT / £287.99 inc-VAT. **USD price unverified.**

- Tri-band WiFi 7, 4096-QAM: **6 GHz 2x2, 5 GHz 4x4, 2.4 GHz 2x2**
- 802.11 **r/k/v** roaming; mesh on 5 and 6 GHz (proprietary; Alta refuses WDS)
- **Uplink is 10 GbE RJ45, not 2.5** — but *"PoE+ for up to 2.5 Gbps, PoE++ for up
  to 10 Gbps"*. **On 802.3at you are capped at 2.5 Gbps.**
- Power: 30 W (PoE+) / 35 W (PoE++), **12 W typical**
- Indoor only, no weatherproofing. SoC "Qualcomm" — exact part **unknown**
- ⛔ **There is no AP6-LR.** (Confabulated in this session's own research brief;
  likely confusion with Ubiquiti's U6-LR.)
- ⛔ **Don't buy any AP6** — the whole line is **1 GbE uplink**. AP6-Pro SoC
  confirmed IPQ5018 via a user-posted kernel oops.

### Lock-in is milder than expected

Cloud management is **free**; local options are a **$49 one-time Docker controller**
or **$149 hardware controller**. No subscription.

**AltaPass multi-PSK** (patented) — one SSID, per-password VLAN/rate-limit/schedule.
No clean OpenWrt equivalent. ⚠ 6 GHz supports only one password (WPA3/SAE limit).

**Mixing an OpenWrt AP in:** breaks portal visibility/management of that AP, AP-side
DPI, multi-PSK, vouchers, mesh, zero-touch. Does **not** break DHCP/DNS/VLANs
(it's an L2 bridge), route10's own per-client counters and connlimit, PoE from an
Alta switch, or **802.11r/k/v roaming** — that's standards-based and works across
vendors given matching SSID, PSK, mobility domain and FT settings.

### Real risks — none of which are openness

1. **Brazil has no Alta distributor.** 40 reseller countries; South America is only
   Argentina, Chile, Ecuador, Venezuela. Import + duty, no local RMA.
2. **PoE++ for full 10G.** 802.3at caps at 2.5 Gbps.
3. **Undocumented everything** — no API, no CLI docs (*"We probably won't publish
   any kind of documentation for it"*), dead package repos (`ipq50xx` dropped from
   OpenWrt 21.02 archives), and Alta reserves the right to change `rcstats-mon`'s
   output. Same bet as route10, doubled.
4. **No `/a`-equivalent found on APs** — assume `/cfg` only, and small. **Unknown.**

---

## PoE — the hidden cost

**We have no PoE anywhere.** Neither route10 nor the office switch supplies it
(verified 2026-08-11). Any ceiling AP needs an injector.

802.3af delivers only **12.95 W at the device**. Every Pro-class WiFi 7 AP exceeds
it:

| AP | Max power | Requires | Uplink |
|---|---|---|---|
| Alta AP7 Pro | 30 W (at) / 35 W (bt) | **802.3at** min | 10 GbE (2.5 on at) |
| UniFi U7 Pro | 21 W | 802.3at | 2.5 GbE |
| TP-Link EAP772 | 25.4 W | 802.3at | 2.5 GbE |
| *UniFi U6 Pro (WiFi 6)* | *13 W* | *802.3af* | *1 GbE* |

⚠ **Degraded-mode behaviour on af is undocumented per model** — do not assume it
boots at all.

⚠ **A 1 GbE injector silently caps a 2.5 GbE AP.** 2.5 GbE 802.3at injector
availability and pricing were **not verified** — resolve before ordering.

⚠ **Never mix passive PoE.** An 802.3at AP won't power from a 24 V passive
injector; the damage risk runs the other way.

---

## Client-side reality (from apple.com)

| Model | 6 GHz? |
|---|---|
| iPhone 15 / 15 Plus | **No** — WiFi 6 |
| iPhone 15 Pro / Pro Max | Yes, 6E |
| iPhone 16 / 17 series | Yes, WiFi 7, **2x2** |
| **iPhone 16e / 17e** | **No** — WiFi 6 island |
| MacBook Pro M5 base | 6E only |
| MacBook Pro M5 Pro/Max, MacBook Air | WiFi 7 |

**320 MHz support on iPhone is unverified** — Apple states standard and MIMO width,
never channel width.

⛔ **Establish which iPhone is hers before spending anything.** If it's a base 15 or
an "e", every 6 GHz argument is irrelevant to the actual complaint. As of
2026-08-11 leases show `.47` (private MAC, hostname `iPhone`) and `.121`
(`iPhone-Antonio`) — suggestive that `.47` is hers, not proof.

---

## Homologation

**Resolução 715/2019 Art. 55:** homologation is mandatory for **use**, not just
sale. No personal-use exemption for use. Art. 83 lists both *use of unhomologated
product* and *import of unhomologated product* as sanctionable.

**But:** Art. 20 III lets any individual request homologation "para uso próprio",
Art. 33 II routes own-use imports to the lighter declaração de conformidade, and
Art. 58 makes the certificate **free**. **Resolução 780/2025 shifted enforcement
onto marketplaces**, explicitly covering the commercialization conducts — not
use or import by the individual.

**Unverified:** real customs seizure rates for personal parcels, current Remessa
Conforme tax figures, and whether any specific WiFi 7 AP is homologated (ANATEL's
SCH database now sits behind SSO and no longer answers anonymous queries).

---

## Buying criteria, extended from the office-switch research

The office-switch file's criterion #1 was *prefer a box you can run your own code
on*. This research adds:

1. **Check whether the vendor box ALREADY satisfies criterion #1 before assuming
   OpenWrt is the only path.** Alta does. The entire "ecosystem vs OpenWrt" framing
   was false and nearly cost a worse purchase.
2. **A "WiFi 7" label does not imply 6 GHz.** MT7992/MT7990 are permanently
   dual-band. Verify the *chip*, and verify it via the firmware package the build
   pulls — not the model name, not the DTS node name.
3. **Capability ≠ radiation.** BPI-R4's zeroed-TX-power EEPROM proves per-unit data
   decides real behaviour. "Nothing blocks the path" is not "it works".
4. **Price the domestic option before importing.** EAP670 landed ≈R$1,296 vs
   R$1,330 on Kabum — parity, so importing buys only customs risk and no warranty.
5. **Check for EOL before falling in love.** EAP683-LR is officially EOL; Netgear
   WAX220 non-orderable at source; WAX218 has no live channel.
6. **The revision trap recurs.** TP-Link lists EAP670 v1/v2/v3 simultaneously and
   retail listings don't say which ships.

---

## Verdict

**The AP7 Pro is defensible and the wait is over** — because it is an OpenWrt box
with root SSH, a `/cfg/post-cfg.sh` hook and per-second per-client JSON, that also
happens to have a purpose-built AP form factor, PoE, tri-band radios with 4x4 on
5 GHz, and standards-based roaming. The OpenWrt alternative for tri-band WiFi 7 is
a router on a shelf with a barrel jack.

**But the AP is a diagnostic purchase, not a throughput one.** MLO isn't
dependable, EPCS is absent, 6 GHz is a same-room band with the client capped 6 dB
below the AP, and half the household's phones can't use it. What justifies the
spend is per-client radio telemetry and `rcstats-mon`.

**For a multi-AP house the roaming finding is close to decisive.** On the OpenWrt
path, 6 GHz roaming fails three independent ways (dawn blind, usteer blind, FT-SAE
broken and unshipped). Alta ships its own steering stack and standards-based
r/k/v. If the plan is two APs rather than one fast one — and the coverage evidence
points that way — that gap is the difference between a network that roams and one
that doesn't.

**If coverage is the real complaint, a second AP beats a faster one.**

### Open questions, cheapest first

1. Which iPhone is hers. Free.
2. What is currently serving WiFi — `.134`/`.135` share an OUI, answer no HTTP/SSH,
   and look like an app-managed mesh pair. Physical inspection.
3. Does the QCA stack cap 6 GHz in BR? `iw reg get` on the AP, day one.
4. 2.5 GbE 802.3at injector availability and price in Brazil.
