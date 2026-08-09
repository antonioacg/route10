#!/bin/sh
# heartbeat.sh — external dead-man for "Router + internet (route10)".
#
# WHY THIS EXISTS. ops runs an external dead-man. Their beat, "Home server +
# alerting (opi5pro)", is sent by Alertmanager itself and travels
# opi5pro → LAN → route10 → WAN, so SIX very different faults collapse into one
# indistinguishable signal — cluster dead, router dead, WAN down, LAN dead,
# receiver down, alerting chain broken. This script is the complement: the same
# destination over OUR OWN WAN path, never touching opi5pro. Together they carry
# one bit that decides whose problem it is:
#     theirs stops, ours continues → their cluster or its alerting (router fine)
#     both stop                    → router, WAN, or the receiver
# Agreed with ops 2026-08-09 (seam thread dead-man-coverage); cadence + grace +
# body assertion are recorded in ops/NETWORK-CONTRACT.md.
#
# NAMING: the old "beat A / beat B" shorthand is retired. A/B carries no
# information and destroys the only thing the pair is for — at 1am "beat A is
# down" needs a lookup nobody performs correctly under pressure. Say which box
# and which capability, always.
#
# ⚠ THE DESIGN RULE, and it is the whole point:
#   A HEALTH COMPUTATION DECIDES WHAT THE MESSAGE SAYS, NEVER WHETHER IT IS SENT.
# The obvious implementation — "beat only while healthy" — converts a BUG IN THE
# HEALTH LOGIC into a page saying everything is dead: a monitoring bug wearing an
# outage costume. So the alive ping below is unconditional, always, and the
# health verdict selects only WHICH endpoint of the LAN check we hit.
#
# TWO CHECKS, not one. healthchecks.io has no keyword matching (Kuma did), so a
# single ping URL cannot carry both signals. Repointing both at one URL would
# leave the LAN check green-by-construction — it would still render, and mean
# nothing. Mapping agreed with ops 2026-08-09:
#     lan_ok=1        → POST <lan>          success
#     lan_ok=0        → POST <lan>/fail     pages IMMEDIATELY (no poll wait)
#     lan_ok=unknown  → POST <lan>/log      event recorded, status unchanged
# /log is what preserves the three-way semantics: `unknown` means "our health
# logic is degraded", which must be visible but must never page. Kuma could only
# render it as not-lan_ok=1, i.e. indistinguishable from a real LAN failure.
#
# WHAT lan_ok ASSERTS. br-lan holding a v4 address AND br-lan rx packets
# advancing — the same two inputs as obs-collect's wedge tripwire, chosen
# because they are the signals the 2026-08-08 IP-stack wedge actually moved
# (rx froze at zero with carrier up). Deliberately NOT a new probe: under a
# wedge is the worst possible time to be trusting a code path nothing has
# exercised. Note this is a LAN assertion only — it says nothing about the WAN,
# which the beat's own arrival already proves.
#
# ⚠ IT CANNOT REPORT OUR OWN DEATH. A signal published BY a thing cannot report
# that thing's death: lan_ok rides inside this beat, so in the 2026-08-08 shape
# (route10's IP stack dark while the switch ASIC kept forwarding) nothing is sent
# at all and "router dark / LAN alive" is indistinguishable from a power cut.
# Absence detection fires, but absence is ambiguous. Distinguishing it needs an
# observer that is NOT route10 — ops is building one on opi5pro, comparing
# ".1 unreachable AND >=1 LAN peer still reachable". Do not add a self-check here
# and imagine it closes that gap; it cannot, by construction.
#
# IPv6 FIRST, deliberately. curl's happy-eyeballs prefers v6 and we do NOT pass
# -4. Our v6 is native with no CGNAT; the v4 path has a demonstrated brownout
# mode (2026-08-08: ~5 min of ISP CGNAT table exhaustion with our own probes
# clean at 13.8 ms/0% loss). Beating over v4 would eventually manufacture the
# 3am "everything is dead" page this system exists to prevent. v4 still serves
# as automatic fallback if v6 is the broken thing.
#
# ⚠ THE PING URL IS THE CREDENTIAL. The UUID in a healthchecks.io ping URL is a
# bearer token — anyone holding it can forge beats, which makes the dead-man
# report "alive" while we are dark. The predecessor (an ntfy topic, same class)
# leaked through Uptime Kuma notification click-throughs, because Kuma sets a
# notification's click target to the monitor's own polled URL. So:
#   - URLs live ONLY in /cfg/seam.env (0600). Never git, never NETWORK-CONTRACT,
#     never the seam channel. Operator carries them out of band.
#   - NEVER pass a URL as a curl argument: `ps w` on this box shows full command
#     lines. We hand it to curl as a config on STDIN (`curl -K -`), so it is in
#     neither argv nor on disk. A URL cannot be moved into a header the way a
#     bearer token can, so stdin is the only place left.
#   - Absent ⇒ clean no-op (warn hourly), same pattern as TS_LOGIN_URL.
#
# Install: scp to /cfg/scripts/heartbeat.sh, chmod +x
# Cron:    */2 * * * *  (reinstalled each boot by post-cfg.sh — / is tmpfs)
# Log:     /cfg/scripts/heartbeat.log

LOG=/cfg/scripts/heartbeat.log
RXSTATE=/var/run/.heartbeat.rx
FAILSTATE=/var/run/.heartbeat.failing
NOURL=/var/run/.heartbeat.nourl

obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init heartbeat "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

[ -f /cfg/seam.env ] && . /cfg/seam.env

# No URLs ⇒ nothing to beat to. Warn at most hourly: this is a real gap (ops
# cannot monitor a beat we never send) but it is the operator's out-of-band step,
# so it must be visible without becoming a 2-minute log flood.
if [ -z "$HC_URL_ALIVE" ] || [ -z "$HC_URL_LAN" ]; then
    _last=$(cat "$NOURL" 2>/dev/null); case "$_last" in *[!0-9]*|'') _last=0 ;; esac
    if [ $(( $(date +%s) - _last )) -ge 3600 ]; then
        date +%s > "$NOURL"
        warn "HC_URL_ALIVE/HC_URL_LAN unset in /cfg/seam.env — dead-man is NOT being sent (operator must add both ping URLs out of band)"
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

# URL via stdin config so it never reaches argv (see credential note above).
# -f so an HTTP error is a failure rather than a silently-swallowed 500. The body
# is not secret and may stay an argument.
#
# ⚠ The no-argv guarantee depends on `printf` being a SHELL BUILTIN — verified on
# this build (`type printf` → shell builtin; there is a /usr/bin/printf symlink to
# busybox that the shell never reaches). A builtin does not fork, so the URL exists
# only in this shell's memory. Calling /usr/bin/printf explicitly, or switching to
# any external helper, silently puts the credential back into `ps` output.
hc_ping() {
    printf 'url = "%s"\n' "$1" | curl -K - -fsS -m 10 --data-binary "$2" >/dev/null 2>&1
}

# ── send: the alive ping is UNCONDITIONAL. Never gate it on the verdict. ─────
# Warn on the TRANSITION to failing and event on recovery (never every cycle): a
# send failure is usually a WAN outage, during which ops is already being paged
# by the missing beat — but we must not depend on THEIR silence to learn that our
# own emitter broke.
if hc_ping "$HC_URL_ALIVE" "$BODY"; then
    [ -f "$FAILSTATE" ] && { rm -f "$FAILSTATE"; event "heartbeat send recovered ($BODY)"; }
    alive=ok
else
    [ -f "$FAILSTATE" ] || { touch "$FAILSTATE"; warn "heartbeat send FAILED (WAN down? URL rotated?) — ops dead-man will read this as home dark"; }
    alive=fail
fi

# ── LAN check: the verdict selects the endpoint, not whether we send ─────────
case "$lan_ok" in
    1) lan_target="$HC_URL_LAN"      ;;
    0) lan_target="$HC_URL_LAN/fail" ;;
    *) lan_target="$HC_URL_LAN/log"  ;;
esac

# Only worth reporting when the alive ping SUCCEEDED: if transport is down both
# fail together and the warn above already says so — logging twice would imply
# two faults. A LAN ping failing alone is genuinely odd (same host, same instant)
# and usually means the LAN check's own URL is wrong.
if ! hc_ping "$lan_target" "$BODY" && [ "$alive" = ok ]; then
    err "LAN check ping failed while the alive ping succeeded — HC_URL_LAN may be wrong (lan_ok=$lan_ok)"
fi

exit 0
