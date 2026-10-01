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
