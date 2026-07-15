#!/bin/sh
# lan-prefix-track.sh — deprecate the OUTGOING LAN /64 when the ISP rotates our
# delegated prefix. ONE script, cron-driven (* * * * *), no daemon. Same
# "reconnect self-heal" family as route-defaultroute-hook.sh.
#
# ROOT CAUSE (confirmed 2026-07-15). On a prefix rotation (PPP reconnect / cloud
# reapply) the LAN's RA daemon — dnsmasq, constructor:br-lan — simply STOPS
# advertising the old /64. It does NOT emit a deprecation. That normally works
# because dnsmasq, while it keeps running, re-advertises the outgoing prefix with
# preferred-lifetime 0 for a while. But the rotation here coincides with a dnsmasq
# RESTART (Alta cloud reapply rewrites config.json and bounces network/dnsmasq;
# our own `network reload`s can too) — a fresh dnsmasq has no memory of the prefix
# it *was* advertising, so no deprecation ever goes out. Per RFC 4862 every host
# then keeps the dead /64 as a *preferred* SLAAC address for its full valid
# lifetime (up to 24 h) and source-selects it for new connections the ISP no
# longer routes → the whole LAN is "stuck" on a black-holed prefix.
#
# Measured 2026-07-15: br-lan carried only the live 2804:2488:5082:7300::1 (dash-
# board + `ip -6 addr` agree), yet every LAN host still held 2804:2488:5083:8830::
# preferred with ~14 h to run and used it for ~half its new flows.
#
# A prior hardening (post-cfg ip6class unbind + `network reload`, PR #4 / 373b0b4)
# fixed the router PULLING the new /64 but never addressed clients DUMPING the old
# one — and its `network reload` is itself one of the dnsmasq bounces that eats the
# deprecation. This closes that gap independently of who restarted dnsmasq.
#
# FIX. Remember the current LAN GUA /64 in a state file; when it changes, send the
# deprecation RA (preferred-lifetime 0) for the PREVIOUS /64 ourselves, to all LAN
# nodes, via ra-deprecate.py. Hosts stop using it immediately; new flows move to
# the live prefix. Deterministic — does not rely on dnsmasq's own deprecation.
#
# We track ONLY the GUA (2xxx…). The LAN ULA (fd..) is a static br-lan address
# that never rotates and must NEVER be deprecated; link-local is ignored. State in
# /var/run (tmpfs): a reboot resets it, which is correct — a fresh boot has no
# stale client prefix to chase. Idempotent and QUIET when healthy (touches the
# state file / log only on an actual rotation).
#
# See CLAUDE.md "stale IPv6 prefix", ra-deprecate.py, and project memory.

STATE=/var/run/.lan-prefix.env
DEP=/cfg/scripts/ra-deprecate.py
IFACE=br-lan
# Dual-sink logging (syslog route10.prefix-track + /cfg/scripts/prefix-track.log);
# fall back to file-only if the lib is missing so a bad deploy can't break us.
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init prefix-track \
  || { OBS_LOG=/cfg/scripts/prefix-track.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

# Current LAN GUA /64: a global-scope br-lan address that is NOT ULA (fc00::/7);
# reduce it to its /64 network (first four hextets, host part zeroed).
cur_addr=$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
             | awk '/inet6/ {print $2}' \
             | grep -iv '^f[cd]' \
             | head -1)
net=""
if [ -n "$cur_addr" ]; then
    net=$(echo "${cur_addr%/*}" | awk -F: '{printf "%s:%s:%s:%s::/64",$1,$2,$3,$4}')
fi

# PD not up yet (no GUA on br-lan) → keep prior state, nothing to deprecate.
[ -n "$net" ] || exit 0

prev=""
[ -f "$STATE" ] && . "$STATE" 2>/dev/null && prev="$LAN_PREFIX"

if [ -n "$prev" ] && [ "$prev" != "$net" ]; then
    if [ -x "$DEP" ]; then
        out=$(python3 "$DEP" "$prev" "$IFACE" 3 2>&1)
        event "GUA rotated $prev -> $net; deprecated old prefix on $IFACE (${out:-no output})"
    else
        err "GUA rotated $prev -> $net but $DEP missing — cannot deprecate old prefix"
    fi
fi

# Persist current (only when it changed — keeps the tmpfs file untouched otherwise).
if [ "$prev" != "$net" ]; then
    printf "LAN_PREFIX='%s'\n" "$net" > "$STATE"
fi
exit 0
