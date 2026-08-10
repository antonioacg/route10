#!/bin/sh
# obs-collect.sh — per-minute host collector for what Alta's rcstats does NOT sample.
#
# rcstats covers load/mem/temp (min-avg-max) and switch-ASIC port counters.
# This collector covers the CPU-mediated side of the box — the part that died in
# the 2026-08-08 IP-stack wedge while every ASIC counter looked normal:
#
#   - /proc/stat CPU counters (total/idle/softirq/iowait — raw; deltas come from
#     consecutive rows, so a stuck minute is visible as a flat or missing row)
#   - softnet_stat dropped + time_squeeze (NAPI starvation — the closest thing
#     this kernel has to a datapath distress signal; it has NO soft-lockup or
#     hung-task detector compiled in, only panic*/RCU-stall)
#   - per-interface counters for CPU-side interfaces the switch MIB can't see:
#     br-lan, pppoe-wan3, tailscale0 — plus eth4/eth5 with carrier
#   - br-lan address presence (v4 / GUA / ULA) — "does the box still own .1"
#   - conntrack count/limit (CGNAT-exhaustion class)
#   - optical DDM: L4 BiDi via direct i2c (same SFF-8472 reads as odi-health),
#     W2 stick from the daemon cache (/var/run/w2-ddm.env — NEVER Boa, NEVER
#     stick telnet from here)
#   - EDMA/NSS interrupt total (a storm and a full stop both matter)
#
# Storage is the same fashion as Alta's own: SQLite rows of (ts, json) in
# /a/obs/rt.sql on the persistent 3.1 G partition. ~0.7 KB/row → ~1 MB/day →
# 30-day prune ≈ 30 MB. Query like the rcstats archive; JSON keys are stable.
#
# Also owns two persistence jobs no sampler can replace:
#   - KERNEL RING DRAIN → /a/obs/kernel-ring.log. The ring is a ~36 KB volatile
#     buffer and the 2026-08-08 recovery reboot destroyed it, taking whatever
#     the kernel did say. dmesg stamps are uptime-relative; we track the last
#     drained stamp and re-drain from the top when it goes backwards (= reboot).
#   - PSTORE HARVEST → /a/obs/pstore/<ts>/. pstore is ramoops-backed and works;
#     if it is ever non-empty a kernel crash record exists. We copy it out,
#     free the slots, and log at ERROR severity — which trips the ops-side
#     Route10ComponentError alert with no new plumbing.
#
# Quiet by design: no per-cycle log line (the DB row is the record); warn/err
# only. NOT an unconditional syslog emitter — the ops dead-man keys on
# odi-health + dhcp-watchdog, not on this.
#
# Install: scp to /cfg/scripts/obs-collect.sh, chmod +x
# Cron:    * * * * *  (reinstalled each boot by post-cfg.sh)
# Log:     /cfg/scripts/obs-collect.log (errors only)

DB=/a/obs/rt.sql
KLOG=/a/obs/kernel-ring.log
LOG=/cfg/scripts/obs-collect.log

obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init obs-collect "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

mkdir -p /a/obs 2>/dev/null

# ── JSON helper: numeric passthrough, everything else null ───────────────────
jnum() {
    case "$1" in
        ''|'?') echo null ;;
        *[!0-9.+-]*) echo null ;;   # catches "-Inf", hex, garbage
        *) echo "$1" ;;
    esac
}

# ── pstore harvest ──────────────────────────────────────────────────────────
if [ -d /sys/fs/pstore ] && [ -n "$(ls -A /sys/fs/pstore 2>/dev/null)" ]; then
    PDIR="/a/obs/pstore/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$PDIR"
    if cp /sys/fs/pstore/* "$PDIR"/ 2>/dev/null; then
        N=$(ls "$PDIR" | wc -l)
        # Freeing the slots matters: ramoops holds a bounded number of records
        # and a full store may not capture the NEXT crash.
        rm -f /sys/fs/pstore/* 2>/dev/null
        err "KERNEL CRASH RECORD harvested: $N pstore file(s) -> $PDIR — a panic/oops occurred; read them"
    else
        err "pstore non-empty but harvest to $PDIR FAILED — read /sys/fs/pstore manually"
    fi
fi

# ── kernel ring drain (proven shape from the reverted host-health draft) ────
_last=$(cat /var/run/.kring.offset 2>/dev/null)
_max=$(dmesg 2>/dev/null | sed -n 's/^\[ *\([0-9]*\)\.[0-9]*\].*/\1/p' | tail -1)
if [ -n "$_max" ]; then
    if [ -z "$_last" ] || [ "$_max" -lt "$_last" ]; then
        [ -n "$_last" ] && echo "$(date '+%F %T') === ring restarted (reboot detected: $_max < $_last), re-draining ===" >> "$KLOG"
        _last=-1
    fi
    [ -f "$KLOG" ] && [ "$(wc -c < "$KLOG")" -gt 2097152 ] && mv "$KLOG" "$KLOG.1"
    dmesg 2>/dev/null | awk -v last="$_last" -v d="$(date '+%F %T')" '
        match($0, /^\[ *[0-9]+\.[0-9]+\]/) {
            t = $0; sub(/^\[ */, "", t); sub(/\..*/, "", t)
            if (t+0 > last+0) print d " " $0
        }' >> "$KLOG"
    printf '%s' "$_max" > /var/run/.kring.offset
fi

# ── samples ─────────────────────────────────────────────────────────────────
TS=$(date +%s)

set -- $(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5, $8, $6}' /proc/stat)
CPU_TOT=$1; CPU_IDLE=$2; CPU_SIRQ=$3; CPU_IOW=$4

# softnet_stat cols are bare hex; busybox awk has no strtonum but ash does $((0xNN))
SN_D=0; SN_S=0
while read -r _c1 _c2 _c3 _rest; do
    SN_D=$(( SN_D + 0x$_c2 )); SN_S=$(( SN_S + 0x$_c3 ))
done < /proc/net/softnet_stat

IRQ=$(awk '/edma|nss/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i} END{printf "%d", s+0}' /proc/interrupts 2>/dev/null)
CT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
CTMAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)

# ct.n above is the GLOBAL counter: both address families, and every scope
# including LAN<->LAN flows that never touch the ISP NAT. It is therefore useless
# for a CGNAT question, while looking exactly like the number you want — which is
# how it produced a confident wrong answer on 2026-08-09 (2231 "conntrack" read as
# CGNAT pressure against a ~1400 v4 ceiling; the true v4 internet-bound figure was
# 991, and v6 has no CGNAT at all). Keep n/max for continuity, add the breakdown
# that can actually answer the question:
#   v4 / v6  — per-family totals
#   wan4     — ipv4 entries whose ORIGINAL destination is a public address, i.e.
#              flows genuinely egressing to the internet. This is the count
#              comparable to an ISP NAT-session budget. Excludes RFC1918, loopback,
#              link-local, multicast, and 100.64/10 (our own CGNAT + tailscale).
# Single pass over /proc/net/nf_conntrack: ~2 ms against a ~57 ms script budget,
# versus ~10 ms for each `conntrack -L` invocation.
# Per-host "worst offender" identity, for the connlimit alerts: a cap breach names
# a source, and the source alone does not say which device to go and look at.
# v4 comes straight from the DHCP lease; v6 needs the neighbour table (addr->MAC)
# joined to the lease (MAC->name), because a host's v6 addresses are not in the
# lease file. Hosts with no lease (statically configured, e.g. .200) legitimately
# resolve to "unknown" — the IP is still carried, so nothing is hidden.
# ⚠ /proc/net/nf_conntrack writes v6 EXPANDED (8 groups of 4 hex); `ip -6 neigh`
# prints RFC5952-COMPRESSED. Without expanding one side the map NEVER matches and
# every v6 host reports "unknown" — a failure that reads as "no v6 traffic" rather
# than as a bug. Verified 17/19 live addresses match; the 2 that do not are the
# router's own WAN address and a host with an expired neighbour entry, both correct.
IDMAP=/var/run/.obs-idmap
{
  awk '$3 ~ /^[0-9]+\./ && $4 != "*" && $4 != "" {print $3, $4}' /cfg/dhcp.leases 2>/dev/null
  ip -6 neigh show dev br-lan 2>/dev/null | awk '
    function pad(g) { while (length(g) < 4) g = "0" g; return g }
    function expand(a,   lead,tail,nl,nt,i,out,L,T) {
      if (index(a, "::")) {
        lead = substr(a, 1, index(a,"::")-1); tail = substr(a, index(a,"::")+2)
        nl = (lead == "") ? 0 : split(lead, L, ":")
        nt = (tail == "") ? 0 : split(tail, T, ":")
        out = ""
        for (i=1; i<=nl; i++) out = out pad(L[i]) ":"
        for (i=0; i < 8-nl-nt; i++) out = out "0000:"
        for (i=1; i<=nt; i++) out = out pad(T[i]) ":"
        return substr(out, 1, length(out)-1)
      }
      nl = split(a, L, ":"); out = ""
      for (i=1; i<=nl; i++) out = out pad(L[i]) ":"
      return substr(out, 1, length(out)-1)
    }
    NR==FNR { if ($4 != "*" && $4 != "") nm[$2] = $4; next }
    /lladdr/ { m=""
               for (i=1; i<=NF; i++) if ($i == "lladdr") m = $(i+1)
               if (m != "" && (m in nm)) print expand($1), nm[m] }
  ' /cfg/dhcp.leases -
} > "$IDMAP" 2>/dev/null || : > "$IDMAP"

LAN6=$(ip -6 addr show br-lan scope global 2>/dev/null | awk '/inet6 2/{print $2; exit}' | cut -d/ -f1)

# ONE pass produces both the totals and the per-host top-N, deliberately: two
# passes would sample /proc at different instants and the offender counts would
# not sum to the totals in the same record, which is the kind of small
# disagreement that gets read as a bug in whichever number you trust less.
CTOUT=$(awk -v lan6="$LAN6" -v topn=10 '
  function pad(g) { while (length(g) < 4) g = "0" g; return g }
  function expand(a,   lead,tail,nl,nt,i,out,L,T) {
    if (index(a, "::")) {
      lead = substr(a, 1, index(a,"::")-1); tail = substr(a, index(a,"::")+2)
      nl = (lead == "") ? 0 : split(lead, L, ":")
      nt = (tail == "") ? 0 : split(tail, T, ":")
      out = ""
      for (i=1; i<=nl; i++) out = out pad(L[i]) ":"
      for (i=0; i < 8-nl-nt; i++) out = out "0000:"
      for (i=1; i<=nt; i++) out = out pad(T[i]) ":"
      return substr(out, 1, length(out)-1)
    }
    nl = split(a, L, ":"); out = ""
    for (i=1; i<=nl; i++) out = out pad(L[i]) ":"
    return substr(out, 1, length(out)-1)
  }
  function pub4(ip,   p) {
    split(ip, p, ".")
    if (p[1]==127 || p[1]==10 || p[1]==0)            return 0
    if (p[1]==192 && p[2]==168)                      return 0
    if (p[1]==172 && p[2]>=16 && p[2]<=31)           return 0
    if (p[1]==169 && p[2]==254)                      return 0
    if (p[1]==100 && p[2]>=64 && p[2]<=127)          return 0
    if (p[1]>=224)                                   return 0
    return 1
  }
  # Names are kept verbatim, not curated. Only characters that cannot survive a
  # JSON string or a Prometheus label are mapped — a stray quote in a DHCP name
  # would otherwise break the JSON blob and take the WHOLE sample down with it.
  function safe(s) { gsub(/[^A-Za-z0-9._:-]/, "_", s); return s }
  function emit(cnt, N,   i, k, best, bk, out, first) {
    out = "["; first = 1
    for (i = 0; i < N; i++) {
      best = -1; bk = ""
      for (k in cnt) if (!(k in used) && cnt[k] > best) { best = cnt[k]; bk = k }
      if (bk == "") break
      used[bk] = 1
      if (!first) out = out ","
      out = out "{\"h\":\"" safe((bk in nm) ? nm[bk] : "unknown") "\",\"ip\":\"" bk "\",\"n\":" cnt[bk] "}"
      first = 0
    }
    delete used
    return out "]"
  }
  # Ranked by UNANSWERED count, and carrying the denominator with it. The ratio is
  # the interesting number but it is meaningless alone: 1 of 1 is 100% and says
  # nothing. Emitting both lets the consumer gate on a minimum flow count instead
  # of trusting a ratio built from noise.
  function emit_stall(N,   i, k, best, bk, out, first) {
    out = "["; first = 1
    for (i = 0; i < N; i++) {
      best = -1; bk = ""
      for (k in y4) if (!(k in used2) && y4[k] > best) { best = y4[k]; bk = k }
      if (bk == "" || best <= 0) break
      used2[bk] = 1
      if (!first) out = out ","
      out = out "{\"h\":\"" safe((bk in nm) ? nm[bk] : "unknown") "\",\"ip\":\"" bk \
                "\",\"tcp\":" t4[bk]+0 ",\"syn\":" y4[bk]+0 "}"
      first = 0
    }
    delete used2
    return out "]"
  }
  BEGIN { lan6x = (lan6 == "") ? "" : substr(expand(lan6), 1, 19) }
  # The FILENAME guard is load-bearing, not belt-and-braces: with an EMPTY idmap
  # (no leases yet at boot) NR==FNR is still true for the first conntrack line,
  # and that line would be swallowed as a map entry.
  NR==FNR && FILENAME != "/proc/net/nf_conntrack" { nm[$1] = $2; next }
  $1=="ipv4" {
    v4++; s=""; d=""
    for (i=1; i<=NF; i++) {
      if (s=="" && substr($i,1,4)=="src=") s = substr($i,5)
      else if (d=="" && substr($i,1,4)=="dst=") { d = substr($i,5); break }
    }
    if (d != "" && pub4(d)) {
      w4++
      if (s ~ /^192\.168\./) {
        c4[s]++
        # PASSIVE experience signal. An ICMP probe cannot characterise a phone:
        # measured 2026-08-10, an iPhone answered every echo on all 11 minutes it
        # was passing traffic and lost all five on all 5 minutes it was idle, so
        # the probe reports iOS power management rather than the link. Her real
        # traffic has none of that problem — a sleeping device simply opens no
        # connections, so idleness yields NO signal instead of a false one.
        # SYN_SENT is a connection that was attempted and never established,
        # which is literally the reported symptom (the tail of a burst of image
        # or video requests failing to load).
        # State is $6 for tcp lines only; on udp rows $6 is already src=.
        if ($3=="tcp") { t4[s]++; if ($6=="SYN_SENT") y4[s]++ }
      }
    }
    next
  }
  $1=="ipv6" {
    v6++; s=""; d=""
    for (i=1; i<=NF; i++) {
      if (s=="" && substr($i,1,4)=="src=") s = substr($i,5)
      else if (d=="" && substr($i,1,4)=="dst=") { d = substr($i,5); break }
    }
    if (s == "" || d == "") next
    lansrc = (lan6x != "" && substr(s,1,19) == lan6x) || substr(s,1,2) == "fd"
    pubdst = (substr(d,1,1) == "2" || substr(d,1,1) == "3") && \
             !(lan6x != "" && substr(d,1,19) == lan6x)
    if (lansrc && pubdst) c6[s]++
    next
  }
  END {
    printf "TOTALS %d %d %d\n", v4+0, v6+0, w4+0
    printf "TOP4 %s\n", emit(c4, topn)
    printf "TOP6 %s\n", emit(c6, topn)
    printf "STALL4 %s\n", emit_stall(topn)
  }
' "$IDMAP" /proc/net/nf_conntrack 2>/dev/null)

set -- $(printf '%s\n' "$CTOUT" | grep '^TOTALS ')
CT4=$2; CT6=$3; CTW4=$4
TOP4=$(printf '%s\n' "$CTOUT" | sed -n 's/^TOP4 //p')
TOP6=$(printf '%s\n' "$CTOUT" | sed -n 's/^TOP6 //p')
[ -n "$CT4" ] || { CT4=0; CT6=0; CTW4=0; }
[ -n "$TOP4" ] || TOP4="[]"
[ -n "$TOP6" ] || TOP6="[]"
STALL4=$(printf '%s\n' "$CTOUT" | sed -n 's/^STALL4 //p')
[ -n "$STALL4" ] || STALL4="[]"

# Per-interface {rx_bytes,rx_pkts,tx_bytes,tx_pkts} as a JSON object keyed by name
IFJSON=$(awk 'NR>2{
    n=$1; sub(/:$/,"",n)
    if (n=="br-lan"||n=="eth4"||n=="eth5"||n=="pppoe-wan3"||n=="tailscale0") {
        if (s) s=s","
        # rxe/rxd/rxf = rx errs / drop / fifo (cols 4,5,6 of /proc/net/dev).
        # These are the counters a NAPI stall would move, and softnet_dropped is
        # NOT: softnet counts the per-CPU BACKLOG queue (netif_rx path — PPP, TUN,
        # re-injection), while the ethernet here is nss-dp, a NAPI driver whose
        # (NB: no apostrophes in this comment — it lives inside a single-quoted
        # awk program, and one would terminate the string mid-script.)
        # RX never touches that queue. If the CPU-side stack stops draining, packets
        # pile up in the hardware ring and are dropped by the DEVICE, landing here.
        # Collected because INC-11 (br-lan rx frozen, ASIC still forwarding) is the
        # shape softnet may be structurally blind to, and nothing was recording these.
        s=s "\"" n "\":{\"rxb\":" $2 ",\"rxp\":" $3 ",\"rxe\":" $4 ",\"rxd\":" $5 ",\"rxf\":" $6 ",\"txb\":" $10 ",\"txp\":" $11 "}"
    }} END{print "{" s "}"}' /proc/net/dev)

C4=$(cat /sys/class/net/eth4/carrier 2>/dev/null)
C5=$(cat /sys/class/net/eth5/carrier 2>/dev/null)
CBR=$(cat /sys/class/net/br-lan/carrier 2>/dev/null)

A4=$(ip -4 addr show dev br-lan 2>/dev/null | grep -c 'inet ')
AG=$(ip -6 addr show dev br-lan scope global 2>/dev/null | grep -c 'inet6 [23]')
AU=$(ip -6 addr show dev br-lan scope global 2>/dev/null | grep -c 'inet6 f[cd]')
W3=$(ip -4 addr show dev pppoe-wan3 2>/dev/null | grep -c 'inet ')

# L4 DDM — same registers/idiom as odi-health's read_l4_ddm
DHI=$(i2cget -y 0 0x51 0x60 2>/dev/null); DLO=$(i2cget -y 0 0x51 0x61 2>/dev/null)
[ -n "$DHI" ] && [ -n "$DLO" ] && L4T=$(awk "BEGIN{v=($DHI*256)+$DLO; if(v>32767)v-=65536; printf \"%.1f\", v/256}") || L4T=""
DHI=$(i2cget -y 0 0x51 0x66 2>/dev/null); DLO=$(i2cget -y 0 0x51 0x67 2>/dev/null)
[ -n "$DHI" ] && [ -n "$DLO" ] && L4TX=$(awk "BEGIN{v=($DHI*256)+$DLO; if(v>0) printf \"%.2f\", 10*log(v*0.0001)/log(10); else print \"?\"}") || L4TX=""
DHI=$(i2cget -y 0 0x51 0x68 2>/dev/null); DLO=$(i2cget -y 0 0x51 0x69 2>/dev/null)
[ -n "$DHI" ] && [ -n "$DLO" ] && L4RX=$(awk "BEGIN{v=($DHI*256)+$DLO; if(v>0) printf \"%.2f\", 10*log(v*0.0001)/log(10); else print \"?\"}") || L4RX=""

# W2 DDM — daemon cache only (single Boa poller lives in daemon-odi-w2-ddm.sh)
W2T=""; W2TX=""; W2RX=""
if [ -f /var/run/w2-ddm.env ]; then
    . /var/run/w2-ddm.env
    if [ $(( TS - ${W2_TS:-0} )) -le 60 ]; then
        W2T=$W2_T; W2TX=$W2_P; W2RX=$W2_R
    fi
fi

JSON=$(printf '{"cpu":{"tot":%s,"idle":%s,"sirq":%s,"iow":%s},"softnet":{"drop":%s,"squeeze":%s},"irq_edma":%s,"ct":{"n":%s,"max":%s,"v4":%s,"v6":%s,"wan4":%s,"top4":%s,"top6":%s,"stall4":%s},"if":%s,"carrier":{"eth4":%s,"eth5":%s,"brlan":%s},"addr":{"v4":%s,"gua":%s,"ula":%s,"wan3":%s},"ddm":{"l4_t":%s,"l4_tx":%s,"l4_rx":%s,"w2_t":%s,"w2_tx":%s,"w2_rx":%s}}' \
    "$(jnum "$CPU_TOT")" "$(jnum "$CPU_IDLE")" "$(jnum "$CPU_SIRQ")" "$(jnum "$CPU_IOW")" \
    "$(jnum "$SN_D")" "$(jnum "$SN_S")" "$(jnum "$IRQ")" \
    "$(jnum "$CT")" "$(jnum "$CTMAX")" \
    "$(jnum "$CT4")" "$(jnum "$CT6")" "$(jnum "$CTW4")" "$TOP4" "$TOP6" "$STALL4" "$IFJSON" \
    "$(jnum "$C4")" "$(jnum "$C5")" "$(jnum "$CBR")" \
    "$(jnum "$A4")" "$(jnum "$AG")" "$(jnum "$AU")" "$(jnum "$W3")" \
    "$(jnum "$L4T")" "$(jnum "$L4TX")" "$(jnum "$L4RX")" \
    "$(jnum "$W2T")" "$(jnum "$W2TX")" "$(jnum "$W2RX")")

OUT=$(sqlite3 "$DB" "
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS samples (ts INTEGER PRIMARY KEY, json TEXT);
INSERT OR IGNORE INTO samples VALUES ($TS, '$JSON');
DELETE FROM samples WHERE ts < $TS - 30*86400;
" 2>&1) || err "sample insert FAILED: $(echo "$OUT" | head -1)"

# ── wedge tripwire ──────────────────────────────────────────────────────────
# The 2026-08-08 IP-stack wedge left no mechanism evidence because a deadlocked
# kernel emits nothing and nobody can SSH in to ask (the fault kills the LAN).
# So the diagnostic must be PRE-ARMED: if br-lan receives ZERO packets for two
# consecutive minutes while its carrier is up — impossible on this LAN's
# background chatter (ARP/mDNS/DHCP) unless the CPU-side rx path is dead — dump
# the kernel's own view via sysrq into the ring, which this script persists:
#   'w' = show blocked (D-state) tasks — names what a deadlock is stuck on
#   'l' = backtrace all active CPUs
# Diagnostic-only characters; kernel.sysrq=1 verified on this build. One shot
# per 30-min cooldown so a sustained wedge doesn't spam the ring. cron kept
# running through the real wedge, so this path is expected to execute.
BRLAN_RXP=$(echo "$IFJSON" | sed -n 's/.*"br-lan":{"rxb":[0-9]*,"rxp":\([0-9]*\).*/\1/p')
# busy_timeout matters on THIS read, not just on the insert: stats-archive VACUUMs
# /a/obs every 30 min, and a lock here makes sqlite3 exit non-zero — which 2>/dev/null
# turns into an empty PREV_RXP that is indistinguishable from "no prior sample".
PREV_RXP=$(sqlite3 -readonly "$DB" "PRAGMA busy_timeout=5000; SELECT json_extract(json,'\$.if.\"br-lan\".rxp') FROM samples WHERE ts < $TS ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
STALLS=$(cat /var/run/.obs-wedge.stalls 2>/dev/null)
case "$STALLS" in ''|*[!0-9]*) STALLS=0 ;; esac
# ⛔ Validate the two operands SEPARATELY. This used to test the CONCATENATION
# ("$BRLAN_RXP$PREV_RXP"), which cannot see an empty second operand: with
# BRLAN_RXP=8529086 and PREV_RXP="" the joined string is all-digits and non-empty,
# so the guard passed and `[ 8529086 -eq "" ]` reached the shell as "out of range".
# Harmless-looking (rc stayed 0, stderr only) but it meant the wedge counter was
# reset by any condition that emptied PREV_RXP — including archiver lock contention,
# i.e. the tripwire could lose its 2-consecutive-minute streak for reasons that have
# nothing to do with the LAN. Never fired in production (verified 0 occurrences in
# syslog); every sighting was a fresh scratch DB during testing.
_cmp_ok=1
case "$BRLAN_RXP" in ''|*[!0-9]*) _cmp_ok=0 ;; esac
case "$PREV_RXP"  in ''|*[!0-9]*) _cmp_ok=0 ;; esac
if [ "$_cmp_ok" = 1 ]; then
    if [ "$BRLAN_RXP" -eq "$PREV_RXP" ] && [ "${CBR:-0}" = "1" ]; then
        STALLS=$((STALLS+1))
    else
        STALLS=0
    fi
else
    # No comparable baseline (first sample, or the read failed). Conservative: do
    # not count a stall we cannot evidence.
    STALLS=0
fi
printf '%s' "$STALLS" > /var/run/.obs-wedge.stalls
if [ "$STALLS" -ge 2 ]; then
    COOL=/var/run/.obs-wedge.fired
    NOW_OK=1
    if [ -f "$COOL" ]; then
        AGE=$(( TS - $(date -r "$COOL" +%s 2>/dev/null || echo 0) ))
        [ "$AGE" -lt 1800 ] && NOW_OK=0
    fi
    if [ "$NOW_OK" = 1 ]; then
        touch "$COOL"
        echo w > /proc/sysrq-trigger 2>/dev/null
        echo l > /proc/sysrq-trigger 2>/dev/null
        sleep 2
        # Re-drain immediately so the dump reaches /a even if the box degrades
        # further before the next cycle.
        _max=$(dmesg 2>/dev/null | sed -n 's/^\[ *\([0-9]*\)\.[0-9]*\].*/\1/p' | tail -1)
        _last=$(cat /var/run/.kring.offset 2>/dev/null || echo -1)
        dmesg 2>/dev/null | awk -v last="$_last" -v d="$(date '+%F %T')" '
            match($0, /^\[ *[0-9]+\.[0-9]+\]/) {
                t = $0; sub(/^\[ */, "", t); sub(/\..*/, "", t)
                if (t+0 > last+0) print d " " $0
            }' >> "$KLOG"
        [ -n "$_max" ] && printf '%s' "$_max" > /var/run/.kring.offset
        err "WEDGE SIGNATURE: br-lan rx frozen ${STALLS} min with carrier up — sysrq w+l dumped to kernel ring (persisted $KLOG)"
    fi
fi

exit 0
