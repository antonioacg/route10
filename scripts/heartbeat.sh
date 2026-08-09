#!/bin/sh
# heartbeat.sh — external dead-man "beat B" (route10 → WAN → ntfy.sh).
#
# WHY THIS EXISTS. ops runs an external dead-man: Alertmanager's Watchdog beats
# to an ntfy topic, and Uptime Kuma on an off-site edge box pages if the beat
# stops. That beat ("A") travels opi5pro → LAN → route10 → WAN, so SIX very
# different faults collapse into one indistinguishable signal — cluster dead,
# router dead, WAN down, LAN dead, ntfy down, alerting chain broken. This script
# is beat "B": the same destination over OUR OWN WAN path, never touching
# opi5pro. Together they carry one bit that decides whose problem it is:
#     A stops, B continues  → their cluster or its alerting (router is fine)
#     both stop             → router, WAN, or ntfy
# Agreed with ops 2026-08-09 (seam thread dead-man-coverage); cadence + poll
# window + body assertion are recorded in ops/NETWORK-CONTRACT.md.
#
# ⚠ THE DESIGN RULE, and it is the whole point:
#   A HEALTH COMPUTATION DECIDES WHAT THE MESSAGE SAYS, NEVER WHETHER IT IS SENT.
# The obvious implementation — "beat only while healthy" — converts a BUG IN THE
# HEALTH LOGIC into a page saying everything is dead: a monitoring bug wearing an
# outage costume. So the send below is unconditional, always, and the health
# verdict rides in the BODY as lan_ok=1|0|unknown. If the inputs are missing or
# stale we emit `unknown` — never silence. ops keys on the healthy assertion:
#     beat + lan_ok=1        → router and LAN both fine
#     beat + lan_ok=0        → router alive, LAN dead   (page route10)
#     beat + lan_ok=unknown  → router alive, our health logic degraded (low prio)
#     no beat                → router, WAN, or ntfy
#
# WHAT lan_ok ASSERTS. br-lan holding a v4 address AND br-lan rx packets
# advancing — the same two inputs as obs-collect's wedge tripwire, chosen
# because they are the signals the 2026-08-08 IP-stack wedge actually moved
# (rx froze at zero with carrier up). Deliberately NOT a new probe: under a
# wedge is the worst possible time to be trusting a code path nothing has
# exercised. Note this is a LAN assertion only — it says nothing about the WAN,
# which the beat's own arrival already proves.
#
# ⚠ NOT a case-4 splitter. In the only wedge we have measured, br-lan, the eth4
# mgmt MACVLAN and PPPoE died TOGETHER, so B would have stopped alongside A and
# "router/WAN/ntfy" would have been the CORRECT reading. lan_ok earns its place
# as a diagnostic bonus (eth4 is a physically separate port, so a LAN-only fault
# sparing the WAN is a real shape) — it is NOT the justification for the beat.
#
# IPv6 FIRST, deliberately. curl's happy-eyeballs prefers v6 and we do NOT pass
# -4. Our v6 is native with no CGNAT; the v4 path has a demonstrated brownout
# mode (2026-08-08: ~5 min of ISP CGNAT table exhaustion with our own probes
# clean at 13.8 ms/0% loss). Beating over v4 would eventually manufacture the
# 3am "everything is dead" page this system exists to prevent. v4 still serves
# as automatic fallback if v6 is the broken thing.
#
# The topic IS the credential (ntfy has no account/token), so it lives ONLY in
# /cfg/seam.env — never in git, never in NETWORK-CONTRACT.md. Absent ⇒ clean
# no-op (warn hourly), same pattern as TS_LOGIN_URL / LAN_DNS4.
#
# Install: scp to /cfg/scripts/heartbeat.sh, chmod +x
# Cron:    */2 * * * *  (reinstalled each boot by post-cfg.sh — / is tmpfs)
# Log:     /cfg/scripts/heartbeat.log

LOG=/cfg/scripts/heartbeat.log
RXSTATE=/var/run/.heartbeat.rx
FAILSTATE=/var/run/.heartbeat.failing
NOTOPIC=/var/run/.heartbeat.notopic

obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init heartbeat "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

[ -f /cfg/seam.env ] && . /cfg/seam.env
: "${NTFY_BASE:=https://ntfy.sh}"

# No topic ⇒ nothing to beat to. Warn at most hourly: this is a real gap (ops
# cannot monitor a beat we never send) but it is the operator's out-of-band step,
# so it must be visible without becoming a 2-minute log flood.
if [ -z "$NTFY_HEARTBEAT_TOPIC" ]; then
    _last=$(cat "$NOTOPIC" 2>/dev/null); case "$_last" in *[!0-9]*|'') _last=0 ;; esac
    if [ $(( $(date +%s) - _last )) -ge 3600 ]; then
        date +%s > "$NOTOPIC"
        warn "NTFY_HEARTBEAT_TOPIC unset in /cfg/seam.env — dead-man beat B is NOT being sent (operator must mint the topic)"
    fi
    exit 0
fi

# ── health verdict: what the message SAYS (never whether it is sent) ─────────
# Any failure to determine a component yields `unknown`, which is strictly more
# informative than a confident wrong answer and cannot page ops for an outage.
lan_ok=unknown
ADDR=$(ip -4 addr show br-lan 2>/dev/null | grep -c 'inet ')
RX=$(cat /sys/class/net/br-lan/statistics/rx_packets 2>/dev/null)
PREV=$(cat "$RXSTATE" 2>/dev/null)
case "$RX" in ''|*[!0-9]*) RX='' ;; esac
case "$PREV" in ''|*[!0-9]*) PREV='' ;; esac
[ -n "$RX" ] && echo "$RX" > "$RXSTATE"

if [ -n "$RX" ] && [ -n "$PREV" ] && [ "$ADDR" -gt 0 ] 2>/dev/null; then
    # Counters only ever climb (or reset to a smaller value on reboot, which is
    # also "moving"); frozen rx with the address still present is the wedge shape.
    if [ "$RX" -ne "$PREV" ]; then lan_ok=1; else lan_ok=0; fi
elif [ -n "$RX" ] && [ -n "$PREV" ] && [ "$ADDR" = 0 ]; then
    lan_ok=0                      # br-lan lost its v4 address — unambiguously bad
fi
# else: first run after boot (no PREV) or unreadable counter ⇒ stays `unknown`

UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
PPP=$(ifstatus wan3 2>/dev/null | grep -c '"up": true')
[ "$PPP" = 1 ] && PPP=up || PPP=down

BODY="route10 beat lan_ok=$lan_ok up=${UP:-?} ppp=$PPP"

# ── send: UNCONDITIONAL. Never gate this on the verdict above. ───────────────
# -f so an HTTP error is a failure, not a silently-swallowed 500. Warn on the
# TRANSITION to failing and event on recovery (never every cycle): a send failure
# is usually a WAN outage, during which ops is already being paged by the missing
# beat — but we must not depend on THEIR silence to learn our own emitter broke.
if curl -fsS -m 10 -d "$BODY" "$NTFY_BASE/$NTFY_HEARTBEAT_TOPIC" >/dev/null 2>&1; then
    [ -f "$FAILSTATE" ] && { rm -f "$FAILSTATE"; event "heartbeat send recovered ($BODY)"; }
else
    [ -f "$FAILSTATE" ] || { touch "$FAILSTATE"; warn "heartbeat send FAILED (WAN down? topic rotated?) — ops dead-man will read this as home dark"; }
fi

exit 0
