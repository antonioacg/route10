#!/bin/sh
# tailscale-reconcile.sh — single owner of the Alta-native Tailscale integration.
#
# Alta firmware (≥ the 2026-07-22 auto-update) ships tailscale natively:
# /usr/sbin/tailscaled + /etc/init.d/tailscale (procd, respawn), configured via
# uci /etc/config/tailscale. It is NOT cloud-modeled (no tailscale keys in
# /cfg/config.json) and NOT rc.d-enabled, so nothing starts or configures it
# unless we do. This script converges the box to the desired mesh state:
#
#   1. uci /etc/config/tailscale — state under persistent /cfg (node identity
#      survives reboots), advertise_exit_node=1, advertise_routes = LAN /24
#      (derived from br-lan) + LAN ULA /64 (derived from seam.env LAN_ULA).
#   2. Daemon running via the FIRMWARE init script (never a sideload), with
#      prefs matching the uci intent (heals the firmware init's boot-time
#      `tailscale set --advertise-routes=""` reset — the 2026-07-22 outage).
#   3. tailscale0 firewall accepts + NAT, both families (NetfilterMode=0: the
#      daemon does not manage netfilter; an Alta config reapply flushes fw3
#      chains, so these must be re-assertable at any time).
#   4. br-lan GRO off (mesh->LAN bulk-transfer blackhole fix, see
#      project_route10_mesh_offload_blackhole.md).
#
# Idempotent, non-destructive, quiet when converged. NO connectivity gate and
# NO revert path — the retired sideload boot hook's "revert all rules if one
# ping to 8.8.8.8 fails" landmine (this ISP path ICMP-rate-limits anycast) is
# exactly what this replaces. Callers: post-cfg.sh (every boot/reapply) and
# mesh-health.sh (*/5 cron, as the self-heal when drift is detected).
#
# Seam: the ULA comes from /cfg/seam.env (contract §mesh routes); absent value
# ⇒ the ULA route is simply not advertised (clean degradation, never hardcode).

# --- observability (file-only fallback so a missing lib never breaks us) -------
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init ts-reconcile \
  || { OBS_LOG=/cfg/scripts/ts-reconcile.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; \
       event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

# Firmware without the native package -> nothing to own here. mesh-health's
# "tailscaled NOT running" assertion is the alarm for that regression.
[ -x /usr/sbin/tailscaled ] || exit 0
[ -x /etc/init.d/tailscale ] || exit 0

[ -f /cfg/seam.env ] && . /cfg/seam.env

# ── desired route set ─────────────────────────────────────────────────────────
# LAN v4 subnet derived from br-lan's own address (contract-follower, not a
# second authority); ULA /64 derived from seam.env LAN_ULA (e.g. fdxx::1/64).
LAN4=$(ip -4 -o addr show br-lan 2>/dev/null | awk '{print $4; exit}')
LAN4=$(python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)" "$LAN4" 2>/dev/null)
ULA6=
[ -n "$LAN_ULA" ] && \
  ULA6=$(python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)" "$LAN_ULA" 2>/dev/null)

ROUTES="$LAN4 $ULA6"          # whitespace-separated, either may be empty
ROUTES=$(echo $ROUTES)        # normalize spacing

# ── 1. uci intent ─────────────────────────────────────────────────────────────
UCI_DIRTY=0
uci -q get tailscale.settings >/dev/null 2>&1 || { uci set tailscale.settings=settings; UCI_DIRTY=1; }
[ "$(uci -q get tailscale.settings.state_file)" = "/cfg/tailscaled.state" ] \
  || { uci set tailscale.settings.state_file='/cfg/tailscaled.state'; UCI_DIRTY=1; }
[ "$(uci -q get tailscale.settings.port)" = "41641" ] \
  || { uci set tailscale.settings.port='41641'; UCI_DIRTY=1; }
[ "$(uci -q get tailscale.settings.advertise_exit_node)" = "1" ] \
  || { uci set tailscale.settings.advertise_exit_node='1'; UCI_DIRTY=1; }
if [ "$(uci -q get tailscale.settings.advertise_routes)" != "$ROUTES" ]; then
    uci -q delete tailscale.settings.advertise_routes
    for r in $ROUTES; do uci add_list tailscale.settings.advertise_routes="$r"; done
    UCI_DIRTY=1
fi
[ "$UCI_DIRTY" = 1 ] && { uci commit tailscale; event "uci tailscale config converged (routes: $ROUTES + exit-node)"; }

# ── 2. daemon running + prefs match ───────────────────────────────────────────
# The firmware init's reload: daemon-level opts changed -> restart; otherwise
# apply_runtime_config re-runs `tailscale set` from uci (non-disruptive).
NEED_APPLY=0
if ! pidof tailscaled >/dev/null 2>&1; then
    event "tailscaled not running — starting via firmware init"
    /etc/init.d/tailscale start >/dev/null 2>&1
elif [ "$UCI_DIRTY" = 1 ]; then
    NEED_APPLY=1
else
    # Daemon up and uci already correct — but did something (e.g. the firmware
    # init at boot, before our uci landed) reset the live AdvertiseRoutes?
    WANT=$(printf '%s\n' 0.0.0.0/0 ::/0 $ROUTES | sort)
    HAVE=$(tailscale debug prefs 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(sorted(d.get("AdvertiseRoutes") or [])))
' 2>/dev/null)
    [ "$WANT" != "$HAVE" ] && NEED_APPLY=1
fi
if [ "$NEED_APPLY" = 1 ]; then
    event "live prefs drifted from uci intent — reloading (re-applies advertised routes)"
    /etc/init.d/tailscale reload >/dev/null 2>&1
fi

# ── 3. firewall accepts + NAT (both families) ─────────────────────────────────
# -w on every call: mesh-health may run us while post-cfg's connlimit job also
# holds the xtables lock. -C (check) + -I (insert) = idempotent.
FW_ADDED=0
ens4()    { iptables  -w        -C "$@" 2>/dev/null || { iptables  -w        -I "$@" 2>/dev/null; FW_ADDED=1; }; }
ens6()    { ip6tables -w        -C "$@" 2>/dev/null || { ip6tables -w        -I "$@" 2>/dev/null; FW_ADDED=1; }; }
ens4nat() { iptables  -w -t nat -C "$@" 2>/dev/null || { iptables  -w -t nat -I "$@" 2>/dev/null; FW_ADDED=1; }; }
ens6nat() { ip6tables -w -t nat -C "$@" 2>/dev/null || { ip6tables -w -t nat -I "$@" 2>/dev/null; FW_ADDED=1; }; }

ens4 INPUT   -i tailscale0 -j ACCEPT
ens4 FORWARD -i tailscale0 -j ACCEPT
ens4 FORWARD -o tailscale0 -j ACCEPT
ens4nat POSTROUTING -s 100.64.0.0/10 -o br-lan     -j MASQUERADE
ens4nat POSTROUTING -s 100.64.0.0/10 -o pppoe-wan3 -j MASQUERADE

ens6 INPUT   -i tailscale0 -j ACCEPT
ens6 FORWARD -i tailscale0 -j ACCEPT
ens6 FORWARD -o tailscale0 -j ACCEPT
ens6nat POSTROUTING -s fd7a:115c:a1e0::/48 -o br-lan     -j MASQUERADE
ens6nat POSTROUTING -s fd7a:115c:a1e0::/48 -o pppoe-wan3 -j MASQUERADE

# Retire any pinned-GUA SNAT for the tailnet ULA (a rotated-away GUA breaks v6
# exit traffic silently; MASQUERADE above tracks the live WAN address instead).
ip6tables -w -t nat -S POSTROUTING 2>/dev/null | grep -- "-s fd7a:115c:a1e0::/48" | grep -- "-j SNAT" | \
while read -r rule; do
    ip6tables -w -t nat $(echo "$rule" | sed 's/^-A/-D/') 2>/dev/null \
      && event "removed stale pinned-GUA SNAT rule: $rule"
done

[ "$FW_ADDED" = 1 ] && event "tailscale0 firewall/NAT rules re-added (fw3 reload had flushed them)"

# ── 4. br-lan GRO off (mesh->LAN bulk-transfer blackhole fix) ─────────────────
ethtool -K br-lan gro off 2>/dev/null

exit 0
