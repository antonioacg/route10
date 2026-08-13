---
name: net-triage
description: Triage a "the internet is slow / streaming is dropping / buffering / graining" complaint on the Route10 network, and get better at it every time. Use when the user reports slowness, drops, buffering, low speedtest numbers, or hands over a net-snap capture. Captures evidence in the act, classifies it against previously-seen signatures, and appends what was learned so the next run starts ahead.
---

# Network slowness triage (self-improving)

A slowness complaint is the hardest class we have, because **the fault is usually
gone before anyone measures it**, and the obvious probes are the ones most likely
to lie. This skill exists to make the next incident cheaper than the last.

## ⭐ STEP 0 — read the record BEFORE measuring

Read [`docs/incidents/net-triage-log.md`](../../../docs/incidents/net-triage-log.md).
It holds every previous complaint, what was measured, and what it turned out to be.
Check whether the current symptom matches a known signature **first** — several
past incidents were re-derived from scratch because nobody looked.

⛔ And consulting the record is not the same as having consulted it: check whether
the measurement behind an entry was actually taken **for a case like this one**. A
conclusion from a different device, medium, or destination may not transfer.

## STEP 1 — capture, while it is still happening

```sh
~/git/route10/scripts/net-snap.sh --note "<what the user sees, verbatim>"
```

Read-only, ~45 s, never touches the stick CLI. If the user reports it while it is
happening, **run this before asking any questions** — the fault is perishable and
the answers are not.

If it has already recovered, say so plainly and go to STEP 4 (retrospective).

## STEP 2 — establish the vantage, in the user's words

Never assume. Ask (or read from the note) and record all four:

| | why it matters |
|---|---|
| **which device** | a TV box, a phone and a wired Mac are three different networks |
| **which medium** | 2.4 GHz / 5 GHz / wired. On 2026-08-12 the same evening gave **1.5 Mbps on 2.4 GHz, 10 Mbps on 5 GHz, and fine on 5 GHz later** |
| **which app/service** | Globoplay ≠ Netflix ≠ a speedtest. Each is a different CDN and path |
| **what "slow" means** | a number, a spinner, graining, a drop? Graining is bitrate; a drop is a stall |

**Topology as of 2026-08-12** (confirm, don't assume — it changes):

```
Claro TV Box ──wired──┐
                      ├── AX73 (AP ONLY, not routing) ──wired── route10 ── WAN
phones / laptops ─wifi┘
.200 and others sit behind the office switch on eth5
```

A shared AP uplink is a single point that degrades **both** its wired and its
wireless clients — so "the TV box is wired" does not exempt it from a wifi-side
problem at the AP.

## STEP 3 — classify

Compare measurements *within one run*, never across runs, and never across time
without timestamps.

| signature | reading |
|---|---|
| **PON O5 + FEC 0 + `retx` flat + DNS fast + CRC 0 + no bufferbloat, yet throughput collapsed** | **upstream of the ONU** (ISP BNG/CGNAT/peering). Seen 2026-08-13: ~7 min, whole link, perfectly clean local stack |
| **network TOTAL falls, not just one client** | link problem, not a hog. One slow client is a client problem |
| gateway RTT clean, PON O5, no CRC, throughput fine to several hosts | link is healthy — look at LAN/AP/client/CDN |
| one destination slow, others fast, same family | **CDN/path problem**, not your link |
| v4 slow **and** v6 fast, to the *same* host, repeatable on *distinct* hosts | possible ISP CGNAT pressure (our v4 is `100.68.x` = CGNAT; v6 bypasses it) |
| v4 **and** v6 both dead everywhere | **suspect the probe.** Symmetrical failure is almost never the network |
| latency inflates under load | bufferbloat — check qdisc/shaping on `pppoe-wan3` |
| one host with hundreds of flows + connlimit warns | torrent/p2p pressure (`.200` is the usual one) |
| per-client rx/tx low for the complaining device while WAN total is high | the device is being starved *locally* — AP or LAN, not WAN |

## ⭐ STEP 4 — retrospective, when it already recovered

**Do this FIRST if the complaint has passed — it beats any live probe.** On
2026-08-13 the live probes all ran *after* recovery and said "healthy"; the
per-client counters pinned the window to the minute and matched the user's own
number (1.44 vs "1.5 Mbps"). Ask for the complaint's wall-clock time and mine it:

⚠ `/a/stats.sql` `minutes` is a **rolling 60-minute window** — older windows live
in `/a/obs/stats-archive.sql`. In both, `minutes.ts` is in **SECONDS** (the
`speed_tests` table uses **milliseconds** — do not copy one query into the other).

Read the **network total** as well as the complaining client: one slow client is a
client problem, every client slow at once is a link problem.

The router keeps first-person evidence you can still mine:

- **`/a/stats.sql` `minutes`** — per-client `tx`/`rx` **and DPI protocol names**,
  per minute. This is the only account of what an un-instrumentable box (TV box,
  phone) was actually getting. Find the complaint minute and read that client.
- **`/a/stats.sql` `speed_tests`** — router-run M-Lab tests, independent of us.
- **`/a/obs/rt.sql`** — `pon` (PON/optical/alarms), `samples` (CPU, ifaces, DNS
  ladder), `lanq` (per-client probe RTT/loss).
- **`/var/log/messages`** — `route10.connlimit` warns name the offending host.

Ask the user for the **wall-clock time** of the complaint, and convert carefully:
syslog is **UTC**, `date`/`ls -l` are **local (UTC-3)**.

## ⛔ Anti-patterns — every one of these cost real time on 2026-08-12

1. **No claim of simultaneity without timestamps.** "Both happened in the same
   window" was asserted, challenged, and could not be backed. Two numbers are
   only comparable if you can show *when* each was taken.
2. **Never hammer one endpoint.** ~15 rapid requests to one host from two
   machines behind a single CGNAT IP produced a rate-limit that was then read as
   a v4 fault. One shot per host, distinct hosts.
3. **A symmetrical failure is a broken probe.** v4 and v6 both at ~15 B/s, and
   20/20 handshakes failing on both families, while another machine pulled
   500 Mbit/s through the same router. It was BusyBox `nc` (no `-z`) plus
   self-inflicted rate limiting.
4. **Verify a tool can succeed before believing its failure.** `dd` did not exist
   on the stick; `nc -z` does not exist in BusyBox; `ls /var/run/pon-collect.lock`
   checked a path that was never the lock. Each "result" was an absence of tooling.
5. **Do not use player symptoms as a time marker.** Buffering makes graining lag
   the cause by minutes, and recovery can coincide with an episode boundary for
   reasons that have nothing to do with the network.
6. **Know what your speedtest measures.** `fast.com` targets Netflix OCAs (its API
   returned four `ipv6-…oca.nflxvideo.net` hosts) — a fine streaming signal, a
   poor link test. `1.1.1.1` **rate-limits ICMP** on this path and has shown
   40–100% loss while TCP through it was clean; use the PPP gateway as the control.
7. **Do not put words in the user's mouth.** Their observation is data; your
   framing of it is not. If they say the link was bad, the link was bad.

## ⭐ STEP 5 — self-improvement (this is the point; do not skip)

After **every** invocation, append an entry to
[`docs/incidents/net-triage-log.md`](../../../docs/incidents/net-triage-log.md):

```markdown
## <UTC date/time of the COMPLAINT, and how you know>
- **Reported:** <verbatim from the user>
- **Vantage:** device / medium / app
- **Measured:** <the numbers, each with its timestamp>
- **Verdict:** confirmed <X> | not reproduced | inconclusive
- **Evidence gap:** <what would have settled it, and why it was missing>
- **New rule:** <what changes next time — or "none">
```

**"Not reproduced" is a required, first-class outcome.** Most entries will be
that, and a log of near-misses is what eventually makes the pattern obvious. An
entry that records only wins teaches nothing.

Then, when a run produces something durable:

- a new **signature** → add a row to the STEP 3 table
- a new way a probe **lied** → add to the anti-patterns
- a new **data source** → add to STEP 4
- a topology change → fix STEP 2

Keep this file and the log honest about confidence: mark a claim **CONFIRMED**
only with the measurement beside it, otherwise **SUSPECTED**. A suspicion promoted
to fact by repetition is how a wrong conclusion outlives its evidence.
