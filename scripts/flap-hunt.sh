#!/bin/sh
# flap-hunt.sh — sub-minute event detector for wan3 / eth4 / stick
#
# Sibling to odi-health.sh. odi-health samples every 5 min and trends thermals,
# DDM, RTT, PPP state — perfect for "is the link healthy on average". But its
# cadence misses brief events: ICMP-loss windows of ~5–8s, transient eth4 PHY
# flaps, mwan3 tracking-IP failures the Alta dashboard alerts on, single-burst
# CRC growth that triggers route-swd's mode flip.
#
# This script polls fast (2s) but writes ONLY EVENT lines + a periodic
# heartbeat — so the log stays small (target <5MB/week) and every line means
# something. The /tmp ancestor of this script logged every tick and ballooned;
# don't go back to that.
#
# Events captured:
#   eth4_carrier_flap   — kernel carrier_changes counter advanced (L1)
#   ppp_reconnect       — wan3 uptime regressed (PPP teardown + redial)
#   mwan_track_loss     — Alta mwan3 saw ping.alta.inc fail (≥1 lost)
#   mwan_score_low      — score dipped <10 (subset of track_loss, lighter alerts)
#   mwan_recovered      — score back to 10 after a drop
#   crc_growth          — RxFcsErr / RxAlignErr / RxOverFlow / RxRunt grew
#   stick_boa_fail      — stick /admin/login.asp non-200 in 1.5s
#
# Lessons from the 2026-05-28 session that this script bakes in:
#   - mwan3 'turn' is a heartbeat counter (~1/5s), NOT a state change. Ignored.
#   - Track-IP loss to ping.alta.inc != actual data drop. PPP and eth4 byte
#     counters keep ticking. We capture both so we can confirm post-hoc.
#   - The cli.pid lock means we must NEVER telnet probe for liveness. The Boa
#     /admin/login.asp returns 401 (unauth) or 200 — both prove the stick is
#     responsive without engaging /bin/login. See project_odi_cli_pid_lock.md.
#   - restore_mgmt() is needed only if ont_mgmt0 disappears (Alta cloud reload).
#     Same self-heal as odi-health.sh.
#
# Install: scp to /cfg/scripts/flap-hunt.sh, chmod +x
# Run:     nohup /cfg/scripts/flap-hunt.sh >/dev/null 2>&1 &
# Logs:    /cfg/scripts/flap-hunt.log (rotated at ~5MB → flap-hunt.log.1)
# Tail:    tail -F /cfg/scripts/flap-hunt.log
# Stop:    PID=$(ps w | grep flap-hunt.sh | grep -v grep | awk '{print $1}' | head -1); kill $PID

LOG=/cfg/scripts/flap-hunt.log
INTERVAL=2
HEARTBEAT_SEC=300        # one heartbeat line every 5 min (matches odi-health cadence)
MIB_SEC=30               # CRC counter sample every 30s
BOA_SEC=30               # stick Boa liveness every 30s
ROTATE_BYTES=5242880     # rotate at 5 MiB

ts() { date '+%Y-%m-%d %H:%M:%S'; }

restore_mgmt() {
    ip link show ont_mgmt0 >/dev/null 2>&1 && return 0
    [ -x /cfg/post-cfg.sh ] && /cfg/post-cfg.sh >/dev/null 2>&1
}

# Cheap log writer with size-based rotation. Keeps current + .1; drops older.
emit() {
    sz=$(wc -c < "$LOG" 2>/dev/null)
    if [ -n "$sz" ] && [ "$sz" -gt $ROTATE_BYTES ]; then
        mv "$LOG" "$LOG.1" 2>/dev/null
    fi
    echo "$@" >> "$LOG"
}

# Pull one nested value from mwan3 status JSON without a python heredoc per call.
# Use a single python invocation per cycle for all fields (cheaper).
read_mwan3() {
    ubus call mwan3 status 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); w=d["interfaces"]["wan3"]
    t=w["track_ip"][0] if w.get("track_ip") else {"latency":"-","packetloss":"-","status":"-"}
    print(w.get("score",-1), w.get("lost",-1), w.get("uptime",-1),
          t.get("latency","-"), t.get("packetloss","-"), t.get("status","-"))
except Exception:
    print("- - - - - -")
' 2>/dev/null
}

# ssdk MIB read — adapt to single-shot ssdk_sh
read_mib() {
    ( printf "mib counter get 5\nquit\n" | ssdk_sh 2>/dev/null ) \
      | tr '\n' ' ' | tr -d '<>'
}

mib_field() {
    # $1 = haystack, $2 = field name (e.g. RxFcsErr)
    echo "$1" | sed -n "s/.*$2  *\(0x[0-9a-fA-F]*\).*/\1/p"
}

emit "$(ts) start interval=${INTERVAL}s heartbeat=${HEARTBEAT_SEC}s pid=$$"

# Initial baseline
restore_mgmt
sleep 2

prev_ccnt=$(cat /sys/class/net/eth4/carrier_changes 2>/dev/null)
prev_pppup=$(ifstatus wan3 2>/dev/null | sed -n 's/.*"uptime": \([0-9]*\).*/\1/p')
prev_mscore=10
prev_mlost=0
mib_now=$(read_mib)
prev_crc=$(mib_field "$mib_now" RxFcsErr)
prev_align=$(mib_field "$mib_now" RxAlignErr)
prev_overflow=$(mib_field "$mib_now" RxOverFlow)
prev_runt=$(mib_field "$mib_now" RxRunt)

last_heartbeat=0
last_mib=0
last_boa=0
in_loss_window=0

# LCP state — populated by lcp-watch.sh sibling daemon.
# /var/run/.lcp-state.env exists only if lcp-watch is running.
LCP_STATE=/var/run/.lcp-state.env
prev_lcp_streak=0
prev_lcp_missed=0

emit "$(ts) baseline ccnt=$prev_ccnt pppup=$prev_pppup crc=$prev_crc align=$prev_align overflow=$prev_overflow runt=$prev_runt"

while true; do
    restore_mgmt

    # Read everything cheap once
    ccnt=$(cat /sys/class/net/eth4/carrier_changes 2>/dev/null)
    cup=$(cat /sys/class/net/eth4/carrier_up_count 2>/dev/null)
    cdwn=$(cat /sys/class/net/eth4/carrier_down_count 2>/dev/null)
    pppup=$(ifstatus wan3 2>/dev/null | sed -n 's/.*"uptime": \([0-9]*\).*/\1/p')
    set -- $(read_mwan3)
    mscore=$1; mlost=$2; muptime=$3; mlat=$4; mloss=$5; mstatus=$6

    NOW=$(ts)
    NOW_S=$(date +%s)

    # eth4 L1 flap
    if [ -n "$ccnt" ] && [ -n "$prev_ccnt" ] && [ "$ccnt" != "$prev_ccnt" ]; then
        emit "$NOW EVENT eth4_carrier_flap prev=$prev_ccnt now=$ccnt up=$cup down=$cdwn"
    fi

    # PPP reconnect (uptime regressed)
    if [ -n "$pppup" ] && [ -n "$prev_pppup" ] && [ "$pppup" -lt "$prev_pppup" ] 2>/dev/null; then
        emit "$NOW EVENT ppp_reconnect prev_uptime=$prev_pppup now_uptime=$pppup"
    fi

    # mwan3 tracking loss — enter window
    if [ "$in_loss_window" = "0" ] && [ -n "$mlost" ] && [ "$mlost" != "-" ] && [ "$mlost" != "0" ] 2>/dev/null; then
        in_loss_window=1
        loss_start=$NOW
        emit "$NOW EVENT mwan_track_loss_begin lost=$mlost score=$mscore lat=$mlat loss%=$mloss status=$mstatus"
    fi
    # ...escalating drop
    if [ "$in_loss_window" = "1" ] && [ -n "$mscore" ] && [ "$mscore" != "-" ] \
       && [ "$mscore" -lt "$prev_mscore" ] 2>/dev/null; then
        emit "$NOW EVENT mwan_score_drop prev=$prev_mscore now=$mscore lost=$mlost"
    fi
    # ...recovery
    if [ "$in_loss_window" = "1" ] && [ -n "$mlost" ] && [ "$mlost" = "0" ] && [ -n "$mscore" ] && [ "$mscore" = "10" ]; then
        in_loss_window=0
        # capture wan3 byte deltas during the loss window for sanity check
        rxb=$(cat /sys/class/net/pppoe-wan3/statistics/rx_bytes 2>/dev/null)
        txb=$(cat /sys/class/net/pppoe-wan3/statistics/tx_bytes 2>/dev/null)
        emit "$NOW EVENT mwan_recovered started=$loss_start ppp_rx=$rxb ppp_tx=$txb"
    fi

    # MIB sampling every $MIB_SEC
    if [ $((NOW_S - last_mib)) -ge $MIB_SEC ]; then
        last_mib=$NOW_S
        mib_now=$(read_mib)
        crc=$(mib_field "$mib_now" RxFcsErr)
        align=$(mib_field "$mib_now" RxAlignErr)
        overflow=$(mib_field "$mib_now" RxOverFlow)
        runt=$(mib_field "$mib_now" RxRunt)
        if [ -n "$crc" ] && [ "$crc" != "$prev_crc" ]; then
            emit "$NOW EVENT crc_growth field=RxFcsErr prev=$prev_crc now=$crc"
            prev_crc=$crc
        fi
        if [ -n "$align" ] && [ "$align" != "$prev_align" ]; then
            emit "$NOW EVENT crc_growth field=RxAlignErr prev=$prev_align now=$align"
            prev_align=$align
        fi
        if [ -n "$overflow" ] && [ "$overflow" != "$prev_overflow" ]; then
            emit "$NOW EVENT crc_growth field=RxOverFlow prev=$prev_overflow now=$overflow"
            prev_overflow=$overflow
        fi
        if [ -n "$runt" ] && [ "$runt" != "$prev_runt" ]; then
            emit "$NOW EVENT crc_growth field=RxRunt prev=$prev_runt now=$runt"
            prev_runt=$runt
        fi
    fi

    # LCP echo headroom — read state from lcp-watch.sh's env file every tick.
    # Cheap: small file, atomic mv from lcp-watch means we always read a
    # consistent snapshot.
    if [ -f "$LCP_STATE" ]; then
        # Source in a subshell-free way: sed into local assignments.
        # We only need three fields.
        cur_streak=$(sed -n 's/^LCP_CUR_STREAK=//p' "$LCP_STATE")
        max_streak=$(sed -n 's/^LCP_MAX_STREAK=//p' "$LCP_STATE")
        missed=$(sed -n 's/^LCP_MISSED=//p' "$LCP_STATE")

        # Streak increased: a new miss happened. Emit immediately.
        if [ -n "$cur_streak" ] && [ "$cur_streak" -gt "$prev_lcp_streak" ] 2>/dev/null; then
            emit "$NOW EVENT lcp_miss_streak=$cur_streak max_ever=$max_streak total_missed=$missed"
        fi
        # Streak cleared after being >0: a miss window closed without
        # crossing the disconnect threshold. Useful "we survived" signal.
        if [ -n "$cur_streak" ] && [ "$cur_streak" = "0" ] && [ "$prev_lcp_streak" -gt 0 ] 2>/dev/null; then
            emit "$NOW EVENT lcp_recovered after_streak=$prev_lcp_streak total_missed=$missed"
        fi
        [ -n "$cur_streak" ] && prev_lcp_streak=$cur_streak
        [ -n "$missed" ] && prev_lcp_missed=$missed
    fi

    # Stick Boa liveness every $BOA_SEC
    if [ $((NOW_S - last_boa)) -ge $BOA_SEC ]; then
        last_boa=$NOW_S
        t0=$(date +%s%N)
        code=$(curl --http0.9 -s -o /dev/null -w "%{http_code}" --interface 192.168.1.2 \
               --max-time 1.5 -u admin:admin http://192.168.1.1/admin/login.asp 2>/dev/null)
        t1=$(date +%s%N)
        ms=$(( (t1 - t0) / 1000000 ))
        # 200=ok, 401=auth-required (also alive). Anything else = degraded.
        if [ "$code" != "200" ] && [ "$code" != "401" ]; then
            emit "$NOW EVENT stick_boa_fail code=$code took=${ms}ms"
        fi
    fi

    # Heartbeat every $HEARTBEAT_SEC
    if [ $((NOW_S - last_heartbeat)) -ge $HEARTBEAT_SEC ]; then
        last_heartbeat=$NOW_S
        lcp_h=""
        if [ -f "$LCP_STATE" ]; then
            lcp_sent=$(sed -n 's/^LCP_SENT=//p' "$LCP_STATE")
            lcp_missed=$(sed -n 's/^LCP_MISSED=//p' "$LCP_STATE")
            lcp_max=$(sed -n 's/^LCP_MAX_STREAK=//p' "$LCP_STATE")
            lcp_h=" lcp_sent=$lcp_sent lcp_missed=$lcp_missed lcp_max_streak=$lcp_max"
        fi
        emit "$NOW heartbeat ccnt=$ccnt pppup=$pppup mscore=$mscore mlost=$mlost mlat=$mlat crc=$prev_crc${lcp_h}"
    fi

    prev_ccnt=$ccnt
    prev_pppup=$pppup
    [ -n "$mscore" ] && [ "$mscore" != "-" ] && prev_mscore=$mscore
    [ -n "$mlost" ]  && [ "$mlost" != "-" ]  && prev_mlost=$mlost

    sleep $INTERVAL
done
