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
# The cron path also heals mwan3 POLICY DRIFT (heal_mwan3_drift below): a WAN the
# routing policy still counts as online while its own tracker says offline.
#
# `/` is tmpfs — post-cfg.sh installs the ip-up.d symlink and the cron line each
# boot. Log (persistent; logread is volatile here): /cfg/scripts/route-hook.log

# Dual-sink logging (syslog route10.route-hook + /cfg/scripts/route-hook.log);
# fall back to file-only if the lib is missing so a bad deploy can't break us.
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init route-hook \
  || { OBS_LOG=/cfg/scripts/route-hook.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

# Ensure v4+v6 default routes for one pppoe iface; act only when missing. $2/$3 =
# v4/v6 gateway from pppd env, derived from the iface itself if empty (cron path).
fix_iface() {
    IF="$1"; V4GW="$2"; V6GW="$3"
    [ -n "$IF" ] || return
    [ -n "$V4GW" ] || V4GW=$(ip -4 addr show "$IF" 2>/dev/null | sed -n 's/.*peer \([0-9.]*\).*/\1/p' | head -1)
    [ -n "$V6GW" ] || V6GW=$(ip -6 route show dev "$IF" 2>/dev/null | sed -n 's/^\(fe80::[0-9a-f:]*\) metric 1.*/\1/p' | head -1)

    if [ -n "$V4GW" ] && ! ip route show default 2>/dev/null | grep -q "via $V4GW dev $IF"; then
        ip route replace default via "$V4GW" dev "$IF" 2>/dev/null &&
            event "v4 default via $V4GW dev $IF re-asserted ($CALLER)"
    fi
    # Match the v6 default by `dev`, not the exact gateway string: pppd hands us
    # $LLREMOTE zero-padded (fe80::02e4:06ff:…) while `ip` prints it unpadded
    # (fe80::2e4:6ff:…), so an exact-string check would re-fire every link-up.
    # Single-WAN: any v6 default out this iface is ours.
    if [ -n "$V6GW" ] && ! ip -6 route show default 2>/dev/null | grep -q "dev $IF"; then
        ip -6 route replace default via "$V6GW" dev "$IF" 2>/dev/null &&
            event "v6 default via $V6GW dev $IF re-asserted ($CALLER)"
    fi
}

# mwan3 policy drift. Alta's mwan3track (1.5j+, "WAN down in traffic graphs")
# records an outage when it starts before the WAN is up, then RESUMES it on the
# first connect via `disconnected 1`, which writes STATUS=offline and returns
# WITHOUT the hotplug event. The ifup had already put the WAN in the policy
# (initial_state=online), and a WAN that never passes tracking never sends
# another event, so the policy keeps a dead uplink for good. Hit at boot on
# 2026-11-04 and 11-06: the fibreless Huawei on eth0 (wan2) outranks the stick,
# so ALL v4 went to it while v6 (no mwan3 policy) worked. Heal: send the event
# the tracker skipped once the mismatch has held for two runs (a real transition
# clears within a second), then drop that WAN's marked connections — the
# connmark keeps them on the dead table and UDP flows never time out. The event
# itself rebuilds policy + sticky rules and flushes the sticky sets.
DRIFT_DIR=/var/run/route-hook.mwan3-drift
heal_mwan3_drift() {
    for f in /var/run/mwan3/iface_state/*; do
        [ -e "$f" ] || continue
        i=${f##*/}; st="$DRIFT_DIR/$i"
        pol=$(cat "$f" 2>/dev/null)
        trk=$(cat "/var/run/mwan3track/$i/STATUS" 2>/dev/null)
        if [ "$pol" != online ] || [ "$trk" != offline ]; then
            [ -e "$st" ] && { event "mwan3 drift on $i cleared (policy=$pol tracker=$trk)"; rm -f "$st"; }
            continue
        fi
        mkdir -p "$DRIFT_DIR"
        case "$(cat "$st" 2>/dev/null)" in
            '') echo pending > "$st" ;;                 # first sighting: confirm next run
            pending)
                dev=$(cat "/var/run/mwan3track/$i/DEVICE" 2>/dev/null)
                mask=$(uci -q get mwan3.globals.mmx_mask || echo 0x3f00)
                mark=$(iptables -w -t mangle -S "mwan3_iface_in_$i" 2>/dev/null |
                       sed -n "s/.*--comment $i -j MARK --set-xmark \(0x[0-9a-fA-F]*\)\/.*/\1/p" | head -1)
                env -i ACTION=disconnected INTERFACE="$i" DEVICE="$dev" /sbin/hotplug-call iface
                [ -n "$mark" ] && conntrack -D --mark "$mark/$mask" >/dev/null 2>&1
                echo healed > "$st"
                warn "mwan3 drift on $i: policy online, tracker offline for >=1 min; sent the missed 'disconnected' event${mark:+, dropped its $mark connections}" ;;
            healed)
                err "mwan3 drift on $i survived the heal (policy still online, tracker offline); not retrying until it clears"
                echo failed > "$st" ;;
        esac
    done
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
    heal_mwan3_drift
fi
exit 0
