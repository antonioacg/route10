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
