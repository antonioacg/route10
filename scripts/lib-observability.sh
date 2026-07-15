#!/bin/sh
# lib-observability.sh — shared logging for Route10 /cfg/scripts helpers.
#
# Every message is DUAL-SUNK:
#   1. syslog — `logger -t route10.<component> -p daemon.<severity>`. busybox
#      syslogd writes it to /var/log/messages and can forward it to the homelab
#      collector via `syslogd -R host:port` (uci system.@system[0].log_ip). THIS
#      is the capture surface for the observability stack.
#   2. file — /cfg/scripts/<component>.log, size-rotated (keeps <log> + <log>.1).
#      Persistent on-box forensics that outlive the tiny volatile syslog buffer
#      (system.@system[0].log_size is only 64 KiB here).
#
# Defensive: a `logger` or file-write failure never aborts the caller. If this lib
# is ever absent, sourcing scripts fall back to a file-only log() in their own
# preamble, so a missing lib can NEVER stop a daemon:
#   . /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init <comp> \
#     || { OBS_LOG=/cfg/scripts/<comp>.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; \
#          event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }
#
# API:
#   obs_init <component> [logfile] [rotate_bytes]   # once, up front
#   log   "msg"   # daemon.info    — routine / metrics
#   event "msg"   # daemon.notice  — a state change worth capturing
#   warn  "msg"   # daemon.warning
#   err   "msg"   # daemon.err
#   obs_syslog <severity> "msg"   # syslog ONLY — for callers that own their file
#                                 #   format (e.g. flap-hunt's millisecond lines)
#
# Tag convention: route10.<component>  (route/filter on this in the collector).

obs_init() {
    OBS_TAG="route10.$1"
    OBS_LOG="${2:-/cfg/scripts/$1.log}"
    OBS_ROTATE="${3:-1048576}"          # 1 MiB
}

# syslog only. daemon facility, route10.<component> tag. Never fails hard.
obs_syslog() {
    _sev="$1"; shift
    logger -t "${OBS_TAG:-route10}" -p "daemon.$_sev" -- "$*" 2>/dev/null || true
}

# persistent file with size rotation. Never fails hard.
obs_file() {
    [ -n "$OBS_LOG" ] || return 0
    # Guard the size check on existence: `wc < missing` is a SHELL redirection
    # failure whose error escapes wc's 2>/dev/null (first write to a fresh log).
    if [ -f "$OBS_LOG" ]; then
        _sz=$(wc -c < "$OBS_LOG" 2>/dev/null)
        [ -n "$_sz" ] && [ "$_sz" -gt "${OBS_ROTATE:-1048576}" ] && mv "$OBS_LOG" "$OBS_LOG.1" 2>/dev/null
    fi
    echo "$(date '+%F %T') $*" >> "$OBS_LOG" 2>/dev/null || true
}

obs_emit() { _sev="$1"; shift; obs_syslog "$_sev" "$*"; obs_file "$*"; }
log()   { obs_emit info    "$*"; }
event() { obs_emit notice  "$*"; }
warn()  { obs_emit warning "$*"; }
err()   { obs_emit err     "$*"; }
