# Alta mwan3 false "wan3 down" from anycast ICMP loss

*Alta's mwan3 tracks wan3 via `ping.alta.inc` → AWS CloudFront anycast (`75.2.70.75`), which gets aggressive ICMP rate-limit from this ISP path. 40% ICMP loss → 5 consecutive misses → mwan3 marks wan3 down → `flush_conntrack` kills all live TCP sessions. User perceives this as "internet dropped" while eth4/PPP never moved.*

**Captured live 2026-05-28 21:13 BRT** via `/cfg/scripts/flap-hunt.sh`.

**Mechanism:**
1. `mwan3.wan3.track_ip = 'ping.alta.inc'` → resolves to `75.2.70.75` (AWS
   CloudFront anycast) / IPv6 `2606:4700:4700::1111` (Cloudflare anycast).
2. The Brazilian ISP path rate-limits ICMP to all public anycast targets
   (1.1.1.1, 8.8.8.8 same behaviour). Loss bursts to 40–100%.
3. mwan3 polls every 5 s with 1 s timeout. After 5 consecutive failures →
   wan3 marked "disconnected".
4. `mwan3.wan3.flush_conntrack = 'ifup' 'ifdown' 'connected' 'disconnected'`
   → conntrack flushed on every false "down" → every TCP session dies.
5. mwan3 sees pings succeed again within 5–10 s, marks "online", but the
   damage is done — user's browsers/apps reconnecting from scratch.

**Why eth4/PPP show no problem during these events:**
- `carrier_changes` doesn't move (no L1 flap)
- PPP uptime keeps incrementing (no PPPoE teardown)
- eth4 byte counters keep growing (data still flowing)
- Stick optical (Tx/Rx/Temp) unchanged
- `odi-health.sh` at 5-min cadence misses the 5–15 s windows

**The destructive piece:** `flush_conntrack 'disconnected'` is what turns a
~10 s ICMP blip into a session-killing event. Without it, false alarms
would be invisible to the user.

**Some events include a real upstream blip too:** at 21:13 the live TCP
throughput dropped from 230–520 Mbit/s to ~5 Mbit/s and iperf3 control
sockets reset. So ISP-side congestion contributes — but mwan3's
NAT-flush is what makes it feel like an outage.

**Actionable fixes (require Alta dashboard, config is cloud-mastered):**

| Lever | Effect |
|---|---|
| Change `track_ip` to `168.195.103.5` (PPP gateway, always 0% loss) | Best — only marks down on real ISP-L3 fail |
| Drop `'disconnected'` from `flush_conntrack` | Existing TCP survives false alarms |
| `down: 5→10` and/or `failure_loss: 10→50%` | Tolerates ICMP bursts; doesn't fix root |

**How to apply:** when the user reports "internet dropped" but the link
looks healthy, check `/cfg/scripts/flap-hunt.log` for
`mwan_track_loss_begin` → `mwan_score_drop ... lost=5 score=0` → recovery
sequence. That signature = NAT-flush false alarm, not a real outage. Don't
reboot anything; the link is fine. Push the user toward Alta dashboard to
change `track_ip` and/or `flush_conntrack`.

**Other Route10 users have hit this** (2026-05-28 research, both never resolved):
- forum.alta.inc thread #5443 *"Route10 intermittent packet loss"* — exact match
- forum.alta.inc thread #5320 *"Route10 drops connections"* — same shape
- thread #5471 (LosSantosPro) independently confirmed `uci set mwan3.*` doesn't
  persist — Alta cloud rewrites `/etc/config/mwan3` on every boot. Matches the
  Route10 cloud-config-overwrite behaviour. So the only sustainable fix
  is a dashboard knob, not a local override.

**Alta-added vs upstream:**
- Upstream OpenWrt mwan3 default has `flush_conntrack=` (empty list).
- Alta sets `flush_conntrack=['ifup','ifdown','connected','disconnected']`.
  The 'connected'/'disconnected' entries are Alta-specific and are the
  foot-gun that turns ICMP blips into TCP-session-killing events.

**Proper-fix recipe (needs Alta dashboard):**
```
list track_ip '168.195.103.5'   # PPP gateway — anchor for L2 sanity
list track_ip '200.147.67.142'  # UOL — battle-tested BR target (Netgate forum)
list track_ip '9.9.9.9'         # Quad9 — diversified vs Cloudflare/Google
reliability '1'                  # ANY one responding = up (loose OR)
timeout '2'                      # was 1; wiki says ≥2 on slow links
down '10'                        # was 5; tolerates more ICMP jitter
failure_loss '20'                # was 10
list flush_conntrack 'ifup'      # drop 'connected' and 'disconnected'
list flush_conntrack 'ifdown'
```

**`httping` IS available** at `/usr/bin/httping` on Route10. If Alta exposes
`track_method='httping'` and `track_ip` accepts HTTP URLs, the entirely-
clean fix is httping against `http://www.gstatic.com/generate_204` or
`http://detectportal.firefox.com/success.txt` — both small, BR-peered, no
ICMP rate-limit dependency.
