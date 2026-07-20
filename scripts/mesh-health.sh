#!/bin/sh
# mesh-health.sh — Tailscale mesh DRIFT smoke tests (route10-side). Cron-driven
# (*/5), no daemon. QUIET when healthy; WARN/ERR on drift. Two assertions, both
# aimed at the failure class that bit us on 2026-07-20 and hid for ~5 days:
#
#   1. NODE LIVENESS — tailscaled must not be running a DELETED/stale binary, and
#      the running daemon version must equal the on-disk binary version. The
#      incident: the on-disk tailscaled was replaced (1.82.0 -> 1.98.9) but the
#      daemon was never restarted, so it kept running the old (deleted) binary.
#
#   2. FILTER ENFORCEMENT — the compiled packet filter must ADMIT every subnet
#      route route10 advertises (the LAN /24 + LAN ULA /64). The stale 1.82.0
#      daemon mis-compiled ops's Headscale v0.29.2 policy-v2, so its live filter
#      silently DROPPED all mesh->subnet traffic even though the policy granted it
#      and the route was approved+primary. "Declarative policy" guarantees the
#      intent is versioned; it does NOT guarantee the running system enforces it.
#      This test closes that gap: declared-intent (advertised routes) vs
#      live-enforcement (compiled filter).
#
# Design notes:
#   - Expected grants are DERIVED from route10's own AdvertiseRoutes (minus the two
#     default/exit-node routes, which the filter represents as a fragmented CIDR
#     list, not a literal 0.0.0.0/0). Nothing hardcoded -> no seam values here, and
#     the test auto-adapts if the LAN subnet/ULA ever moves in the contract.
#   - We assert on the filter's DSTs, NEVER its SRCs: the src set churns as admin
#     devices join/leave the tailnet (and registered-but-offline nodes linger),
#     so pinning srcs would false-alarm. A missing DST is the real regression.
#   - Clean no-op on a stick-only router (no tailscale installed).
#
# See project_route10_tailscale_stale_binary_filter.md and CLAUDE.md observability.

# --- observability (file-only fallback so a missing lib never breaks the check) --
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init mesh-health \
  || { OBS_LOG=/cfg/scripts/mesh-health.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; \
       event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

# --- locate the daemon + CLI; clean no-op if the mesh isn't installed ------------
PID=$(pidof tailscaled 2>/dev/null | awk '{print $1}')
DAEMON_EXE=""
[ -n "$PID" ] && DAEMON_EXE=$(readlink "/proc/$PID/exe" 2>/dev/null)
DISK_BIN=${DAEMON_EXE% (deleted)}                    # strip a "(deleted)" suffix
[ -x "$DISK_BIN" ] || DISK_BIN=/a/tailscale/tailscaled
TS="$(dirname "$DISK_BIN")/tailscale"
[ -x "$TS" ] || TS=$(command -v tailscale 2>/dev/null)

# Not a mesh node at all (stick-only router) -> nothing to assert.
[ -z "$PID" ] && [ ! -x "$TS" ] && exit 0

# ===== Assertion 1: node liveness (the stale/deleted-binary footgun) =============
if [ -z "$PID" ]; then
    err "tailscaled NOT running — mesh subnet-router + exit-node are OFFLINE"
else
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

# ===== Assertion 2: compiled filter admits every advertised subnet route =========
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
        MISSING=$($TS debug netmap 2>/dev/null | python3 -c '
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

exit 0
