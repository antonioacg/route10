# Post-mortem — 2026-08-18/19 ODI stick management-plane collapse (data plane never moved)

**Status:** trigger **established with a clean correlation**; mechanism **narrowed to two
variants of one cause**, with the discriminating measurement identified but **not yet taken** —
it needs a live stick. Recovery required physically power-cycling the module. Three separate
telemetry defects were found *during* the incident, two of which made our own instruments
report health that did not exist.

**One-line:** The stick's userspace collapsed top-down — daemons stopped serving, then TCP
accept, then ICMP, leaving only ARP — while GPON forwarding, PPP and the WAN ran normally
throughout. Onset was in the minute after an OMCI drain, twice, and the drain reads a file whose
size grows with stick uptime and had reached **10,014,726 B**.

Sibling incidents: [`2026-08-08-ipstack-wedge-lan-outage.md`](2026-08-08-ipstack-wedge-lan-outage.md)
(same *shape* on route10 itself: IP stack dark, hardware forwarding on — different box, no
established relationship).

---

## 1. Impact

- **Internet: unaffected.** PPP up on 100.68.228.244 for the whole event, 1.1.1.1 at 10.3 ms
  0% loss, eth4 carrier up with counters advancing. No user-visible outage.
- **PON/OMCI telemetry: dead** from 22:58Z (last real sample) — the fibre-degradation early
  warning, the upstream-loss measurement and the OMCI write-verb pager were all blind.
- **Alerting integrity: compromised for 22 minutes** (00:31Z–00:53Z), see §5 — ops's staleness
  alert cleared itself on a dark stick, and their `onu_state != 5` rule paged critical on the
  hollow data.
- **Recovery: physical.** No software lever survived, including the documented reboot.

## 2. Timeline (UTC)

| Time | Event |
|---|---|
| 22:58 | Last real PON sample. Successful OMCI drain-and-truncate (86 lines, 12,231 B row) |
| ~22:59 | **First wedge.** CLI stops issuing a banner |
| 23:00:11 | Boa begins failing (W2 DDM daemon, 5 s cadence — first trouble line of the day) |
| 23:00:35 | pon-collect: `stick CLI wedged, auto-unwedge did not recover` |
| 23:00–23:30 | Six auto-unwedge attempts, all ineffective (their own bug — §6.1) |
| 23:30 | Manual kill of the orphan holders (`/bin/sh` 529, `/bin/login` 3972/1122) → **CLI recovers**, PON resumes |
| 23:43 | Successful drain-and-truncate again (86 lines); `OMCI logger RECOVERED` |
| 23:45:03 | Boa starts failing again |
| 23:45:32 | **Second wedge.** This one never recovers |
| 23:45–00:20 | Boa flaps (down 3 min, up 2 min, down 5 min, up briefly at 23:55:14), then stops entirely |
| 00:22–00:27 | **Five minutes of total management silence** (DDM daemon paused, collector lock held): no recovery — it got *worse* |
| ~00:27 | TCP connect starts timing out (was completing in 0.7 ms) |
| ~00:31 | ICMP stops. Only ARP still answers (0.6 ms). Collector begins writing hollow rows (§5) |
| 00:53 | Fail-closed fix deployed; hollow rows stop, wedge latches honestly |

## 3. What is established

1. **Userspace collapsed top-down, the kernel did not.** In order: daemons stopped serving →
   TCP accept stopped → ICMP stopped → ARP still replies at 0.6 ms. Measured, not inferred:
   `connect=0.001357` with zero bytes received proved the handshake completing while nothing
   answered; `arping` returned 3/3 unicast replies after ICMP had gone to 100% loss.
2. **It was not a crash and not a CPU hang.** `omci_app` kept answering the OLT for the whole
   event — the OLT would have deactivated the ONU within minutes otherwise, and the WAN never
   dropped. An already-resident process kept running while everything needing new resources died.
3. **The trigger correlates with the OMCI drain, three for three.** Both wedges began in the
   minute after a successful drain-and-truncate; 2026-08-12's wedge was a timeout on the
   OMCI-*size* command. Those are the only cycles that touch the log file.
4. **It was not caused by our probing, and not by the deploy.** The W2 DDM daemon is an
   independent 5-second Boa probe with days of history: **zero** trouble lines on 2026-08-17 and
   none on 2026-08-18 before 23:00:11 — the same minute as the first wedge. Boa dying and the
   CLI wedging are one event. Five minutes of total silence made it worse, not better.
5. **The file the drain reads grows with stick uptime.** Apparent size 10,014,726 B at 7.4 days,
   ≈1.2 MB/day, matching the 12,231 B captured per 15-minute OLT burst. It is read **in full**
   every cycle by `cat /var/tmp/omcilog.par | nc`.

## 4. Mechanism — one cause, two variants

`/var` on the stick is **ramfs**, whose pages have no backing store and are **never reclaimed**.
The drain reads the whole apparent size of a file that grows daily. Either:

- **(a) The bytes are real.** `omci_app` writes NUL padding, so the file genuinely occupies
  ~10 MB of unreclaimable RAM continuously, and our truncate is the only thing that ever frees
  it; or
- **(b) The bytes are a hole.** Reading a hole in ramfs does not return a shared zero page —
  `simple_readpage` allocates one, fills it and leaves it in the page cache — so the drain
  *materialises* the full apparent size as permanent RAM at read time.

Both make the drain the trigger, both scale with stick uptime, and **both are fixed by never
reading the whole file.** The prior record (2026-08-12) cleared `nc` for this job by measuring
the hole as a **transfer cost** — 2.5 MB in 1.8 s — and that conclusion outlived its evidence:
it never measured memory, and the file has since grown 4×.

**Discriminating measurement, not yet taken (needs a live stick):** `ls -ls` on the log — allocated
blocks versus apparent size — plus `df /var` and `/proc/meminfo` sampled immediately before and
after one drain. That separates (a) from (b) and confirms or refutes the whole model.

## 5. The instruments lied, in three different ways

Found *during* the incident, all fixed:

1. **A dead stick produced fresh, hollow samples** (`e9fdd6a`). The wedge gate enumerated the
   failure strings we had seen — `WEDGED:`, `ERR:`, empty. When the stick stopped answering TCP
   entirely, the tool began returning `FATAL: timeout: timed out`, which matched none of them.
   The collector then parsed absence into a complete row of NULLs once a minute:
   `route10_pon_sample_timestamp_seconds` advanced normally while every value served NaN, ops's
   `Route10PonStale` **cleared itself on a dark stick**, and this log recorded a false
   `stick CLI recovered`. *The sicker the stick got, the healthier its telemetry looked.*
   Fixed by demanding positive proof of a live session (`/proc/uptime` parsed as two floats)
   instead of listing ways it can fail.
2. **Absence read as inequality** (`128f926`). Those NULL rows diffed against real state and
   raised firmware-bank and TR-069 advisories about changes nobody made. Ops hit the mirror
   image from the other end the same night: `<`, `>`, `==` fail silent on NaN, but `!=` compares
   unequal to everything and **fires**, so their `onu_state != 5` rule paged critical. Swept
   every change-detector on this side; `lan-prefix-track` — the one that can cause a real outage
   — was already fail-closed.
3. **A false `OMCI logger DEAD`** (`db6660e`). The ram-guard truncate discards the log unread;
   the next cycle then saw an empty drain (because we emptied it) and an advanced counter
   (because the delta spanned the outage) and latched "the recorder is dead". Deterministic on
   every wedge long enough to fill the log.

## 6. Why the self-heal could not save it

1. **The unwedge was blind, not outmatched** (`0ec0046`). It read the stick's process table
   through a Boa injection whose output lands *after* Boa's own 5-second ping, using a fixed
   `sleep 5`. Under contention the page still said `ping wait`, the parse found zero processes,
   and "no table" was indistinguishable from "no orphans" — so it took the do-nothing branch
   against a wedge held by live processes, six times. The manual kill of exactly those processes
   recovered it in one cycle.
2. **Every lever runs through the daemon that dies.** `stick-unwedge` injects through Boa. So
   does the documented reboot (`formReboot`). There is no sshd on this stick and none can be
   added. When Boa goes, so does recovery.
3. **There is no hardware lever.** Checked and ruled out: the SFP cage has no power-enable line
   (gpio490/491 are the LED enable — `black`'s neighbouring strings are `linkLeds`/`leds`;
   469–478 are the two cages' MOD_ABS/RX_LOS/TX_FAULT plus TX_DISABLE, which kills a laser, not
   a CPU). SFP cages are permanently powered by design.

## 7. Actions

- [x] Unwedge reads the process table with a control (`0ec0046`)
- [x] Wedge gate fails closed on proof, not on a failure list (`e9fdd6a`)
- [x] Change-detectors require both sides present (`128f926`)
- [x] Ram-guard truncate no longer manufactures a dead-logger latch (`db6660e`)
- [ ] **Stop reading the hole** — replace the whole-file `cat` with a tail-bounded read sized
      from the delta in apparent size since the previous cycle (both numbers are already read
      every minute and discarded). `tail -c` seeks, so cost becomes proportional to *new* log
      text — ~12 KB per burst — instead of stick uptime. This is the fix that stops recurrence
- [ ] **Take the discriminating measurement** (§4) on the next live stick, before assuming the
      model is right
- [ ] **Record what we already read and throw away**: the OMCI log size every cycle, plus a
      cheap `/proc/meminfo` and `df /var` in the *existing* session — no extra CLI session, so
      no added wedge risk. This is the curve that would have shown this coming

## 8. Open questions

- Which variant, (a) or (b) — §4 has the measurement.
- Why the *first* wedge left recoverable orphans while the second went all the way to a dark IP
  stack. Same trigger, different depth, and we have no stick-side resource data for either.
- Whether the module's watchdog is armed at all: ~1 h of dead userspace produced no reset.
