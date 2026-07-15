#!/bin/sh
# daemon-odi-w2-ddm.sh — populate W2 stick's i2c slave A2 page from Boa HTTP.
#
# Background (full rationale: reference_odi_ddm_blocker.md, reference_europa_sdk_leak.md):
#   The ODI stick's i2c slave at 0x51 page A2 is a RAM-backed register buffer on
#   the RTL9601D. The chip's europa_drv.ko isn't loaded — its polling thread
#   would be a no-op anyway (leaked SDK source shows the update_ddmi() call is
#   commented out in europa_main.c). So bytes 96-105 stay at 0xff forever.
#
#   But Boa's /status_pon.asp serves real DDM values via the SerDes path
#   (rtk_ponmac_transceiver_get in libmib.so). And Route10's rcstats agent reads
#   i2c-1 0x51 bytes 96-105 every ~5s, writes parsed JSON to /var/run/.sfp1ddm.json,
#   ships it to the Alta cloud dashboard.
#
#   This daemon bridges them: pull DDM from Boa over HTTP, encode per SFF-8472,
#   write the 10 bytes to the i2c slave. rcstats then picks them up exactly the
#   same way it does for L4. End result: W2 cage shows full DDM in Alta dashboard.
#
# Architecture (per user "one session" constraint):
#   - Login to Boa once at startup (Boa session is IP-bound per memory).
#   - Every $POLL_S seconds: GET /status_pon.asp, parse 5 fields, encode, write.
#   - Also publish parsed values to /var/run/w2-ddm.cache so odi-health.sh can
#     read it instead of doing its own Boa fetch (one session, like the user said).
#   - On parse/auth failure: re-login next iteration.
#
# Lifecycle:
#   - Launched by /cfg/post-cfg.sh (Alta-blessed hook, idempotent on reapply).
#   - Stopped via: pkill -f /cfg/scripts/daemon-odi-w2-ddm.sh

set -u

LOGIN_URL='http://192.168.1.1/boaform/admin/formLogin'
LOGIN_POST='username=admin&password=admin&challenge=&save=Login&submit-url=%2Fadmin%2Flogin.asp'
STATUS_URL='http://192.168.1.1/status_pon.asp'
SRC_IP='192.168.1.2'
I2C_BUS=1
I2C_SLAVE='0x51'
I2C_OFFSET='0x60'        # SFF-8472 A2 real-time data start (byte 96)
POLL_S=5                 # match rcstats' cadence
CACHE='/var/run/w2-ddm.cache'       # JSON form (general consumers)
CACHE_SH='/var/run/w2-ddm.env'      # POSIX-sh-sourceable (for odi-health.sh)
LOG='/cfg/scripts/daemon-odi-w2-ddm.log'
LOG_MAX=524288           # 512K — manual rotation (Route10 has no logrotate here)

# Add a syslog copy (route10.w2-ddm) to the existing file logger. no-op default
# so a missing lib can't break the daemon; the lib overrides it.
obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init w2-ddm "$LOG"
log() { obs_syslog notice "$*"; echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Rotate log if it exceeds LOG_MAX
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt "$LOG_MAX" ] && : > "$LOG"

cleanup() { log "shutdown (signal)"; exit 0; }
trap cleanup TERM INT

# Boa session is IP-bound; one login lets all subsequent GETs through.
login() {
    curl --http0.9 -s -m 5 --interface "$SRC_IP" -o /dev/null \
        -X POST -d "$LOGIN_POST" "$LOGIN_URL"
}

# Fetch /status_pon.asp and parse the 5 DDM fields.
# Output (stdout): "T V A P R" floats, single line. Empty on parse failure.
# Detects session-lost (Boa returns tiny login redirect) — emits nothing.
fetch_parse() {
    local html
    html=$(curl --http0.9 -s -m 5 --interface "$SRC_IP" "$STATUS_URL" 2>/dev/null)
    [ -z "$html" ] && return 1
    # Session-lost check: response is short and contains login.asp redirect.
    if [ "$(echo "$html" | wc -c)" -lt 800 ] && echo "$html" | grep -q 'login.asp'; then
        return 1
    fi
    echo "$html" | awk '
        /<b>Temperature<\/b>/   { f="t"; next }
        /<b>Voltage<\/b>/       { f="v"; next }
        /<b>Bias Current<\/b>/  { f="a"; next }
        /<b>Tx Power<\/b>/      { f="p"; next }
        /<b>Rx Power<\/b>/      { f="r"; next }
        f && match($0, />[ ]*[-+]?[0-9]+\.[0-9]+/) {
            v = substr($0, RSTART+1, RLENGTH-1)
            gsub(/ /, "", v)
            val[f] = v
            f = ""
        }
        END {
            if (("t" in val) && ("v" in val) && ("a" in val) && ("p" in val) && ("r" in val))
                printf "%s %s %s %s %s\n", val["t"], val["v"], val["a"], val["p"], val["r"]
        }'
}

# Encode the 5 floats as 10 hex bytes per SFF-8472 A2 page (offsets 96-105).
# Output (stdout): "0xHH 0xHH 0xHH 0xHH 0xHH 0xHH 0xHH 0xHH 0xHH 0xHH"
# Empty if any value is out of plausible range.
encode_bytes() {
    awk -v t="$1" -v v="$2" -v a="$3" -v p="$4" -v r="$5" '
        function be(x) {
            return sprintf("0x%02x 0x%02x", int(x/256) % 256, x % 256)
        }
        function clamp16(x) {
            x = int(x + 0.5)
            if (x < 0)     return -1
            if (x > 65535) return -1
            return x
        }
        BEGIN {
            # Plausible-range sanity bounds (must match the daemon comment above).
            if (t < -40  || t > 100)  exit 1
            if (v < 1.0  || v > 5.0)  exit 1
            if (a < 0.0  || a > 200)  exit 1
            if (p < -50  || p > 20)   exit 1
            if (r < -50  || r > 10)   exit 1

            # Temperature: signed Q8.8 °C, big-endian
            temp_raw = int(t * 256 + (t < 0 ? -0.5 : 0.5))
            if (temp_raw < 0) temp_raw += 65536

            # Vcc: uint16, units of 100µV → V * 10000
            vcc_raw  = clamp16(v * 10000)
            # Tx bias: uint16, units of 2µA → mA * 500
            bias_raw = clamp16(a * 500)
            # Tx/Rx power: uint16, units of 0.1µW; dBm → µW: 10^(dBm/10) * 1000
            #   raw = µW * 10 = 10000 * 10^(dBm/10) = 10000 * exp(dBm/10 * log(10))
            tx_raw   = clamp16(10000 * exp(p / 10 * log(10)))
            rx_raw   = clamp16(10000 * exp(r / 10 * log(10)))

            if (vcc_raw < 0 || bias_raw < 0 || tx_raw < 0 || rx_raw < 0) exit 1
            print be(temp_raw), be(vcc_raw), be(bias_raw), be(tx_raw), be(rx_raw)
        }'
}

write_cache() {
    # $1..$5: T V A P R    $6: i2c_ok ("true" or "false")
    local ts; ts=$(date +%s)
    # JSON (general consumers)
    local tmp="${CACHE}.tmp"
    printf '{"t":%s,"v":%s,"a":%s,"p":%s,"r":%s,"ts":%s,"i2c_ok":%s}\n' \
        "$1" "$2" "$3" "$4" "$5" "$ts" "$6" > "$tmp"
    mv "$tmp" "$CACHE"
    # POSIX-sh sourceable (odi-health.sh reads this)
    local tmp_sh="${CACHE_SH}.tmp"
    printf 'W2_T=%s\nW2_V=%s\nW2_A=%s\nW2_P=%s\nW2_R=%s\nW2_TS=%s\nW2_I2C_OK=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$ts" "$6" > "$tmp_sh"
    mv "$tmp_sh" "$CACHE_SH"
}

log "start poll=${POLL_S}s pid=$$"

logged_in=0
fail_count=0

while true; do
    if [ "$logged_in" -eq 0 ]; then
        if login; then
            log "login ok"
            logged_in=1
        else
            log "login failed (retry in 10s)"
            sleep 10
            continue
        fi
    fi

    parsed=$(fetch_parse)
    if [ -z "$parsed" ]; then
        fail_count=$((fail_count + 1))
        # Periodic re-login attempt to recover from silent session loss.
        if [ $((fail_count % 6)) -eq 0 ]; then
            log "parse fail x$fail_count — forcing re-login"
            logged_in=0
        fi
        sleep "$POLL_S"
        continue
    fi

    bytes=$(encode_bytes $parsed)
    if [ -z "$bytes" ]; then
        log "encode failed (out of range): $parsed"
        sleep "$POLL_S"
        continue
    fi

    # i2c write: 10 bytes burst to slave 0x51 at offset 0x60
    if i2ctransfer -y "$I2C_BUS" w11@"$I2C_SLAVE" "$I2C_OFFSET" $bytes >/dev/null 2>&1; then
        i2c_ok='true'
    else
        i2c_ok='false'
        log "i2c write failed: $bytes"
    fi

    # Cache for downstream consumers (odi-health.sh reads this instead of curling Boa)
    set -- $parsed
    write_cache "$1" "$2" "$3" "$4" "$5" "$i2c_ok"

    fail_count=0
    sleep "$POLL_S"
done
