---
name: net-triage
description: Triage a "the internet is slow / no internet / streaming is dropping / buffering / Wi-Fi is bad" complaint on the Route10 network, and get better at it every time. Use when the user reports slowness, drops, "no internet" on a device, buffering, low speedtest numbers, or Wi-Fi trouble. One command captures every vantage in parallel (~15 s) and prints an automatic verdict; every run then teaches the tool something (new collector, new rule, new fixture).
---

# Network triage (self-improving)

A complaint is the hardest class we have, because **the fault is usually gone before anyone
measures it**, and the obvious probes are the ones most likely to lie. This skill makes the
next incident cheaper than the last, and the memory lives in **code**, not prose:

| file (`scripts/triage/`) | role |
|---|---|
| `net-triage` | entry point: runs every collector in parallel, then the analyzer |
| `collect-route10.sh` | piped over ssh: WAN, mwan3 policy, PON, DNS ladder, per-client bytes, LAN probes, syslog, fence drop deltas, mesh, bridge ports, live client capture |
| `collect-ax73.sh` | piped over ssh, **read-only**: BSSes, station RSSI, association log, AP bridge ports, channel airtime (`wl chanim_stats`) |
| `analyze.py` | raw → `facts.json` → report. Also `--replay`, `--selftest`, `--save-fixture` |
| `signatures.py` | **every known failure shape, one rule each. This is the classification table.** |
| `fixtures/<date-slug>/` | scrubbed facts from a real capture + `expect.json` (what MUST and must NOT fire) |

## STEP 1 — capture first, questions later

```sh
scripts/triage/net-triage --client <name|ip|mac> --note "<what the user sees, verbatim>"
scripts/triage/net-triage --at 21:40 --client tv            # retrospective (local time)
```

Run it **before asking anything** when the user reports a live problem: the fault is
perishable, the answers are not. ~15 s; raw files + `facts.json` + `report.txt` land in
`~/.cache/net-triage/<UTC stamp>/` (kept 30 days, never committed: it holds DNS names and
addresses). `--client` matches a hostname substring, IP or MAC, and follows a phone across
SSIDs (iOS uses one private MAC per network, so a band switch looks like a new device).

If it already recovered, say so and use `--at <HH:MM>`: the router keeps per-minute
per-client bytes, LAN probes, PON and the DNS ladder (30 d), syslog (~1.5 d on-box, 30 d in
Loki), the AP association log (~3 h), and ops Prometheus keeps per-station RSSI/retries.

While it runs, read [`docs/incidents/net-triage-log.md`](../../../docs/incidents/net-triage-log.md).
⛔ Consulting the record is not the same as having consulted it: check that a past
measurement was taken **for a case like this one** (device, medium, destination).

## STEP 2 — read the report, then establish the vantage

The report leads with **VERDICT** (rules that matched, with evidence), then
**checked, not matched** and **could not check (why)**. Then layers (WAN / PON / DNS / vantage /
fences / mesh / flows / guards / logs), Wi-Fi (radio airtime, retry-vs-RSSI curve, station
table, AP events), LAN probes, the client's minute-by-minute timeline, and collector timings.
**The verdict is a hypothesis: check it against the numbers under it.**

Then confirm, in the user's words, what the report can't know:

| | why it matters |
|---|---|
| **which device** | a TV box, a phone and a wired Mac are three different networks |
| **which medium** | 2.4 GHz / 5 GHz / wired (the report shows it if `--client` resolved) |
| **which app/service** | Globoplay ≠ Netflix ≠ a speedtest: different CDNs and paths |
| **what "slow" means** | a number, a spinner, graining, a drop? Graining is bitrate; a drop is a stall |
| **where they are** | coverage findings need it: a phone walking away reads as signal falling |

**Topology (2026-11-18; the report's `at` column is the live truth):** route10 `eth1` → AX73,
the ONLY access point (AP mode, 2.4 GHz `wl1.1`, 5 GHz `wl0.1`). The wired Mac and `.200` sit on
route10 `eth5` (office fiber); the PS5 is wired to AX73 port 3 (`eth2`). The vacuum is on 2.4 GHz
(−40 dBm since it moved next to the AP on 11-18). The LAN probe follows it by DHCP name and pinged
whatever held its old IP while it had no lease (the PS5, 11-16 → 11-18): `probe-target-mismatch`
flags that. A shared AP uplink degrades both its wired and its wireless clients.

**Judgement calls the rules don't encode** (compare within one run, never across runs):
- the network **total** falls, not just one client → link; one slow client → that client
- one destination slow, others fast, same family → CDN/path, not our link
- v4 slow **and** v6 fast to the *same* host, repeatable on *distinct* hosts → CGNAT pressure
  (our v4 is `100.68.x`; v6 bypasses it)
- the client's rx low while the WAN total is high → starved locally (AP/LAN)
- mesh devices: VPN icon reappearing, Chrome "network changed", hang-then-burst while every
  probe is clean → `route -n monitor` on a peer across a `:x0:01`/`:x5:01` tick (`RTM_DELADDR`
  on the tailscale utun = tunnel rebuild). Probes can't see it.

## ⭐ STEP 3 — make the tool smarter (the point; do it before reporting)

1. **Did you run anything by hand to reach the verdict?** Put it in a collector
   (`collect-*.sh` / `net-triage`) and a fact in `build_facts`, so the next report shows it.
   Read-only stays read-only, and on the AX73 nothing that touches the radio (no `wl scan`).
2. **Did the automatic verdict differ from yours** (a miss, a false hit, a wrong "can't
   check")? Fix or add the rule in `signatures.py` (`since`, CONFIRMED only with the measurement
   written down, thresholds next to the measurement they came from). Then:
   ```sh
   scripts/triage/net-triage --save-fixture <yyyy-mm-dd-slug> ~/.cache/net-triage/<stamp>
   # edit fixtures/<slug>/expect.json: the TRUE verdict, and what must NOT fire, with "why"
   scripts/triage/net-triage --selftest
   ```
   **Prove the test can fail**: re-introduce the bug in a scratch copy and watch `--selftest`
   go red. A test you haven't seen fail is not a control.
3. **Did a probe lie, a collector fail, or a run take over ~20 s?** Fix it (COLLECTION shows
   each collector's time). If a human would fall into the same trap, add an anti-pattern below.
4. **The repo is public.** Fixtures are scrubbed by `--save-fixture` (MACs keep only the OUI,
   names/SSIDs/apps hashed, global IPv6 → `2001:db8::`). Check before committing:
   `rg -i '<names>|[0-9a-f]{2}(:[0-9a-f]{2}){5}|2804:' scripts/triage/fixtures/`.
5. **Log only real network incidents** in `net-triage-log.md` (operator, 2026-11-11). A device-side
   or coverage complaint teaches through a rule + fixture, not a log entry. "Not reproduced" is
   still a first-class outcome for a real incident.
6. Commit (route10: straight to main) and tell the user what the tool learned.

## ⛔ Anti-patterns (each one cost real time)

1. **No claim of simultaneity without timestamps.** Two numbers are comparable only if you can
   show *when* each was taken.
2. **Never hammer one endpoint.** ~15 requests to one host from behind one CGNAT IP produced a
   rate-limit that was read as a v4 fault.
3. **A symmetrical failure is a broken probe** until shown otherwise (BusyBox `nc` without `-z`,
   2026-08-12).
4. **Verify a tool can succeed before believing its failure** (`dd` absent on the stick, a lock
   path that was never the lock).
5. **Player symptoms are not a time marker**: buffering lags the cause by minutes.
6. **Know what a speedtest measures.** fast.com = Netflix OCAs. `1.1.1.1` rate-limits ICMP on this
   path: use the PPP gateway as the control. **A far host under a short cap measures slow start,
   not the link**: Hetzner (DE) read 9 Mbit/s on a 600 Mbit/s line in 3 s (2026-11-18).
7. **Don't put words in the user's mouth.** If they say the link was bad, the link was bad.
8. **Split a 1 s connect stall by destination** before calling it loss: it is one SYN retransmit.
9. **curl, sockets and ping can't see a tunnel rebuild** (2026-10-26).
10. **A canary must answer when healthy.** A dozing iPhone drops ICMP for most minutes and a
    laptop may firewall it: both read as endless outages. And canaries move: check where the
    probe target connects (the report's `at` column) before using it as a control.
11. **The main routing table is not the LAN's path.** `ip route` lists the fibreless Huawei
    (`eth0`, metric 101) first while mwan3 sends every LAN flow out wan3: read the mwan3 policy.
12. **An AP's bridge shows every upstream MAC on its uplink port**: "behind the AP" needs
    route10's port first (the analyzer does this).
13. **One 5-minute retry figure is noise for a dozing phone** (4% → 289% → 509% between points):
    compare stations on frame-weighted 15-minute retries.
14. **In `sh`, a background job's stdin is `/dev/null`**: redirect inside the job, or ssh
    `sh -s` receives nothing and the collector "fails" silently.
15. **A capture on `br-lan` can't see what the fences drop** (2026-11-23). Bridged frames meet
    iptables on the bridge PORT (the log says `PHYSIN=eth1`), before `br-lan`'s capture point,
    so a dropped packet never shows there: 0 captured while `RT10_LANCGNAT` logged the phone.
    Capture on the port (`eth1` = AX73, `eth5` = office) or diff the chain counters.
