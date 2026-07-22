#!/bin/sh
# dhcp-watchdog.sh — detect a MUTE dnsmasq (process up, LISTENING on udp/67, but
# answering no DHCP) and restart it. Defense-in-depth for the 2026-06-24
# power-surge failure mode. See docs/postmortems/2026-06-24-power-surge-dhcp.md.
#
# Detection is PASSIVE — veth / raw-packet injection isn't available on this
# kernel (RTNETLINK: Not supported), so we watch real client traffic on br-lan.
# The mute signature is unmistakable and is exactly what we observed during the
# outage:
#     many client REQUESTs (X.68 > Y.67), ZERO server REPLIES (X.67 > Y.68).
# A healthy dnsmasq answers every broadcast request; a quiet LAN simply never
# reaches REQ_MIN. We require DEBOUNCE consecutive bad samples before acting and
# COOLDOWN between restarts, so the watchdog never thrashes or fights the
# post-cfg.sh boot-time restart.
#
# Deploy to: /cfg/scripts/dhcp-watchdog.sh   (launched by post-cfg.sh)
# Log:       /cfg/scripts/dhcp-watchdog.log  (EVENT lines + heartbeat, rotates)

IFACE=br-lan
LOG=/cfg/scripts/dhcp-watchdog.log
SAMPLE_SECS=15                  # how long each br-lan DHCP sample runs
LOOP_SLEEP=30                   # gap between samples (~45 s/cycle)
REQ_MIN=4                       # >= this many requests with ZERO replies = suspicious
DEBOUNCE=2                      # consecutive bad samples required before restarting
COOLDOWN=300                    # min seconds between restarts
HEARTBEAT=300                   # heartbeat cadence (s)
ROTATE_BYTES=$((5 * 1024 * 1024))

# Add a syslog copy (route10.dhcp-watchdog) to the existing file logger. no-op
# default so a missing lib can't break the watchdog; the lib overrides it.
obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init dhcp-watchdog "$LOG"
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { obs_syslog notice "$*"; echo "$(ts) $*" >> "$LOG"; }
# heartbeat: full line to the file, syslog at DEBUG — proof-of-life counters are
# not a state change; at notice they polluted severity-based Loki views.
hb()  { obs_syslog debug  "$*"; echo "$(ts) $*" >> "$LOG"; }
# count lines in $1 matching BRE $2
cnt() { printf '%s\n' "$1" | grep -c "$2"; }

log "=== dhcp-watchdog started (iface=$IFACE sample=${SAMPLE_SECS}s req_min=$REQ_MIN debounce=$DEBOUNCE) ==="

bad=0; last_fix=0; last_hb=0; checks=0; fixes=0

while :; do
  # rotate if the log got big
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$ROTATE_BYTES" ]; then
    mv "$LOG" "$LOG.1" 2>/dev/null
  fi

  cap=$(timeout "$SAMPLE_SECS" tcpdump -p -i "$IFACE" -n -l 'udp port 67 or udp port 68' 2>/dev/null)
  req=$(cnt "$cap" '\.68 >')   # client -> server (DISCOVER/REQUEST)
  rep=$(cnt "$cap" '\.67 >')   # server -> client (OFFER/ACK/NAK)
  checks=$((checks + 1))
  now=$(date +%s)

  if [ "$req" -ge "$REQ_MIN" ] && [ "$rep" -eq 0 ]; then
    bad=$((bad + 1))
    log "EVENT dhcp_suspect req=$req rep=0 streak=$bad"
    if [ "$bad" -ge "$DEBOUNCE" ] && [ $((now - last_fix)) -ge "$COOLDOWN" ]; then
      log "EVENT dhcp_mute_confirmed req=$req rep=0 -> dnsmasq restart"
      /etc/init.d/dnsmasq restart >/dev/null 2>&1
      fixes=$((fixes + 1)); last_fix=$now; bad=0
      sleep 5
      v=$(timeout 10 tcpdump -p -i "$IFACE" -n -l 'udp port 67 or udp port 68' 2>/dev/null)
      log "EVENT dhcp_post_restart replies=$(cnt "$v" '\.67 >') dnsmasq_pid=$(pgrep dnsmasq | tr '\n' ' ')"
    fi
  else
    [ "$bad" -gt 0 ] && log "EVENT dhcp_ok req=$req rep=$rep (streak reset)"
    bad=0
  fi

  if [ $((now - last_hb)) -ge "$HEARTBEAT" ]; then
    hb "heartbeat checks=$checks fixes=$fixes last=req:$req/rep:$rep dnsmasq_pid=$(pgrep dnsmasq | tr '\n' ' ')"
    last_hb=$now
  fi

  sleep "$LOOP_SLEEP"
done
