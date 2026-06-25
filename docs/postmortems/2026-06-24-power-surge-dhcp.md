# Post-mortem — 2026-06-24 power-surge LAN outage (Route10 DHCP failure)

**Status:** service restored; **dnsmasq-mute fix implemented** (`scripts/post-cfg.sh`, see the
fix commit/PR); the exact mute mechanism is **not yet confirmed on-demand** (§6 repro was
confounded); network **not fully re-converged** at write time (some devices on stale leases, §8).

**One-line:** A mains power surge rebooted Route10 (both UPSs failed). On the way back
up, Route10's `dnsmasq` came up **listening but mute on DHCP** — it answered *zero*
requests until manually restarted. Every LAN device lost its lease; a TP-Link AP's
"DHCP=Auto" failsafe then self-enabled and handed out dead-end `192.168.0.x` leases.
The WAN/ISP path was healthy throughout.

---

## 1. Topology (as built, 2026-06-24)

### Power domains — BOTH failed in this event
```
            ┌──────────────────────── MAINS (surge ~19:40) ────────────────────────┐
            │                                                                       │
   ┌────────┴─────────┐  UPS-A "usually holds"          ┌──────────┴──────────┐  UPS-B (cheaper)
   │  LIVING ROOM     │  → did NOT hold this time       │  OFFICE             │  → did NOT hold,
   │  • Route10       │  (Route10 rebooted at surge)    │  • this Mac (laptop)│    PDU came back OFF
   │  • TP-Link AP    │                                 │  • office switch    │  → office dark ~1.5h
   │  • Living devices│                                 │  • eth5 fiber far-end│    longer than Route10
   └──────────────────┘                                 └─────────────────────┘
```

### Network path
```
  ISP OLT ══fiber══ ODI DFP-34X stick (Route10 W2 cage, eth4) ── PPPoE wan3 ─┐
  (Huawei ONT on eth3/wan = manual backup)                                    │
                                                                              ▼
  ┌─────────────────────────── Route10 (Alta IPQ9574, Living Room) ──────────────────────┐
  │  WAN: eth4 = ODI stick (primary)   eth3 = Huawei (backup)                             │
  │  br-lan = { eth1(down) , eth2 (1G copper, clean spare) , eth5 (10G fiber UPLINK) }    │
  │  LAN 192.168.10.0/24   gateway+DNS handed by DHCP = 192.168.10.1 (dnsmasq)            │
  │  DHCP pool .10–.252 (86400s)   leasefile = /cfg/dhcp.leases (persistent ext4)         │
  └───────┬──────────────────────────────────────────────────┬──────────────────────────┘
          │ eth2 (1G, Living Room LAN)                        │ eth5 (10G FIBER, marginal -16.3 dBm)
          ▼                                                   ▼
   TP-Link AP  ◄── AP/bridge mode, L2 only.            Office switch
   DHCP = "AUTO"  ⚠ LANDMINE (see §4)                        │ en13 (USB 2.5G)
   mgmt 192.168.0.254 when failsafe DHCP on                  ▼
                                                          this Mac
  opi5pro (single-node k8s, 192.168.10.200):
     MetalLB VIPs → .240 ingress-nginx , .241 AdGuard (LAN DNS)
     ⚠ Many devices MANUALLY point DNS at .241 (AdGuard), not at Route10 .1
     (100% ICMP loss to a MetalLB VIP is NORMAL — it just doesn't answer ping)
```

Key facts that bite during incidents:
- **eth5 (10G fiber) is the single LAN uplink** carrying every client→gateway flow. It is
  also the marginal `-16.3 dBm` dirty-connector link from the 2026-06-xx CRC incident.
- **TP-Link is in the Living Room, on Route10's L2 LAN** (not the office), AP/bridge mode.
- **Two independent power domains**; the office holds one end of the critical fiber AND
  is on the weaker UPS — backwards from where protection should be.

---

## 2. Timeline (data-backed from persistent logs)

All times BRT, 2026-06-24. Evidence = `/cfg/scripts/flap-hunt.log` (5-min heartbeat with
`pppup`=PPP uptime), `/cfg/scripts/odi-health.log` (writes a `=== restarted ===` marker per
boot, stamped `2021-10-24 06:01:5x` = the pre-NTP boot clock), and `dmesg`.

| Time | Event | Evidence |
|---|---|---|
| before 19:40 | Route10 up **45.4 h** continuous, healthy | `pppup=163401` climbing, continuous heartbeats |
| **~19:40** | **SURGE — Route10 loses power (UPS-A did NOT hold)** | heartbeat GAP `19:39:58→19:46:49` (411 s); `pppup 163401→19` |
| ~19:46–19:50 | **Reboot #1.** dnsmasq comes up **MUTE**. PPP reconnects. | boot marker → first real line `19:50:54` |
| ~19:4x | TP-Link AP (fast boot) sees no upstream DHCP → **DHCP-Auto self-enables** → serves `192.168.0.x` | rogue lease observed; AP never left AP mode |
| (parallel) | ISP SMS: known upstream issue, being worked | user report |
| **~20:04–20:07** | **Reboot #2 — user's remote reboot. "Nothing changed"** (dnsmasq still mute) | `pppup 921→13`; boot marker → `20:07:53` |
| ~21:26–21:34 | **eth5 (office fiber) finally links** (+~87 min into boot) = office power restored / PDU switched back on | `dmesg [5212s] eth5 PHY Link up 10000`, `carrier_changes=1` |
| ~21:3x→ | Office switch + Mac reconnect over fiber; Mac pulls a **rogue `192.168.0.246`** lease (dnsmasq still mute) | `ipconfig getpacket en13` → server `192.168.0.254` |
| this session | Diagnosis: WAN 0% loss; DNS ruled out; tcpdump on br-lan = **requests arrive, ZERO replies** | `tcpdump -i br-lan port 67/68` |
| | User disables TP-Link DHCP → Mac STILL `169.254` (no lease) → proves **dnsmasq**, not the rogue | |
| | **`/etc/init.d/dnsmasq restart`** → instantly serves; Mac gets `192.168.10.10`, internet 0% loss | |

**Two reboots, both today** — the first (~19:40) was the surge (UPS did not hold), the
second (~20:04) was the user's remote reboot. This corrects an earlier assumption that
Route10's UPS held.

---

## 3. Root cause

- **Trigger:** mains surge → **both UPSs failed** → Route10 rebooted.
- **Primary fault:** after the surge-reboot (and again after the remote reboot) Route10's
  **`dnsmasq` was up and `LISTEN`ing on udp/67 but answered no DHCP** — no OFFER, no ACK,
  no NAK. Config was valid the whole time (`dhcp-authoritative`, `bind-dynamic`,
  `interface=br-lan`, range `.10–.252`), `/cfg` writable. **A plain
  `/etc/init.d/dnsmasq restart` fixed it instantly.** Exact internal trigger = **OPEN (§6)**.
- **Amplifier (NOT independent):** the TP-Link AP's **DHCP="Auto"** enables its own DHCP
  server *only when it detects no upstream DHCP*. Because Route10's dnsmasq was mute, the AP
  correctly (from its POV) concluded "no DHCP here" and switched its failsafe on, handing out
  `192.168.0.x` with itself (`192.168.0.254`) as gateway+DNS — a dead end (it's a bridge; it
  doesn't route; its DNS answered `REFUSED`). **The rogue DHCP is a *symptom* of the dnsmasq
  failure, not a separate coincidence.**
- **Aggravator:** the office PDU **came back OFF**, so the office stayed dark ~1.5 h after
  Route10 had recovered → `eth5` had no link partner → office cut off until manually restored.

What it was **NOT**: not the ISP (WAN/PPP healthy throughout, Alta portal showed Route10
online), not AdGuard/DNS (user's `1.1.1.1` test failed too), not the USB adapter, not a
broadcast storm, not the eth5 connector this time.

---

## 4. Why "DHCP=Auto" on an AP is a landmine

Even in **AP/bridge mode**, consumer APs keep a built-in DHCP server with Off/On/**Auto**.
"Auto" = "serve DHCP if I don't see another server." That makes the AP a **latent rogue
DHCP server that arms itself exactly when your real DHCP is down** — i.e. at the worst
possible moment, turning a recoverable gateway hiccup into a wrong-subnet, dead-gateway
outage for every device. **Fix: set it to OFF explicitly. AP mode alone does not disable it.**

---

## 5. A rogue DHCP server cannot "break" a real one (for the record)

DHCP has no server↔server messaging. A rogue only wins OFFER races for *clients*; the
legitimate server never reads its packets and is never poked, malformed, or overloaded.
Removing the rogue + renewing fully reverses its effect. So the rogue did **not** damage
Route10 — Route10's dnsmasq failed on its own (§3, §6).

---

## 6. OPEN QUESTION — why does dnsmasq come up mute after an unclean reboot?

Not 100% proven, but the mechanism below is consistent with every observation. It happened
on **both** boots and persisted across the remote reboot → **systematic to this boot path**,
not random. dnsmasq uses `bind-dynamic` (which *should* follow interface changes), yet it
still went mute — so it is not simple `bind-interfaces` staleness.

### Leading mechanism (post-incident dig)

**post-cfg.sh bounces `br-lan` TWICE on every boot**, while dnsmasq is already running:
- The eth4-MAC block → `/etc/init.d/network reload` (fires because the cloud reapply wipes
  the eth4 MAC override, so post-cfg re-sets it → **full** network reload, includes br-lan).
- The ip6class block → `ifup lan` (fires because the cloud re-pins `network.lan.ip6class`,
  so post-cfg deletes it → **bounces br-lan** to re-pull the IPv6 PD). This is the recent
  `ip6class` fix — i.e. **a likely regression**: it added a per-boot br-lan bounce. Both
  confirmed to have fired this boot (`ip6class` empty; eth4 macaddr override present).

**dnsmasq's recovery from that bounce is weak:**
- Its init `reload_service()` only does `procd_send_signal dnsmasq` = **SIGHUP** (init line
  1278), not a restart. SIGHUP re-reads config/hosts but does not reliably re-bind the DHCP
  listener if br-lan was down/transitioning when the signal landed.
- The **live service has `triggers: null`** (`ubus call service list`) — the procd
  interface/reload triggers aren't registered, so a br-lan reconfig may not reload dnsmasq at
  all. Either way (no trigger, or SIGHUP-mid-bounce), dnsmasq keeps a **stale binding → mute
  on the new br-lan**. A **full restart** re-inits cleanly — which is exactly what fixed it.

**Why this boot and not every boot:** a timing race. The messy surge boot (slow, eth5 joining
br-lan ~87 min late, multiple netifd reloads) widened the window where dnsmasq got
signalled/bounced into the stale state and stayed there. On clean boots the timing usually
lands fine — but it is latent on *every* boot.

### Reproduction attempt 2026-06-24 — CONFOUNDED, but informative

Ran `ifup lan` on Route10 (exactly what post-cfg.sh does), then probed DHCP from a client,
inside a self-healing harness (dnsmasq restart at the end + a 100 s watchdog) so the LAN
always recovered.

**Could NOT cleanly confirm the dnsmasq-mute** — the test is confounded on this NSS-offloaded
hardware:
- **`ifup lan` itself severs client→br-lan forwarding for ~85 s.** Reproduced twice: in both
  runs the Route10-side `tcpdump -i br-lan` saw **zero** DHCP packets from any client during
  the window (`requests=0 replies=0`). So the bounce drops the client's path, and a request
  never reached dnsmasq for me to observe whether it would reply.
- My only test client (this Mac) sits **behind the eth5 uplink** — exactly the port the bounce
  disrupts.
- The clean isolation tool — a local **veth** client on br-lan — **isn't supported on this
  kernel** (`RTNETLINK: Not supported`). A macvlan won't work either (dnsmasq serves only
  `interface=br-lan`, not a child interface).

**But the original incident still points to a broad dnsmasq-mute, by inference:**
- It lasted **minutes-to-hours**, far longer than the ~85 s forwarding blip.
- It was cleared **only by a dnsmasq restart**.
- The TP-Link's DHCP-Auto failsafe fired — and the TP-Link is on **eth2**, a *different*
  bridge port than eth5. If only eth5 forwarding had broken, the eth2-side TP-Link would still
  have seen Route10's DHCP and stayed quiet. It going rogue means DHCP was unavailable
  **network-wide** → dnsmasq was mute, not just an eth5 forwarding glitch.

**Net:** the repro surfaced a SECOND, distinct problem — **`ifup lan` is itself LAN-disruptive
(~85 s) on this hardware, on every boot** — and reinforced that the original outage was a broad
dnsmasq-mute. A direct, isolated confirmation needs either a real recurrence (with Syslog→Loki
capturing it) or a raw-socket DHCP probe injected locally on br-lan.

### THE FIX — implemented

`scripts/post-cfg.sh` now runs `/etc/init.d/dnsmasq restart` at the end **only when it actually
churned the LAN** (the eth4-MAC `network reload` or the ip6class `ifup lan` fired), after a
short settle. This guarantees dnsmasq ends each boot cleanly bound to the final br-lan — it
would have prevented the entire outage. (Deployment to `/cfg/post-cfg.sh` on Route10 is a
separate step.) Follow-ups, in priority:
- **Make the ip6class refresh less disruptive** than a full `ifup lan` (it's an ~85 s LAN
  outage every boot).
- **DHCP self-test watchdog** (§7) — defense-in-depth for any *other* mute cause.
- **Alta Syslog Host → Loki** (§7) — so the next event has real data (the volatile-`logread`
  blind spot is why this stays "not 100% proven").

---

## 7. Action items

| # | Action | Why | Status |
|---|---|---|---|
| 0 | **post-cfg.sh: `dnsmasq restart` after LAN churn** | Directly prevents the mute (§6) | ✅ committed (fix PR); **deploy to `/cfg` pending** |
| 1 | **Route10 + Living Room gear on a proven surge-rated UPS** | Gateway dropped from a 45 h run; it's the one box that must never lose power | TODO |
| 2 | **Office PDU → "last state = ON"**; office gear on real UPS | It came back OFF → 1.5 h extra outage needing a human | TODO |
| 3 | **DHCP self-test watchdog** (fits flap-hunt/odi-health daemon pattern): periodically DHCP-probe br-lan; if no OFFER, `/etc/init.d/dnsmasq restart` | Defense-in-depth for any *other* mute cause | TODO (next) |
| 4 | **TP-Link DHCP = OFF** (not Auto), stays AP mode | Disarms the failsafe-rogue landmine (§4) | user disabled DHCP this session; **confirm it's OFF not Auto** |
| 5 | **Make the ip6class refresh non-disruptive** (avoid full `ifup lan`) | `ifup lan` = ~85 s LAN outage every boot (repro) | TODO |
| 6 | **DHCP snooping on the office/managed switch** if supported | Drops rogue DHCP server packets from untrusted ports | TODO |
| 7 | **Clean the eth5 fiber connector** (one-click/IPA), recheck Rx | Latent marginal `-16.3 dBm` link, has bitten before | TODO |
| 8 | **Alta Syslog Host → Loki** + `log-dhcp` on Route10 | So the next event is diagnosable (§6); kills the volatile-logread blind spot | TODO |

---

## 8. Restoration status — NOT fully converged (at write time)

- Route10 dnsmasq **healthy** (writing leases; `/cfg/dhcp.leases` populated).
- This Mac: back on `192.168.10.10`, internet 0% loss, DNS OK.
- **Not all devices have re-acquired** a `192.168.10.x` lease — some still held stale
  `192.168.0.x` (rogue) or expired leases. They need a renew: **toggle Wi-Fi off/on or
  replug**. Devices seen on the rogue island earlier: `70:89:76:22:bc:26`,
  `70:89:76:22:ab:df`, `84:e3:42:5b:7c:e8`, `ee:18:13:dd:ac:fc`.
- **Work Mac DNS** was manually set to `1.1.1.1` during triage — set back to Automatic (or
  `192.168.10.241` AdGuard) once it's on the right subnet.
- TODO: sweep the LAN and confirm every device is on `192.168.10.x` with internet.

---

## 9. Useful commands (incident playbook)

```sh
# Is dnsmasq mute? (requests arrive but zero replies = the failure signature)
ssh route10 'timeout 30 tcpdump -i br-lan -n -e udp port 67 or udp port 68 > /tmp/dhcpcap.txt 2>&1 &'
#   ...trigger a client DHCP, then:  ssh route10 'grep -c "\.67 >" /tmp/dhcpcap.txt'  # 0 replies = mute
# The fix:
ssh route10 '/etc/init.d/dnsmasq restart'
# Reboot history from persistent logs (gaps + pppup resets + boot markers):
ssh route10 'grep -c "2021-10-24.*restarted, interval" /cfg/scripts/odi-health.log'   # total reboots
ssh route10 'grep heartbeat /cfg/scripts/flap-hunt.log | sed -E "s/.* ([0-9:]+) .*pppup=([0-9]+).*/\1 \2/"'  # pppup resets = restarts
# Reach Route10 while LAN DHCP is dead (L2 is fine, only DHCP was broken):
sudo ifconfig <iface> inet 192.168.10.99 netmask 255.255.255.0     # delete with: ifconfig <iface> inet 192.168.10.99 delete
# Clean client DHCP renew (macOS): networksetup -setdhcp "<Hardware Port name>"
```
