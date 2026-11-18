#!/bin/sh
# collect-ax73.sh — Wi-Fi AP evidence for net-triage. Piped over ssh, never deployed:
#   ssh ax73 'sh -s' < collect-ax73.sh
#
# ⛔ READ-ONLY, and it must stay that way: the AX73 belongs to the wifi-ap agent
# (seam ~/git/agent-seam-wifi). No `wl scan` (takes the radio off-channel and drops
# clients' traffic), no up/down, no nvram set, no files written. BusyBox 1.19: no
# `timeout`, so only commands that return at once.
#
# Sections: meta, bss (per BSS: ssid, chanspec, client count), rssi (per station),
# events (association log, ms epoch), fdb (which AP port each MAC is behind: a wl*
# port = on Wi-Fi, an eth port = wired or behind another AP), chanim (channel
# airtime: busy / obss = neighbours / idle / knoise, 3 samples ~4 s apart).

echo "@@ meta"
echo "now=$(date +%s) uptime=$(cut -d' ' -f1 /proc/uptime)"

echo "@@ bss"
for i in $(ls /sys/class/net | grep '^wl'); do
    ssid=$(wl -i "$i" ssid 2>/dev/null | sed -e 's/^[^"]*"//' -e 's/"$//')
    echo "$i up=$(wl -i "$i" isup 2>/dev/null) chanspec=$(wl -i "$i" chanspec 2>/dev/null | cut -d' ' -f1) n=$(wl -i "$i" assoclist 2>/dev/null | grep -c assoclist) ssid=$ssid"
done

echo "@@ rssi"
for i in $(ls /sys/class/net | grep '^wl'); do
    for m in $(wl -i "$i" assoclist 2>/dev/null | awk '{print $2}'); do
        echo "$i $m $(wl -i "$i" rssi "$m" 2>/dev/null)"
    done
done

echo "@@ events"
cat /tmp/ce0.log.bak /tmp/ce0.log 2>/dev/null \
  | grep -E 'E_(ASSOC_IND|REASSOC_IND|DEAUTH|DEAUTH_IND|DISASSOC|DISASSOC_IND|AUTHORIZED)/' \
  | awk '{print $2, $3, $4, $5, $6, $7, $8, $NF}'

echo "@@ fdb"
brctl showstp br-lan 2>/dev/null | grep -E '^[A-Za-z0-9._-]+ \([0-9]+\)'
echo "## macs"
brctl showmacs br-lan 2>/dev/null

echo "@@ chanim"
for k in 1 2 3; do
    for r in wl0 wl1 wl2; do
        [ -d /sys/class/net/$r ] || continue
        echo "$r $(date +%s) $(wl -i $r chanim_stats 2>/dev/null | tail -1)"
    done
    [ $k = 3 ] || sleep 4
done
