#!/bin/sh
# Cutover monitor for ODI DFP-34X-2C3 → Alta Route10 (W2 cage).
# W2-ONLY since 2026-05-24 — L4 is the office switch 10G BiDi; we do not
# poll port 6 to avoid noise (it's production traffic, not the stick).
#
# Phases:
#   PHASE_0_NO_FIBER              — stick may be in W2 but no light yet
#   PHASE_1_FIBER_LIGHT_NO_LINK   — LOS clear but host-side SerDes not up
#   PHASE_2_W2_LINK_UP            — eth4 carrier up; PPPoE should dial via WAN3
#   PHASE_3_PPPOE_UP              — pppoe-wan3 / ppp* established
#
# Usage: /cfg/scripts/cutover-monitor.sh [duration_seconds]   (0 = forever, default)
#   /cfg/scripts/cutover-monitor.sh           # foreground, Ctrl-C to stop
#   /cfg/scripts/cutover-monitor.sh 0 &       # background, kill PID to stop
#
# Log file: /tmp/cutover-<timestamp>.log

DURATION=${1:-0}
TS=$(date +%Y%m%d-%H%M%S)
LOG=/tmp/cutover-$TS.log

ssdk() { printf '%s\nquit\n' "$1" | ssdk_sh 2>&1 | grep -vE 'SSDK Init|Welcome|^dev0|^$|^quit'; }
ts() { date -Is; }
emit() { echo "[$(ts)] $*" | tee -a "$LOG"; }

echo "==================================================================" | tee "$LOG"
echo "ODI stick cutover monitor (W2) — started $(ts)" | tee -a "$LOG"
echo "Log: $LOG" | tee -a "$LOG"
echo "Stick: ODI DFP-34X-2C3 in W2 (eth4), mgmt UI at http://192.168.1.1" | tee -a "$LOG"
echo "L4 (eth5) is office switch BiDi — NOT POLLED." | tee -a "$LOG"
echo "==================================================================" | tee -a "$LOG"

emit "INITIAL SNAPSHOT"
{
    echo "  W2/eth4 link:    $(ip -br link | awk '$1=="eth4"{print $2}')  speed: $(ethtool eth4 2>/dev/null | awk '/Speed:/{print $2}')"
    echo "  ssdk port 5 (W2): $(ssdk 'port linkstatus get 5' | awk -F: '/Status/{print $2}' | tr -d ' ') / $(ssdk 'port interfaceMode get 5' | awk -F: '/Mode/{print $2}' | tr -d ' ') / txmac=$(ssdk 'port txmacstatus get 5' | awk -F: '/Value/{print $2}' | tr -d ' ') / rxmac=$(ssdk 'port rxmacstatus get 5' | awk -F: '/Value/{print $2}' | tr -d ' ')"
    echo "  LOS W2 gpio25:   $(awk '/^ gpio25 /{print $3}' /sys/kernel/debug/gpio)"
    echo "  Default route:   $(ip route show default | head -1)"
    echo "  WAN1 (eth3):     $(ip -br addr show eth3 | awk '{$1=""; print $0}')"
    echo "  WAN3 (eth4):     $(ip -br addr show eth4 | awk '{$1=""; print $0}')"
    echo "  PPPoE ifaces:    $(ip -br link | grep -E '^ppp|pppoe' || echo '(none)')"
    echo "  Stick MAC seen:  $(ip neigh show 192.168.1.1 2>/dev/null | awk '{print $5}' || echo '(not yet ARPed)')"
} | tee -a "$LOG"
echo "" | tee -a "$LOG"

current_phase() {
    local w2_carrier w2_los ppp_up
    w2_carrier=$(ip -br link | awk '$1=="eth4"{print $2}')
    w2_los=$(awk '/^ gpio25 /{print $3}' /sys/kernel/debug/gpio)
    ppp_up=$(ip -br link | grep -E 'pppoe-wan3|^ppp[0-9]' | grep -i UP)
    if [ -n "$ppp_up" ]; then echo "PHASE_3_PPPOE_UP"
    elif [ "$w2_carrier" = "UP" ]; then echo "PHASE_2_W2_LINK_UP"
    elif [ "$w2_los" = "low" ]; then echo "PHASE_1_FIBER_LIGHT_NO_LINK"
    else echo "PHASE_0_NO_FIBER"
    fi
}

start=$(date +%s)
last=""
last_phase=""

while true; do
    [ $DURATION -gt 0 ] && [ $(($(date +%s) - start)) -ge $DURATION ] && break

    w2_los=$(awk '/^ gpio25 /{print $3}' /sys/kernel/debug/gpio)
    w2_link=$(printf 'port linkstatus get 5\nquit\n' | ssdk_sh 2>&1 | awk -F: '/Status/{print $2}' | tr -d ' ' | head -1)
    w2_tx=$(printf 'port txmacstatus get 5\nquit\n' | ssdk_sh 2>&1 | awk -F: '/Value/{print $2}' | tr -d ' ' | head -1)
    w2_rx=$(printf 'port rxmacstatus get 5\nquit\n' | ssdk_sh 2>&1 | awk -F: '/Value/{print $2}' | tr -d ' ' | head -1)
    w2_car=$(ip -br link | awk '$1=="eth4"{print $2}')
    w2_speed=$(ethtool eth4 2>/dev/null | awk '/Speed:/{print $2}')
    w2_mode=$(printf 'port interfaceMode get 5\nquit\n' | ssdk_sh 2>&1 | awk -F: '/Mode/{print $2}' | tr -d ' ' | head -1)
    stick=$(ip neigh show 192.168.1.1 2>/dev/null | awk '{print $4" "$5}' | head -1)
    wan3_addr=$(ip -br addr show eth4 2>/dev/null | awk '{print $3}')
    ppp_iface=$(ip -br link | awk '/pppoe-wan|^ppp[0-9]/{print $1":"$2}' | head -3 | tr '\n' ' ')
    defroute=$(ip route show default | head -1 | awk '{print $3" via "$5}')

    state="W2[los=$w2_los link=$w2_link mode=$w2_mode tx=$w2_tx rx=$w2_rx car=$w2_car spd=$w2_speed] stick[$stick] wan3_ip[$wan3_addr] ppp[$ppp_iface] gw[$defroute]"

    if [ "$state" != "$last" ]; then
        emit "$state"
        last="$state"
        phase=$(current_phase)
        if [ "$phase" != "$last_phase" ]; then
            emit ">>> PHASE TRANSITION: $last_phase -> $phase"
            case "$phase" in
                PHASE_1_FIBER_LIGHT_NO_LINK) emit ">>> Light at stick rx — waiting on SerDes / GPON range" ;;
                PHASE_2_W2_LINK_UP) emit ">>> W2 link up — PPPoE on WAN3 should authenticate shortly" ;;
                PHASE_3_PPPOE_UP)
                    emit ">>> PPPoE SESSION ESTABLISHED on stick"
                    ip -br addr show pppoe-wan3 2>/dev/null | tee -a "$LOG"
                    ip route show default | tee -a "$LOG"
                    ;;
            esac
            last_phase="$phase"
        fi
        recent_swd=$(logread 2>/dev/null | grep route-swd | tail -2)
        [ -n "$recent_swd" ] && echo "    route-swd: $recent_swd" | tee -a "$LOG"
    fi
    sleep 2
done

emit "monitor exiting"
