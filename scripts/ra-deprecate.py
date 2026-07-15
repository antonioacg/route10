#!/usr/bin/env python3
# ra-deprecate.py — emit ICMPv6 Router Advertisements that DEPRECATE one /64
# prefix (Prefix-Info option with preferred-lifetime 0) to all LAN nodes (ff02::1).
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
#   * Adds exactly ONE Prefix-Info option, for the prefix named on the command
#     line. It never mentions the live GUA or the ULA, so those are untouched
#     (a host only updates lifetimes for a prefix actually present in the RA).
#   * Router-lifetime is kept NON-zero (matches dnsmasq's ra-param 7200 s) so we
#     do NOT withdraw ourselves as the default router.
#   * Header flags copy dnsmasq's own RA (M bit — it runs stateful DHCPv6 in the
#     ::1000-::ffff range alongside SLAAC) so we don't perturb DHCPv6 either.
#   * Touches no interface address, no uci, no daemon → zero WAN-path impact.
#
# Usage:  ra-deprecate.py <prefix>/<len> [iface] [count]
#   <prefix>/<len> : /64 to deprecate, e.g. 2804:2488:5083:8830::/64
#   iface          : LAN bridge to send on        (default: br-lan)
#   count          : RAs to send, ~1 s apart      (default: 3)
import socket, struct, sys, time

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


def build_ra(prefix_bytes, prefix_len):
    # RA header (RFC 4861 s4.2), 16 bytes. checksum=0 → kernel fills it for ICMPv6.
    ra = struct.pack("!BBHBBHII", 134, 0, 0,
                     CUR_HOP_LIMIT, RA_FLAGS, ROUTER_LIFETIME, 0, 0)
    # Prefix Information option (RFC 4861 s4.6.2), 32 bytes (length field = 4).
    pio = struct.pack("!BBBBIII16s", 3, 4, prefix_len, PIO_FLAGS,
                      VALID_LIFETIME, PREFERRED_LIFETIME, 0, prefix_bytes)
    return ra + pio


def main():
    if len(sys.argv) < 2 or "/" not in sys.argv[1]:
        sys.exit("usage: ra-deprecate.py <prefix>/<len> [iface] [count]")
    pfx_str, plen = sys.argv[1].split("/")
    plen = int(plen)
    iface = sys.argv[2] if len(sys.argv) > 2 else "br-lan"
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    prefix_bytes = socket.inet_pton(socket.AF_INET6, pfx_str)  # host part must be 0

    idx = socket.if_nametoindex(iface)
    s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
    # RAs MUST leave with hop limit 255; receivers drop anything less (RFC 4861 s6.1.2).
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)

    ra = build_ra(prefix_bytes, plen)
    for i in range(count):
        s.sendto(ra, ("ff02::1", 0, 0, idx))   # all-nodes on this link
        if i + 1 < count:
            time.sleep(1)
    print("ra-deprecate: sent %d RA(s) on %s deprecating %s/%d (preferred=0, valid=%d)"
          % (count, iface, pfx_str, plen, VALID_LIFETIME))


if __name__ == "__main__":
    main()
