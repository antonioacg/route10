# net-triage log

One entry per slowness complaint, **including the ones we failed to catch**. The
near-misses are the point: a log of only wins teaches nothing. Newest first.

Written by the `net-triage` skill. Mark claims **CONFIRMED** only with the
measurement beside them, otherwise **SUSPECTED**.

---

## 2026-08-13 00:33–00:40 UTC (21:33–21:40 BRT) — Globoplay graining, whole-link capacity loss

- **Reported:** "Bandwidth is bad, streaming is dropping." Globoplay graining at
  low bitrate on a Claro TV Box. User's own fast.com runs: **1.5 Mbps on 2.4 GHz,
  10 Mbps on 5 GHz, then fine on 5 GHz.** Recovered around an episode boundary —
  **the user flagged that timing as coincidental**, and player buffering means it
  cannot be used as a time marker either way.
- **Vantage:** Claro TV Box (`.20`, `NET_HD_Decoder`), **wired** to the AX73
  (AP only, not routing), which is wired to route10. User's speedtests were from a
  phone on wifi — a different medium from the device that was graining.

### Measured (CONFIRMED, from `/a/obs/stats-archive.sql` `minutes`, per-client)

```
Claro TV Box (.20) rx/min      network total/min
00:20-00:32   70-95 MB          ~110 MB      baseline, ~10 Mbit/s stream
00:33         17.5 MB            26 MB
00:34         10.8 MB  =1.44 Mbit/s          <-- matches the user's "1.5 Mbps"
00:37         17.0 MB          1031 MB
00:39          3.1 MB  =0.41 Mbit/s   21 MB  <-- worst
00:40         15.6 MB            39 MB
00:41        112.7 MB           136 MB       recovery
00:42-01:10  165-178 MB  =~23 Mbit/s  1500+  sustained, ABOVE baseline
```

**It was the whole link, not one device.** Network totals fell from ~110 MB/min to
21–39 MB/min and nothing was saturating it — consistent with the user's phone also
seeing 1.5/10 Mbps on two different bands.

### What it was NOT (all CONFIRMED, same window, per-minute)

| layer | evidence |
|---|---|
| PON / fibre | `onu_state` O5 throughout; BIP flat at 52; FEC cor/uncor **0**; `omci_tx.retx` flat at 908 (**zero** upstream loss); no LOS/LOF/SD |
| LAN fiber (eth5) | CRC 0; `carrier_changes` static at 29 |
| DNS | AdGuard up, **6 ms**; routedns up, 7 ms — no fallback, no stall |
| bufferbloat | idle 10.78 ms vs loaded 10.62 ms — flat |
| a LAN hog | totals were *low* during the starvation; `.200`'s BitTorrent was 7–18 MB/min, far too small to explain it |

### Verdict

**CONFIRMED: a real ~7-minute capacity degradation with a completely clean local
stack.** Everything from the ONU inward was healthy, so the constraint sat
**upstream of the ONU** (ISP BNG / CGNAT / peering) — which we cannot observe
directly. **SUSPECTED** only as to which of those.

### Evidence gap — why it wasn't caught live

**Every probe I ran started at ~00:44, after recovery at 00:41.** I then reported
"your internet is healthy" from measurements taken in the wrong minutes, and
asserted my numbers and the user's were "in the same window" with **no timestamps
to support it**. The user challenged that; the challenge was correct.

The per-client counters that settled this were available the whole time. Nobody
looked until the third round of questioning.

### New rules (folded into SKILL.md)

1. **Get the complaint's wall-clock time first, and mine `minutes` for it.** A
   retrospective from per-client counters beats any live probe run after recovery.
   ⚠ `/a/stats.sql` `minutes` is a rolling **60-minute** window — anything older
   must come from `/a/obs/stats-archive.sql`. `ts` there is **seconds**, not ms.
2. **Read the network TOTAL, not just the complaining device.** One slow client is
   a client problem; every client slow at once is a link problem.
3. Never claim two measurements share a window without timestamps on both.
4. A clean PON + clean DNS + clean CRC + flat bufferbloat, with throughput still
   collapsed, points **upstream of the ONU**. That combination is now a signature.

---

## Template

```markdown
## <UTC window> — <one-line symptom>
- **Reported:** <verbatim>
- **Vantage:** device / medium / app
- **Measured:** <numbers, each with its timestamp>
- **Verdict:** confirmed <X> | not reproduced | inconclusive
- **Evidence gap:** <what would have settled it, and why it was missing>
- **New rule:** <what changes next time — or "none">
```

## 2026-10-01 01:52Z — "what's up with my wifi?" (complaint time unknown; reported at ask time)
- **Reported:** "What's up with my wifi? Check diagnostics"
- **Vantage:** not yet given — device / band / app unknown. Snap ran from the wired Mac (en10).
- **Measured:**
  - 01:52–01:53Z net-snap: gateway RTT 1.8 ms; 8.8.8.8 0% loss 11 ms; idle 11.1 vs loaded 11.0 ms (no bufferbloat); PON O5, FEC unc 0; eth4/eth5 no flaps; v4 375 / v6 510 Mbit/s to host 1.
  - 01:52Z AX73 cache (counters since AP boot, 3.3 d): **2.4 GHz (ch 3, 20 MHz, 8 clients)** txretrans/txframe = 60%, unicast PER 42.3%, rxbadfcs 9.2M vs rxframe 5.1M, crsglitch 460M. **5 GHz (ch 36, 1 client)** PER 20.9%, MBP −33 dBm, 780/867 Mbit/s, ~0% retries.
  - iPhone-Antonio on **2.4 GHz** at −64 dBm: tx retries 81% of ucast packets, 1933 tx failures in 5.1 h. Four other 2.4 clients at −68…−75 dBm.
- **Verdict:** WAN/link not the problem (CONFIRMED, same minute). 2.4 GHz radio heavily degraded (CONFIRMED from AP counters); cause = interference/overlap SUSPECTED — channel 3 overlaps 1 and 6, neighbour scan not available.
- **Evidence gap:** no complaint time, device, or band from the user yet; AP counters are lifetime totals, not a rate — two scrapes a few minutes apart are needed to say "now" vs "average".
- **New rule:** for a WiFi complaint read the AX73 cache first (`/tmp/ax73-metrics.prom` on route10, joined to names via `route10_client_info`) — per-station band/RSSI/retries answers "which band is the device on" without asking. Diff two scrapes before calling a counter current.

## 2026-10-01 01:05–01:09Z and 01:49–01:53Z — vacuum screamed twice, iPhone "no connection" (follow-up, same session)
- **Reported:** "The vacuum canary has complained 2 times already. My iPhone looked like it had no connection while that happened."
- **Vantage:** vacuum (`3c3bad1fa850`, .148, 2.4 GHz, −43 dBm) + iPhone-Antonio (.146, 2.4 GHz). Times pinned from data, not from the user.
- **Measured (per-minute, UTC):**
  - lanq: router→vacuum ICMP **100 % loss 01:05–01:09 and 01:49–01:53**, ARP present. Notebook-Ana-Clara (2.4 GHz) also lost — ARP gone 01:49–01:52, 100 % loss 01:53. AX73 itself 0 % / 0.6 ms throughout. Wired Mac 0 % loss.
  - rcstats: vacuum tx up (~14 KB/min retries), rx ~1 KB/min in both windows; ~100 KB re-registration burst at 01:09 and 01:53. Same shape as the 2026-08-08 canary event.
  - AX73 (ops Prometheus, 2-min scrape): vacuum stayed associated (in_network continuous), RSSI −43, AP kept RECEIVING its frames (~470 ucast/5 min, normal). wl1.1 (2.4 GHz) tx fell to ~600–2500 frames/5 min around 01:52–01:54 (vs ~16k before); wl0.1 (5 GHz) tx normal/up in both windows. A pair of far 2.4 GHz IoT clients (`70:89:76:22:*`, −75 dBm) re-joined + re-DHCP'd at 01:04 and 01:48, ~1 min before each window.
  - WAN: odi-health clean, PON O5, DNS ladder all up, total v4 flows 200–530 (no CGNAT pressure).
  - iPhone, window 2 only: Tailscale DERP fan-out — 20+ unanswered SYNs to :443 at 01:49–01:52 — hit `connlimit warn` 01:49:00 and **`block` 01:49:50**, so our guard refused its new v4 connections on top of the outage. Window 1: iPhone traffic continued.
- **Verdict:** CONFIRMED LAN-side, 2.4 GHz only: router→client delivery to ≥2 independent 2.4 GHz clients failed for ~4–5 min while associated, wired + 5 GHz + WAN clean. Cause SUSPECTED: burst interference near the AP (4–5 min evening windows fit a microwave oven) or a 2.4 GHz radio TX stall on the AX73. Not distinguished yet.
- **Evidence gap:** AX73 per-radio counters are scraped every 2 min and read through 5 min windows, too coarse to order the events; no channel-busy/CCA metric is exported. The user's microwave/appliance timing would settle the interference theory.
- **New rule:** **vacuum screams + lanq shows ICMP loss to it while the AX73 answers ⇒ LAN/WiFi, not WAN** — check a second 2.4 GHz lanq target and the 5 GHz radio as controls before going near the WAN. A connlimit `block` on an iPhone during an outage is an EFFECT (Tailscale retry fan-out), not the cause.

## 2026-10-01 — follow-up: the trigger is a Tuya device (re)joining 2.4 GHz
- **Reported:** "Might be Tuya devices" / "I do have some Tuya light bulbs that are really flaky in responding to commands, staying for days with no issues and then giving some"
- **Measured:**
  - AX73 association log (ms timestamps): two Tuya stations (`70:89:76:22:ab:df`, `…:bc:26`, hostname `wlan0`) joined within 40 ms of each other at **01:04:06Z** and **01:48:13Z**; the vacuum outages ran ~01:05–01:09 and ~01:49–01:53. The AP removed them for **inactivity (reason 4)** at 01:09:31, and at 01:49:57 + 01:53:38; the vacuum recovered at each removal. In window 1 they sent 7 DHCPDISCOVERs and never a REQUEST — the router's OFFERs did not reach them either. A third Tuya (`84:e3:42:08:6e:f6`, `TY_WR`) went into an auth/deauth loop 3 s after the pair joined, both times.
  - 30 d Loki DHCP × lanq: **14 of 16** vacuum outages ≥3 min began within 5 min (12 of them within 46 s) after a DHCP DISCOVER/REQUEST from a Tuya MAC; base rate 5.7 % of minutes ⇒ ~0.9 expected by chance. The `wlan0` pair alone: 9/16. Nine Tuya MACs seen, up to 422 rejoins/month each.
  - Coverage caveat: lanq lost the vacuum 09-11 → 09-29 (IP moved), so this rests on ~12 days.
- **Verdict:** CONFIRMED trigger — a Tuya station (re)joining 2.4 GHz precedes the long outages. Mechanism inside the AP UNKNOWN; outage length tonight matched the AP's ~5 min inactivity hold on the silent station (2/2 cases only).
- **Evidence gap:** no capture during an event of who answers ARP for the victim's IP, or the AP's per-station TX state. A deliberate power-cycle of the bulb fixture would reproduce on demand.
- **New rule:** on a vacuum scream, first look for a Tuya DHCP line in the minute before it. Loki `|= "dnsmasq-dhcp"` matches nothing — use `|= "DHCP"` and always include a known-present control.

## 2026-10-01 02:23Z — deliberate bulb power-on (smart switch) — NOT reproduced
- **Done:** user switched on the fixture holding the `wlan0` pair; both joined at 02:23:22Z (40 ms apart), `TY_WR` dropped and rejoined 2 s later — same join signature as the outages.
- **Measured:** route10 1 s pings 02:24:07–02:33:06Z: vacuum **450/450 answered**; both bulbs and the AP 0 loss; iPhone short gaps only (iOS doze). Bulbs: −77…−83 dBm, legacy rates (no HT caps), last TX 11/18 Mbps; AP protection modes stayed off.
- **Verdict:** not reproduced. A clean power-on join does not trigger it by itself; in both real outages the pair joined and then went SILENT until the AP removed them for inactivity — here they stayed responsive. Next suspect: a bulb that joins and then drops off the air (flaky/brown-out), not the join itself.
- **New rule:** none yet — the 14/16 correlation stands, but "join" is necessary-looking, not sufficient.

## 2026-10-26 15:35–15:41Z — follow-up: it is mesh netmap churn, 2 tunnel rebuilds per 5 min
- **Reported:** "I do see it on my iPhone VPN on the status bar showing often, even when I'm on 5G WiFi, by the side of the router. And on my wired work Mac (also on the mesh) sometimes I see network changed in chrome."
- **Measured (CONFIRMED):**
  - route10 syslog: the Alta cloud agent re-runs its whole config apply **every minute** (`rc: Re-running dl cfg`; 1,139 runs since 10-25 20:37Z). Each run warns twice (`apkg update` rc 256; `/etc/init.d/netbird … stop` rc 32512 = not installed), rewrites `tailscale.settings.advertise_routes` to the portal's `192.168.10.0/24` and runs `/etc/init.d/tailscale reload`.
  - mesh-health re-adds the ULA /64 at every 5-min tick; the agent's next run (~23 s later) removes it. The ULA is advertised ~23 s of every 300 s.
  - Loki, 14 d, with a control (`wan3_up=true` present every day from 10-12): `Re-running dl cfg` and `AdvertiseRoutes drifted` both start **2026-10-23 07:00–08:00Z**, right after the 1.5k auto-update reboot at 06:56Z (1.5l followed 10-24 06:51Z), zero before. ~1,435 agent runs/day, 288 drift-heals/day.
  - `route -n monitor` on the Mac (peer, accept-routes on): **full utun4 teardown + rebuild** (both tunnel addresses, every route including 100.100.100.100 MagicDNS) at 12:40:02 (our re-add) and 12:40:25 (agent removal) local; same at 12:35:02. The agent's no-op runs (route already absent, e.g. 12:34:24) caused **no** rebuild, so only real route-set changes reach peers.
- **Verdict:** CONFIRMED mechanism for the mesh devices: 2 tunnel rebuilds per 5 min (~576/day) on every peer since 10-23 ⇒ iOS VPN icon re-shown, Chrome `ERR_NETWORK_CHANGED`, in-flight requests dropped and retried ("hangs then loads at once"). Matches the user's iPhone + Mac report. Does NOT explain the TV (not a mesh node), not pursued.
- **Root cause + fix (2026-10-26, CONFIRMED by test):** the loop is `rc` re-running the apply until it ends with `touch /var/run/cfg-dl.ready`. `apkg update` failed every pass because 1.5k's feed list (kept in 1.5l) names `netbird/0.80.0-1`, which Alta never published (403; `0.78.1-1` = 200 control). At 18:07:01Z we wrote apkg's own "lists current" stamp by hand. The 18:07:23Z run logged `touch /var/run/cfg-dl.ready` (first time ever) and there was no re-run after it. 18:15Z tick: no drift, ULA advertised, **0 route messages on the Mac** in 70 s (was 2 tunnel rebuilds per tick). The portal card still rejects IPv6 (`ipWithNetRegex` v4-only), so writers still disagree on each real apply: rare, as before 10-23.
- **Evidence gap:** yesterday's probes (curl, python sockets, ping) don't react to route changes, so they could not see this; the user's own observation (VPN icon, Chrome's message) is what pointed at it.
- **New rule:** on hang/"network changed" reports from mesh devices, run `route -n monitor` on a peer across a mesh-health tick (`:x0:01`/`:x5:01`) and count `RTM_DELADDR` on the tailscale utun. A probe that doesn't care about the route table can't see a tunnel rebuild.

## 2026-10-25 ~19:36Z — "stuff hangs loading then all loads at once" (reported "right now")
- **Reported:** "Why is my internet so weird? Stuff hangs loading then all loads at once." Devices: this Mac, iPhone, TV. Apps, web pages, video. "Right now."
- **Vantage (bridge ports, `brctl showmacs` 19:47Z):** Mac en10 wired → **eth5** (office fiber); its en0 Wi-Fi is up too, but it is not the default route. LG TV **wired to the AX73** (eth1, not a Wi-Fi station). iPhone (`A2:DD:99:C6:20:C0`, .192) on AX73 **5 GHz at −84…−87 dBm** (uplink rate 12–65 Mbit/s). The only things all three share: route10, WAN, AdGuard (Mac: MagicDNS → system default .241; TV: route10 → routedns → AdGuard).
- **Measured (all from the Mac, all clean):**
  - 19:36Z net-snap: gateway 0.6 ms, idle 17.0 vs loaded 17.3 ms (no bufferbloat), PON O5 fec_unc 0, no eth4/eth5 flaps in 24 h. Throughput erratic to EU hosts (Hetzner v4 0.1 Mbit/s over 15 s), CF v4 93 / v6 527.
  - 19:38–19:42Z: 1 s DNS + TCP-connect probe; DNS ≤226 ms throughout. 1 s connect stalls (one SYN retransmit) on 14/170, **but all on Quad9 v6 (7/42) and OpenDNS v4 (6/42); Cloudflare 0/43, Google 0/43** ⇒ destination-side, not our network.
  - 19:41Z: 30 real sites, one shot each: worst TTFB 0.56 s. 19:43Z: QUIC vs TCP to 10 sites, both families: all fast.
  - 19:43:52–19:45:55Z, 5/s for 2 min: Mac→.1 at 1472 B 0/600 lost; Mac→8.8.8.8 1/600, max 21 ms; route10→8.8.8.8 5/600. No gap-then-burst.
  - 19:46Z: uncached lookups via .1, the LAN ULA and .241 directly: all ≤340 ms.
- **Side finding (real, not the cause so far):** since 2026-10-23 ~07:00Z (fw **1.5k**, then 1.5l), mesh-health re-adds the ULA tailnet route every 5 min and something removes it again **within ~10 s** (watched 19:40:01–19:40:16Z: uci and live prefs both lose it). 800 drift lines. Two writers again. No stall at the 19:40:01 or 19:45:01 ticks.
  - 19:48:20–20:08:17Z, 2 s watcher (475 samples, 8 sites in rotation + uncached DNS via system resolver and via .1): DNS never over 276 ms. **One hang, on one host:** `www.microsoft.com` (Akamai, `2600:1419:6a00:…`) hung 20:03:32 (1.6 s), 20:04:02, 20:04:32, 20:05:41Z (10 s timeouts), fine at 20:04:52 and from 20:06:01Z. In the same seconds the other 7 sites (including Apple on a different Akamai edge) answered in 85–770 ms.
- **Verdict (so far):** not reproduced as a whole-network fault. CONFIRMED one ~2-minute single-destination stall (Akamai edge for microsoft.com), with every other host in the same seconds acting as the control ⇒ CDN/path, not our link. Whether that is what the user felt is SUSPECTED only: there is no complaint timestamp to match it to. The iPhone's −84…−87 dBm 5 GHz link is a sufficient cause on the iPhone alone (weak signal CONFIRMED; effect on its traffic SUSPECTED).
- **Evidence gap:** no wall-clock moment of a felt hang from the user yet. The watcher didn't record which address or which phase (connect / TLS / first byte) hung; record `remote_ip` and the phase times next time.
- **New rule:** a 1 s TCP-connect stall is one SYN retransmit — **split it by destination before calling it loss**. Small DNS-provider anycast :443 (Quad9, OpenDNS) drops probe SYNs; Cloudflare/Google don't.

## 2026-10-02 ~21:50Z — "WiFi unusable" after Alta firmware 1.5i
- **Reported:** "What's going on with my WiFi now, it's unusable. Last night Alta pushed a new firmware, it seems it's out of the mesh."
- **Vantage:** tailnet clients on the LAN (operator's Mac / iPhone); exact device not given.
- **Measured (21:54–21:56Z):** net-snap from the wired Mac: 613/494 Mbit/s, gateway 1.3 ms, PON O5, no bufferbloat. DNS ladder all up, 5–20 ms. AX73 up 5.2 d, MBP 5 GHz −33 dBm 780/867. route10 rebooted into **1.5i** at 06:44Z, and `tailscale` was absent from the filesystem.
- **Verdict:** CONFIRMED, not WiFi. 1.5i dropped built-in Tailscale, so route10 left the mesh. Tailnet clients send `*.net.aac.gd` to route10's tailnet IPs (Headscale split DNS); those names timed out while the network itself was fine (ops-measured on the operator's Mac). A client using route10 as exit node loses everything. Restored 22:16Z via the portal Tailscale card.
- **Evidence gap:** the detectors were silent for 15 h — mesh-health exited 0 on "binary absent", and ops' tag check stays green on a logged-out node. Both are fixed router-side.
- **New rule:** on a "WiFi unusable" report after a firmware update, check `tailscale status` on route10 first. A tailnet client loses internal names (or all internet, with an exit node) while every LAN/WAN probe reads healthy.

## 2026-10-29 20:53:35Z → ongoing at 21:09Z — "Is internet down?" (WAN outage, PPP flapping every 20–40 s)
- **Reported:** "Check what's going on with my network please. Is internet down?" (asked 21:00Z; the user was already on the iPhone hotspot, gateway 172.20.10.1)
- **Vantage:** whole house; WAN path (route10 → ODI stick → fiber)
- **Measured:**
  - 20:53:35Z netifd "wan3 link connectivity loss". eth4 carrier_changes went 175 → 299 by 21:04:45Z, 48 flaps in 8 min.
  - pppd: PADO timeouts and "Unable to complete PPPoE Discovery". Sessions that do come up (CHAP OK every time) drop within seconds; the live watch 21:03:39–21:04:49Z saw 4 drops. ⚠ CORRECTED 2026-10-30: those drops were our own reload loop, not the line. See **Correction** at the end of this entry.
  - Stick pon rows: O5 until 20:53, **O3 at 20:54**, O5 again at 20:57 with ranging_req 1/1/3. Stick uptime continuous (16.2 d, NO reboot).
  - Stick raw 20:54: **DS PLOAM CRC 172/243**, **BWMAP CRC 11,736/528k** (+2,488 invalid), GEM LOS 2,809, HEC-corrected 300k, DS-ETH FCS 67. LOS/LOF/SF/SD all clear, BIP 0, FEC 0. All of these were **0 for the 24 h before 20:53Z**: abrupt onset, not degradation.
  - DDM flat throughout: Rx −15.1 dBm, Tx +2.3 dBm, 3.23 V, 13.7 mA, 42 °C.
  - Neighbour broadcasts on eth4 stayed ~200/min, with no re-dial (PADI) storm, so the rest of the segment does not look reset.
  - Our config: no change since 10-27, no cloud apply or post-cfg before the onset; CHAP succeeds (refuse-pap is irrelevant).
- **Verdict:** confirmed WAN outage caused by **downstream signal corruption at our ONU with normal optical power**. Mechanism of the corruption NOT known. ⚠ RETRACTED 21:20Z: "no neighbour re-dial storm ⇒ local" does NOT hold. If our whole PON branch failed, those neighbours' ONUs are down too and their PADIs never reach the OLT, so the storm would be invisible. The evidence does not separate our stick from an ISP-side fault on our branch. The operator also notes nobody touched the fiber, which argues against a connector fault.
- **Evidence gap:** a second ONU on the same fiber to A/B against (the Huawei is the swap target), and visibility of the OLT side.
- **New rule:** ONU O5→O3 plus DS PLOAM/BWMAP CRC errors with flat Rx power ⇒ a PON-layer fault, not routing or config. The neighbour PADI rate (`route10_eth_broadcast_packets_total{dir=rx}`) separates segment-wide from local-only.
- **Follow-up 21:21:47Z (operator approved):** remote stick reboot via Boa formReboot, accepted on the 1st attempt. Stick dark 21:22:06–21:23:01, uptime **39 s at 21:23 (reboot confirmed)**, PPP up 21:23:32. Flapping resumed within ~30 s (eth4 flaps 609→635 by 21:25) with **ranging_req 4 in the first 39 s**. ⇒ a stuck stick software state is RULED OUT. (⚠ 2026-10-30: the resumed flapping was our reload loop restarting with the new session; the ranging_req count is PON-layer and still stands.) Still open: stick hardware vs fiber vs ISP side; the A/B swap to the Huawei is the decisive test. ⚠ pon json `ds.ploam_crc` / `bw.crc_err` read the SAME values after the reboot as before it (211 / 14040), so they are not reset-aware; don't trust them across a reboot.
- **A/B swap 21:29–21:38Z (operator):** fibre moved to the Huawei EG8145X6 (bridge mode, **LAN1** confirmed by the operator) → route10 eth3. eth3 got link 21:30:49Z and then **cycled on a regular ~18 s period (≈15 s up / 3 s down, 45 changes by 21:37:40Z)**. PPPoE on `wan`: only "Timeout waiting for PADO", no session in 7+ min. **The same fault on two different ONUs ⇒ CONFIRMED NOT our stick and NOT route10. It is the fiber or the ISP side** (their equipment, splitter, or the drop outside). Supports: abrupt onset, nobody touched anything, the stick reboot didn't help, flat DDM. Also learned: both ONUs drop their LAN link whenever PON registration fails, so a regular eth3/eth4 flap period is itself a PON-down tell.
- **Follow-up 21:50–22:15Z (Huawei web-UI login, from route10):** operator hypothesis "maybe the modem is not in bridge mode" — TESTED AND REFUTED, worthily. The udhcpc lease on eth3 (`192.168.18.16/24`) comes from the Huawei's **LAN management DHCP, which bridge-mode ONTs also serve** — a lease proves nothing about mode. Logged into `192.168.18.1` as `Epadmin` (reachable from route10 itself with `192.168.18.16/24` temporarily on eth3 — REMOVE after swap-back; not from the Mac):
  - **INTERNET WAN is still bridged:** `2_INTERNET_B_VID_1011`, `IP_Bridged`/DHCP (mode read from the device, previously assumed from the April config). The routed `1_TR069_INTERNET_R_VID_1011` PPPoE WAN (user `410563@btt`, WAN MAC `E0:DA:90:C4:F8:86`) shows **Disconnected** — the Huawei's own dial can't get out either.
  - **Identity:** SN `48575443370F0BAE` (= `HWTC370F0BAE`, the SN our stick spoofs), EG8145X6-10, V5R022C00S265 — same unit as the April 2026 migration. Uptime 46 min ⇒ it was power-cycled at the swap; **a fresh boot didn't help**, so a wedged Huawei software state is ruled out too.
  - **Optics:** Tx +2.16 dBm, **Rx −26.20 dBm stable** (two samples 15 min apart), LosStatus 0 ⇒ light present, no LOS declared. ⚠ **Absolute value NOT comparable across ONUs:** the same unit read **−22.44 and −30.46 dBm in April on a WORKING line**, while the stick read −15.1…−15.45 all year — this Huawei's Rx calibration is off by several dB in both directions. Cross-ONU DDM comparisons are void; only same-device deltas mean anything.
  - **MAC mystery resolved:** the 1 Hz `fe80::1` ICMPv6 pings seen on eth3 with MAC `e0:da:90:c4:f8:85` are the **Huawei** — its LAN MAC is `E0:DA:90:C4:F8:85`, and the stick's ELAN_MAC was cloned from it (onu-config.md). Not a stick ghost; `STICK_MAC`/`RT10_ONTEDGE` values remain correct (the two devices never share a live segment).
  - **PON registration state NOT retrievable as Epadmin:** every gponstatus/gponinfo/ponstate path 404s (matches April's "GPON-config pages 404 without telecomadmin"). The physical **PON LED** is the remaining local registration read.
- **Verdict (final for tonight):** abrupt onset 20:53:35Z; DS corruption at normal optical power (stick); stick reboot no help; Huawei fresh boot no help; **two different ONUs — including the ISP's own — fail identically**; bridge config intact ⇒ fault is **upstream of both ONUs: the drop fiber, splitter, or OLT PON port**. Nothing on our side can restore service; it needs the ISP.
- **New rules:** (1) a DHCP lease from an ONU does NOT prove routing mode — bridge-mode ONTs serve their management subnet; read the WAN connection list (`IP_Bridged` vs `IP_Routed`) to settle mode. (2) Never compare DDM Rx across different ONU models — calibrations differ by many dB (here −26 vs a stick's −15 on the same fiber, with the Huawei's own healthy history spanning −22…−30). (3) The Huawei's LAN MAC == the stick's cloned ELAN_MAC — a MAC-based identity check cannot tell these two devices apart.
- **Side observation (DEFERRED):** dnsmasq `failed to send packet: Permission denied` ~1/s since 21:36Z (3,599 lines by 22:15Z), i.e. from the swap window. Suspected dnsmasq sending on eth3 while it sits in the wan zone (output DROP ⇒ EPERM). Re-check after WAN restore; investigate separately only if it persists.
- **Recovery ~23:49–23:50Z (~3 h after onset):** the operator contacted the ISP, who rebooted and re-provisioned the Huawei. It now dials PPPoE ITSELF (router mode; it was bridge in April), so the operator moved it to route10's DHCP WAN (`wan2` = eth0) to avoid a double PPPoE dial. wan2 got 192.168.18.37/24 (gw 192.168.18.1) at 23:48:39Z. Internet followed ~1 min later: v4 26 ms, HTTPS 200, router DNS OK (internet + split zone), IPv6 OK via the Huawei, Tailscale Running, eth0 link stable (0 changes/30 s). The fix came from the ISP side, consistent with the A/B verdict. Still unknown: whether the stick path would work again, and what the ISP changed. ⚠ Running double-NAT on the Huawei means the stick telemetry (pon-collect/DDM/eth4 metrics) does not describe the live path.
- **Recovery ~23:48:33Z (ISP side).** After the operator engaged the ISP ("they might restart it"), the Huawei's PON registered: the ~18 s eth-link flap cadence stopped dead at 23:48:33Z (stable ever since). The Huawei then dialed **its own routed `TR069_INTERNET_R` PPPoE WAN** (creds `410563@btt`) and came up with **public IPv4 177.55.227.221** (no CGNAT on this session) and IPv6 PD `2804:2488:5081:bec0::/64`. route10 rides it via **wan2** (eth0, DHCP `192.168.18.37`, default route, mwan3 score 10); LAN restored v4+v6 (ping6 27 ms). Outage total: **20:53:35Z → 23:48Z ≈ 2 h 55 m**. ISP restart SUSPECTED as the clearing event (timing fits), not confirmed.
- **How the accidental path worked:** the operator, mid-swap, had plugged the Huawei into the "other WAN" — eth0 = `wan2`, proto **dhcp** (vs eth3 = `wan`, pppoe). A routing-mode ONU behind a DHCP WAN = instant double-NAT internet. The same cable on eth3 (PPPoE into a routing ONU) could never have worked while the Huawei held its own session.
- **Prefix rotation handled automatically:** `lan-prefix-track` rotated the LAN /64 `2804:2488:5081:3b30::/64` (pre-outage) → `…:bec1::/64` at 23:51 local, NAT66 bridge + re-announce covering the old prefix for 24 h, p2p6 pinhole re-pointed. ⚠ The pinhole is `-i pppoe-wan3`-scoped ⇒ **ops p2p inbound is dead while WAN rides eth0** (double NAT anyway); self-heals on cutover.
- **Interim-path gaps (why this is not a steady state):** `RT10_CONNLIMIT` (pppoe-wan3-scoped) and `RT10_MESHEGRESS` (pppoe+-scoped) don't cover eth0; pon-collect is blind (stick dark); double NAT; the Huawei is ISP-managed (TR069 can change it at any time).
- **Cutover plan (pending operator go):** fiber Huawei → stick (W2). Expect a short blip; the risk is the BNG holding the Huawei's PPPoE session (PON loss sends no PADT) so the stick's first dials could hit AUTH_TOPEER_FAILED until the BNG's LCP timeout (~30–120 s typical; the 2026-05-28 pathological case needed ~1 h). A third PD rotation follows; the tracker covers it.
- **New rules:** (1) A "bridge-mode" ONU may also hold a ROUTED PPPoE WAN that dials on its own — read the WAN list (`WanPPP` status in getwanlist.asp), don't assume mode from one entry. (2) A regular ONU-side eth-link flap cadence that stops dead = PON registered; judge recovery from the cadence, not from PPP. (3) During ONU swaps, the DHCP-WAN port + a routing ONU is a working emergency path (double NAT) — it is also a trap: the same ONU on the PPPoE port yields nothing while its own session holds the line.
- **Correction (2026-10-30, from Loki):** part of the stick phase was our own reload loop, found when the fiber went back to the stick on 10-30 and the same loop held the WAN down for 26 min. Alta's `/etc/ppp/ip-up.d/ppp-up.sh` runs `cfg -r vpns` on every new PPP IP. cfg sees post-cfg's network edits as changes and reloads the network, which flips the eth4 MAC and restarts wan3, so the session dies ~0.3 s after CHAP succeeds. Fixed by post-cfg job 14 (ef9bdcb).
  - 20:54:42–21:29:16Z: **113 sessions came up, and 82 `cfg: Found interface config changes, applying.`** followed. The first apply came after the 20:53:35Z onset.
  - So in that window the session drops are ours, and the eth4 flap counts (175→299, 609→635) and the 46 `Timeout waiting for PADS` are partly our own reloads. None of them measure the PON.
  - **Still stands:** the onset; O3 at 20:54 and the DS PLOAM/BWMAP CRC errors (PON layer, which a reload can't cause); ranging_req after the reboot; the Huawei A/B (no session ever came up, so the loop never ran, and the ~18 s link cycle with no PADO is independent); the ISP-side clearing at 23:48Z. The line was really down from ~21:30Z.
  - **Now open:** from 20:57Z (stick back in O5) to the 21:22Z reboot, 82 sessions came up and only 7 dials hit `Timeout waiting for PADO`, so PPPoE was reaching the BNG. Whether the stick path would have carried traffic then is unknown, because the loop killed every session first.
- **New rule:** if wan3 gets CHAP OK and still won't hold, look for `cfg: Found interface config changes` right after `pppd: local IP` before blaming the line. If it's there, eth4 flap counts and PADS timeouts in that window are ours.
