#!/bin/sh
# collect-route10.sh — router-side evidence for net-triage. Piped over ssh, never deployed,
# so the repo copy is always the one that runs:
#   ssh route10 "FROM=<epoch> TO=<epoch> LIVE=1 CLIENT=<ip|mac|name> sh -s" < collect-route10.sh
#
# Read-only. Never touches the stick CLI (pon-collect owns it). Every section runs in the
# background, so one slow source can't hold up the rest; output is '@@ <section>' blocks
# (plus '@@took <section> <s>') that analyze.py parses. LIVE=0 (a retrospective --at run)
# skips what only describes "now": the 8 s firewall delta, tcpdump, neighbour state.

NOW=$(date +%s)
TO=${TO:-$NOW}
FROM=${FROM:-$((TO - 2700))}
case "$TO$FROM" in *[!0-9]*) echo "@@ error"; echo "FROM/TO must be epoch seconds"; exit 2 ;; esac
CLIENT=$(printf '%s' "${CLIENT:-}" | tr -cd 'A-Za-z0-9:._-')
LIVE=${LIVE:-1}
D=/tmp/net-triage.$$
mkdir -p "$D" || exit 1
trap 'rm -rf "$D"' EXIT INT TERM
RT=/a/obs/rt.sql
ST=/a/stats.sql
AR=/a/obs/stats-archive.sql
q() { timeout 10 sqlite3 -readonly "$1" "$2" 2>/dev/null; }

s_meta() {
    echo "now=$NOW from=$FROM to=$TO live=$LIVE client=$CLIENT"
    echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
    echo "hz=$(zcat /proc/config.gz 2>/dev/null | sed -n 's/^CONFIG_HZ=//p')"
    echo "tz=$(date +%z)"
}

s_wan() {
    for i in wan3 wan36 wan wan2; do
        echo "## ifstatus $i"
        timeout 3 ubus call network.interface.$i status 2>/dev/null
    done
    echo "## route4"; ip -4 route show default 2>/dev/null
    echo "## route6"; ip -6 route show default 2>/dev/null
    echo "## mwan3"
    for w in wan wan2 wan3; do
        echo "$w iface_state=$(cat /var/run/mwan3/iface_state/$w 2>/dev/null) track=$(cat /var/run/mwan3track/$w/STATUS 2>/dev/null)"
    done
    # LAN v4 follows mwan3's marks, NOT the main table: the fibreless Huawei (eth0, metric
    # 101) sits first in `ip route` even while every LAN flow uses wan3.
    echo "## mwan3policy"
    timeout 3 ubus call mwan3 status 2>/dev/null | python3 -c 'import json,sys
try: print(json.dumps((json.load(sys.stdin).get("policies") or {}).get("ipv4")))
except Exception: pass'
    echo "## carrier"
    for i in eth4 eth5 eth1 br-lan pppoe-wan3 eth0 eth3; do
        [ -d /sys/class/net/$i ] && echo "$i $(cat /sys/class/net/$i/carrier 2>/dev/null) $(cat /sys/class/net/$i/carrier_changes 2>/dev/null)"
    done
    echo "## odi"      # local time, 5-min cadence; analyze.py filters on time
    tail -n 300 /cfg/scripts/odi-health.log 2>/dev/null
}

# ⛔ rt.sql/stats.sql ts are SECONDS (stats.sql speed_tests is ms — not read here).
s_pon()     { q $RT "SELECT ts,json FROM pon WHERE ts BETWEEN $FROM AND $TO ORDER BY ts"; }
s_samples() { q $RT "SELECT ts,json_remove(json,'\$.if.eth4','\$.if.eth5','\$.if.tailscale0','\$.ct.top6','\$.irq_edma','\$.softnet') FROM samples WHERE ts BETWEEN $FROM AND $TO ORDER BY ts"; }
s_lanq()    { q $RT "SELECT ts,json FROM lanq WHERE ts BETWEEN $FROM AND $TO ORDER BY ts"; }
s_minutes() {
    # stats.sql keeps a rolling ~60 min; older minutes live in the archive (same format).
    first=$(q $ST "SELECT min(ts) FROM minutes")
    if [ -z "$first" ] || [ "$FROM" -lt "$first" ]; then
        q $AR "SELECT ts,json FROM minutes WHERE ts BETWEEN $FROM AND $TO ORDER BY ts"
    fi
    q $ST "SELECT ts,json FROM minutes WHERE ts BETWEEN $FROM AND $TO ORDER BY ts"
}

s_leases() {
    cat /cfg/dhcp.leases 2>/dev/null
    echo "## targets"
    grep -v '^#' /cfg/lan-probe.targets 2>/dev/null
}

s_log() {
    # UTC 'Mon DD HH:MM:SS.mmm'; analyze.py filters on time. Drops the two firehoses
    # (raw OMCI lines, and lan-probe's per-minute "moved" notices).
    tail -n 40000 /var/log/messages 2>/dev/null \
      | grep -v -e 'route10\.omci' -e 'lan-probe: .* moved ' \
      | grep -E 'route10\.|DHCP|pppd|netifd|mwan3|block: |rc: |cfg: |odhcp6c|kernel: .*(eth[0-9]|br-lan)' \
      | tail -n 8000
}

s_fw() {
    # Counters of every RT10_* rule, twice LIVE: the delta is what the fences drop NOW.
    for f in iptables ip6tables; do echo "## $f t0"; ${f}-save -c 2>/dev/null | grep -E '^\*|RT10_'; done
    echo "## recent"
    for r in /proc/net/xt_recent/*; do [ -f "$r" ] && { echo "### ${r##*/}"; cat "$r"; }; done
    [ "$LIVE" = 1 ] || return 0
    sleep 8
    for f in iptables ip6tables; do echo "## $f t1"; ${f}-save -c 2>/dev/null | grep -E '^\*|RT10_'; done
}

s_mesh() {
    timeout 6 tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(json.dumps({"error": e.__class__.__name__})); sys.exit()
peers = []
for p in (d.get("Peer") or {}).values():
    peers.append({k: p.get(v) for k, v in (("name", "HostName"), ("ips", "TailscaleIPs"),
        ("online", "Online"), ("active", "Active"), ("relay", "Relay"), ("cur", "CurAddr"),
        ("hs", "LastHandshake"), ("rx", "RxBytes"), ("tx", "TxBytes"),
        ("exit_node", "ExitNode"), ("exit_opt", "ExitNodeOption"))})
print(json.dumps({"state": d.get("BackendState"), "version": d.get("Version"), "peers": peers}))'
    echo "## mesh-allow"
    for f in /var/run/mesh-allow/s.*; do [ -f "$f" ] && echo "${f##*/} $(cat "$f")"; done
}

s_bridge() {
    brctl showstp br-lan 2>/dev/null | grep -E '^[A-Za-z0-9._-]+ \([0-9]+\)'
    echo "## macs"
    brctl showmacs br-lan 2>/dev/null
}

s_client() {
    [ -n "$CLIENT" ] || return 0
    c=$(printf '%s' "$CLIENT" | tr 'A-Z' 'a-z')
    # v4 lease lines are '<exp> <mac> <ip> <host> ...'; match an exact ip/mac or a hostname substring
    macs=$(awk -v c="$c" 'index($2, ":") && (tolower($2) == c || $3 == c || index(tolower($4), c)) {print tolower($2)}' /cfg/dhcp.leases 2>/dev/null | sort -u | tr '\n' ' ')
    echo "macs=$macs"
    [ "$LIVE" = 1 ] || return 0
    [ -n "$macs" ] || return 0
    echo "## neigh"
    for m in $macs; do ip neigh 2>/dev/null | grep -i "$m"; done
    echo "## conntrack"
    for ip in $(awk -v m=" $macs" 'index(m, " " tolower($2) " ") {print $3}' /cfg/dhcp.leases 2>/dev/null); do
        timeout 4 conntrack -L -f ipv4 -s "$ip" 2>/dev/null
    done
    f=""
    for m in $macs; do f="${f:+$f or }ether host $m"; done
    echo "## tcpdump"
    timeout 8 tcpdump -lnni br-lan -tt -c 400 "$f" 2>/dev/null
}

SECTIONS="meta wan pon samples lanq minutes leases log fw mesh bridge client"
for s in $SECTIONS; do
    ( t0=$(date +%s); s_$s > "$D/$s" 2>&1; echo "$(( $(date +%s) - t0 ))" > "$D/$s.took" ) &
done
wait
for s in $SECTIONS; do
    echo "@@ $s"
    cat "$D/$s"
    echo "@@took $s $(cat "$D/$s.took" 2>/dev/null)"
done
