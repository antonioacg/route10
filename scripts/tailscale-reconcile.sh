#!/bin/sh
# tailscale-reconcile.sh — gap-filler for the PORTAL-OWNED Tailscale integration.
#
# Since Alta 1.5i (2026-10-02) tailscale is an on-demand package: enabling the
# Route10 → VPN → Tailscale card makes the cloud agent `apkg install tailscale`
# (cached on /a, reinstalled every boot since / is tmpfs) and write uci
# login_url, advertise_exit_node and advertise_routes (LAN /24) on every apply.
# The portal owns those. This script only does what the card cannot express:
#
#   1. uci /etc/config/tailscale — state under persistent /cfg, quiet logs,
#      and the LAN ULA /64 ADDED to advertise_routes (the card's subnet picker
#      rejects IPv6 CIDRs). Portal-owned keys are checked, never written —
#      a disagreeing login_url makes the init log the node out.
#   2. Daemon running via the FIRMWARE init script (never a sideload), with
#      live prefs carrying every intended route (heals an init/agent reload
#      that dropped the ULA).
#   3. tailscale0 firewall accepts + NAT, both families — a BACKSTOP: the
#      1.102 daemon also manages its own ts-* chains (NetfilterMode=2), but an
#      Alta config reapply flushes non-fw3 rules, so ours must be
#      re-assertable at any time.
#   4. br-lan GRO off (mesh->LAN bulk-transfer blackhole fix, see
#      project_route10_mesh_offload_blackhole.md).
#   5. dnsmasq mesh listener — tailscale0 in dhcp.@dnsmasq[0].interface, so
#      dnsmasq binds the tailnet addresses and off-LAN split-DNS answers
#      (2026-08-14: the cloud dhcp regen dropped it for ~20 h, silently).
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

# Package not installed (portal card disabled, or the agent has not installed it
# yet) -> nothing to fill in. mesh-health's "NOT INSTALLED" assertion alarms.
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
# DAEMON_DIRTY = daemon-level opts (need a stop/start to take effect);
# ROUTES_DIRTY = runtime prefs (a `reload` re-applies via `tailscale set`).
DAEMON_DIRTY=0; ROUTES_DIRTY=0
uci -q get tailscale.settings >/dev/null 2>&1 || { uci set tailscale.settings=settings; DAEMON_DIRTY=1; }
[ "$(uci -q get tailscale.settings.state_file)" = "/cfg/tailscaled.state" ] \
  || { uci set tailscale.settings.state_file='/cfg/tailscaled.state'; DAEMON_DIRTY=1; }
# Control plane + exit node are PORTAL-OWNED since 1.5i (Route10 → VPN →
# Tailscale card; the cloud agent writes login_url / advertise_exit_node /
# advertise_routes on every apply). We CHECK them, never write them: the init
# logs the node out whenever the live .ControlURL differs from uci login_url, so
# two writers disagreeing turns every apply into a logout. A mismatch here means
# the portal card drifted from the contract value — fix it in the portal.
if [ -n "$TS_LOGIN_URL" ]; then
    [ "$(uci -q get tailscale.settings.login_url)" = "$TS_LOGIN_URL" ] \
      || err "portal Tailscale Login URL is '$(uci -q get tailscale.settings.login_url)', contract wants '$TS_LOGIN_URL' — the init will log this node out; fix the Route10 VPN → Tailscale card"
fi
[ "$(uci -q get tailscale.settings.advertise_exit_node)" = "1" ] \
  || warn "portal Tailscale 'Run as exit node' is OFF — exit node not advertised; fix the Route10 VPN → Tailscale card"
[ "$(uci -q get tailscale.settings.port)" = "41641" ] \
  || { uci set tailscale.settings.port='41641'; DAEMON_DIRTY=1; }
# Silence the daemon's stdout/stderr: with logtail disabled (--no-logs-no-support)
# tailscaled emits its FULL verbose stream ([v1] per-packet Accepts, disco, wg
# keepalives) which procd would pump into syslog at daemon.err — churning the
# 64 KiB ring and flooding Loki. mesh-health (*/5) is the health monitor; flip
# these to 1 + restart only for ad-hoc daemon debugging.
[ "$(uci -q get tailscale.settings.log_stdout)" = "0" ] \
  || { uci set tailscale.settings.log_stdout='0'; DAEMON_DIRTY=1; }
[ "$(uci -q get tailscale.settings.log_stderr)" = "0" ] \
  || { uci set tailscale.settings.log_stderr='0'; DAEMON_DIRTY=1; }
# Routes: the portal owns the list but its subnet picker rejects IPv6 CIDRs, so
# the contract ULA /64 can only come from here. ADD what is missing, never
# rewrite — a wholesale rewrite would delete anything added in the portal. The
# agent's next apply drops the ULA again; post-cfg re-runs us right after it.
for r in $ROUTES; do
    uci -q get tailscale.settings.advertise_routes | tr ' ' '\n' | grep -qxF "$r" \
      || { uci add_list tailscale.settings.advertise_routes="$r"; ROUTES_DIRTY=1; }
done
if [ "$DAEMON_DIRTY" = 1 ] || [ "$ROUTES_DIRTY" = 1 ]; then
    uci commit tailscale
    event "uci tailscale config converged (routes: $ROUTES + exit-node)"
fi

# ── 2. daemon running + prefs match ───────────────────────────────────────────
NEED_APPLY=0
if ! pidof tailscaled >/dev/null 2>&1; then
    event "tailscaled not running — starting via firmware init"
    /etc/init.d/tailscale start >/dev/null 2>&1
elif [ "$DAEMON_DIRTY" = 1 ]; then
    # The init's reload->restart does NOT reliably re-apply procd params when
    # stop/start happen back-to-back (observed 2026-07-22: log flags ignored);
    # an explicit stop, settle, start does.
    event "daemon-level uci changed — restarting tailscaled (stop/settle/start)"
    /etc/init.d/tailscale stop >/dev/null 2>&1
    sleep 2
    /etc/init.d/tailscale start >/dev/null 2>&1
elif [ "$ROUTES_DIRTY" = 1 ]; then
    NEED_APPLY=1
else
    # Daemon up and uci already correct — but did something (e.g. the firmware
    # init at boot, before our uci landed) reset the live AdvertiseRoutes?
    # Subset check: the portal may legitimately advertise more than we want.
    HAVE=$(tailscale debug prefs 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(sorted(d.get("AdvertiseRoutes") or [])))
' 2>/dev/null)
    for r in 0.0.0.0/0 ::/0 $ROUTES; do
        echo "$HAVE" | grep -qxF "$r" || NEED_APPLY=1
    done
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

# v6 exit-node egress: the wan MASQUERADE above is the SOLE owner. It replaces
# lan-prefix-track's old pinned-GUA SNAT job (removed 2026-07-22 — my earlier
# "Alta's daemon appends it" attribution was wrong, it was that cron job): the
# ISP now provides pppoe-wan3 its own global SLAAC address, so MASQUERADE
# sources from the live WAN GUA per-packet — rotation-proof, no upkeep
# (verified: exit-node curl -6 egresses the WAN GUA and round-trips).

[ "$FW_ADDED" = 1 ] && event "tailscale0 firewall/NAT rules re-added (fw3 reload had flushed them)"

# ── 4. br-lan GRO + TSO off (mesh->LAN forward-path fixes) ────────────────────
# Two distinct bugs on the same interface, both reachable ONLY from the mesh.
#
#   gro off (2026-07-18) — br-lan GRO coalesced WG-tunnel segments into frames
#   lost re-segmenting for the 1280 tunnel. Bulk mesh->LAN transfers blackholed
#   (ssh "Connection closed", dd 0 bytes). A/B/A'd as the sole culprit THEN.
#
#   tso off (2026-09-18) — a SECOND, independent bug the gro fix never covered.
#   wireguard-go does its own TCP GRO in userspace and hands the kernel a
#   coalesced super-segment (measured: 4198 B payload, gso_size 1240 from the
#   1280 tunnel). Forwarding that out br-lan, the IPQ9574 hardware TSO engine
#   mis-segments a non-1460 gso_size — payload boundaries stop matching the
#   sequence numbers, and since the engine also computes the checksums the
#   receiver ACCEPTS the corrupt bytes. TLS then fails the record MAC.
#   ⛔ SILENT DATA CORRUPTION, not loss: nothing logs it, no counter moves.
#   ⛔ ethtool -K tailscale0 gro off does NOT help — the coalescing is inside
#   wireguard-go, not kernel GRO, and this build exposes no knob for it
#   (only TS_DEBUG_DISABLE_UDP_GSO/GRO, which are the encrypted UDP side).
#   ⭐ TSO is the SOLE culprit, A/B/A'd: tso off + gso on PASSES, tso on +
#   gso off FAILS. GSO stays ON — software segmentation splits it correctly.
#   Threshold is the first upload needing >1 tunnel MSS (~2 KB), not 8 KB.
#   Cost of tso off is ZERO measured (WAN->LAN 703 vs 697 Mbit/s over 3
#   alternating 50 MB runs): ecm/qca_nss_sfe shortcut-forwards WAN->LAN around
#   the kernel path, so mesh traffic (userspace WG, never offloadable) is the
#   only traffic that meets this engine at all.
# ⛔ NOT expressible in the Alta portal: the cloud config model has no
#   offload/ethtool concept and does not know tailscale0 exists — checked
#   against /cfg/config.json, not assumed.
ethtool -K br-lan gro off 2>/dev/null
ethtool -K br-lan tso off 2>/dev/null

# ── 5. dnsmasq mesh listener (off-LAN split-DNS) ──────────────────────────────
# Headscale split-DNS points mesh clients at this node's TAILNET addresses for
# the split domain. dnsmasq is interface-list + bind-dynamic: without tailscale0
# in dhcp.@dnsmasq[0].interface it neither binds the tailnet addresses nor
# accepts a query that ingresses on tailscale0 (bind-dynamic does per-arrival-
# interface access control). The entry is OURS, not the cloud's: an Alta apply
# that regenerates /etc/config/dhcp drops it, and the apply restarts dnsmasq
# AFTER post-cfg has completed — a one-shot re-add there loses that race (it
# lost on 2026-08-14: ~20 h of silently dead off-LAN split-DNS, on-LAN fine,
# every assertion on both sides green). Convergence lives HERE so both callers
# re-assert it; mesh-health assertion 6 detects the missing BIND. bind-dynamic
# tolerates tailscale0 coming/going, so the uci entry + reload is the whole fix.
if [ -d /sys/class/net/tailscale0 ] \
   && ! uci -q get dhcp.@dnsmasq[0].interface 2>/dev/null | grep -qw tailscale0; then
    uci add_list dhcp.@dnsmasq[0].interface='tailscale0'
    uci commit dhcp
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    event "dnsmasq tailscale0 listener re-added (cloud dhcp regen drops it) — off-LAN split-DNS rebound"
fi

exit 0
