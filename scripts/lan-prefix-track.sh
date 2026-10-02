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
# that never rotates and must NEVER be deprecated; link-local is ignored.
# Idempotent and QUIET when healthy (touches the state file / log only on an
# actual rotation).
#
# STATE IS PERSISTENT (/cfg), NOT tmpfs. This file used to live in /var/run with
# the rationale "a reboot resets it, which is correct — a fresh boot has no stale
# client prefix to chase". That reasoning is exactly backwards and cost us a real
# outage: OUR memory resets on reboot, the CLIENTS' does not. A LAN host holds its
# SLAAC address as *preferred* for up to 24h regardless of what the router does in
# between, so a rotation that spans a reboot is precisely when clients are most
# stranded — and precisely when the tmpfs version was guaranteed to be blind to it.
#
# Observed 2026-08-09: rotation at ~19:21Z, reboot at 19:45:23Z, no prior state on
# the first post-boot run, so no diff, so no deprecation RA ever sent. Every LAN
# client kept 2804:2488:5083:d670::/64 preferred alongside the live prefix; source
# selection could pick the dead one, producing intermittent v6 egress failures that
# looked like a host bug. Ceasing to advertise a prefix does NOT deprecate it —
# RFC 9096 requires an explicit RA with preferred_lft 0, which is what we send.
#
# See CLAUDE.md "stale IPv6 prefix", ra-deprecate.py, and project memory.

STATE=/cfg/scripts/.lan-prefix.env
DEP=/cfg/scripts/ra-deprecate.py
IFACE=br-lan
# Dual-sink logging (syslog route10.prefix-track + /cfg/scripts/prefix-track.log);
# fall back to file-only if the lib is missing so a bad deploy can't break us.
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init prefix-track \
  || { OBS_LOG=/cfg/scripts/prefix-track.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

# Current LAN GUA /64: a global-scope br-lan address that is NOT ULA (fc00::/7);
# reduce it to its /64 network (first four hextets, host part zeroed).
# Skip DEPRECATED addresses: after a rotation the dying /64 stays on br-lan for up to
# 2 h (preferred_lft 0). Picking it by list order would make us "rotate" back to the
# dead prefix and deprecate the LIVE one to every LAN host. No live address (the
# ~2 min reconnect window, before the new PD lands) => keep the current state: a
# fallback to "some deprecated one" can pick an OLDER prefix and jump backwards.
pick_gua() {
    ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
      | awk -v want="$1" '/inet6/ { dep = ($0 ~ / deprecated/); if (dep == want) print $2 }' \
      | grep -iv '^f[cd]' | head -1
}
cur_addr=$(pick_gua 0)
net=""
if [ -n "$cur_addr" ]; then
    net=$(echo "${cur_addr%/*}" | awk -F: '{printf "%s:%s:%s:%s::/64",$1,$2,$3,$4}')
fi

# PD not up yet, or only deprecated GUAs (reconnect window) → keep prior state.
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

# Persist current (only when it changed — avoids rewriting /cfg every minute).
if [ "$prev" != "$net" ]; then
    printf "LAN_PREFIX='%s'\n" "$net" > "$STATE"
fi

# ── stale-prefix bridge: keep a rotated-away /64 WORKING for its RFC 4862 tail ──
# A rotation hands us a new PD every PPP session (measured 2026-10-02: no DUID,
# hint or early-SOLICIT lever keeps it). The deprecation RA above cannot remove
# the old address from hosts: RFC 4862's two-hour rule keeps it valid up to 2 h,
# and a host that still sources from it (ops' Cilium pods do, UP-12) sends
# traffic whose replies never come back — the ISP no longer routes that /64 to us.
# Two pieces make it work instead of black-holing, for each stale /64 in its tail:
#   out:  NAT66 MASQUERADE to our WAN address (only for traffic leaving pppoe-wan3);
#   back: an on-link route for the /64 on br-lan, because netifd drops the old
#         prefix route — without it the de-NATed reply is routed back OUT to the ISP.
# Verified live 2026-10-02 23:20-23:23Z: ops' v6 probes recovered within a minute,
# 65 min before the dead address would have expired on its own.
# The current prefix is never bridged. Expiry = rotation + 2 h + 15 min margin.
STALE=/cfg/scripts/.lan-prefix-stale     # "<prefix/64> <expiry epoch>" per line
STALE_TTL=8100
STALE_METRIC=4242                        # tags OUR br-lan routes for the sweep
now=$(date +%s)
{
    [ -f "$STALE" ] && cat "$STALE"
    [ -n "$prev" ] && [ "$prev" != "$net" ] && echo "$prev $((now + STALE_TTL))"
} | awk -v now="$now" -v cur="$net" \
      '$2 > now && $1 != cur { if (!($1 in e) || $2 > e[$1]) e[$1] = $2 }
       END { for (p in e) print p, e[p] }' | sort > "$STALE.new"
if cmp -s "$STALE.new" "$STALE" 2>/dev/null; then rm -f "$STALE.new"; else mv "$STALE.new" "$STALE"; fi
desired=$(awk '{print $1}' "$STALE" 2>/dev/null | tr '\n' ' ')

# NAT66 chain: rebuild only when the set changes (marker hashes it).
smark="rt10-stale6 $(printf '%s' "$desired" | md5sum | cut -c1-8)"
ip6tables -w -t nat -N RT10_STALE6 2>/dev/null || true
if ! ip6tables -w -t nat -S RT10_STALE6 2>/dev/null | grep -qF -- "$smark"; then
    ip6tables -w -t nat -F RT10_STALE6 2>/dev/null || true
    for _p in $desired; do
        ip6tables -w -t nat -A RT10_STALE6 -s "$_p" -j MASQUERADE 2>/dev/null || true
    done
    ip6tables -w -t nat -A RT10_STALE6 -m comment --comment "$smark" -j RETURN 2>/dev/null || true
    if [ -n "$desired" ]; then
        event "stale-prefix bridge now covers: ${desired% } (NAT66 out + br-lan route back)"
    else
        event "stale-prefix bridge idle (no /64 in its tail)"
    fi
fi
# The jump is re-asserted every tick: an fw3 reload flushes our direct rules.
ip6tables -w -t nat -C POSTROUTING -o pppoe-wan3 -j RT10_STALE6 2>/dev/null \
  || ip6tables -w -t nat -I POSTROUTING 1 -o pppoe-wan3 -j RT10_STALE6 2>/dev/null || true

# Return routes: add ours for every stale /64, sweep any of ours no longer wanted.
for _p in $desired; do
    ip -6 route replace "$_p" dev "$IFACE" metric "$STALE_METRIC" proto static 2>/dev/null || true
done
ip -6 route show dev "$IFACE" 2>/dev/null | awk -v m="metric $STALE_METRIC" 'index($0, m) {print $1}' \
  | while read -r _r; do
        case " $desired " in *" $_r "*) continue ;; esac
        ip -6 route del "$_r" dev "$IFACE" metric "$STALE_METRIC" 2>/dev/null || true
    done

# NOTE (2026-07-22): the "Tailscale v6 exit-node egress SNAT" job that lived here
# is REMOVED. Its premise no longer holds — pppoe-wan3 now carries its own global
# SLAAC address, so tailscale-reconcile.sh's plain MASQUERADE handles v6 exit
# egress rotation-proof with no per-tick upkeep (verified live: exit-node curl -6
# egresses from the WAN GUA and round-trips). Single owner = the reconcile.

# ── v6 inbound pinhole for the ops p2p listener (contract §IPv6 inbound perimeter)
#
# THE ONLY WAN→LAN v6 ACCEPT WE HAVE. On native v6 there is no NAT, so this
# FORWARD policy is the sole boundary between the internet and every LAN host's
# GUA. Approved 2026-08-12 against a contract entry, which the invariant requires
# BEFORE any such rule exists. Scope is one address, one port, both protocols.
#
# WHY IT LIVES HERE and not in post-cfg: the destination is *prefix-relative*.
# Only the IID is stable (EUI-64, ops-owned); the /64 rotates with the ISP PD.
# This script already watches exactly that rotation and already re-runs on the
# `ifupdate` hotplug + the 1-min cron, so the pinhole re-points itself and, on a
# rotation, the stale one is DELETED rather than left as an orphaned hole into a
# prefix we no longer own. The same cron also re-asserts it after an fw3 reload
# flushes our directly-inserted rules.
#
# ⭐ INFORMATIVE, NOT RESTRICTIVE (operator decision 2026-08-12). The thresholds
# below only LOG; nothing here rejects or drops. This is a first exposure and we
# do not yet know its normal shape — a cap guessed wrong throttles legitimate
# peers silently, and "slow torrent" is exactly the symptom nobody would trace
# back to a firewall counter. So we measure first and can bound later, on data.
# The v4 CGNAT guard in post-cfg.sh is the opposite trade for the opposite reason
# (there, running out of CGNAT sessions takes the whole LAN's v4 down).
#
# ⚠ Contract values are NOT hardcoded — absent from /cfg/seam.env ⇒ clean no-op,
# i.e. the safe default for a firewall hole is "does not exist". Thresholds are
# OURS (route10 tuning, not a shared value) and stay in this file.
P2P6_WARN_SRC=24      # concurrent conns from ONE remote /64 — a legit peer uses 1-4
P2P6_WARN_TOTAL=800   # concurrent inbound to the listener — a torrent client caps ~200-400

[ -f /cfg/seam.env ] && . /cfg/seam.env 2>/dev/null

# `want` is the ONE destination allowed to hold a pinhole right now. Empty when
# the contract values are absent — and that is the OFF SWITCH: the revocation
# sweep below runs unconditionally, so with no `want` every jump is stale and the
# hole is torn down on the next tick. Keeping the sweep inside the "configured"
# branch would have made deleting the seam.env lines *orphan* the rule instead of
# closing it — an off switch that leaves the door open is worse than none.
want=""
if [ -n "$P2P6_IID" ] && [ -n "$P2P6_PORT" ]; then
    want="${net%::/64}:$P2P6_IID"     # <current /64>:<ops-owned IID>
fi

# Revoke any jump aimed at an address we no longer hold — prefix rotated, IID
# changed, or the pinhole switched off entirely. This is the half that makes the
# hole close by itself; without it a rotation leaves a permanent accept into a
# prefix somebody else now owns.
ip6tables -w -S FORWARD 2>/dev/null | grep -- '-j RT10_P2P6$' | while read -r _rule; do
    if [ -n "$want" ]; then
        case "$_rule" in
            *" -d $want/128 "*) continue ;;
        esac
    fi
    ip6tables -w -D FORWARD ${_rule#-A FORWARD } 2>/dev/null \
        && event "p2p6 pinhole REVOKED (stale destination): ${_rule#-A FORWARD }"
done

if [ -n "$want" ]; then
    mark="p2p6 $want $P2P6_PORT $P2P6_WARN_SRC $P2P6_WARN_TOTAL"

    ip6tables -w -N RT10_P2P6      2>/dev/null || true
    ip6tables -w -N RT10_P2P6_LOGT 2>/dev/null || true
    ip6tables -w -N RT10_P2P6_LOGS 2>/dev/null || true

    # Rebuild only when the address or a threshold moved (marker encodes both).
    # An unchanged re-run must not flush the chain: connlimit's accounting lives
    # in it, and a flush every minute would reset the very counts we are here to
    # observe — the guard would then be structurally incapable of ever warning.
    if ! ip6tables -w -S RT10_P2P6 2>/dev/null | grep -qF -- "$mark"; then
        for _c in RT10_P2P6 RT10_P2P6_LOGT RT10_P2P6_LOGS; do
            ip6tables -w -F "$_c" 2>/dev/null || true
        done
        # Log prefixes are a published interface (ops may key on them) and are
        # DISTINCT from "route10.connlimit warn:/block:" on purpose — those four
        # strings are frozen and consumed by existing ops rules; feeding this
        # firehose into them would corrupt an alert that already works.
        # iptables caps --log-prefix at 29 chars; both fit with room to spare.
        ip6tables -w -A RT10_P2P6_LOGT -m limit --limit 6/hour --limit-burst 3 \
            -j LOG --log-prefix "route10.p2p6 warn: " --log-level warning 2>/dev/null || true
        # Per-source: gate on `recent` so one noisy peer cannot bury the rest,
        # then a shared rate backstop for a spoofed-source storm.
        ip6tables -w -A RT10_P2P6_LOGS -m recent --name p2p6s --rcheck --seconds 600 -j RETURN 2>/dev/null || true
        ip6tables -w -A RT10_P2P6_LOGS -m recent --name p2p6s --set 2>/dev/null || true
        ip6tables -w -A RT10_P2P6_LOGS -m limit --limit 60/hour --limit-burst 10 \
            -j LOG --log-prefix "route10.p2p6 srcwarn: " --log-level warning 2>/dev/null || true

        # Both tiers are non-terminating: they log and fall through to ACCEPT.
        ip6tables -w -A RT10_P2P6 \
            -m connlimit --connlimit-above "$P2P6_WARN_TOTAL" --connlimit-mask 128 --connlimit-daddr \
            -j RT10_P2P6_LOGT 2>/dev/null || true
        ip6tables -w -A RT10_P2P6 \
            -m connlimit --connlimit-above "$P2P6_WARN_SRC" --connlimit-mask 64 --connlimit-saddr \
            -j RT10_P2P6_LOGS 2>/dev/null || true
        ip6tables -w -A RT10_P2P6 -j ACCEPT 2>/dev/null || true
        ip6tables -w -A RT10_P2P6 -m comment --comment "$mark" -j RETURN 2>/dev/null || true
        event "p2p6 pinhole chain built: dst=$want port=$P2P6_PORT (warn-only: src>$P2P6_WARN_SRC/64, total>$P2P6_WARN_TOTAL)"
    fi

    # Stateful: only NEW is steered here; replies ride fw3's ESTABLISHED accept.
    for _proto in tcp udp; do
        if ! ip6tables -w -C FORWARD -i pppoe-wan3 -o br-lan -d "$want" \
                -p "$_proto" --dport "$P2P6_PORT" -m conntrack --ctstate NEW \
                -j RT10_P2P6 2>/dev/null; then
            ip6tables -w -I FORWARD 1 -i pppoe-wan3 -o br-lan -d "$want" \
                -p "$_proto" --dport "$P2P6_PORT" -m conntrack --ctstate NEW \
                -j RT10_P2P6 2>/dev/null \
                && event "p2p6 pinhole OPEN: $_proto/$P2P6_PORT -> $want"
        fi
    done
fi
exit 0
