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
# ⛔ THREE CONTROLS, and they are the whole design. A bare ping to a phone answers
# nothing, because both a WiFi problem and route10 being busy raise RTT, and a
# sleeping phone looks exactly like a dropped packet — and also exactly like a bad
# radio, since 802.11 power-save inflates RTT on a perfectly healthy link:
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
#   3. FLOOR control (within a burst). rtt_min alongside rtt_max separates a bad
#      radio from a SLEEPING one — see the long note at the parse below. A
#      battery device idling behind power-save shows a low floor and a huge tail;
#      a degraded link lifts the floor itself. `dup` corroborates: duplicate
#      replies mean 802.11 retransmitted, which power-save cannot produce.
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

    # ── follow the DEVICE, not the address ──────────────────────────────────
    # iOS private Wi-Fi addressing rotates the MAC; a rotated MAC takes a NEW
    # lease at a NEW ip, and the configured address goes quiet forever. The probe
    # would then read present=0 while she stands next to the AP using the
    # internet — a control that looks healthy while aimed at nothing.
    #
    # The DHCP hostname survives the rotation even though the MAC and ip do not,
    # so resolve name -> current lease each run and probe wherever the device
    # actually is. This removes the dependency on a static reservation entirely:
    # nothing has to be pinned, because nothing is assumed to stay still.
    #
    # Newest lease wins (max expiry) so a stale row for the same name cannot win
    # over the live one. Targets with no DHCP name (`*` in the lease file) or no
    # lease at all — statics like the AP — keep their configured ip untouched.
    #
    # ⛔ FAMILY-MATCHED. The lease file carries v4 AND v6 rows under the SAME
    # hostname, so a bare max-expiry match returns whichever renewed last — the
    # first test of this resolved `Notebook-Ana-Clara` to a GUA and would have
    # silently repointed a v4 target at an IPv6 address. Match the family of the
    # configured address and the ambiguity cannot arise.
    if [ -f /cfg/dhcp.leases ]; then
        case "$ip" in *:*) want=6 ;; *) want=4 ;; esac
        cur=$(awk -v n="$name" -v want="$want" '
              $4==n {
                  fam = (index($3, ":") ? 6 : 4)
                  if (fam == want && $1 > best) { best = $1; found = $3 }
              }
              END { if (found) print found }' /cfg/dhcp.leases 2>/dev/null)
        if [ -n "$cur" ] && [ "$cur" != "$ip" ]; then
            # Not a warning: this is the mechanism working. But it IS a state
            # change worth a line, because the ip label on every series for this
            # host changes with it and a reader will otherwise see a series end.
            event "$name moved $ip -> $cur (lease follows the device; probing the new address)"
            ip="$cur"
        fi
    fi

    # ── lease freshness: does this ADDRESS still belong to that device? ──────
    # `present=0` alone cannot tell "the phone is asleep" (recoverable, the
    # control working) from "this IP stopped being her phone days ago" (the probe
    # is pinging a dead lease and will read absent forever while she stands next
    # to the AP using the internet). Both render identically, and the second is a
    # control that looks healthy while aimed at nothing.
    #
    # The lease table is the only thing that separates them. dnsmasq field 1 is
    # the EXPIRY epoch, so `expiry - now` is what is left of a 24 h lease: a
    # device that renewed recently has most of it, a device that walked away
    # decays to zero and then vanishes from the file entirely.
    #
    # ⚠ Empty is NOT a failure. Statically-configured hosts (the AP, .200) never
    # take a lease, so they are permanently NaN here — a rule reading NaN as
    # "stale target" would condemn exactly the hosts that are most stable. This
    # discriminates for DHCP clients and says nothing about anyone else.
    lease=$(awk -v ip="$ip" -v now="$TS" '$3==ip {print $1-now; exit}' /cfg/dhcp.leases 2>/dev/null)
    case "$lease" in ''|*[!0-9-]*) lease="" ;; esac

    # ── presence control ────────────────────────────────────────────────────
    # A live neighbour entry means the device is on the segment and answering at
    # L2. FAILED/INCOMPLETE/absent means it is asleep, off, or gone — in which
    # case ICMP loss says nothing about link quality and must not be scored.
    st=$(ip neigh show "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^(REACHABLE|STALE|DELAY|PROBE|PERMANENT|FAILED|INCOMPLETE)$/) print $i}' | head -1)
    case "$st" in
        REACHABLE|STALE|DELAY|PROBE|PERMANENT) present=1 ;;
        *) present=0 ;;
    esac

    rtt_min=""; rtt_avg=""; rtt_max=""; loss=""; dup=""
    if [ "$present" = 1 ]; then
        out=$(ping -c "$COUNT" -W "$WAIT" -q "$ip" 2>/dev/null)
        # busybox: "N packets transmitted, M packets received[, D duplicates], X% packet loss"
        # `received` excludes duplicates (they are counted separately), so the
        # loss arithmetic below stays correct even when DUPs are present.
        rx=$(printf '%s' "$out" | sed -n 's/.*, *\([0-9]*\) packets received.*/\1/p')
        case "$rx" in ''|*[!0-9]*) rx="" ;; esac
        if [ -n "$rx" ]; then
            loss=$(( (COUNT - rx) * 100 / COUNT ))
            # round-trip min/avg/max = 1.234/5.678/9.012 ms
            #
            # ⛔ MIN IS THE THIRD CONTROL, and without it this probe cannot tell
            # a bad radio from a sleeping one. 802.11 power-save parks a phone or
            # a battery IoT device between DTIM beacons; the echo that arrives
            # while it is asleep waits for the wakeup, so avg and max climb into
            # the hundreds of ms on a PERFECTLY HEALTHY link. Plotting avg as
            # "WiFi quality" therefore paints a permanently-red panel that is
            # really just a device saving battery — a confidently-wrong signal,
            # which is worse than none.
            #   min rises too      => the floor moved: congestion or a bad link
            #   min flat, max high => the device slept; the air is fine
            # The floor is the honest measure; the tail is what a person feels.
            # Report both and let the reader see the gap, rather than averaging
            # two different phenomena into one number that means neither.
            rtt_min=$(printf '%s' "$out" | sed -n 's|.*= *\([0-9.]*\)/.*|\1|p')
            rtt_avg=$(printf '%s' "$out" | sed -n 's|.*= *[0-9.]*/\([0-9.]*\)/.*|\1|p')
            rtt_max=$(printf '%s' "$out" | sed -n 's|.*= *[0-9.]*/[0-9.]*/\([0-9.]*\).*|\1|p')
            # DUPLICATE replies are an 802.11 RETRANSMISSION tell: the receiver
            # got the frame but its ACK was lost, so the sender sent it again and
            # both copies were delivered. Power-save does NOT produce duplicates.
            # This is the one field here that a sleeping device cannot fake, so it
            # discriminates where latency alone is ambiguous. Absent field => 0.
            dup=$(printf '%s' "$out" | sed -n 's/.*, *\([0-9]*\) duplicates.*/\1/p')
            case "$dup" in ''|*[!0-9]*) dup=0 ;; esac
        fi
        # ARP said present but every echo was lost: that is a REAL finding (the
        # device is on the segment and not answering), not an absent device.
        [ -n "$rx" ] && [ "$rx" = 0 ] && event "$name ($ip, $medium) present at L2 but 100% ICMP loss"
    fi

    j() { case "$1" in ''|*[!0-9.]*) echo null ;; *) echo "$1" ;; esac; }
    # lease may legitimately be negative (expired but not yet reaped), so it gets
    # its own guard rather than j()'s digits-only one.
    jl() { case "$1" in ''|*[!0-9-]*) echo null ;; *) echo "$1" ;; esac; }
    ROWS="$ROWS${ROWS:+,}{\"ip\":\"$ip\",\"n\":\"$name\",\"m\":\"$medium\",\"present\":$present,\"loss\":$(j "$loss"),\"rtt\":$(j "$rtt_avg"),\"rttmin\":$(j "$rtt_min"),\"rttmax\":$(j "$rtt_max"),\"dup\":$(j "$dup"),\"lease\":$(jl "$lease")}"
done < "$TARGETS"

[ -n "$ROWS" ] || exit 0

OUT=$(sqlite3 "$DB" "
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS lanq (ts INTEGER PRIMARY KEY, json TEXT);
INSERT OR IGNORE INTO lanq VALUES ($TS, '[$ROWS]');
DELETE FROM lanq WHERE ts < $TS - 30*86400;
" 2>&1) || err "lanq insert FAILED: $(echo "$OUT" | head -1)"

exit 0
