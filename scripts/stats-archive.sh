#!/bin/sh
# stats-archive.sh — persist Alta's own telemetry beyond its rolling windows.
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
# minutes ~2 KB -> ~2.9 MB/day -> 60-day prune ≈ 175 MB steady-state.
# hours/days/speed_tests are negligible and kept ~2 years.
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
DELETE FROM minutes WHERE ts < strftime('%s','now') - 60*86400;
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

# Belt-and-suspenders on the disk itself: /a also hosts a 2G swap file and
# routedns. If free space decays toward nothing the prune horizon must shrink
# BEFORE writes start failing — warn at 200 MB so a human decides.
FREE_KB=$(df -k /a | awk 'NR==2{print $4}')
[ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 204800 ] && \
    warn "/a free space low: ${FREE_KB}KB — shrink the 60-day minutes prune or clean /a"

exit 0
