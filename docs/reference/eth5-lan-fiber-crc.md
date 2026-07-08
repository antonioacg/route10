# Route10 eth5 LAN-fiber CRC mimics an ISP outage

*eth5 is Route10's 10G LAN fiber uplink; a dirty/loose fiber connector causes RX CRC errors → LAN-wide packet loss that mimics an "ISP/internet down" outage on every device.*

Route10's LAN bridge `br-lan` = `eth1` (down), `eth2` (1G copper, clean spare),
`eth5` (**10G fiber SFP+ uplink to the LAN switch**). `eth5` carries ALL
client→gateway→internet traffic.

**2026-06-15 incident:** every device (cable Mac + WiFi Work-Mac + WiFi iPhone)
lost internet simultaneously; user failed over to iPhone tether. **It was NOT
the ISP and NOT DNS.**

- WAN/PPPoE (wan3) was healthy throughout: up 3.4d, 0% loss to gw + 1.1.1.1 (v4+v6).
- AdGuard DNS at 192.168.10.241 (opi5pro k8s, MetalLB VIP — note: 100% ICMP loss
  to a MetalLB VIP is NORMAL, it just doesn't answer ping) answered fine; user's
  1.1.1.1 test also failed → ruled DNS out.
- Root cause: `eth5` had **51k+ RX CRC errors, climbing ~8% idle / 15–25% under
  load**, plus **261 carrier flaps in 3.4d**. Corrupted frames silently dropped
  → ~15–32% loss to the gateway → all clients "no internet."

**Why it localized cleanly:** ping `.200` (opi5pro, same switch as clients) was
0% — that traffic is pure L2 and never crosses eth5. Only gateway-bound (.1) and
internet traffic crosses eth5. So `.200 clean + .1 lossy` = the lossy element is
the switch↔Route10 link, i.e. eth5. CRC is RX-only → corruption is the cable or
the switch's TX, not Route10's TX.

**Fix:** user reseated the eth5 fiber ("touched fiber and back", Rx ≈ -16.33 dBm).
CRC froze (+0/5s), flaps stopped, gateway loss → 0.0%. Classic dirty/partially-
mated fiber connector. NOTE: -16.33 dBm is on the weak side — a reseat without
cleaning can be temporary; proper one-click/IPA clean of both ferrules gives real
margin.

**Diagnostic one-liners:**
```sh
# Is the LAN uplink corrupting frames?  (the tell that mimics an ISP outage)
ssh route10 'ethtool -S eth5 | grep -E "rx_crc_err|runt|carrier"; cat /sys/class/net/eth5/carrier_changes'
# Localize loss: gateway vs a same-switch host (L2-only, never touches Route10)
ping -c40 192.168.10.1    # gateway  (crosses eth5)
ping -c40 192.168.10.200  # opi5pro  (stays on switch — clean = eth5 is the fault)
```

Lesson: "internet down on all devices" with a healthy WAN ⇒ suspect the LAN-side
gateway link (eth5 CRC), not the ISP. CRC errors are physical-layer; no config
change can cause/fix them — thermal cycling + 10G's thin margin + a marginal
connector drift past the cliff with "nothing changed" in software.

Related: the single-fiber internet-path note, the Route10 cage-layout note,
and the mwan3 anycast false-drop note.
