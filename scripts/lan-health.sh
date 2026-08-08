#!/bin/sh
# lan-health.sh — LAN-side link + address state recorder.
#
# WHY THIS EXISTS (2026-08-08 IP-stack wedge):
# route10 stopped answering ARP for its own 192.168.10.1 for 27 minutes while the
# switch ASIC kept forwarding between wired ports and userspace kept running. We
# could not explain it from route10's own logs, because nothing on the box
# recorded LAN-side state: odi-health covers the ODI/GPON/WAN path and logs
# carrier for eth4 ONLY. eth5 (office fibre / cage L4) and br-lan were entirely
# uninstrumented. See docs/postmortems/2026-08-08-ipstack-wedge-lan-outage.md.
#
# THE DESIGN POINT — write EVERY cycle, healthy or not.
# An event tap would NOT have helped that incident: the stack died without
# emitting a single netifd/kernel interface event (verified against the ops
# collector: zero netifd, zero pppd, zero link transitions in the 19 minutes
# before the fault). What actually saved the RCA was odi-health appending a line
# to /cfg on every cycle, which kept working while the box was cut off. A
# persistent unconditional record beats an event stream you can only read if the
# network is alive. So: always append, and warn only on change.
#
# NOT a daemon — `*/5` cron, matching mesh-health / lan-prefix-track. `/` is
# tmpfs, so post-cfg.sh reinstalls the cron line each boot.
#
# Install: scp to /cfg/scripts/lan-health.sh, chmod +x
# Cron:    */5 * * * * /cfg/scripts/lan-health.sh
# Log:     /cfg/scripts/lan-health.log   (persistent — this is the whole point)

LOG=/cfg/scripts/lan-health.log
STATE=/var/run/.lan-health.state
LAN_IP4=192.168.10.1

# Dual-sink logging; file-only fallback so a missing lib can't break the check.
obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init lan-health "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

# One port's link state. `?` when sysfs is absent so a renamed/missing iface is
# visible in the record rather than silently blank.
port_state() {
    _i=$1
    [ -d "/sys/class/net/$_i" ] || { echo "${_i}=absent"; return; }
    printf '%s_carrier=%s %s_oper=%s %s_chg=%s %s_speed=%s' \
        "$_i" "$(cat /sys/class/net/$_i/carrier 2>/dev/null || echo '?')" \
        "$_i" "$(cat /sys/class/net/$_i/operstate 2>/dev/null || echo '?')" \
        "$_i" "$(cat /sys/class/net/$_i/carrier_changes 2>/dev/null || echo '?')" \
        "$_i" "$(cat /sys/class/net/$_i/speed 2>/dev/null || echo '?')"
}

# br-lan: operstate plus whether it still OWNS the gateway addresses. The v4
# check is the load-bearing one — br-lan losing 192.168.10.1 is exactly the state
# that produces `ARP INCOMPLETE` on every LAN host while userspace runs on, and
# it is the hypothesis we could not confirm or refute in the 2026-08-08 incident.
brlan_state() {
    _oper=$(cat /sys/class/net/br-lan/operstate 2>/dev/null || echo '?')
    _v4=$(ip -4 addr show br-lan 2>/dev/null | grep -c "inet ${LAN_IP4}/")
    _v6ula=$(ip -6 addr show br-lan 2>/dev/null | grep -c 'inet6 fd')
    _v6gua=$(ip -6 addr show br-lan 2>/dev/null | grep -c 'inet6 2')
    # Bridge members actually enslaved right now (a member silently leaving the
    # bridge looks identical to a link drop from the client side).
    _mem=$(ls /sys/class/net/br-lan/brif 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    printf 'brlan_oper=%s brlan_ip4=%s brlan_ula=%s brlan_gua=%s brlan_members=%s' \
        "$_oper" "$_v4" "$_v6ula" "$_v6gua" "${_mem:-none}"
}

TS=$(date '+%Y-%m-%d %H:%M:%S')
LINE="$(port_state eth1) $(port_state eth2) $(port_state eth5) $(brlan_state)"

# Size-rotate at 512 KiB (keep .1). /cfg is only ~26 MB total and odi-health
# already claims 2 MiB there, so this stays deliberately small.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
    mv "$LOG" "$LOG.1" 2>/dev/null
fi
echo "$TS $LINE" >> "$LOG"

# Warn only on CHANGE — the unconditional line above is the forensic record, so
# the warn exists purely to be alertable. carrier_changes is excluded from the
# comparison: it is a monotonic counter, so including it would fire every time a
# port blinked and make the warn meaningless.
CMP=$(echo "$LINE" | sed -E 's/[a-z0-9]+_chg=[0-9?]+ ?//g')
PREV=$(cat "$STATE" 2>/dev/null)
if [ -n "$PREV" ] && [ "$CMP" != "$PREV" ]; then
    warn "LAN state changed: $PREV  ->  $CMP"
fi
printf '%s' "$CMP" > "$STATE"

# br-lan losing the gateway address is severe on its own, every cycle it holds —
# a continuous signal a rule can fire on, and the single most diagnostic state
# for the "LAN hosts get no ARP reply while the box is otherwise alive" class.
if ! echo "$LINE" | grep -q 'brlan_ip4=1'; then
    err "br-lan has LOST ${LAN_IP4} — LAN hosts will get no ARP reply; box may still be up and logging"
fi

# Compact copy to syslog (busybox syslogd truncates ~256 B): drop speed and the
# member list, keep link/oper state and the address ownership flags.
obs_syslog info "$(echo "$LINE" | sed -E 's/[a-z0-9]+_speed=[^ ]+ ?//g; s/brlan_members=[^ ]+ ?//')"
