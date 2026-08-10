# Post-mortem — 2026-08-08 whole-LAN outage (route10 IP-stack wedge; switch ASIC kept forwarding)

**Status:** root cause **LOCALIZED with packet-level evidence** — route10's **CPU-mediated network
stack** wedged while the **switch ASIC kept forwarding**. Onset bracketed to a **~98-second
window**. The precise kernel fault is not identified and, absent a repeat with better
instrumentation, may not be identifiable.

**One-line:** In a ~98 s window ending by 19:20:23 UTC, route10 stopped answering for **its own
IP** — LAN ARP, the eth4 management MACVLAN and the PPPoE session all died together — while the
hardware switch provably continued flooding broadcast and forwarding unicast between wired ports.
Userspace (cron, odi-health) ran throughout. Only a power cycle recovered it.

⚠ **Amended 2026-08-10:** the operator reports internet access was **wedged and highly unstable
during the outage, not 100 % down.** The counters showing a hard stop only begin **18 minutes
after onset**; that first third is unobserved by every source we hold. Read "died" below as
"stopped being usable / stopped delivering telemetry", not as a proven instantaneous stop — see
the correction in §"What the last minute looked like".

Sibling incidents: [`2026-07-08-wan3-route-loss.md`](2026-07-08-wan3-route-loss.md),
[`2026-06-24-power-surge-dhcp.md`](2026-06-24-power-surge-dhcp.md).

---

## 1. Impact

- **27.0 minutes** of total LAN isolation — `19:18:45Z → 19:45:45Z` (16:18–16:45 local, UTC−3).
- Whole LAN lost internet **and** DNS; clients resolve via route10.
- **WiFi clients were more isolated than wired ones** (§4) — wired hosts could still reach each
  other, WiFi hosts lost broadcast into the wired segment.
- Recovered only by operator power cycle. No config change involved. No data loss.

---

## 2. Timeline

Two independent clocks, reconciled. route10's `/cfg/scripts/*.log` stamp **LOCAL (UTC−3)**;
the ops collector stamps **receive time in UTC** and is the authority for cross-host correlation.
All times below are **UTC**.

| UTC | Event | Source |
|---|---|---|
| 19:16:58 | odi-health healthy — **reached the collector** | ops Loki |
| 19:15:08 | `dhcp-watchdog` heartbeat `checks=2942`; cadence ~5 m15 s ⇒ next due **~19:20:23** | ops Loki |
| 19:18:44–45 | **Full dual-stack DHCP negotiation completes** for the operator's Mac — v6 SOLICIT→ADVERTISE→REQUEST→REPLY *and* v4 DISCOVER→OFFER→REQUEST→ACK, in the final 1.0 s | ops Loki |
| **19:18:45.0946** | **LAST line ever received.** A `DHCPACK(br-lan) 192.168.10.140` | ops Loki |
| **(19:18:45.09 , ~19:20:23]** | **LAN forwarding path dies — ~98 s bracket.** Next heartbeat never arrives | ops Loki |
| 19:21:58 | odi-health records `wan3_up=false ip=- pppd=1 carrier=1 ping_fail` + `W2_mgmt_path_down` — **written to `/cfg`, never delivered** | route10 `/cfg` |
| 19:26–19:42 | Four more identical cycles, all logged locally, none delivered | route10 `/cfg` |
| 19:36:24 | Headscale marks route10 offline (keepalive reap — lags the fault) | Headscale |
| **19:45:22** | Operator power cycle; reset reason `Power on Reset [0x20]` | `/proc/uptime`, SCM |
| 19:45:45.8548 | **First line after the gap** — boot config replay. Gap = **1620.8 s** | ops Loki |
| 19:49:41 | mesh-health self-heals tailscaled (stopped by the cloud reapply at 19:45:37) | route10 `/cfg` |
| 19:50:01 | route10 back on the mesh, `tag:home-router` intact, all four routes serving | Headscale |

**The asymmetry that closes the bracket:** the 19:16:58 odi-health line reached the collector; the
19:21:58 one did not. It exists on `/cfg` but never crossed the LAN — independently confirming the
LAN path was already dead by 19:21:58, from a source that knows nothing about DHCP.

---

## 3. What failed, and what did not

| Died in the ~98 s window | Ran normally throughout |
|---|---|
| ARP replies for `192.168.10.1` (LAN) | odi-health cron, every 5 min, writing to `/cfg` |
| PPPoE session (`ip=-`, **`pppd=1`**, **`carrier=1`**) | `pppd` process alive; PHY carrier up at 1000 |
| eth4 management MACVLAN (`192.168.1.2 → .1`) | i2c/DDM reads, all 13 thermal zones |
| WiFi→wired broadcast/flood path | **Switch ASIC: broadcast flooding + unicast forwarding** |
| Syslog egress to `.242:514` | dnsmasq had been serving leases 1 s earlier |

**br-lan was healthy right up to 19:18:45.094 — no ramp preceded the last line.** A complete
dual-stack lease negotiation finished 1.0 s before it. At 19:18:45.094 `br-lan` held its address,
dnsmasq was bound and answering broadcast, and the forwarding path to the collector was intact.

> ⚠ **CORRECTION 2026-08-10.** An earlier version of this paragraph read *"br-lan was not
> degrading — it was perfect, then gone."* The second half of that is **not supported**, and the
> operator's first-hand account contradicts it: during the outage internet access was **wedged and
> highly unstable, but not 100 % down.**
>
> The evidence only ever established that **logging stopped** abruptly. Silence in the log is
> equally consistent with "network dead" and "network too degraded to deliver a syslog line", and
> this document treated the first reading as the only one. Absence of telemetry was read as
> absence of traffic.
>
> The switch counters that show a hard stop (§ below: port 5 zero rx for 8 consecutive minutes)
> begin at **19:37:00** — **18 minutes after onset**, two thirds of the way through the wedge.
> Those 18 minutes have **no counter data from any source**, and they are exactly the window the
> operator describes as unstable-not-dead. Nothing we hold contradicts that account.
>
> Revised shape: **healthy → abrupt loss of the CPU-mediated path → a degraded phase of unknown
> length → a hard stop by 19:36 → recovery at 19:45.**
>
> **Combined bracket, after reconciling with ops (2026-08-10).** Their record made the mirror
> error from the other side: a "~98 s" LAN-death bracket derived from *our last received syslog
> line plus a missed heartbeat* — and syslog rides the LAN it was being used to time, so it
> timed **delivery**, not the LAN. They retracted it. Their `tcpdump` ARP capture survives and is
> direct evidence, but it establishes a hard stop **by 19:36**, not **from 19:20**:
>
> ```
> 19:18:45          last line we receive        <- delivery stops; LAN state UNKNOWN
> 19:20:23 → 19:36  NO DIRECT EVIDENCE (~16 min) <- operator: wedged but unstable, not dead
> 19:36 → 19:42     ARP capture: gateway dead, switch forwarding  <- measured hard stop
> 19:37 → 19:44     switch counters: port 5 zero rx               <- measured hard stop
> 19:45:22          power cycle
> ```
>
> **Both sides summarised their observed tail as though it described the whole event** — this
> document with "every minute of the wedge", ops with a 98-second bracket. Two independent
> sources, the same blind spot, the same direction of overclaim. Their hole ends at 19:36; ours
> begins at 19:37. Neither instrumented the middle.
>
> This also weakens the *deadlock* inference below. "Idle CPU + complete stop" reads cleanly as a
> wait that never returns; "idle CPU + intermittent service" does not, and an intermittent fault
> fits neither deadlock nor livelock cleanly. The mechanism should be treated as **less settled
> than the retraction of the livelock reading made it sound.**

**Zero interface events preceded it.** A query of 19:00–19:19Z for
`netifd|pppd|padt|auth|eth4|eth5|carrier|link up/down|br-lan: port|interface down` returned **five
matches, none of them an event** — four odi-health lines merely *reporting* state, one connlimit
warn. No netifd, no PADT, no AUTH, no link transition, no bridge port state change. The LAN died
without the stack emitting a single interface event.

---

## 4. The decisive evidence — packet capture during the outage

`tcpdump -e arp` on a wired host's bridge, mid-outage:

```
16:36:24  .200 > ff:ff:ff:ff:ff:ff   who-has 192.168.10.1  tell 192.168.10.200   (no reply)
16:36:27  .72  > ff:ff:ff:ff:ff:ff   who-has 192.168.10.1  tell 192.168.10.72    (no reply)
16:36:28  .11  > e6:35:…             who-has 192.168.10.200 tell 192.168.10.11
16:36:28  e6:35:… > .11              Reply  192.168.10.200 is-at e6:35:…         ← ANSWERED
16:36:28  .11  > e6:35:…             who-has 192.168.10.241 tell 192.168.10.11
16:36:28  e6:35:… > .11              Reply  192.168.10.241 is-at e6:35:…         ← ANSWERED
```

Three independent wired hosts broadcast for `.1` → **zero replies, ever**. In the same capture
window, broadcasts for `.200` and for the `.240`/`.241` VIPs were **flooded and answered normally**.

**The switch ASIC was provably still flooding broadcast and forwarding unicast between wired
ports. Only route10's own IP stack stopped answering for its own address.**

A second observation constrains it further: a WiFi client stayed associated and kept passing
**unicast** over already-learned MAC paths (its ICMP to `.200` was answered), but a forced
**broadcast** ARP never appeared on the wired segment at all, while a wired host's did in the same
window. Broadcast/flood between the WiFi and wired domains is **CPU-mediated**; unicast over
learned ASIC paths is not. That is why WiFi clients were more isolated than wired ones.

---

## 5. Root cause

**route10's kernel network stack — the CPU-mediated datapath — wedged.** One fault took
`br-lan`'s IP stack, the eth4 management MACVLAN and the PPPoE session together, left the switch
ASIC forwarding, and left userspace scheduling normally. It did not clear itself in 27 minutes and
required a power cycle.

What the box's own flight data says about the mechanism: **the box was idle, not spinning.**
Alta's `rcstats` daemon keeps per-minute min/avg/max samples in `/a/stats.sql`, and the wedge
window was preserved from it before the rolling 60-minute window aged out:

| | inside the wedge (19:37–19:44 UTC) | after recovery (19:45–20:52) |
|---|---|---|
| load | avg **0.031**, peak **0.188** | avg 0.018, peak **0.500** |
| temp | avg 57.4 °C, range 55.6–62.1 | avg 56.6 °C, range 54.7–63.7 |

Load through the outage was indistinguishable from idle — it peaked *higher* after recovery than
during it — and the temperature bands overlap completely. **An earlier draft of this document
claimed the opposite** ("`tz_max` rose 58.9 → 60.2 °C at zero traffic; an idle box cools, so
something was spinning ⇒ livelock"). That single-sensor step sits well inside the 54.7–63.7 °C
band the same sensor wandered through the following idle hour: it was noise, read as signal. The
retraction sharpens the finding rather than weakening it — an idle CPU with a dead network stack
is a **deadlock / stuck state, a wait that never returns — not a livelock** — which also fits
pstore's silence and the absence of any RCU-stall report.

The same source adds one hard datum route10's own logs never carried: **switch port 5 (eth4)
counted zero received bytes while the box kept transmitting 51–56 KB/min out of it.**

⚠ **Scope of that datum, corrected 2026-08-10.** It was written as "for every minute of the
wedge". It is not: the archive's earliest row is **19:37:00**, so it covers **19:37–19:44 — eight
minutes, the tail** — against a wedge that began at 19:18:45. Verified directly:

```
19:37  port5 {tx:53848}                 <- no rx key at all
19:44  port5 {tx:53669}                 <- 8 consecutive minutes, zero rx
19:45  port5 {tx:881427, rx:167636}     <- recovery
       ports 1 and 4: rx AND tx every minute throughout
```

"Every minute of the wedge" silently upgraded *every minute we have data for* into *every minute*.
The missing 18 minutes are where the operator reports unstable-but-working internet, so the
overclaim erased precisely the interval that disagrees with it. At the ASIC counter this cannot discriminate "host ingress path dead"
from "stick stopped transmitting" — but a stick-only fault is already excluded by the LAN evidence,
so it reads as the WAN-side face of the same one-sided stop. Ports 1 and 4 (LAN) passed traffic in
**both** directions every minute throughout — the ASIC-keeps-forwarding conclusion confirmed a
second time, from the box's own counters, independent of the packet capture.

The specific kernel fault is **not identified**. The QCA NSS/PPE datapath driver is the leading
candidate on shape alone (it owns exactly the CPU-path plumbing that failed while the ASIC it
programs kept running), but there is **no direct evidence**.

Why no evidence — and one correction to an earlier draft of this document:

- **`pstore` is empty, and that is a FINDING, not a gap.** It is ramoops-backed and functional
  (`pstore: Registered ramoops as persistent store backend`, `0x40000@0x41000000`, deflate
  compression) and it *does* survive reboot. Empty therefore means **no kernel panic and no oops
  occurred** — positive evidence for a livelock/wedge over a crash. An earlier draft listed it as
  a missing capability; that was wrong.
- **This kernel has no soft-lockup or hung-task detector.** `/proc/sys/kernel/` exposes only
  `panic`, `panic_on_oops`, `panic_on_rcu_stall`, `panic_on_warn`, `panic_print` — no `watchdog`,
  no `soft_watchdog`, no `hung_task_*`. **A CPU spinning in kernel space produces no message at
  all**, so even a perfectly preserved kernel ring would have been silent about it. RCU-stall
  detection *is* compiled in, so that class would have been reported and was not.
- The **kernel ring is volatile** (~36 KB) and was destroyed by the recovery reboot — a real gap,
  and the one of these three that is fixable.
- **`route-swd` keeps no persistent log**, and it is Alta's production switch daemon — capturing
  its stderr would mean restarting the process that runs the switch. Accepted, not fixed.

The practical consequence is narrower than an earlier draft stated: the spin question **was**
answered — by Alta's per-minute `rcstats` sampling, which showed idle (§5 table) — but nothing on
the box can say *what* the stack was blocked on. The mechanism is bounded (deadlock-class, not
spin, not crash), not identified. What nearly lost the evidence was retention, not sampling:
the `minutes` window is ~60 minutes and survived only as a hand-taken copy. Addressed in §8.

### Ruled out

| Hypothesis | Why it's dead |
|---|---|
| **ODI stick wedge** (the original call in this document) | A stick fault cannot stop `br-lan` answering ARP — the stick is not on the LAN. It explains the WAN and mgmt symptoms only because **both those probes leave via eth4**. It was a symptom, named as a cause. |
| **Power loss / crash / reboot** | odi-health logged to `/cfg` every 5 min throughout; SCM reset reason is `Power on Reset [0x20]`, i.e. the operator's unplug, not a watchdog. |
| **Office fibre (eth5) optical** | `L4_rx_dBm` held −15.7 with zero CRC growth — **but note this alone proves nothing** (§7). It is excluded by the packet capture: the wired segment was still being flooded and answered. |
| **Switch ASIC failure** | Directly refuted by the capture — it was forwarding and flooding correctly. |
| **Memory pressure / OOM** | 705 MB free of 1 GB; `/` tmpfs 21%; no OOM in dmesg. |
| **`route-defaultroute-hook.sh`** | Runs `* * * * *` and touches WAN state, but only ever calls `ip route replace default`. Cannot affect `br-lan`. |
| **Loki ingest artifact** (would have invalidated the whole timeline) | Ruled out three ways, decisively by **route10's own monotonic `checks=` counter**: 268 heartbeats in 24 h, every consecutive delta exactly 7, one anomaly = the reboot reset. Nothing was dropped. |

### Unproven contributing factor

A LAN host was driving a BitTorrent swarm before and after the outage (`RT10_CONNLIMIT` firing on
6881/51413). High concurrent-flow load is a plausible stressor for the offload path, but **nothing
links it to the fault** and it should not be presented as a cause.

---

## 6. Why nothing alerted

- `wan3_up=false`, `ping_fail` and `W2_mgmt_path_down` were emitted **every cycle for 24 minutes**
  at `info` — the same severity as a healthy line — so nothing downstream could distinguish them.
  Fixed in this change (§8).
- It would not have mattered on the night: **the alert path is syslog over the LAN**, and the LAN
  was the casualty. See §7.

---

## 7. The systemic findings

**(a) Telemetry cannot survive the failure it needs to report.** Syslog forwards
fire-and-forget UDP over the LAN to `.242:514` — no buffering, no retry, no store-and-forward. The
27 minutes of local evidence were written to `/cfg` and **dropped at source**. `/var/log/messages`
is a 64 KiB volatile ring destroyed by the recovery reboot. At the moment the box had most to say,
it could neither send nor remember.

The one thing that *did* survive is what made this RCA possible: **odi-health's persistent `/cfg`
log**. It is the control that proved the box never died — and it disproved the ops side's initial
"power loss or CPU hang" reading, which rested on syslog silence. Both sides independently made
the same error today: **treating the silence of a channel as evidence about the health of its
source, when the silence was the symptom.**

**(b) Optical power is not link state.** `L4_rx_dBm` is an i2c read of the module; it reports
**light**, not link, and reads normally across a port that is down or wedged. This document's first
draft used it to "exonerate the fibre" — unsupported. Carrier/operstate are the load-bearing
fields, and odi-health records them for **eth4 only**; `eth5` and `br-lan` are not instrumented at
all. That gap is why the LAN failure could not be explained from route10's own logs.

**(c) There is no out-of-band access, and an ACL change would not have created one.** Mid-outage
route10 was `online=False` on the mesh (19:36:24Z → 19:50:01Z). A mesh `:22` grant would **not**
have helped: tailscaled needs the WAN, which had died. **Every remote path shares the WAN.** A
lifeline that survives this class of fault must not depend on it — a physically separate path, not
a policy change.

---

## 8. Actions

**Done in this change:**

- `scripts/odi-health.sh` — escalate WAN/stick signals to `warn` so they are alertable:
  `wan3_up != true` warns every cycle (continuous signal a rule can fire on, and it shows outage
  duration); `W2_mgmt_path_down` warns on transition only. The wan3 message distinguishes
  session-layer failure from a link drop via `carrier`. Deliberately **states observation, not
  cause** — both probes leave via eth4, so the pair is equally consistent with stick-side and
  host-side faults.
- `scripts/stats-archive.sh` — **flight recorder**. Alta's `rcstats` already samples this box
  per-minute (load/mem/temp min-avg-max, per-port and per-client counters) into `/a/stats.sql`;
  it is the data that settled §5, and its `minutes` table is a rolling ~60-min window. The
  archiver copies it every 30 min into `/a/obs/stats-archive.sql` (persistent 3.1 G partition,
  60-day minute retention ≈ 175 MB) so the next incident's evidence doesn't depend on a human
  taking a copy within the hour. `*/30` cron, reinstalled by post-cfg.
- `scripts/obs-collect.sh` — **per-minute collector for the CPU-mediated side** rcstats can't
  see: CPU/softirq + `softnet_stat` counters, br-lan/pppoe-wan3/tailscale0 interface counters,
  eth4/eth5 carrier, br-lan address presence, conntrack, optical DDM → `/a/obs/rt.sql` (90-day
  retention). Also closes two §5 gaps directly: a **persistent kernel-ring drain** to
  `/a/obs/kernel-ring.log` (the ring the recovery reboot destroyed), and a **pstore harvest**
  that logs at `error` severity if a crash record ever appears — making a future panic
  alertable through the existing ops-side rule. A repeat of this incident now leaves a
  minute-resolution record of exactly the counters this RCA had to reconstruct or do without.

**Recommended, not done here:**

1. **Instrument `eth5` and `br-lan`** (carrier, operstate, address presence). Not in odi-health —
   that script owns the ODI/GPON/WAN path and LAN link state is not its job. A first cut
   (`lan-health.sh`) was built and then deliberately reverted: 5-min cron sampling structurally
   cannot see a ~98 s onset, and Alta's own per-minute sampling already covers most of it. The
   redesign builds on `stats.sql` instead of adding parallel collectors.
2. **Metrics, not just logs.** Expose what the box already knows — the latest `stats.sql` minute
   (load/mem/temp/ports), live optical DDM, carrier/wan3 state — as a Prometheus endpoint, rather
   than re-sampling anything. Prometheus/Grafana are ops-side ⇒ **contract-first**; a scrape is
   also pull-over-LAN, so it dies with the LAN — it buys trending and slow-degradation alerting,
   never outage telemetry. The unconditional `/cfg` + `/a` records are the complement.
3. **A lifeline independent of the WAN** (§7c).
4. **Alert rules on `route10.*` at `warning`+.** Emitted errors are safe to alert on; silence is
   not health.

**Watch item:** office fibre Rx **−15.69 dBm**, 0.31 dB from the −16.0 low-warning threshold and
~1 dB down from the −14.69 measured after the 2026-08-07 reseat. Not implicated here, but trending
the wrong way. `L4_temp_C` runs **69.4–70.3 °C**, at/above the usual 70 °C commercial SFP limit.
