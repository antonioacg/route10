#!/bin/sh
# stats-archive.sh — persist Alta's own telemetry beyond its rolling windows,
# and enforce the hard storage cap for everything under /a/obs (see the cap
# section at the foot of the file — it's the single janitor for the whole dir,
# not just this DB).
#
# Alta's rcstats daemon already samples this box better than anything we could
# bolt on: /a/stats.sql gets a per-minute row with intra-minute min/avg/max for
# load, memory and temperature, per-switch-port tx/rx byte counts, and per-client
# traffic with DPI classification. It is the data that settled the 2026-08-08
# RCA (load 0.03 through the wedge = idle, not spinning; port5 rx=0 while tx
# continued). The catch is retention: `minutes` is a rolling ~60-minute window —
# the incident evidence survived only because a copy was taken by hand within
# the hour.
#
# This script is that copy, on a timer. Every 30 min (2x margin on the 60-min
# window) it INSERT OR IGNOREs the source rows into /a/obs/stats-archive.sql.
# /a is a 3.1G persistent ext4 (964M free, survives reboots AND firmware
# updates — routedns/ predates the 2026-07-22 update). Measured row sizes:
# minutes ~2 KB -> ~2.9 MB/day -> 30-day prune ≈ 87 MB steady-state.
# hours/days/speed_tests are negligible and kept ~2 years — and those two
# rollup tiers ARE the long-term view, so trimming minutes to 30d loses almost
# nothing (fine-grained recent, downsampled long-term, black-style, for free).
#
# Read-only on the source (URI mode=ro) + busy_timeout so we never block or
# corrupt rcstats' own writes (journal_mode=delete on its side).
#
# Install: scp to /cfg/scripts/stats-archive.sh, chmod +x
# Cron:    */30 * * * *  (reinstalled each boot by post-cfg.sh — / is tmpfs)
# Log:     /cfg/scripts/stats-archive.log

SRC=/a/stats.sql
DST=/a/obs/stats-archive.sql
LOG=/cfg/scripts/stats-archive.log

obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init stats-archive "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

if [ ! -r "$SRC" ]; then
    # A missing source is a real event: a firmware update moved/renamed Alta's
    # stats DB and the archive has silently stopped growing. err, not warn —
    # this must trip the ops-side Route10ComponentError rule.
    err "source $SRC missing/unreadable — Alta stats layout changed? archive is NOT growing"
    exit 1
fi
mkdir -p /a/obs 2>/dev/null

OUT=$(sqlite3 "$DST" "
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS minutes     (ts INTEGER PRIMARY KEY, json TEXT);
CREATE TABLE IF NOT EXISTS hours       (ts INTEGER PRIMARY KEY, json TEXT);
CREATE TABLE IF NOT EXISTS days        (ts INTEGER PRIMARY KEY, json TEXT);
CREATE TABLE IF NOT EXISTS speed_tests (ts INTEGER PRIMARY KEY, json TEXT);
ATTACH 'file:$SRC?mode=ro' AS src;
INSERT OR IGNORE INTO minutes     SELECT ts, json FROM src.minutes;
INSERT OR IGNORE INTO hours       SELECT ts, json FROM src.hours;
INSERT OR IGNORE INTO days        SELECT ts, json FROM src.days;
INSERT OR IGNORE INTO speed_tests SELECT ts, json FROM src.speed_tests;
DETACH src;
DELETE FROM minutes WHERE ts < strftime('%s','now') - 30*86400;
DELETE FROM hours   WHERE ts < strftime('%s','now') - 730*86400;
DELETE FROM days    WHERE ts < strftime('%s','now') - 730*86400;
SELECT (SELECT count(*) FROM minutes)||' '||(SELECT count(*) FROM hours)||' '||(SELECT count(*) FROM days);
" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
    err "archive cycle FAILED rc=$RC: $(echo "$OUT" | head -1)"
    exit 1
fi

# PRAGMA busy_timeout echoes its value as an output row, so the counts we want
# are specifically the LAST line, not the whole capture.
set -- $(echo "$OUT" | tail -n1)
SIZE=$(wc -c < "$DST" 2>/dev/null)
log "archived: minutes=$1 hours=$2 days=$3 db_bytes=$SIZE"

# ── hard storage cap for /a/obs ─────────────────────────────────────────────
# The per-table time prunes above (and in obs-collect/pon-collect) bound row
# AGE. This bounds total BYTES — a safety net against row-size growth beyond
# projection (a stats.sql per-client DPI balloon, an obs-collect regression, a
# pstore crash-loop) filling /a, which it shares with the 2G swap + routedns.
#
# Projected steady state is ~130 MB (stats-archive ~87 + rt.sql samples ~30 +
# pon ~9, all at 30-day retention). Cap at 500 MB: generous headroom over
# projection, and /a has ~960 MB free so this leaves a wide margin. A normal run
# is a no-op — the trim only fires on a genuine overrun, and it WARNS then because a breach
# means a projection was wrong and a human should see why.
#
# When breached: cap the pstore dir (crash-loop guard), hard-rotate the ring
# log, then delete the oldest ~25% of every table in each DB and VACUUM to
# actually reclaim the file (SQLite reuses freed pages but never shrinks the
# file on its own). Loop a few times; if still over, escalate to err.
#
# NOTE: trimming is oldest-first, so preserved incident data (deliberately the
# oldest rows) is the first thing a cap breach — or the routine time-prune —
# sacrifices. That's acceptable BY DESIGN: this is a forensic buffer, not a
# permanent archive. An incident's *conclusions* belong in a committed
# postmortem well within the 30-day window; the raw rows are only needed
# long enough to reach them. Don't rely on this DB to hold evidence forever.
OBS_DIR=/a/obs
OBS_CAP_KB=512000

obs_usage_kb() { du -sk "$OBS_DIR" 2>/dev/null | awk '{print $1}'; }
trim_db_oldest() {   # $1=db — drop oldest ~25% of every table, then reclaim
    _db=$1; [ -f "$_db" ] || return 0
    for _t in $(sqlite3 "$_db" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null); do
        # OFFSET count/4 => the 25th-percentile ts; deletes rows older than it.
        # count/4==0 on a tiny table => OFFSET 0 => deletes nothing (safe no-op).
        sqlite3 "$_db" "DELETE FROM $_t WHERE ts < (SELECT ts FROM $_t ORDER BY ts LIMIT 1 OFFSET (SELECT count(*)/4 FROM $_t));" 2>/dev/null
    done
    sqlite3 "$_db" "VACUUM;" 2>/dev/null
}

USED_KB=$(obs_usage_kb)
if [ -n "$USED_KB" ] && [ "$USED_KB" -gt "$OBS_CAP_KB" ]; then
    warn "/a/obs at ${USED_KB}KB > cap ${OBS_CAP_KB}KB — trimming oldest data + reclaiming"
    # pstore crash-loop guard: keep only the 20 newest harvested dirs.
    if [ -d "$OBS_DIR/pstore" ]; then
        ls -1t "$OBS_DIR/pstore" 2>/dev/null | tail -n +21 | while read -r _d; do
            rm -rf "$OBS_DIR/pstore/$_d" 2>/dev/null
        done
    fi
    [ -f "$OBS_DIR/kernel-ring.log" ] && mv "$OBS_DIR/kernel-ring.log" "$OBS_DIR/kernel-ring.log.1" 2>/dev/null
    _pass=0
    while [ "$_pass" -lt 4 ]; do
        trim_db_oldest "$OBS_DIR/rt.sql"
        trim_db_oldest "$DST"
        USED_KB=$(obs_usage_kb)
        [ -n "$USED_KB" ] && [ "$USED_KB" -le "$OBS_CAP_KB" ] && break
        _pass=$((_pass + 1))
    done
    if [ -n "$USED_KB" ] && [ "$USED_KB" -le "$OBS_CAP_KB" ]; then
        event "/a/obs trimmed to ${USED_KB}KB (under ${OBS_CAP_KB}KB cap)"
    else
        err "/a/obs STILL ${USED_KB}KB after 4 trim passes — investigate a runaway writer under $OBS_DIR"
    fi
fi

# Additional early signal on the disk as a WHOLE (catches swap/routedns growth,
# not just ours): warn if free space falls below 200 MB regardless of the cap.
FREE_KB=$(df -k /a | awk 'NR==2{print $4}')
[ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 204800 ] && \
    warn "/a free space low: ${FREE_KB}KB free — something beyond /a/obs may be growing (swap? routedns?)"

exit 0
