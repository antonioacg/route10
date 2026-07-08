#!/bin/sh
# route-defaultroute-hook.sh — re-assert the WAN default route (v4 + v6) that
# netifd drops on a PPP reconnect. ONE script, two callers, no daemon:
#   * /etc/ppp/ip-up.d/50-route10-defaultroute — pppd runs it on every link-up
#     (instant fix), with env IFNAME + IPREMOTE (IPv4CP) / LLREMOTE (IPv6CP).
#   * cron (* * * * *) — periodic backstop; no env, so it discovers the active
#     pppoe interface(s) and derives the gateways itself.
# Idempotent and QUIET when healthy — it only touches the kernel / writes the log
# when a default route is actually missing.
#
# ROOT CAUSE (confirmed 2026-07-08 in netifd source): ppp-up/ppp6-up run
# `proto_set_keep 1`. With a STABLE peer gateway (ours: v4 168.195.103.5,
# v6 fe80::2e4:6ff:fe8a:3f10) a reconnect purges the kernel default route (ppp
# device dropped) but netifd's cache still believes it is installed, so when
# ppp-up re-declares the byte-identical route netifd's diff sees no change and
# SKIPS system_add_route(). The route stays gone → whole LAN blackholed. Fresh
# boot works (empty cache); `ifup wan3` doesn't (re-runs with keep=1). netifd
# will NOT clobber our route — it believes it exists, so issues no add/del for
# the session. See docs/postmortems/2026-07-08-wan3-route-loss.md + memory
# project_route10_wan3_route_loss.
#
# We fix ONLY the `main` table. mwan3's per-interface table (fwmark 0x300 →
# table 3 for wan3) is owned by mwan3rtmon, which mirrors `main` once the route
# is back AND its tracker is up — and it intentionally keeps that table empty
# while the tracker is down. Forcing a route into it here just fights mwan3's
# own up/down logic (observed: mwan3rtmon flushes a manual table-3 add), so we
# leave table 3 to mwan3. The `main` miss is the whole bug; fixing it lets
# mwan3rtmon repopulate table 3 on its own.
#
# `/` is tmpfs — post-cfg.sh installs the ip-up.d symlink and the cron line each
# boot. Log (persistent; logread is volatile here): /cfg/scripts/route-hook.log

LOG=/cfg/scripts/route-hook.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Ensure v4+v6 default routes for one pppoe iface; act only when missing. $2/$3 =
# v4/v6 gateway from pppd env, derived from the iface itself if empty (cron path).
fix_iface() {
    IF="$1"; V4GW="$2"; V6GW="$3"
    [ -n "$IF" ] || return
    [ -n "$V4GW" ] || V4GW=$(ip -4 addr show "$IF" 2>/dev/null | sed -n 's/.*peer \([0-9.]*\).*/\1/p' | head -1)
    [ -n "$V6GW" ] || V6GW=$(ip -6 route show dev "$IF" 2>/dev/null | sed -n 's/^\(fe80::[0-9a-f:]*\) metric 1.*/\1/p' | head -1)

    if [ -n "$V4GW" ] && ! ip route show default 2>/dev/null | grep -q "via $V4GW dev $IF"; then
        ip route replace default via "$V4GW" dev "$IF" 2>/dev/null &&
            log "v4 default via $V4GW dev $IF re-asserted ($CALLER)"
    fi
    if [ -n "$V6GW" ] && ! ip -6 route show default 2>/dev/null | grep -q "via $V6GW dev $IF"; then
        ip -6 route replace default via "$V6GW" dev "$IF" 2>/dev/null &&
            log "v6 default via $V6GW dev $IF re-asserted ($CALLER)"
    fi
}

if [ -n "${IFNAME:-$1}" ]; then          # pppd link-up: one iface, gateways from env
    CALLER=link-up
    case "${IFNAME:-$1}" in pppoe-*) fix_iface "${IFNAME:-$1}" "$IPREMOTE" "$LLREMOTE" ;; esac
else                                      # cron backstop: discover active pppoe ifaces
    CALLER=backstop
    for d in /sys/class/net/pppoe-*; do
        [ -e "$d" ] || continue
        fix_iface "$(basename "$d")" "" ""
    done
fi
exit 0
