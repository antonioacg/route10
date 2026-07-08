#!/bin/sh
# lcp-watch.sh — PPPoE LCP echo headroom telemetry for `pppoe-wan3`.
#
# Why this exists:
#   pppd's `lcp-echo-failure 5 lcp-echo-interval 5` only logs at the moment
#   it terminates ("No response to 5 echo-requests"). There's no in-flight
#   counter for "we got within N of disconnect" — the link looks fine right
#   up until pppd kills it. After the 2026-05-28 22:16 BNG outage we know
#   exactly what a missed-echo streak feels like; we want to see streaks
#   accumulate *before* they hit 5.
#
# How it works:
#   - tcpdump on `pppoe-wan3` filters protocol 0xc021 (LCP only). With
#     `lcp-echo-adaptive` enabled, real traffic moments produce ZERO LCP
#     activity → the listener is near-idle by design.
#   - Detection is *event-driven*, not time-based: on every Echo-Request, if
#     the *previous* Echo-Request was never matched by an Echo-Reply, we
#     count a miss. On Echo-Reply, we clear the pending state and reset the
#     current streak.
#   - This avoids any need for periodic timers (which are painful in ash),
#     and naturally handles the adaptive case: when no echoes are flowing,
#     no events fire, no false miss counts.
#
# State output: /var/run/.lcp-state.env — overwritten atomically each update.
#   Five-line key=value file (~150 bytes). Consumed by flap-hunt.sh.
#   Counters persist across PPP reconnects (we restore from file on restart).
#
# Storage footprint: state file size is constant. No logs written. tcpdump
# stdout is consumed line-by-line — never persisted, never spooled.
#
# Resilience: if pppoe-wan3 disappears (PPP reconnect, wan3 ifdown, stick
# reboot), tcpdump exits and we re-attach when the interface returns.
#
# Install: scp to /cfg/scripts/lcp-watch.sh, chmod +x. Launched by post-cfg.sh.
# Stop:    PID=$(pgrep -f lcp-watch.sh | head -1); kill $PID
# Inspect: cat /var/run/.lcp-state.env

STATE=/var/run/.lcp-state.env
TMP="$STATE.new"

# Counters (loaded from file if present, else start fresh)
LCP_SENT=0
LCP_REPLIED=0
LCP_MISSED=0
LCP_CUR_STREAK=0
LCP_MAX_STREAK=0
LCP_LAST_MISS_TS=0
[ -f "$STATE" ] && . "$STATE"

write_state() {
    # Atomic: write to .new then rename. Reader sees either old or new,
    # never a torn write.
    {
        echo "LCP_SENT=$LCP_SENT"
        echo "LCP_REPLIED=$LCP_REPLIED"
        echo "LCP_MISSED=$LCP_MISSED"
        echo "LCP_CUR_STREAK=$LCP_CUR_STREAK"
        echo "LCP_MAX_STREAK=$LCP_MAX_STREAK"
        echo "LCP_LAST_MISS_TS=$LCP_LAST_MISS_TS"
        echo "LCP_LAST_UPDATE=$(date +%s)"
    } > "$TMP"
    mv "$TMP" "$STATE"
}

# Write initial state so flap-hunt.sh has something to read immediately.
write_state

while true; do
    # Wait for pppoe-wan3 to exist before starting tcpdump. Avoids tcpdump
    # spamming "No such device" during PPP reconnect windows.
    while ! ip link show pppoe-wan3 >/dev/null 2>&1; do
        sleep 5
    done

    # Reload state inside the loop in case the previous tcpdump's subshell
    # lost variable updates (they shouldn't — write_state persists everything
    # — but defensive).
    [ -f "$STATE" ] && . "$STATE"

    # On PPP reconnect, the current streak from a previous session is no
    # longer meaningful (pppd starts fresh LCP). Don't reset MAX_STREAK
    # though — that's the all-time headroom watermark we care about.
    LCP_CUR_STREAK=0
    pending=0
    write_state

    # tcpdump:
    #   -i pppoe-wan3       PPP iface
    #   -p                  no promisc (irrelevant on PPP but cheap)
    #   -nn                 no DNS / no service lookups
    #   -l                  line-buffered stdout (so our loop sees lines promptly)
    #   'proto 0xc021'      LCP only — keeps the byte stream tiny
    #
    # The body of `while read` runs in a subshell because of the pipe, but
    # we write_state on every relevant event, so state lives in the file.
    tcpdump -i pppoe-wan3 -p -nn -l 'proto 0xc021' 2>/dev/null | while read line; do
        case "$line" in
            *"Echo-Request"*)
                LCP_SENT=$((LCP_SENT + 1))
                if [ "$pending" = "1" ]; then
                    # The previous Echo-Request was never answered before
                    # this new one fired → count it as a miss.
                    LCP_MISSED=$((LCP_MISSED + 1))
                    LCP_CUR_STREAK=$((LCP_CUR_STREAK + 1))
                    if [ "$LCP_CUR_STREAK" -gt "$LCP_MAX_STREAK" ]; then
                        LCP_MAX_STREAK=$LCP_CUR_STREAK
                    fi
                    LCP_LAST_MISS_TS=$(date +%s)
                fi
                pending=1
                write_state
                ;;
            *"Echo-Reply"*)
                LCP_REPLIED=$((LCP_REPLIED + 1))
                pending=0
                LCP_CUR_STREAK=0
                write_state
                ;;
        esac
    done

    # tcpdump exited — pppoe-wan3 went away. Brief pause before re-attaching.
    sleep 2
done
