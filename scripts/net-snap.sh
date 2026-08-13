#!/bin/sh
# net-snap.sh — capture a slowness complaint IN THE ACT, from every vantage at once.
#
# Run it the moment something feels slow. It is read-only, bounded (~45 s), and
# never touches the stick CLI (that belongs to pon-collect).
#
#   ~/git/route10/scripts/net-snap.sh --note "globoplay graining, phone on 5G"
#
# ⭐ WHY THIS EXISTS. On 2026-08-12 a real degradation (1.5 Mbps on 2.4 GHz,
# 10 Mbps on 5 GHz, recovering later) was NOT caught, because every probe run
# afterwards was clean and several were self-invalidating. The failures were:
#   - claimed two measurements were "in the same window" with NO timestamps
#   - hammered ONE endpoint ~15x from two hosts behind one CGNAT IP, then read
#     the resulting rate-limit as a v4 fault
#   - read a symmetrical v4+v6 failure as a network fault (it was a broken probe)
#   - used "the picture started graining" as a time marker, which player
#     buffering makes lag by minutes
# So: EVERY line here is timestamped, every probe is single-shot against a
# DISTINCT host, and anything that could not be measured says so out loud.
#
# ⛔ Never conclude from this snapshot alone that a path is broken. Compare
# families (v4 vs v6) and hosts against EACH OTHER inside one run.

NOTE=""; DEV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --note) NOTE="$2"; shift 2 ;;
        --device) DEV="$2"; shift 2 ;;
        *) shift ;;
    esac
done

R10=route10
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${TMPDIR:-/tmp}/net-snap-$STAMP.txt"
ts() { date -u +%H:%M:%SZ; }
say() { echo "$@" | tee -a "$OUT"; }
sec() { say ""; say "── $* ── $(ts)"; }

say "net-snap $STAMP   (all stamps UTC; local $(date '+%F %T %Z'))"
[ -n "$NOTE" ] && say "NOTE: $NOTE"
say "file: $OUT"

# ── A. vantage: what is THIS box, and how is it attached? ───────────────────
# The medium is a first-class variable: 2.4 GHz vs 5 GHz vs wired produced
# 1.5 / 10 / fine on the SAME evening. A number without its medium is noise.
sec "A. vantage (this machine)"
IF=$(route -n get default 2>/dev/null | awk '/interface/{print $2}')
say "  default iface: ${IF:-UNKNOWN}"
if [ -n "$IF" ]; then
    PORT=$(networksetup -listallhardwareports 2>/dev/null | grep -B1 "Device: $IF" | head -1 | sed 's/Hardware Port: //')
    say "  hardware port: ${PORT:-UNKNOWN}"
    case "$PORT" in
        *Wi-Fi*|*wi-fi*)
            say "  medium: WIFI — band/rate matter, capturing:"
            system_profiler SPAirPortDataType 2>/dev/null \
                | sed -n '/Current Network/,/^$/p' \
                | grep -E "PHY Mode|Channel|Signal|Noise|Transmit Rate" \
                | sed 's/^/    /' | tee -a "$OUT" \
                || say "    (SPAirPortDataType unavailable)"
            ;;
        *) say "  medium: WIRED (or non-wifi) — note the streaming device may still be on wifi" ;;
    esac
fi

# ── B. throughput: many paths AT ONCE, one shot each ────────────────────────
# ⛔ ONE request per host. Repeating against a single endpoint is how the last
# investigation rate-limited its own CGNAT address and then misread it.
sec "B. throughput — distinct hosts, v4 and v6, single-shot"
say "  (Mbit/s; 'n/a' = that family/host did not answer, which is DATA not absence)"
for u in \
    "https://speed.cloudflare.com/__down?bytes=20000000" \
    "https://fsn1-speed.hetzner.com/100MB.bin" \
    "https://proof.ovh.net/files/100Mb.dat"
do
    H=$(echo "$u" | sed -e 's|https\?://||' -e 's|/.*||')
    T=$(ts)
    V4=$(curl -4 -s -o /dev/null -w "%{speed_download}" --max-time 15 "$u" 2>/dev/null)
    V6=$(curl -6 -s -o /dev/null -w "%{speed_download}" --max-time 15 "$u" 2>/dev/null)
    f() { [ -z "$1" ] || [ "$1" = "0" ] || [ "$1" = "0.000" ] && echo "n/a" || echo "$1 8 1000000" | awk '{printf "%.1f", $1*$2/$3}'; }
    say "  $T  $(printf '%-30s' "$H")  v4=$(printf '%8s' "$(f "$V4")")  v6=$(printf '%8s' "$(f "$V6")")"
done
say "  ⚠ v4 and v6 BOTH dead to every host = suspect the probe, not the network."

# ── C. latency, including under load ────────────────────────────────────────
# ⛔ Do NOT use 1.1.1.1 for loss: it rate-limits ICMP from this ISP path and has
# read 40-100% loss while TCP through the same path was clean.
sec "C. latency (gateway = the honest control)"
GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
say "  gateway $GW: $(ping -c 5 -i 0.3 -t 3 "$GW" 2>/dev/null | tail -1 | sed 's/^/    /')"
say "  8.8.8.8:  $(ping -c 5 -i 0.3 -t 3 8.8.8.8 2>/dev/null | tail -2 | tr '\n' ' ')"
say "  idle vs LOADED (bufferbloat):"
IDLE=$(ping -c 5 -i 0.3 -t 3 8.8.8.8 2>/dev/null | tail -1)
curl -s -o /dev/null --max-time 10 "https://fsn1-speed.hetzner.com/100MB.bin" & DLPID=$!
sleep 1
LOAD=$(ping -c 8 -i 0.3 -t 3 8.8.8.8 2>/dev/null | tail -1)
wait $DLPID 2>/dev/null
say "    idle:   $IDLE"
say "    loaded: $LOAD"

# ── D. router-side truth ────────────────────────────────────────────────────
sec "D. route10 (link, PON, load, offenders)"
ssh -o ConnectTimeout=5 "$R10" 'sh -s' 2>/dev/null <<'REMOTE' | sed 's/^/  /' | tee -a "$OUT"
echo "t=$(date -u +%H:%M:%SZ)  ppp_up=$(ifstatus wan3 2>/dev/null | grep -c '"up": true')  uptime=$(ifstatus wan3 2>/dev/null | grep -m1 uptime | tr -dc 0-9)"
R1=$(cat /sys/class/net/pppoe-wan3/statistics/rx_bytes); T1=$(cat /sys/class/net/pppoe-wan3/statistics/tx_bytes)
sleep 5
R2=$(cat /sys/class/net/pppoe-wan3/statistics/rx_bytes); T2=$(cat /sys/class/net/pppoe-wan3/statistics/tx_bytes)
echo "WAN now: down=$(( (R2-R1)*8/5/1000000 )) Mbit/s up=$(( (T2-T1)*8/5/1000000 )) Mbit/s"
echo "eth4 carrier=$(cat /sys/class/net/eth4/carrier) chg=$(cat /sys/class/net/eth4/carrier_changes)  eth5 chg=$(cat /sys/class/net/eth5/carrier_changes)"
echo "PON: $(sqlite3 -readonly /a/obs/rt.sql "SELECT 'o'||json_extract(json,'\$.onu_state')||' los='||json_extract(json,'\$.alarm.los')||' sd='||json_extract(json,'\$.alarm.sd')||' fec_unc='||json_extract(json,'\$.ds.fec_uncor_cw')||' age='||(strftime('%s','now')-ts)||'s' FROM pon ORDER BY ts DESC LIMIT 1;" 2>/dev/null)"
echo "conntrack total=$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
echo "top v4 talkers (flows):"
conntrack -L 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^src=192\.168\.10\./){split($i,a,"="); print a[2]; break}}' | sort | uniq -c | sort -rn | head -5
echo "connlimit hits today: $(grep -c 'route10.connlimit' /var/log/messages 2>/dev/null)  (offenders:)"
grep 'route10.connlimit' /var/log/messages 2>/dev/null | grep -oE 'SRC=192\.168\.10\.[0-9]+' | sort | uniq -c | sort -rn | head -3
echo "qdisc: $(tc qdisc show dev pppoe-wan3 2>/dev/null | head -1 | cut -c1-70)"
REMOTE
[ $? -ne 0 ] && say "  ⚠ route10 UNREACHABLE — that itself is the finding"

# ── E. per-client bandwidth, from the router's own view ─────────────────────
# This is what names the starved device. The complaint usually comes from a box
# we cannot run anything on (TV box, phone), so the router's per-client counters
# are the ONLY first-person account of what that device was getting.
sec "E. per-client bytes, last 3 minutes (rcstats /a/stats.sql)"
ssh -o ConnectTimeout=5 "$R10" "sqlite3 -readonly /a/stats.sql \"SELECT ts, json FROM minutes ORDER BY ts DESC LIMIT 3;\"" 2>/dev/null \
 | python3 -c '
import sys, json, datetime
for line in sys.stdin:
    ts, _, js = line.partition("|")
    if not js.strip(): continue
    try: d = json.loads(js)
    except Exception: continue
    # ⛔ minutes.ts is SECONDS. speed_tests.ts is MILLISECONDS. Do not copy one
    # of these conversions into the other -- doing exactly that printed every row
    # as 16:16:29Z (a 1970 date) on this scripts first run.
    when = datetime.datetime.fromtimestamp(int(ts), datetime.timezone.utc).strftime("%H:%M:%SZ")
    rows = []
    for group in ("wired", "wireless", "clients"):
        for c in d.get(group, []) or []:
            tx, rx = c.get("tx", 0), c.get("rx", 0)
            if not (tx or rx): continue
            proto = ",".join(p[0] for p in (c.get("dpi") or [])[:2])
            rows.append((tx + rx, c.get("ip", c.get("id", "?")), group[:4], tx, rx, proto))
    rows.sort(reverse=True)
    print(f"  {when}")
    for tot, ip, g, tx, rx, proto in rows[:6]:
        print(f"    {ip:<16} {g:<5} tx={tx:>9} rx={rx:>9}  {proto}")
' 2>/dev/null | tee -a "$OUT" || say "  (per-client parse unavailable)"

# ── F. the router's own speed tests ─────────────────────────────────────────
sec "F. Alta/M-Lab speed tests on record (router-run, independent of us)"
ssh -o ConnectTimeout=5 "$R10" "sqlite3 -readonly /a/stats.sql \"SELECT json FROM speed_tests WHERE json LIKE '%complete%' ORDER BY ts DESC LIMIT 3;\"" 2>/dev/null \
 | python3 -c '
import sys, json, datetime
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    t = datetime.datetime.fromtimestamp(d.get("ts",0)/1000, datetime.timezone.utc).strftime("%F %H:%MZ")
    dl = d.get("download",{}).get("throughput",{}).get("value")
    ul = d.get("upload",{}).get("throughput",{}).get("value")
    lat = d.get("download",{}).get("latency",{}).get("value")
    print(f"  {t}  down={dl} Mbps  up={ul} Mbps  lat={lat} ms")
' 2>/dev/null | tee -a "$OUT" || say "  (none / unparsable)"

say ""
say "── done $(ts) ── full capture: $OUT"
say "Next: hand this file to Claude and say 'triage this snap'. It will classify"
say "it against docs/incidents/net-triage-log.md and append what it learned."
