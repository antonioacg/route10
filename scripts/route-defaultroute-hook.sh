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
# routing policy still counts as online while its own tracker says offline; and a
# PPP session that never got an IPv6 prefix delegated (heal_missing_pd).
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
            # A PPP reconnect leaves wan3 here for ~25 s (tracker re-proving it), so a
            # lone "pending" is routine; only a real heal gets a "cleared" line.
            case "$(cat "$st" 2>/dev/null)" in
                healed|failed) event "mwan3 drift on $i cleared (policy=$pol tracker=$trk)" ;;
            esac
            rm -f "$st"
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

# IPv6 prefix delegation missing for the PPP session. This ISP delegates only at
# session start and ignores every later SOLICIT, so if that first exchange fails
# the LAN has no GUA (no v6 egress) until the next session. 2026-11-06: after
# the area-wide fibre cut, the ADVERTISE came back in 5 ms but all 10 REQUESTs
# went unanswered; the LAN ran 2.5 days without v6. A delegation normally lands
# within seconds, so once wan36 has been up PD_WAIT with an empty prefix list we
# redial wan3 (netifd down+up, which ends the session cleanly with a PADT).
# Backoff 1h, 2h, 4h, capped at 6h, so an ISP-wide v6 outage can't turn into a
# stream of WAN drops; it resets once a prefix arrives. Not counted across
# reboots (tmpfs), and a reboot starts a new session anyway.
PD_DIR=/var/run/route-hook.pd
PD_WAIT=600
heal_missing_pd() {
    st=$(ubus call network.interface.wan36 status 2>/dev/null) || return 0
    [ "$(echo "$st" | jsonfilter -e '@.up' 2>/dev/null)" = true ] || return 0
    pfx=$(echo "$st" | jsonfilter -e '@["ipv6-prefix"][0].address' 2>/dev/null)
    mkdir -p "$PD_DIR"
    n=$(cat "$PD_DIR/attempts" 2>/dev/null || echo 0)
    if [ -n "$pfx" ]; then
        [ "$n" -gt 0 ] && event "IPv6 prefix delegated ($pfx/$(echo "$st" | jsonfilter -e '@["ipv6-prefix"][0].mask' 2>/dev/null)) after $n reconnect(s)"
        rm -f "$PD_DIR/attempts" "$PD_DIR/last" "$PD_DIR/deferred"
        return 0
    fi
    up=$(echo "$st" | jsonfilter -e '@.uptime' 2>/dev/null)
    [ "${up:-0}" -ge "$PD_WAIT" ] || return 0
    now=$(cut -d. -f1 /proc/uptime); last=$(cat "$PD_DIR/last" 2>/dev/null || echo 0)
    wait=$((3600 << (n > 0 ? n - 1 : 0))); [ "$wait" -gt 21600 ] && wait=21600
    if [ "$n" -gt 0 ] && [ $((now - last)) -lt "$wait" ]; then
        [ -e "$PD_DIR/deferred" ] || { err "still no IPv6 prefix after $n reconnect(s); next try in $(( (wait - now + last) / 60 )) min"; touch "$PD_DIR/deferred"; }
        return 0
    fi
    n=$((n + 1)); echo "$n" > "$PD_DIR/attempts"; echo "$now" > "$PD_DIR/last"; rm -f "$PD_DIR/deferred"
    warn "no IPv6 prefix delegated after ${up}s of this PPP session (LAN has no v6 egress); redialling wan3 to ask again (attempt $n)"
    ubus call network.interface down '{ "interface": "wan3" }' 2>/dev/null
    ubus call network.interface up '{ "interface": "wan3" }' 2>/dev/null
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
    heal_missing_pd
fi
exit 0
