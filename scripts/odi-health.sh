#!/bin/sh
# odi-health.sh — overnight + daytime health monitoring
# Captures every $INTERVAL seconds:
#   - Route10 WAN3 PPPoE state, IPv4, carrier, speed
#   - Ping RTT to 1.1.1.1
#   - Route10's 13 IPQ9574 thermal zones (tsens_tz_sensor3..15)
#   - L4 BiDi SFP+ DDM (real): Temp, Vcc, Tx bias, Tx power, Rx power
#   - W2 ODI stick DDM (temp/Vcc/Tx-bias/Tx-power/Rx-power) — read from cache
#     populated by daemon-odi-w2-ddm.sh (Boa HTTP → SFF-8472 i2c slave write).
#     Single Boa session lives in the daemon, not here. See reference_odi_ddm_blocker.md.
#
# ONU registration state is not collected here — if WAN3 PPPoE is up and ping
# works, the ONU is registered (O5). Saves us a telnet probe that was the only
# place this script could trigger a cli.pid wedge (see project_odi_cli_pid_lock.md).
#
# Install: scp to /cfg/scripts/odi-health.sh, chmod +x
# Run:     nohup /cfg/scripts/odi-health.sh >/dev/null 2>&1 &
# Logs:    /cfg/scripts/odi-health.log
# Stop:    PID=$(ps w | grep odi-health.sh | grep -v grep | awk '{print $1}' | head -1); kill $PID

LOG=/cfg/scripts/odi-health.log
INTERVAL=300

# Add a syslog copy (route10.odi-health) alongside the file log. no-op default so
# a missing lib can't break the daemon; the lib overrides obs_syslog.
obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init odi-health "$LOG"

restore_mgmt() {
    # Mgmt path is now an Alta-blessed MACVLAN child (ont_mgmt0 on eth4),
    # set up persistently via /cfg/post-cfg.sh. Self-heal only if missing.
    ip link show ont_mgmt0 >/dev/null 2>&1 && return 0
    [ -x /cfg/post-cfg.sh ] && /cfg/post-cfg.sh >/dev/null 2>&1
}

# Read all 13 thermal zones, return "tz0=50.5,tz1=50.8,..." in °C
read_route10_thermals() {
    OUT=""
    for f in /sys/class/thermal/thermal_zone*/temp; do
        N=$(echo $f | grep -oE 'zone[0-9]+' | grep -oE '[0-9]+')
        T=$(cat $f 2>/dev/null)
        if [ -n "$T" ]; then
            C=$(awk "BEGIN{printf \"%.1f\", $T/1000}")
            OUT="${OUT}tz${N}=${C} "
        fi
    done
    # Compact max temp summary too
    MAX=$(cat /sys/class/thermal/thermal_zone*/temp | awk '{if($1>m)m=$1}END{printf "%.1f", m/1000}')
    echo "tz_max=${MAX} ${OUT}"
}

# Read L4 BiDi SFP+ DDM from i2c bus 0 0x51 (SFF-8472 page A2)
read_l4_ddm() {
    # Temp bytes 0x60-0x61 (signed int16, 1/256 C)
    HI=$(i2cget -y 0 0x51 0x60 2>/dev/null); LO=$(i2cget -y 0 0x51 0x61 2>/dev/null)
    if [ -n "$HI" ] && [ -n "$LO" ]; then
        TEMP=$(awk "BEGIN{v=($HI*256)+$LO; if(v>32767)v-=65536; printf \"%.1f\", v/256}")
    else TEMP="?"; fi
    # Vcc bytes 0x62-0x63 (uint16, 100µV → V)
    HI=$(i2cget -y 0 0x51 0x62 2>/dev/null); LO=$(i2cget -y 0 0x51 0x63 2>/dev/null)
    if [ -n "$HI" ] && [ -n "$LO" ]; then
        VCC=$(awk "BEGIN{v=($HI*256)+$LO; printf \"%.2f\", v/10000}")
    else VCC="?"; fi
    # Tx bias bytes 0x64-0x65 (uint16, 2µA → mA)
    HI=$(i2cget -y 0 0x51 0x64 2>/dev/null); LO=$(i2cget -y 0 0x51 0x65 2>/dev/null)
    if [ -n "$HI" ] && [ -n "$LO" ]; then
        TXBIAS=$(awk "BEGIN{v=($HI*256)+$LO; printf \"%.2f\", v*0.002}")
    else TXBIAS="?"; fi
    # Tx power bytes 0x66-0x67 (uint16, 0.1µW → dBm)
    HI=$(i2cget -y 0 0x51 0x66 2>/dev/null); LO=$(i2cget -y 0 0x51 0x67 2>/dev/null)
    if [ -n "$HI" ] && [ -n "$LO" ]; then
        TXDBM=$(awk "BEGIN{v=($HI*256)+$LO; if(v>0) printf \"%.2f\", 10*log(v*0.0001/1)/log(10); else printf \"-Inf\"}")
    else TXDBM="?"; fi
    # Rx power bytes 0x68-0x69 (uint16, 0.1µW → dBm)
    HI=$(i2cget -y 0 0x51 0x68 2>/dev/null); LO=$(i2cget -y 0 0x51 0x69 2>/dev/null)
    if [ -n "$HI" ] && [ -n "$LO" ]; then
        RXDBM=$(awk "BEGIN{v=($HI*256)+$LO; if(v>0) printf \"%.2f\", 10*log(v*0.0001/1)/log(10); else printf \"-Inf\"}")
    else RXDBM="?"; fi
    echo "L4_temp_C=${TEMP} L4_vcc_V=${VCC} L4_txbias_mA=${TXBIAS} L4_tx_dBm=${TXDBM} L4_rx_dBm=${RXDBM}"
}

# Read W2 ODI stick DDM from /var/run/w2-ddm.env — populated every 5s by
# daemon-odi-w2-ddm.sh (Boa /status_pon.asp → SFF-8472 i2c slave write + caches).
# Single point of Boa polling — we don't curl Boa from here too.
# See reference_odi_ddm_blocker.md for the full architecture rationale.
probe_w2_ddm() {
    if [ ! -f /var/run/w2-ddm.env ]; then
        printf 'W2_temp_C=? W2_vcc_V=? W2_txbias_mA=? W2_tx_dBm_boa=? W2_rx_dBm_boa=? W2_cache=absent'
        return
    fi
    . /var/run/w2-ddm.env
    AGE=$(( $(date +%s) - ${W2_TS:-0} ))
    if [ "$AGE" -gt 60 ]; then
        printf 'W2_temp_C=? W2_vcc_V=? W2_txbias_mA=? W2_tx_dBm_boa=? W2_rx_dBm_boa=? W2_cache_stale=%ss' "$AGE"
        return
    fi
    printf 'W2_temp_C=%s W2_vcc_V=%s W2_txbias_mA=%s W2_tx_dBm_boa=%s W2_rx_dBm_boa=%s' \
        "$W2_T" "$W2_V" "$W2_A" "$W2_P" "$W2_R"
}

# Switch MIB Rx error counters on port 5 (eth4 / W2 path) — folded in from the
# retired flap-hunt.sh. Growth in FcsErr/Align/OverFlow/Runt is the L2 signature
# of a degrading fibre/SFP (dirty connector, aging optics — cf. the Rx-power drop
# in reference_odi_ddm_thresholds). Nothing else reads these; counters are
# cumulative so any change = growth. Cheap: one ssdk_sh call per 5-min cycle.
_read_mib()  { ( printf 'mib counter get 5\nquit\n' | ssdk_sh 2>/dev/null ) | tr '\n' ' ' | tr -d '<>'; }
_mib_field() { echo "$1" | sed -n "s/.*$2  *\(0x[0-9a-fA-F]*\).*/\1/p"; }
read_switch_crc() {
    m=$(_read_mib)
    echo "crc_fcs=$(_mib_field "$m" RxFcsErr) crc_align=$(_mib_field "$m" RxAlignErr) crc_overflow=$(_mib_field "$m" RxOverFlow) crc_runt=$(_mib_field "$m" RxRunt)"
}

obs_syslog notice "odi-health restarted, interval ${INTERVAL}s"
echo "$(date '+%Y-%m-%d %H:%M:%S') === odi-health.sh restarted, interval ${INTERVAL}s ===" >> $LOG

restore_mgmt
sleep 2

PREV_CRC=""      # switch Rx-error snapshot from the last cycle (growth alert)

while true; do
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    restore_mgmt

    # Route10 PPPoE state
    WAN3_UP=$(ifstatus wan3 2>/dev/null | grep -oE '"up":[^,]+' | head -1 | sed 's/"up"://;s/ //g')
    WAN3_IP=$(ifstatus wan3 2>/dev/null | python3 -c "import json,sys
try:
    d=json.load(sys.stdin); a=d.get('ipv4-address',[])
    print(a[0].get('address','-') if a else '-')
except: print('-')" 2>/dev/null)
    PPPD=$(pgrep -f 'pppd.*wan3' | wc -l)
    CARRIER=$(cat /sys/class/net/eth4/carrier 2>/dev/null)
    SPEED=$(cat /sys/class/net/eth4/speed 2>/dev/null)
    PING_LINE=$(ping -c 3 -W 2 -q 1.1.1.1 2>/dev/null | grep -oE 'min/avg/max[^=]*=[ ]*[0-9./]+' | head -1)
    PING="${PING_LINE:-ping_fail}"

    # Temperature: Route10 SoC + L4 BiDi DDM
    R10_THERM=$(read_route10_thermals)
    L4_DDM=$(read_l4_ddm)

    # W2 stick DDM (from daemon's cache; daemon owns the Boa session)
    if ping -c 1 -W 1 -I 192.168.1.2 192.168.1.1 >/dev/null 2>&1; then
        W2_DDM=$(probe_w2_ddm)
    else
        W2_DDM="W2_mgmt_path_down"
    fi

    # Switch Rx-error counters (eth4/W2 path) + growth alert.
    CRC=$(read_switch_crc)
    if [ -n "$PREV_CRC" ] && [ "$CRC" != "$PREV_CRC" ]; then
        warn "switch Rx error counters changed (fibre/SFP degradation?): $PREV_CRC -> $CRC"
    fi
    PREV_CRC="$CRC"

    # Full verbose line -> persistent file (all 13 thermal zones + full DDM + CRC).
    # Size-rotate at 2 MiB (keep .1): this append bypasses obs_file, and /cfg is
    # only 26 MB — the unrotated log had grown to 7.4 MB by 2026-07-22.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
        mv "$LOG" "$LOG.1" 2>/dev/null
    fi
    LINE="wan3_up=$WAN3_UP ip=$WAN3_IP pppd=$PPPD carrier=$CARRIER speed=$SPEED $PING $R10_THERM $L4_DDM $W2_DDM $CRC"
    echo "$TS $LINE" >> $LOG
    # Compact line -> syslog: busybox syslogd truncates ~256B, which would drop the
    # tail (optical + CRC). Send only the alert-worthy metrics the observability
    # stack needs: drop the 13 per-zone temps (keep tz_max) and verbose DDM (keep Rx
    # power); collapse CRC to "clean" unless non-zero (the warn above carries full
    # detail on any change).
    TZMAX=$(echo "$R10_THERM" | grep -oE "tz_max=[^ ]+")
    L4_RX=$(echo "$L4_DDM"    | grep -oE "L4_rx_dBm=[^ ]+")
    W2_RX=$(echo "$W2_DDM"    | grep -oE "W2_rx_dBm_boa=[^ ]+")
    if echo "$CRC" | grep -qE "^crc_fcs=0x0+ crc_align=0x0+ crc_overflow=0x0+ crc_runt=0x0+$"; then
        CRC_TOK="crc=clean"
    else
        CRC_TOK="$CRC"
    fi
    obs_syslog info "wan3_up=$WAN3_UP ip=$WAN3_IP pppd=$PPPD carrier=$CARRIER speed=$SPEED $PING $TZMAX $L4_RX $W2_RX $CRC_TOK"

    sleep $INTERVAL
done
