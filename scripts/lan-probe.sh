#!/bin/sh
# lan-probe.sh — per-client LAN reachability/latency, so a degraded WiFi link is
# measurable from route10 instead of only reportable by the person suffering it.
#
# WHY. Every alert this box carries watches route10 itself. The chronic complaint
# it never caught — "the last few images of a post do not load", "newer shorts
# struggle", "I switch to 5G" — happens on devices behind an AP route10 has NO
# telemetry from: it has no radios (`iw dev` empty) and Alta's rcstats exposes only
# a `wired` client list. No signal, no retries, no airtime, no PHY rate. If the
# fault is in the air, nothing here could ever see it, and "no alert fired" is
# guaranteed rather than surprising.
#
# ⛔ TWO CONTROLS, and they are the whole design. A bare ping to a phone answers
# nothing, because both a WiFi problem and route10 being busy raise RTT, and a
# sleeping phone looks exactly like a dropped packet:
#
#   1. PRESENCE control (per target). Loss is only counted when the device is
#      demonstrably on the LAN — an `ip neigh` entry in a live state. A phone that
#      is asleep, off, or on 5G is recorded `present=0` and its loss is NOT scored.
#      Without this the probe would manufacture a nightly outage every time she
#      puts the phone down, which trains the reader to ignore it.
#   2. MEDIUM control (across targets). Probing a WIRED host and the AP itself
#      alongside the wireless client is what separates "the air is bad" from
#      "route10 is slow". Wireless degrades + wired clean => the WiFi link.
#      Both degrade => route10 or the LAN, and the AP is exonerated.
#
# Deliberately measures the LAN leg only. It says nothing about the WAN — the
# heartbeat, wan4 budget and PON metrics cover that, and conflating the two is how
# "the internet is bad" stays unattributable for months.
#
# Targets live in /cfg/lan-probe.targets ("<ip> <name> <medium>", # comments), so
# devices can be added without a redeploy. Absent file => seeded with a default set
# and a warning, never a silent no-op.
#
# Install: scp to /cfg/scripts/lan-probe.sh, chmod +x
# Cron:    * * * * *  (reinstalled each boot by post-cfg.sh — / is tmpfs)
# Log:     /cfg/scripts/lan-probe.log (errors/transitions only)

DB=/a/obs/rt.sql
LOG=/cfg/scripts/lan-probe.log
TARGETS=/cfg/lan-probe.targets
COUNT=5          # echoes per target per run; small enough to be invisible on a phone battery
WAIT=1           # per-echo timeout (s)

obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init lan-probe "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

# Seed a default target set rather than exiting quietly: a probe that silently
# does nothing is worse than one that is loudly unconfigured.
if [ ! -f "$TARGETS" ]; then
    cat > "$TARGETS" <<'EOF'
# <ip>            <name>            <medium>   # medium: wifi | wired | ap
# The wired and ap rows are CONTROLS. Do not delete them: without a control a
# wireless RTT spike cannot be distinguished from route10 being busy.
192.168.10.148    iPhone            wifi
192.168.10.24     vacuum            wifi
192.168.10.11     archer-ax73       ap
192.168.10.151    Antonios-MBP      wired
EOF
    warn "no $TARGETS — seeded a default set (iPhone/vacuum wifi, AP + a wired host as controls); edit to taste"
fi

TS=$(date +%s)
ROWS=""

while read -r ip name medium; do
    case "$ip" in ''|'#'*) continue ;; esac
    [ -n "$name" ] && [ -n "$medium" ] || continue

    # ── presence control ────────────────────────────────────────────────────
    # A live neighbour entry means the device is on the segment and answering at
    # L2. FAILED/INCOMPLETE/absent means it is asleep, off, or gone — in which
    # case ICMP loss says nothing about link quality and must not be scored.
    st=$(ip neigh show "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^(REACHABLE|STALE|DELAY|PROBE|PERMANENT|FAILED|INCOMPLETE)$/) print $i}' | head -1)
    case "$st" in
        REACHABLE|STALE|DELAY|PROBE|PERMANENT) present=1 ;;
        *) present=0 ;;
    esac

    rtt_avg=""; rtt_max=""; loss=""
    if [ "$present" = 1 ]; then
        out=$(ping -c "$COUNT" -W "$WAIT" -q "$ip" 2>/dev/null)
        # busybox: "N packets transmitted, M packets received, X% packet loss"
        rx=$(printf '%s' "$out" | sed -n 's/.*, *\([0-9]*\) packets received.*/\1/p')
        case "$rx" in ''|*[!0-9]*) rx="" ;; esac
        if [ -n "$rx" ]; then
            loss=$(( (COUNT - rx) * 100 / COUNT ))
            # round-trip min/avg/max = 1.234/5.678/9.012 ms
            rtt_avg=$(printf '%s' "$out" | sed -n 's|.*= *[0-9.]*/\([0-9.]*\)/.*|\1|p')
            rtt_max=$(printf '%s' "$out" | sed -n 's|.*= *[0-9.]*/[0-9.]*/\([0-9.]*\).*|\1|p')
        fi
        # ARP said present but every echo was lost: that is a REAL finding (the
        # device is on the segment and not answering), not an absent device.
        [ -n "$rx" ] && [ "$rx" = 0 ] && event "$name ($ip, $medium) present at L2 but 100% ICMP loss"
    fi

    j() { case "$1" in ''|*[!0-9.]*) echo null ;; *) echo "$1" ;; esac; }
    ROWS="$ROWS${ROWS:+,}{\"ip\":\"$ip\",\"n\":\"$name\",\"m\":\"$medium\",\"present\":$present,\"loss\":$(j "$loss"),\"rtt\":$(j "$rtt_avg"),\"rttmax\":$(j "$rtt_max")}"
done < "$TARGETS"

[ -n "$ROWS" ] || exit 0

OUT=$(sqlite3 "$DB" "
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS lanq (ts INTEGER PRIMARY KEY, json TEXT);
INSERT OR IGNORE INTO lanq VALUES ($TS, '[$ROWS]');
DELETE FROM lanq WHERE ts < $TS - 30*86400;
" 2>&1) || err "lanq insert FAILED: $(echo "$OUT" | head -1)"

exit 0
