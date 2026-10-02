#!/bin/sh
# wan6-dhcp-early.sh — let odhcp6c talk to the ISP from the first second of a
# PPP session, independent of fw3's zone/device bookkeeping.
#
# WHY (measured 2026-10-02): ip6 OUTPUT/INPUT are policy DROP and fw3 only adds the
# `-o/-i pppoe-wan3` zone jumps when it reloads on the wan3 ifup event (+31 s
# after PPP up at boot; a portal apply also rebuilds the firewall while the link
# is down). Until then odhcp6c's SOLICIT and RS fail with EPERM and its
# exponential backoff left the LAN without a GUA for ~40 s at boot (measured
# 22:26Z). With these rules the PD landed ~7 s into a plain reconnect (22:59Z);
# a plain reconnect WITHOUT them was never measured.
#
# ⚠ It does NOT keep the same PD (the original goal). Measured 2026-10-02 over
# 3 reconnects: the BNG hands out a new /60 per PPP session. The DUID is already
# stable, a prefix hint changes nothing, and an immediate SOLICIT (IA_PD only or
# IA_NA+IA_PD) still gets a new prefix. The one exception (22:47Z: four
# early probes offered the old /60) did not reproduce. Treat rotation as ISP
# behaviour.
#
# WHAT: four narrow rules in fw3's custom chains (output_rule / input_rule).
# Those chains are jumped to BEFORE the per-device zone dispatch and survive a
# fw3 reload; a fw3 restart recreates them empty, which is why this script is
# also hooked into /etc/firewall.user (run by fw3 on start) from post-cfg.
#   out: DHCPv6 client -> server (udp 546 -> 547), Router Solicitation
#   in:  DHCPv6 server -> client and Router Advertisement, link-local source only
# Idempotent (-C before -A) and quiet when already present. Prints "added" when
# it had to insert anything, so callers can log it.
ip6t="ip6tables -w 10"
TAG="rt10-wan6-early"
DEV=pppoe-wan3
added=0
ensure() {   # ensure <chain> <rule...>
    chain=$1; shift
    $ip6t -C "$chain" "$@" -m comment --comment "$TAG" -j ACCEPT 2>/dev/null && return 0
    $ip6t -A "$chain" "$@" -m comment --comment "$TAG" -j ACCEPT 2>/dev/null && added=1
    return 0
}
ensure output_rule -o "$DEV" -p udp --sport 546 --dport 547
ensure output_rule -o "$DEV" -p icmpv6 --icmpv6-type router-solicitation
ensure input_rule  -i "$DEV" -s fe80::/10 -p udp --sport 547 --dport 546
ensure input_rule  -i "$DEV" -s fe80::/10 -p icmpv6 --icmpv6-type router-advertisement
[ "$added" = 1 ] && echo added
exit 0
