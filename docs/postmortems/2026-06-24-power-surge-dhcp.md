# Post-mortem — 2026-06-24 power-surge LAN outage (Route10 DHCP failure)

**Status:** service restored; **dnsmasq-mute fix deployed** (`scripts/post-cfg.sh` → `/cfg`) plus a
**DHCP-mute watchdog deployed** (`scripts/dhcp-watchdog.sh`); the mute mechanism is **CONFIRMED**
(§6: a full `ifup lan` mutes dnsmasq's DHCP) and **fixed at the source** — post-cfg re-pulls
IPv6 via `network reload` (no mute, no restart; validated); network **re-converged** (Wi-Fi via TP-Link restart, wired/switch clients via
manual renew — §8).

**One-line:** A mains power surge rebooted Route10 (both UPSs failed). On the way back
up, Route10's `dnsmasq` came up **listening but mute on DHCP** — it answered *zero*
requests until manually restarted. Every LAN device lost its lease; a TP-Link AP's
"DHCP=Auto" failsafe then self-enabled and handed out dead-end `192.168.0.x` leases.
The WAN/ISP path was healthy throughout.

**Related:** [`2026-07-08-wan3-route-loss.md`](2026-07-08-wan3-route-loss.md) — a different
failure mode on the same box (netifd drops the default route on a PPPoE reconnect).

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
          │ eth2 (1G, Living Room LAN)                        │ eth5 (10G FIBER uplink to office)
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
- **eth5 (10G fiber) is the single LAN uplink** carrying every client→gateway flow — when it
  is down (e.g. the office end loses power), every office client is cut off from the gateway.
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
  `/etc/init.d/dnsmasq restart` fixed it instantly.** Trigger **CONFIRMED**: the per-boot
  post-cfg `ifup lan` mutes dnsmasq (§6).
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
broadcast storm, and not an eth5 fiber fault (its link was down only because the office end
lost power).

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

## 6. ROOT CAUSE — CONFIRMED: `ifup lan` mutes dnsmasq's DHCP

**Directly reproduced 2026-06-25:** a single `ifup lan` makes dnsmasq stop answering DHCP on
br-lan and stay mute **until a full restart** (5/5 probe cycles below). post-cfg.sh runs
`ifup lan` on every boot (the ip6class fix), so the surge boot left DHCP dead until — hours
later — it was restarted by hand. dnsmasq uses `bind-dynamic` (which *should* follow interface
changes) yet still goes mute, so it is not simple `bind-interfaces` staleness — see the mechanism.

### Mechanism (confirmed)

**post-cfg.sh bounces `br-lan` TWICE on every boot**, while dnsmasq is already running:
- The eth4-MAC block → `/etc/init.d/network reload` (fires because the cloud reapply wipes
  the eth4 MAC override, so post-cfg re-sets it → **full** network reload, includes br-lan).
- The ip6class block → `ifup lan` (fires because the cloud re-pins `network.lan.ip6class`,
  so post-cfg deletes it → **bounces br-lan** to re-pull the IPv6 PD). This is the recent
  `ip6class` fix — i.e. **the regression that introduced the per-boot bounce**. (Whether the
  eth4-MAC `network reload` *alone* also mutes dnsmasq is untested — it carries WAN risk; the
  fix covers both triggers regardless.)

**dnsmasq's recovery from that bounce is weak:**
- Its init `reload_service()` only does `procd_send_signal dnsmasq` = **SIGHUP** (init line
  1278), not a restart. SIGHUP re-reads config/hosts but does not reliably re-bind the DHCP
  listener if br-lan was down/transitioning when the signal landed.
- The **live service has `triggers: null`** (`ubus call service list`) — the procd
  interface/reload triggers aren't registered, so a br-lan reconfig may not reload dnsmasq at
  all. Either way (no trigger, or SIGHUP-mid-bounce), dnsmasq keeps a **stale binding → mute
  on the new br-lan**. A **full restart** re-inits cleanly — which is exactly what fixed it.

**Deterministic, not a rare race:** every `ifup lan` triggers the mute (confirmed 5/5), so it's
not boot-timing luck — any boot running the ip6class `ifup lan` mutes DHCP. The surge boot is
simply the one where nothing restarted dnsmasq afterward, and the rogue TP-Link amplified it.
(Aside: eth5 joining br-lan ~87 min late was the **office coming back on power**, NOT a boot
delay — and dnsmasq was already mute ~87 min before — so eth5's lateness is unrelated.)

### Reproduction 2026-06-25 — CONFIRMED

Earlier attempts were confounded by an unreliable test client: `ifup lan` is gentle on L2
forwarding (130/130 Mac pings, ~0.3 s blip), but cycling the Mac adapter `NONE→DHCP` left it on
`169.254` not emitting DISCOVERs — so requests never reached dnsmasq. (`ifup lan` is gentle on
*forwarding*; it is *not* gentle on dnsmasq.) A local **veth** client on br-lan is also
unsupported (`RTNETLINK: Not supported`).

The fix was a **DHCP probe injected directly on br-lan from Route10** — a UDP broadcast socket
bound to br-lan (`tools/dhcp-probe.py`), independent of any client/eth5 path:

```
baseline:          ANSWERED   (OFFER 192.168.10.25 from 192.168.10.1)
ifup-lan cycle 1:  NO_REPLY   +3s NO_REPLY
ifup-lan cycle 2:  NO_REPLY   +3s NO_REPLY
... 5/5 cycles  →  NO_REPLY   (never self-recovered)
dnsmasq restart →  ANSWERED
```

### THE FIX — two steps, both deployed

1. **PR #1 (2026-06-24):** restart dnsmasq at the end of post-cfg.sh whenever it churned the LAN
   — recovers *from* the mute. Validated, but a mute window still existed during boot.
2. **PR #4 (2026-06-25) — the clean fix:** swap the ip6class `ifup lan` for
   `/etc/init.d/network reload`, which re-pulls the IPv6 PD **without muting dnsmasq** (3/3) and
   without bouncing wan3/PPP — `ifup lan` (full interface restart) was the *only* mute trigger.
   The PR #1 restart was then no longer needed and was dropped. **Validated end-to-end:** stale
   `ip6class=wan6` → run the deployed post-cfg.sh → `ip6class` cleared, IPv6 re-pulled
   (`…9a50::1/64`), probe **ANSWERED** throughout, **dnsmasq pid unchanged** (no restart, no
   mute). DHCP no longer dies during boot at all.

Remaining defense-in-depth: the DHCP watchdog (§7 #3, could be upgraded to actively probe with
`tools/dhcp-probe.py`); observability: Syslog→Loki (§7 #7).

---

## 7. Action items

| # | Action | Why | Status |
|---|---|---|---|
| 0 | **post-cfg.sh: `dnsmasq restart` after LAN churn** | Recover *from* the mute (§6) | ✅ PR #1 deployed 2026-06-24 — then **superseded by #5** (PR #4): restart removed once `network reload` eliminated the mute at the source |
| 1 | **Route10 + Living Room gear on a proven surge-rated UPS** | Gateway dropped from a 45 h run; it's the one box that must never lose power | TODO |
| 2 | **Office PDU → "last state = ON"**; office gear on real UPS | It came back OFF → 1.5 h extra outage needing a human | TODO |
| 3 | **DHCP self-test watchdog** (`scripts/dhcp-watchdog.sh`): passively watches br-lan for the "many requests, zero replies" mute signature; `/etc/init.d/dnsmasq restart` on confirmed mute (debounced + cooldown) | Defense-in-depth for any *other* mute cause | ✅ PR #3 + **deployed & running 2026-06-24** |
| 4 | **TP-Link DHCP = OFF** (not Auto), stays AP mode | Disarms the failsafe-rogue landmine (§4) | ✅ done — set OFF (not Auto), AP mode |
| 5 | **Re-pull IPv6 via `network reload`, not `ifup lan`** | `ifup lan` mutes dnsmasq (§6, 5/5); `network reload` re-pulls the /64 without muting (3/3) and without a WAN bounce — eliminates the mute at the source (replaces #0's restart). (`renew` was gentle too but a no-op for config changes.) | ✅ **PR #4 deployed + validated 2026-06-25** — post-cfg run: IPv6 re-pulled, probe ANSWERED, dnsmasq pid unchanged |
| 6 | **DHCP snooping on the office/managed switch** if supported | Drops rogue DHCP server packets from untrusted ports | TODO |
| 7 | **Alta Syslog Host → Loki** + `log-dhcp` on Route10 | So the next event is diagnosable (§6); kills the volatile-logread blind spot | TODO (deferred) |

---

## 8. Restoration — converged

- Route10 dnsmasq **healthy** (writing leases; `/cfg/dhcp.leases` populated).
- This Mac: back on `192.168.10.10`, internet 0% loss, DNS OK.
- **Other devices came off the rogue `192.168.0.x` (2 h) leases — but the path depended on
  how each was attached:**
  - **Wi-Fi clients on the TP-Link** re-DHCP'd when it was restarted (its WLAN bounce forces a
    renew).
  - **Wired / switch clients (and other-AP Wi-Fi)** are NOT bounced by a TP-Link restart —
    they kept the stale lease until T1 (~1 h) and were fixed by a **manual adapter reset / DHCP
    renew** (done by hand; minor).
  Rogue-island MACs seen earlier: `70:89:76:22:bc:26`, `70:89:76:22:ab:df`,
  `84:e3:42:5b:7c:e8`, `ee:18:13:dd:ac:fc`.
- **Work Mac DNS** was manually set to `1.1.1.1` during triage — set back to Automatic (or
  `192.168.10.241` AdGuard).

**Recovery lesson:** restarting the rogue AP only re-converges *its own* Wi-Fi clients;
everything wired or behind the switch needs an explicit renew (or waits out the lease).

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
