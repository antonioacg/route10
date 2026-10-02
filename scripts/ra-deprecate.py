#!/usr/bin/env python3
# ra-deprecate.py — emit ICMPv6 Router Advertisements that DEPRECATE /64 prefixes
# (Prefix-Info options with preferred-lifetime 0) to all LAN nodes (ff02::1).
#
# WHY (see lan-prefix-track.sh for the full root-cause writeup): when the ISP
# rotates our delegated prefix, dnsmasq (constructor:br-lan) stops advertising the
# old /64 but — because the rotation coincides with a dnsmasq restart — never
# emits a deprecation. Hosts then keep the dead prefix *preferred* for its full
# valid lifetime (up to 24 h) and source-select it for new connections the ISP no
# longer routes. This tool sends the deprecation deterministically instead of
# relying on dnsmasq's (here, absent) own deprecation.
#
# SAFE BY CONSTRUCTION:
#   * Adds ONE Prefix-Info option per prefix named on the command line. It never
#     mentions the live GUA or the ULA, so those are untouched (a host only
#     updates lifetimes for a prefix actually present in the RA).
#   * Router-lifetime is kept NON-zero (matches dnsmasq's ra-param 7200 s) so we
#     do NOT withdraw ourselves as the default router.
#   * Header flags copy dnsmasq's own RA (M bit — it runs stateful DHCPv6 in the
#     ::1000-::ffff range alongside SLAAC) so we don't perturb DHCPv6 either.
#   * Touches no interface address, no uci, no daemon → zero WAN-path impact.
#   * Safe to REPEAT: RFC 4862 5.5.3e ignores a valid-lifetime cut once fewer than
#     2 h remain, so re-sending never extends nor shortens an ADDRESS's life. It
#     does drop the old /64's on-link (prefix-list) entry, which has no such rule
#     (RFC 4861 6.3.4) — harmless, nothing relies on a dead /64 being on-link.
#     Measured on macOS 2026-10-02: unicast repeat → prefix entry "expired",
#     addresses kept their remaining ~1 h.
#
# Usage:
#   ra-deprecate.py <prefix>/<len>[,<prefix>/<len>...] [iface] [count] [dest]
#       one-shot: <count> RAs (default 3) ~1 s apart to <dest> (default ff02::1)
#   ra-deprecate.py --reannounce <stale-file> [iface]
#       the per-minute retry + per-device check, see reannounce() below
import ipaddress, json, os, socket, struct, subprocess, sys, time

# --- match dnsmasq's own RA so only the extra Prefix-Info differs ---------------
RA_FLAGS        = 0xC0    # M(managed)+O(other): byte-matches dnsmasq's own RA,
                          #   captured 2026-07-15 as "Flags [managed, other stateful]"
                          #   (it runs stateful DHCPv6 in ::1000-::ffff). Matching means
                          #   our deprecation RA perturbs nothing but the one prefix.
CUR_HOP_LIMIT   = 64
ROUTER_LIFETIME = 7200    # seconds — matches `ra-param=br-lan,0,7200`. NON-zero!
# --- deprecation values ---------------------------------------------------------
PIO_FLAGS       = 0xC0    # L(on-link)=1 A(autonomous)=1 — must match how the prefix
                          #   was first advertised for the host to update its addr.
VALID_LIFETIME  = 0       # RFC 9096 s3.5: advertise a stale prefix with BOTH
                          #   lifetimes 0 (request invalidation). Hosts clamp a
                          #   sudden valid-lifetime cut to ~2 h (RFC 4862 s5.5.3 e),
                          #   so on macOS the addr lingers DEPRECATED up to 2 h
                          #   either way; preferred=0 is the functional cure, valid=0
                          #   is the correct "remove it" signal and lets stacks
                          #   WITHOUT the 2 h clamp drop it immediately.
PREFERRED_LIFETIME = 0    # <<< THE DEPRECATION: hosts stop using it for new flows now.

# --- --reannounce ---------------------------------------------------------------
STATE_FILE     = "/var/run/ra-reannounce.json"
MIN_INTERVAL_S = 50       # cron (1/min) and the hotplug hook both call us; one round/min
QUIET_S        = 600      # this long with no new connection from the /64 => stopped
LEASES         = "/cfg/dhcp.leases"


def build_ra(nets):
    # RA header (RFC 4861 s4.2), 16 bytes. checksum=0 → kernel fills it for ICMPv6.
    ra = struct.pack("!BBHBBHII", 134, 0, 0,
                     CUR_HOP_LIMIT, RA_FLAGS, ROUTER_LIFETIME, 0, 0)
    # One Prefix Information option (RFC 4861 s4.6.2, 32 bytes) per prefix.
    for n in nets:
        ra += struct.pack("!BBBBIII16s", 3, 4, n.prefixlen, PIO_FLAGS,
                          VALID_LIFETIME, PREFERRED_LIFETIME, 0,
                          n.network_address.packed)
    return ra


def send(nets, iface, count=1, dest="ff02::1"):
    idx = socket.if_nametoindex(iface)
    s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
    # RAs MUST leave with hop limit 255; receivers drop anything less (RFC 4861 s6.1.2).
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_UNICAST_HOPS, 255)
    ra = build_ra(nets)
    for i in range(count):
        s.sendto(ra, (dest, 0, 0, idx))
        if i + 1 < count:
            time.sleep(1)
    s.close()


# --reannounce, run every tick by lan-prefix-track.sh (self-gated to once a minute).
# The burst at rotation reaches only hosts awake to hear it, and dnsmasq advertised
# the old /64 with a 24 h lifetime: a host that missed it (asleep, a lost WiFi
# multicast — those are neither ACKed nor retried) keeps it PREFERRED up to a day.
# ⚠ An RA cannot retire a DHCPv6-ASSIGNED address (dnsmasq hands out ::1000-::ffff):
# that one lives until its DHCPv6 lease ends, also up to 24 h. Seen 2026-10-02: a
# Samsung still sourcing from …f860::1006 17 h after f860 rotated away. Step 2
# names such hosts; the bridge is what keeps them working.
#   1. One multicast RA deprecating every /64 in the stale table, each minute.
#   2. The router cannot read a host's address state, only its behaviour. A host
#      that opened a NEW connection from a stale /64 since the last round — a
#      bridge-NAT66'd conntrack entry we had not seen before — did not get the
#      deprecation, or ignores it. It also gets the RA unicast to its link-local
#      (WiFi unicast IS acked and retried), is named once in the log, and is
#      logged again after QUIET_S without a new connection from that /64.
#   Sampled once a minute: a connection that opens and fully expires from
#   conntrack between two rounds is not seen (UDP ≥30 s, TCP ≥120 s, so rare).
# Prints "<warn|event> <message>" lines for the caller to log.
def bridged_flows(nets):
    """{flow key: (source, stale /64)} for conntrack entries sourced from a stale
    /64 that the bridge NAT66'd (reply dst != original src). Only connections
    opened AFTER the rotation are NAT'd; older ones died with the prefix."""
    flows = {}
    try:
        f = open("/proc/net/nf_conntrack")
    except OSError:
        return flows
    with f:
        for line in f:
            if not line.startswith("ipv6"):
                continue
            t = line.split()
            srcs = [i for i, x in enumerate(t) if x.startswith("src=")]
            if len(srcs) < 2:
                continue
            try:
                src = ipaddress.IPv6Address(t[srcs[0]][4:])
                net = next((n for n in nets if src in n), None)
                if net is None:
                    continue
                rdst = next(x[4:] for x in t[srcs[1]:] if x.startswith("dst="))
                if ipaddress.IPv6Address(rdst) == src:
                    continue
            except (ValueError, StopIteration):
                continue
            key = " ".join([t[2]] + [x for x in t[srcs[0]:srcs[1]] if "=" in x
                                     and not x.startswith(("packets=", "bytes="))])
            flows[key] = (str(src), str(net))
    return flows


def neighbours(iface):
    """address -> MAC for the LAN, and MAC -> link-local / IPv4 address."""
    mac_of, ll_of, v4_of = {}, {}, {}
    for fam in ("-6", "-4"):
        out = subprocess.run(["ip", fam, "neigh", "show", "dev", iface],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            t = line.split()
            if "lladdr" not in t:
                continue
            mac = t[t.index("lladdr") + 1].lower()
            if fam == "-4":
                v4_of[mac] = t[0]
                continue
            try:
                a = ipaddress.IPv6Address(t[0])
            except ValueError:
                continue
            mac_of[a] = mac
            if a.is_link_local:
                ll_of[mac] = str(a)
    return mac_of, ll_of, v4_of


def label(mac, v4_of):
    if not mac:
        return "unknown device"
    try:
        for line in open(LEASES):
            t = line.split()
            if len(t) >= 4 and t[1].lower() == mac and t[3] != "*":
                return "%s %s" % (t[3], mac)
    except OSError:
        pass
    return "%s %s" % (v4_of.get(mac, "?"), mac)


def reannounce(stale_file, iface):
    now = int(time.time())
    try:
        with open(STATE_FILE) as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    if now - st.get("ts", 0) < MIN_INTERVAL_S:
        return
    nets = []
    try:
        for line in open(stale_file):
            if line.split():
                nets.append(ipaddress.IPv6Network(line.split()[0]))
    except (OSError, ValueError):
        pass
    flows = bridged_flows(nets) if nets else {}
    hosts = st.get("hosts", {})          # "<mac or addr>|<net>" -> last new-conn ts
    if nets:
        send(nets, iface)                                             # 1. everyone
        if "flows" in st:          # first round after boot/deploy = baseline only
            mac_of, ll_of, v4_of = neighbours(iface)
            sent = set()
            for key, (addr, net) in flows.items():
                if key in st["flows"]:
                    continue
                mac = mac_of.get(ipaddress.IPv6Address(addr))
                hk = "%s|%s" % (mac or addr, net)
                if hk not in hosts:
                    print("warn still using retired %s: %s (%s) — retiring it directly"
                          " each minute; bridged meanwhile" % (net, label(mac, v4_of), addr))
                hosts[hk] = now
                ll = ll_of.get(mac)
                if ll and ll not in sent:                             # 2. stragglers
                    send(nets, iface, dest=ll)
                    sent.add(ll)
    live = {str(n) for n in nets}
    for hk in list(hosts):
        who, net = hk.split("|")
        if net not in live:
            del hosts[hk]
        elif now - hosts[hk] >= QUIET_S:
            print("event no longer using retired %s: %s (no new connection from it in"
                  " %d min)" % (net, who, QUIET_S // 60))
            del hosts[hk]
    with open(STATE_FILE + ".new", "w") as f:
        json.dump({"ts": now, "flows": sorted(flows), "hosts": hosts}, f)
    os.replace(STATE_FILE + ".new", STATE_FILE)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--reannounce":
        reannounce(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "br-lan")
        return
    if len(sys.argv) < 2 or "/" not in sys.argv[1]:
        sys.exit("usage: ra-deprecate.py <prefix>/<len>[,...] [iface] [count] [dest]\n"
                 "       ra-deprecate.py --reannounce <stale-file> [iface]")
    nets = [ipaddress.IPv6Network(p) for p in sys.argv[1].split(",")]
    iface = sys.argv[2] if len(sys.argv) > 2 else "br-lan"
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    dest = sys.argv[4] if len(sys.argv) > 4 else "ff02::1"
    send(nets, iface, count, dest)
    print("ra-deprecate: sent %d RA(s) to %s on %s deprecating %s (preferred=0, valid=%d)"
          % (count, dest, iface, ",".join(map(str, nets)), VALID_LIFETIME))


if __name__ == "__main__":
    main()
