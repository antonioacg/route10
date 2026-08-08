#!/bin/sh
# pon-collect.sh — PON-layer telemetry from the ODI stick, every 15 min.
#
# Metric menu from Strykar/GPON (same RTL960x diag CLI); transport is OURS:
# stick-exec.py clean-exit telnet — the ONLY safe path (single-CLI cli.pid
# lock; see project_odi_cli_pid_lock). Their exporter drives the CLI over SSH;
# this stick has no SSH (port 22 refused, measured 2026-08-08).
#
# ⚠ THE DIAG TRAP, learned the hard way (2026-08-08, wedged the CLI once):
# `diag <subcmd>` as a bare busybox command EXECUTES the query and then STAYS in
# diag's interactive RTK.0> prompt — stick-exec's sentinel never returns, the
# timeout closes the socket abruptly, and a /bin/login+/bin/sh session is left
# orphaned holding the single CLI until stick-unwedge.sh (or a reboot) clears it.
# The safe form pipes the whole batch through diag's stdin with a trailing
# `exit`, so diag processes each line and returns to the shell:
#     printf "gpon get onu-state\n...\nexit\n" | diag
# Verified clean + non-wedging 2026-08-08.
#
# Parsers are built against REAL captured output (2026-08-08). diag prints
# `<label> : <value>` with variable spacing; alarms print `Alarm <T>, status: <s>`.
# The full raw blob is stored alongside the parsed fields so a parser can be
# fixed offline against real text without spending another stick session.
#
# Cadence 1-min (2026-08-08): one telnet session per cycle, one uptime read +
# one diag stdin-batch inside it. Safe at this rate because (a) the wedge class
# is structurally gone — see the diag trap above; (b) pon-collect is the SOLE
# stick-CLI user (W2 DDM uses Boa HTTP, odi-health/obs-collect read i2c+caches),
# so no session overlaps another; and (c) the overlap guard below stops cron
# from stacking a second run on a slow one. Arch note: SSH is impossible on this
# stick (Lexra-MIPS / RO squashfs / no dropbear), so telnet is the only path —
# see reference_odi_stick_arch_no_ssh.
#
# Row: pon(ts, json, raw) in /a/obs/rt.sql. Clean rows are ~200 B (raw stored
# ONLY on a parse anomaly, see below) ⇒ ≈0.3 MB/day, ~9 MB over the 30-day
# prune even at 1-min. Wedge handling: warn on TRANSITION to unreachable, event
# on recovery — a wedged CLI fails fast (empty banner) and probing it via
# stick-exec does not deepen the wedge.
#
# Install: scp to /cfg/scripts/pon-collect.sh, chmod +x
# Cron:    * * * * *  (reinstalled each boot by post-cfg.sh)
# Log:     /cfg/scripts/pon-collect.log

DB=/a/obs/rt.sql
LOG=/cfg/scripts/pon-collect.log
STATE=/var/run/.pon-collect.down
LOCK=/var/run/.pon-collect.lock
STICK_EXEC=/cfg/scripts/stick-exec.py

obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init pon-collect "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

# ── overlap guard ───────────────────────────────────────────────────────────
# At the 1-min cadence a slow or hung session (stick-exec has its own timeout,
# but the mgmt path can stall) must NOT be doubled by the next cron tick — two
# concurrent telnet sessions would collide on the stick's single-CLI lock and
# manufacture a false "wedged" reading.
#
# The lock is a DIRECTORY, not a file: `mkdir` is atomic on the filesystem, so
# two instances starting in the same instant can't both win (a plain
# [ -f ] test-then-write races — verified). /var/run is tmpfs, so a reboot
# clears a leaked lock for free; the only in-boot leak is a SIGKILL'd holder,
# which the pid staleness check below reclaims.
if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -f "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
        exit 0                                   # a live instance holds it — skip
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0   # stale holder — reclaim
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

TS=$(date +%s)

# One clean session: uptime (reboot detection) + the diag batch via stdin pipe.
DIAG='printf "gpon get onu-state\ngpon get alarm-status\ngpon get rogue-sd-cnt\ngpon show counter global ds-phy\ngpon show counter global ds-plm\nexit\n" | diag'
RAW=$(python3 "$STICK_EXEC" "cat /proc/uptime" "$DIAG" 2>&1)

case "$RAW" in
    *WEDGED*|*"ERR:"*|'')
        if [ ! -f "$STATE" ]; then
            warn "stick CLI unreachable ($(printf '%s' "$RAW" | head -c 80)) — PON telemetry paused; will event on recovery"
            touch "$STATE"
        fi
        exit 0 ;;
esac
[ -f "$STATE" ] && { rm -f "$STATE"; event "stick CLI recovered — PON telemetry resumed"; }

# ── parsers (against real 2026-08-08 output) ────────────────────────────────
# `<label> : <value>` — grep the label, take the last colon-separated integer.
val() {
    printf '%s\n' "$RAW" | grep -m1 -- "$1" \
        | sed -n 's/.*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}
# alarm: `Alarm <TYPE>, status: clear|<other>` → 0 clear, 1 otherwise, null absent
alarm() {
    _l=$(printf '%s\n' "$RAW" | grep -m1 -- "Alarm $1,")
    [ -z "$_l" ] && { echo null; return; }
    case "$_l" in *clear*) echo 0 ;; *) echo 1 ;; esac
}
nz() { case "$1" in ''|*[!0-9]*) echo null ;; *) echo "$1" ;; esac; }

UPTIME=$(printf '%s\n' "$RAW" | sed -n 's/^\([0-9][0-9]*\)\.[0-9].*/\1/p' | head -1)
ONU=$(printf '%s\n' "$RAW" | sed -n 's/.*Operation State(O\([0-9]\)).*/\1/p' | head -1)

BIP_BITS=$(val "BIP Error bits")
BIP_BLK=$(val "BIP Error blocks")
FEC_COR=$(val "FEC Correct codewords")
FEC_UNC=$(val "FEC codewords Uncor")
SF_LOS=$(val "Superframe LOS")
PLOAM_RX=$(val "Total RX PLOAM")
PLOAM_CRC=$(val "CRC Err RX PLOAM")
ROGUE_LONG=$(val "SD too long count")
ROGUE_MIS=$(val "SD mismatch count")

JSON=$(printf '{"uptime":%s,"onu_state":%s,"alarm":{"los":%s,"lof":%s,"lom":%s,"sf":%s,"sd":%s,"tx_too_long":%s,"tx_mismatch":%s},"ds":{"bip_bits":%s,"bip_blocks":%s,"fec_cor_cw":%s,"fec_uncor_cw":%s,"sf_los":%s,"ploam_rx":%s,"ploam_crc":%s},"rogue":{"sd_too_long":%s,"sd_mismatch":%s}}' \
    "$(nz "$UPTIME")" "$(nz "$ONU")" \
    "$(alarm LOS)" "$(alarm LOF)" "$(alarm LOM)" "$(alarm SF)" "$(alarm SD)" \
    "$(alarm 'TX Too Long')" "$(alarm 'TX Mismatch')" \
    "$(nz "$BIP_BITS")" "$(nz "$BIP_BLK")" "$(nz "$FEC_COR")" "$(nz "$FEC_UNC")" \
    "$(nz "$SF_LOS")" "$(nz "$PLOAM_RX")" "$(nz "$PLOAM_CRC")" \
    "$(nz "$ROGUE_LONG")" "$(nz "$ROGUE_MIS")")

# Store the raw diag blob ONLY when a field failed to parse (JSON contains a
# null). Parsers are verified against real output, so a healthy row is all
# numbers and needs no raw copy — which keeps the 1-min cadence cheap: a clean
# row is ~200 B (≈0.3 MB/day, ~9 MB over the 30-day window) instead of ~6 KB.
# A parse anomaly is exactly the case worth keeping full context for.
case "$JSON" in
    *null*) RAW_COL=$(printf '%s' "$RAW" | head -c 6000 | sed "s/'/''/g") ;;
    *)      RAW_COL='' ;;
esac
sqlite3 "$DB" "
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS pon (ts INTEGER PRIMARY KEY, json TEXT, raw TEXT);
INSERT OR IGNORE INTO pon VALUES ($TS, '$JSON', '$RAW_COL');
DELETE FROM pon WHERE ts < $TS - 30*86400;
" 2>&1 | grep -qi error && err "pon insert issue (see stderr)"

# Stick reboot: uptime going backwards is worth a line (and resets the counters).
# Both operands must be validated separately — an empty PREV_UP (first run) fed to
# `[ -lt ]` is a shell error, not a skip.
PREV_UP=$(sqlite3 -readonly "$DB" "SELECT json_extract(json,'\$.uptime') FROM pon WHERE ts < $TS ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
case "$UPTIME" in ''|*[!0-9]*) : ;; *)
    case "$PREV_UP" in ''|*[!0-9]*) : ;; *)
        [ "$UPTIME" -lt "$PREV_UP" ] && event "stick REBOOTED: uptime ${PREV_UP}s -> ${UPTIME}s (PON counters reset)" ;;
    esac ;;
esac

# Alarm surfacing: any non-clear PON alarm is worth an event even between scrapes.
for a in LOS LOF LOM SF SD; do
    [ "$(alarm $a)" = 1 ] && warn "PON alarm $a is RAISED (onu_state=O${ONU:-?})"
done

exit 0
