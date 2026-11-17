#!/bin/sh
# mesh-allow.sh — mesh → LAN / exit-node allowlist with node-key pins (RT10_MESHFWD).
#
# Contract: ops/NETWORK-CONTRACT.md §"Mesh → LAN / exit-node allowlist + node-key pins".
# The mesh control plane runs on the edge, so the Headscale ACL is not a boundary the
# edge cannot rewrite. route10 serves the subnets and the exit node, so it decides who
# may use them. Anything in on tailscale0 that isn't a reply to a LAN-opened flow is
# forwarded only for a listed source and destination; everything else is logged
# ("route10.mesh-fwd block: ") and dropped.
#
# Key pins: each listed address passes only while every peer whose AllowedIPs covers
# it carries the pinned node key (scripts/mesh-keypin.py has the why). A mismatch
# closes that one address, drops its live flows, and logs err. Unusable peer status or
# a bad table closes every entry. This is containment, not prevention: it is polled
# once a minute, so a control-plane takeover gets up to a minute before the cut-off.
#
# Values: MESH_ALLOW in /cfg/seam.env (from the contract; rows documented in
# mesh-keypin.py). Missing ⇒ empty allowlist ⇒ every entry closed, err.
# Called by post-cfg (each boot/reapply) and cron (* * * * *). Single owner of the
# chain; it is rebuilt atomically (iptables-restore --noflush) only when it changes.
#
# Log: route10.mesh-allow. err = an entry is closed against intent (key mismatch,
# missing or malformed table) — ops alerts on it. warn/notice = everything else.

. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init mesh-allow \
  || { OBS_LOG=/cfg/scripts/mesh-allow.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; \
       event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

STATE=/var/run/mesh-allow
mkdir -p "$STATE"
exec 9>"$STATE/lock"
flock -n 9 || exit 0

MESH_ALLOW=
[ -f /cfg/seam.env ] && . /cfg/seam.env
# WAN devices the exit node forwards out of: the PPPoE sessions (stick + Huawei
# fallback) and wan2 on eth0 (where v4 lands under the mwan3 misroute).
MESH_WAN_DEVS="pppoe+ eth0"
CHAIN=RT10_MESHFWD
JUMP="-i tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j $CHAIN"
NOW=$(date +%s)
REMIND=3600

# once <key> <severity> <msg> — log on change of <key>'s state, and again hourly
# while it holds (err only). Quiet otherwise.
once() {
    _f="$STATE/s.$1"; _sev=$2; shift 2
    _prev=$(cat "$_f" 2>/dev/null)
    _st=${_prev%% *}; _at=${_prev#* }
    if [ "$_st" != "$_sev" ]; then
        $_sev "$*"; echo "$_sev $NOW" > "$_f"
    elif [ "$_sev" = err ] && [ $((NOW - ${_at:-0})) -ge $REMIND ]; then
        err "still: $*"; echo "$_sev $NOW" > "$_f"
    fi
}
clear_state() {  # clear_state <key> <msg> — note a recovery once
    _f="$STATE/s.$1"
    [ -f "$_f" ] || return 0
    rm -f "$_f"; event "$2"
}

# ── verdicts ────────────────────────────────────────────────────────────────
OUT=; RC=0
if [ -z "$(printf '%s' "$MESH_ALLOW" | tr -d ' \n\t')" ]; then
    RC=3; OUT="MESH_ALLOW missing from /cfg/seam.env"
else
    tailscale status --json > "$STATE/status.json" 2>/dev/null
    OUT=$(printf '%s\n' "$MESH_ALLOW" | MESH_WAN_DEVS="$MESH_WAN_DEVS" \
          python3 -I /cfg/scripts/mesh-keypin.py "$STATE/status.json")
    RC=$?
fi

WHY=$(printf '%s\n' "$OUT" | tail -1)
case $RC in
    0) clear_state table "allowlist check working again"
       clear_state status "peer status readable again" ;;
    2) clear_state table "allowlist check working again"
       once status warn "peer status unusable ($WHY) — every entry closed" ;;
    3) once table err "allowlist table unusable ($WHY) — every entry closed" ;;
    *) once table err "allowlist check failed (rc=$RC: $WHY) — every entry closed" ;;
esac

RULES4=; RULES6=
if [ "$RC" = 0 ]; then
    RULES4=$(printf '%s\n' "$OUT" | sed -n 's/^4 //p')
    RULES6=$(printf '%s\n' "$OUT" | sed -n 's/^6 //p')
    printf '%s\n' "$OUT" | sed -n 's/^v //p' | while read -r name addr v detail; do
        key=$(printf '%s' "$name.$addr" | tr ':' '_')
        case $v in
            ok) clear_state "$key" "$name $addr verified again ($detail) — entry open" ;;
            mismatch)
                [ "$(cut -d' ' -f1 "$STATE/s.$key" 2>/dev/null)" = err ] || {
                    # newly closed: cut the flows it already has, not only new ones
                    case $addr in *:*) fam=ipv6 ;; *) fam=ipv4 ;; esac
                    conntrack -D -f "$fam" -s "$addr" >/dev/null 2>&1
                }
                once "$key" err "key mismatch for $name $addr: $detail — entry closed, flows cut" ;;
            absent) once "$key" event "$name $addr not in the netmap ($detail) — entry closed" ;;
        esac
    done
fi

# ── apply ───────────────────────────────────────────────────────────────────
# apply <iptables|ip6tables> <rules> — rebuild the chain only when its content
# changes (signature in the DROP rule's comment), then make sure the jump exists,
# right after RT10_EDGEMESH's so that chain keeps first look at the edge.
apply() {
    ipt="$1 -w 10"
    body=$(printf '%s\n' "$2" | sed '/^$/d' | sed "s/^/-A $CHAIN /")
    sig=$(printf 'tpl1\n%s\n' "$body" | md5sum | cut -c1-12)   # bump tpl on template edits
    mark="route10-meshfwd-$sig"
    if ! $ipt -t mangle -S "$CHAIN" 2>/dev/null | grep -q -- "$mark"; then
        $ipt -t mangle -N "$CHAIN" 2>/dev/null
        {
            echo '*mangle'
            echo ":$CHAIN - [0:0]"
            [ -n "$body" ] && printf '%s\n' "$body"
            echo "-A $CHAIN -m limit --limit 60/hour --limit-burst 20 -j LOG --log-prefix \"route10.mesh-fwd block: \" --log-level notice"
            echo "-A $CHAIN -m comment --comment $mark -j DROP"
            echo 'COMMIT'
        } | "$1-restore" -w 10 --noflush \
            && event "$1: $CHAIN rebuilt, $(printf '%s' "$body" | grep -c .) allow rule(s) ($mark)" \
            || err "$1: $CHAIN rebuild FAILED"
    fi
    # shellcheck disable=SC2086
    if ! $ipt -t mangle -C FORWARD $JUMP 2>/dev/null; then
        pos=$($ipt -t mangle -S FORWARD | grep -n -- '-j RT10_EDGEMESH' | head -1 | cut -d: -f1)
        # shellcheck disable=SC2086
        $ipt -t mangle -I FORWARD "${pos:-1}" $JUMP \
            && event "$1: jump to $CHAIN installed (FORWARD position ${pos:-1})" \
            || err "$1: jump to $CHAIN could not be installed"
    fi
}
apply iptables  "$RULES4"
apply ip6tables "$RULES6"
