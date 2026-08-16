#!/bin/sh
# ax73-scrape.sh — pull the AX73 WiFi AP's Prometheus exposition into a local
# cache that metrics-cgi.sh appends verbatim to route10's own /metrics page.
#
# Why route10 fronts for the AP (operator decision 2026-08-16): route10 owns
# ALL networking concerns toward ops, so ops keeps exactly ONE seam — their
# Prometheus scrapes 192.168.10.1:9100 and gets the WiFi metrics with it.
# This also closes the long-standing blind spot noted in post-cfg's lan-probe
# job: route10 has no radios and rcstats exposes no wireless clients, so an
# AP-side fault (weak RSSI, retry storms, a dead BSS) was invisible to every
# infra metric we had.
#
# Cadence * * * * *, cron installed by post-cfg.sh (tmpfs-reinstall idiom).
# The metrics-cgi request path stays probe-free: it serves this CACHE, never
# the AP itself, and staleness is exported as route10_ax73_scrape_timestamp_
# seconds + route10_ax73_up so the consumer gates instead of us serving lies.
#
# The AP's exporter is owned by the wifi-ap agent (seam: ~/git/agent-seam-wifi
# on the operator's Mac). Interface we depend on, agreed in that seam's mail:
# endpoint URL below, every metric name prefixed ax73_, renames announced
# via mail first. The prefix filter here is a HARD guard for our whole
# exposition: one malformed line would make Prometheus reject the ENTIRE
# route10:9100 scrape — WiFi metrics must never be able to take down the
# router's. So only lines that are structurally valid samples pass: name with
# ax73_ prefix, optional {labels}, a single numeric value.
#
# On scrape failure the LAST GOOD cache keeps being served (values freeze,
# timestamp doesn't advance, up goes 0) — informative over restrictive; the
# freshness gate belongs to the consumer. Logs on TRANSITION only.

. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init ax73-scrape \
  || { OBS_LOG=/cfg/scripts/ax73-scrape.log; log(){ echo "$(date '+%F %T') $*" >>"$OBS_LOG"; }; \
       event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; obs_syslog(){ :; }; }

AX73_URL="http://192.168.10.11:9100/metrics"
CACHE=/tmp/ax73-metrics.prom
STATUS=/tmp/ax73-metrics.status        # "<epoch of last good scrape> <0|1 up>"
MIN_LINES=50                           # a real page is ~300 lines; below this it
                                       # is an error body or a truncated read

read -r PREV_TS PREV_UP <"$STATUS" 2>/dev/null
PREV_TS=${PREV_TS:-0}; PREV_UP=${PREV_UP:-1}

TMP="$CACHE.new"
if curl -s -m 5 "$AX73_URL" 2>/dev/null \
     | grep -E '^ax73_[A-Za-z0-9_]+(\{[^}]*\})? -?[0-9.]+([eE][+-]?[0-9]+)?$' >"$TMP" \
   && [ "$(wc -l <"$TMP")" -ge "$MIN_LINES" ]; then
    mv "$TMP" "$CACHE"
    echo "$(date +%s) 1" >"$STATUS"
    [ "$PREV_UP" = "0" ] && event "AX73 metrics scrape recovered ($(wc -l <"$CACHE") samples)"
else
    rm -f "$TMP"
    echo "$PREV_TS 0" >"$STATUS"
    [ "$PREV_UP" = "1" ] && warn "AX73 metrics scrape FAILED ($AX73_URL unreachable or body malformed/short) — serving last good cache, route10_ax73_up=0"
fi

exit 0
