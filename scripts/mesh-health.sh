#!/bin/sh
# mesh-health.sh — Tailscale mesh DRIFT smoke tests + SELF-HEAL (route10-side).
# Cron-driven (*/5), no daemon. QUIET when healthy; WARN/ERR on drift; where the
# fix is route10-local it HEALS by re-running tailscale-reconcile.sh (the single
# owner of the native-tailscale integration) and re-checks. Assertions:
#
#   1. NODE LIVENESS — tailscaled running (heal: reconcile starts it), not a
#      DELETED/stale binary, running version == on-disk version. The 2026-07-20
#      incident: on-disk tailscaled replaced but the daemon never restarted, so
#      its live ACL filter was stale and silently dropped all mesh->subnet traffic.
#
#   2. ROUTE INTENT — the live prefs' AdvertiseRoutes must equal the intended set
#      (LAN /24 derived from br-lan + ULA /64 from seam.env + the exit-node
#      defaults). Deliberately derived INDEPENDENTLY of prefs: on 2026-07-22 the
#      Alta firmware update's native init ran `tailscale set --advertise-routes=""`
#      from empty uci defaults at boot, silently un-advertising everything — a
#      prefs-derived expectation is blind to exactly that reset. Heal: reconcile.
#
#   3. FILTER ENFORCEMENT — the compiled packet filter must ADMIT every subnet
#      route route10 advertises. Catches Headscale policy-compile drift / stale-
#      daemon filter (the 2026-07-20 class). Server-side state — NOT healable
#      from here, WARN only. (Per ops: never assert approval from the SELF
#      netmap — Self.AllowedIPs never contains your own subnet routes.)
#
#   4. KERNEL PATH — the tailscale0 INPUT/FORWARD accepts + NAT must be present
#      in both families. An Alta config reapply flushes fw3 chains; on 2026-07-21
#      that (plus the retired sideload hook's ping-revert landmine) blackholed
#      all mesh->LAN traffic with WG up and packets arriving on the tun — every
#      layer above looked healthy. Heal: reconcile re-adds them.
#
# Design notes:
#   - Assertion 3's expected grants are DERIVED from AdvertiseRoutes (minus the
#     exit-node defaults, which the filter fragments); assertion 2 is what makes
#     that base trustworthy. Assert on filter DSTs, NEVER SRCs (srcs churn).
#   - Heal = tailscale-reconcile.sh, at most once per run, then one re-check.
#   - Clean no-op on a stick-only router (no tailscale installed).
#
# See project_route10_tailscale_stale_binary_filter.md,
# project_route10_native_tailscale.md and CLAUDE.md observability.

# --- observability (file-only fallback so a missing lib never breaks the check) --
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init mesh-health \
  || { OBS_LOG=/cfg/scripts/mesh-health.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; \
       event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

# --- self-heal: converge via the single owner, at most once per run --------------
HEALED=0
heal() {
    [ "$HEALED" = 1 ] && return 0
    HEALED=1
    [ -x /cfg/scripts/tailscale-reconcile.sh ] || { warn "heal skipped: tailscale-reconcile.sh missing"; return 1; }
    /cfg/scripts/tailscale-reconcile.sh >/dev/null 2>&1
}

# --- locate the daemon + CLI; clean no-op if the mesh isn't installed ------------
PID=$(pidof tailscaled 2>/dev/null | awk '{print $1}')
DAEMON_EXE=""
[ -n "$PID" ] && DAEMON_EXE=$(readlink "/proc/$PID/exe" 2>/dev/null)
DISK_BIN=${DAEMON_EXE% (deleted)}                    # strip a "(deleted)" suffix
[ -x "$DISK_BIN" ] || DISK_BIN=/usr/sbin/tailscaled  # Alta firmware-native path
TS="$(dirname "$DISK_BIN")/tailscale"
[ -x "$TS" ] || TS=$(command -v tailscale 2>/dev/null)

# Not a mesh node at all (stick-only router) -> nothing to assert.
[ -z "$PID" ] && [ ! -x "$TS" ] && exit 0

# ===== Assertion 1: node liveness (the stale/deleted-binary footgun) =============
if [ -z "$PID" ]; then
    err "tailscaled NOT running — mesh subnet-router + exit-node are OFFLINE; healing via reconcile"
    heal
    PID=$(pidof tailscaled 2>/dev/null | awk '{print $1}')
    [ -n "$PID" ] && event "healed: tailscaled started" || err "heal FAILED: tailscaled still not running"
fi
if [ -n "$PID" ]; then
    case "$DAEMON_EXE" in
        *"(deleted)"*)
            warn "tailscaled is running a DELETED binary ($DAEMON_EXE) — the on-disk binary was replaced and the daemon never restarted; its live ACL filter may be STALE. Fix: kill $PID && /etc/init.d/tailscale start" ;;
    esac
    if [ -x "$TS" ] && [ -x "$DISK_BIN" ]; then
        RUN_VER=$($TS status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("Version","").split("-")[0])' 2>/dev/null)
        DISK_VER=$("$DISK_BIN" --version 2>/dev/null | head -1 | tr -d ' ')
        if [ -n "$RUN_VER" ] && [ -n "$DISK_VER" ] && [ "$RUN_VER" != "$DISK_VER" ]; then
            warn "tailscaled version skew: running $RUN_VER but on-disk is $DISK_VER — restart to load the on-disk binary (a stale daemon can mis-enforce the current policy)"
        fi
    fi
fi

# ===== Assertion 2: live AdvertiseRoutes == intended route set ===================
# Independent derivation (br-lan + seam.env), NOT from prefs — see header.
[ -f /cfg/seam.env ] && . /cfg/seam.env
INTENT=$(python3 -c "
import ipaddress, subprocess, sys
routes = ['0.0.0.0/0', '::/0']
try:
    a = subprocess.run(['ip','-4','-o','addr','show','br-lan'],capture_output=True,text=True).stdout.split()
    routes.append(str(ipaddress.ip_interface(a[a.index('inet')+1]).network))
except Exception: pass
ula = '$LAN_ULA'
if ula:
    try: routes.append(str(ipaddress.ip_interface(ula).network))
    except Exception: pass
print('\n'.join(sorted(routes)))
" 2>/dev/null)
if [ -n "$PID" ] && [ -x "$TS" ] && [ -n "$INTENT" ]; then
    LIVE=$($TS debug prefs 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(sorted(d.get("AdvertiseRoutes") or [])))
' 2>/dev/null)
    if [ "$LIVE" != "$INTENT" ]; then
        warn "AdvertiseRoutes drifted — live [$(echo $LIVE)] != intended [$(echo $INTENT)] (firmware-init reset class, 2026-07-22); healing via reconcile"
        heal
        LIVE=$($TS debug prefs 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(sorted(d.get("AdvertiseRoutes") or [])))
' 2>/dev/null)
        [ "$LIVE" = "$INTENT" ] && event "healed: AdvertiseRoutes restored [$(echo $LIVE)]" \
                                || err "heal FAILED: AdvertiseRoutes still [$(echo $LIVE)]"
    fi
fi

# ===== Assertion 3: compiled filter admits every advertised subnet route =========
if [ -x "$TS" ]; then
    EXPECTED=$($TS debug prefs 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in (d.get("AdvertiseRoutes") or []):
    if r not in ("0.0.0.0/0", "::/0"):
        print(r)
' 2>/dev/null)
    if [ -n "$EXPECTED" ]; then
        NM=$($TS debug netmap 2>&1)
        if echo "$NM" | grep -q "404"; then
            # Alta's firmware tailscaled is a slimmed build with the debug-netmap
            # LocalAPI endpoint compiled out (404). Filter enforcement is not
            # readable on this build — stay QUIET (a perpetual WARN is noise):
            # assertion 1 still guards the stale-daemon cause, and ops's CI
            # (INFRA-103 #3) guards policy->filter compile drift server-side.
            NM=""
        fi
        MISSING=$([ -n "$NM" ] && echo "$NM" | python3 -c '
import sys, json
exp = set(sys.argv[1:])
try:
    d = json.load(sys.stdin)
except Exception:
    print("__NETMAP_UNREADABLE__"); sys.exit(0)
grants = set()
for rule in (d.get("PacketFilter") or []):
    for dp in (rule.get("Dsts") or []):
        n = dp.get("Net")
        if n:
            grants.add(n)
for r in exp:
    if r not in grants:
        print(r)
' $EXPECTED 2>/dev/null)
        if [ "$MISSING" = "__NETMAP_UNREADABLE__" ]; then
            warn "cannot read the compiled packet filter (debug netmap unparseable — likely a CLI/daemon version skew); mesh->subnet enforcement is UNVERIFIED"
        elif [ -n "$MISSING" ]; then
            warn "compiled ACL filter is MISSING the grant for advertised route(s): $(echo $MISSING) — the policy grants them but the live filter does not admit them (stale daemon / Headscale policy-compile drift). mesh->home traffic to these is being dropped."
        fi
    fi
fi

# ===== Assertion 4: kernel path — tailscale0 accepts + NAT present (v4+v6) =======
# fw3 reloads (every Alta portal write/reapply) flush these; without them mesh
# packets arrive on the tun and die in INPUT/FORWARD while WG looks healthy.
if [ -d /sys/class/net/tailscale0 ]; then
    FW_MISSING=""
    iptables  -w -C INPUT   -i tailscale0 -j ACCEPT 2>/dev/null || FW_MISSING="$FW_MISSING v4-input"
    iptables  -w -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || FW_MISSING="$FW_MISSING v4-fwd-in"
    iptables  -w -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || FW_MISSING="$FW_MISSING v4-fwd-out"
    iptables  -w -t nat -C POSTROUTING -s 100.64.0.0/10 -o br-lan -j MASQUERADE 2>/dev/null || FW_MISSING="$FW_MISSING v4-masq-lan"
    ip6tables -w -C INPUT   -i tailscale0 -j ACCEPT 2>/dev/null || FW_MISSING="$FW_MISSING v6-input"
    ip6tables -w -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || FW_MISSING="$FW_MISSING v6-fwd-in"
    ip6tables -w -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || FW_MISSING="$FW_MISSING v6-fwd-out"
    ip6tables -w -t nat -C POSTROUTING -s fd7a:115c:a1e0::/48 -o br-lan -j MASQUERADE 2>/dev/null || FW_MISSING="$FW_MISSING v6-masq-lan"
    if [ -n "$FW_MISSING" ]; then
        warn "tailscale0 firewall/NAT rules MISSING:$FW_MISSING (fw3 reload flushed them) — mesh->LAN is blackholed; healing via reconcile"
        heal
        if iptables -w -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null; then
            event "healed: tailscale0 firewall/NAT rules restored"
        else
            err "heal FAILED: tailscale0 firewall rules still missing"
        fi
    fi
fi

exit 0
