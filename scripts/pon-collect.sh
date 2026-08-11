#!/bin/sh
# pon-collect.sh — PON-layer telemetry from the ODI stick, every 15 min.
#
# Metric menu from Strykar/GPON (same RTL960x diag CLI); transport is OURS:
# stick-exec.py clean-exit telnet — the ONLY safe path (single-CLI cli.pid
# lock; see project_odi_cli_pid_lock). Their exporter drives the CLI over SSH;
# this stick has no SSH (port 22 refused, measured 2026-08-08).
#
# ⚠ THE DIAG TRAP, learned the hard way (2026-08-08, wedged the CLI once):
# `diag <subcmd>` as a bare busybox command EXECUTES the query and then STAYS in
# diag's interactive RTK.0> prompt — stick-exec's sentinel never returns, the
# timeout closes the socket abruptly, and a /bin/login+/bin/sh session is left
# orphaned holding the single CLI until stick-unwedge.sh (or a reboot) clears it.
# The safe form pipes the whole batch through diag's stdin with a trailing
# `exit`, so diag processes each line and returns to the shell:
#     printf "gpon get onu-state\n...\nexit\n" | diag
# Verified clean + non-wedging 2026-08-08.
#
# Parsers are built against REAL captured output (2026-08-08). diag prints
# `<label> : <value>` with variable spacing; alarms print `Alarm <T>, status: <s>`.
# The full raw blob is stored alongside the parsed fields so a parser can be
# fixed offline against real text without spending another stick session.
#
# Cadence 1-min (2026-08-08): one telnet session per cycle, one uptime read +
# one diag stdin-batch inside it. Safe at this rate because (a) the wedge class
# is structurally gone — see the diag trap above; (b) pon-collect is the SOLE
# stick-CLI user (W2 DDM uses Boa HTTP, odi-health/obs-collect read i2c+caches),
# so no session overlaps another; and (c) the overlap guard below stops cron
# from stacking a second run on a slow one. Arch note: SSH is impossible on this
# stick (Lexra-MIPS / RO squashfs / no dropbear), so telnet is the only path —
# see reference_odi_stick_arch_no_ssh.
#
# Row: pon(ts, json, raw) in /a/obs/rt.sql. Clean rows are ~200 B (raw stored
# ONLY on a parse anomaly, see below) ⇒ ≈0.3 MB/day, ~9 MB over the 30-day
# prune even at 1-min. Wedge handling: warn on TRANSITION to unreachable, event
# on recovery — a wedged CLI fails fast (empty banner) and probing it via
# stick-exec does not deepen the wedge.
#
# Install: scp to /cfg/scripts/pon-collect.sh, chmod +x
# Cron:    * * * * *  (reinstalled each boot by post-cfg.sh)
# Log:     /cfg/scripts/pon-collect.log

DB=/a/obs/rt.sql
LOG=/cfg/scripts/pon-collect.log
STATE=/var/run/.pon-collect.down
LOCK=/var/run/.pon-collect.lock
STICK_EXEC=/cfg/scripts/stick-exec.py

obs_syslog() { :; }
. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init pon-collect "$LOG" \
  || { log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }; event(){ log "$@"; }; warn(){ log "$@"; }; err(){ log "$@"; }; }

# ── overlap guard ───────────────────────────────────────────────────────────
# At the 1-min cadence a slow or hung session (stick-exec has its own timeout,
# but the mgmt path can stall) must NOT be doubled by the next cron tick — two
# concurrent telnet sessions would collide on the stick's single-CLI lock and
# manufacture a false "wedged" reading.
#
# The lock is a DIRECTORY, not a file: `mkdir` is atomic on the filesystem, so
# two instances starting in the same instant can't both win (a plain
# [ -f ] test-then-write races — verified). /var/run is tmpfs, so a reboot
# clears a leaked lock for free; the only in-boot leak is a SIGKILL'd holder,
# which the pid staleness check below reclaims.
if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -f "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
        exit 0                                   # a live instance holds it — skip
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0   # stale holder — reclaim
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

TS=$(date +%s)

# One clean session: uptime (reboot detection) + the diag batch via stdin pipe.
DIAG='printf "gpon get onu-state\ngpon get alarm-status\ngpon get rogue-sd-cnt\ngpon show counter global ds-phy\ngpon show counter global ds-plm\ngpon show counter global active\ngpon show counter global us-plm\ngpon show counter global us-phy\ngpon show counter global ds-omci\ngpon show counter global ds-bw\ngpon show counter global us-omci\ngpon show counter global ds-gem\ngpon show counter global ds-eth\ngpon show counter global us-dbr\ngpon show counter global us-gem\nexit\n" | diag'

# ── OMCI message log drain ──────────────────────────────────────────────────
# The stick can log OMCI messages (the OLT's actual instruction channel) via
# `omcicli set logfile <mode> <actMask>` -- mode 2=Parsed | 4=WithTimestamp.
# It writes to /tmp/omcilog, which is tmpfs and therefore lost on every stick
# reboot, so we drain it into the same /a sqlite DB as everything else and
# truncate. Riding the EXISTING once-a-minute session keeps pon-collect the
# sole CLI user (a separate cron would be a second one -- see the wedge notes).
#
# ⚠ PARSED MODE WRITES TO `<logfile>.par`, NOT the path `omcicli get logfile`
# reports. `get logfile` says "/tmp/omcilog"; with mode 2/6 (Parsed) the output
# actually lands in /tmp/omcilog.par and the reported path stays 0 bytes. That
# cost hours on 2026-08-11 -- the empty file was read as "the feature is a stub"
# when 281 KB of the OLT's conversation was sitting in the sibling path. Drain
# BOTH: raw mode (1) uses the bare name, parsed (2) uses .par.
#
# The sentinels are written __OMCI''LOG_* so the ECHOED command line (telnet
# echoes what we send) does not itself match the sed range that extracts the
# body -- otherwise the drain would capture its own command.
OMCI_LOGMODE=6
OMCI_LOGMASK=0x3FFFFFFF
OMCIDRAIN="echo __OMCI''LOG_S__; cat /tmp/omcilog.par /tmp/omcilog 2>/dev/null; echo __OMCI''LOG_E__; : > /tmp/omcilog.par; : > /tmp/omcilog"
poll_stick() { python3 "$STICK_EXEC" "cat /proc/uptime" "$DIAG" "$OMCIDRAIN" 2>&1; }
is_wedged() { case "$1" in *WEDGED*|*"ERR:"*|'') return 0 ;; *) return 1 ;; esac; }

RAW=$(poll_stick)

# ── self-heal on a wedged CLI ───────────────────────────────────────────────
# A wedge (an orphaned /bin/login+/bin/sh session — see project_odi_cli_pid_lock)
# otherwise stales PON indefinitely until a human runs stick-unwedge. At 1-min
# unattended cadence that's the wrong failure mode: bound it. On a detected
# wedge, run the no-reboot unwedge ONCE and re-poll. Rate-limited to one attempt
# per 5 min (a persistent wedge that unwedge can't fix — e.g. needs a reboot —
# must not hammer Boa), tracked in .pon-collect.heal. The overlap lock is still
# held across this, so the extra ~15 s can't stack with the next cron tick.
if is_wedged "$RAW" && [ -x /cfg/scripts/stick-unwedge.sh ]; then
    _last_heal=$(cat /var/run/.pon-collect.heal 2>/dev/null || echo 0)
    case "$_last_heal" in *[!0-9]*|'') _last_heal=0 ;; esac
    if [ $(( $(date +%s) - _last_heal )) -ge 300 ]; then
        date +%s > /var/run/.pon-collect.heal
        /cfg/scripts/stick-unwedge.sh >/dev/null 2>&1
        RAW=$(poll_stick)
        is_wedged "$RAW" || event "stick CLI recovered via auto-unwedge"
    fi
fi

if is_wedged "$RAW"; then
    if [ ! -f "$STATE" ]; then
        warn "stick CLI wedged, auto-unwedge did not recover ($(printf '%s' "$RAW" | head -c 60)) — PON paused; will event on recovery"
        touch "$STATE"
    fi
    exit 0
fi
[ -f "$STATE" ] && { rm -f "$STATE"; event "stick CLI recovered — PON telemetry resumed"; }

# ── split the OMCI drain out of RAW before anything parses it ───────────────
# Must happen before the val()/alarm() greps: OMCI log text is arbitrary and
# could otherwise collide with a counter label. Capped at 32 KB/cycle so a
# chatty or runaway log cannot bloat a row (the /a/obs 500 MB janitor in
# stats-archive.sh is the backstop, not the first line of defence).
# ⚠ The cat-then-truncate is not atomic: a message written between the two
# is lost. At OMCI rates that window is negligible, and losing a line beats
# re-ingesting the whole file every minute.
_omci_body=$(printf '%s\n' "$RAW" | sed -n '/__OMCILOG_S__/,/__OMCILOG_E__/p' | sed '1d;$d')
OMCILOG=$(printf '%s' "$_omci_body" | head -c 32000 | sed "s/'/''/g")
# Never truncate silently -- a capped capture that looks complete is how a
# missing signal gets read as an absent one.
[ ${#_omci_body} -gt 32000 ] && warn "OMCI drain truncated: ${#_omci_body} B drained, 32000 B stored (steady state is ~6 KB/min)"

# ── upstream loss, measured from OMCI retransmissions ───────────────────────
# THE signal this whole drain exists for. The OLT re-sends a request with the
# SAME transaction ID on a ~1 s timeout when it does not receive our reply. So
# duplicate request TCIs are a DIRECT read of upstream loss -- the one
# direction nothing else on this box can measure. DDM reports the light we
# EMIT, never what the OLT receives; these retransmissions are the OLT telling
# us, in its own words, what it did not get.
#
# Measured 2026-08-11: 332/1810 = 18.3% while the ONU answered every request
# correctly. That killed the PLOAM-password theory (auth passes -- the OLT
# gets all the way to MIB upload) and proved physical upstream impairment.
#
# Requests are lines whose op does not end in `Rsp`. TCI reuse inside one
# 60-s drain is not a concern: they increment sequentially through a 16-bit
# space and we see a few hundred per cycle, so a wrap cannot alias here.
_omci_reqs=$(printf '%s\n' "$_omci_body" \
    | sed -n 's/^\[[^]]*\][[:space:]]*\(0x[0-9a-f]*\)[[:space:]][^ ]*[[:space:]]*\([A-Za-z]*\)(.*/\1 \2/p' \
    | grep -v 'Rsp$' | cut -d' ' -f1 | grep '^0x')
OMCI_REQ=$(printf '%s\n' "$_omci_reqs" | grep -c '^0x')
OMCI_RETX=$(( OMCI_REQ - $(printf '%s\n' "$_omci_reqs" | sort -u | grep -c '^0x') ))

# Healthy is ~0 by construction (a delivered reply is never re-requested), so
# a sustained ratio is structural evidence, not a tuned threshold. Gated on a
# sample size so a 1-of-2 blip cannot read as 50% loss. The healthy baseline
# is genuinely unmeasured -- this counter was born during the fault.
if [ "$OMCI_REQ" -ge 20 ] && [ "$OMCI_RETX" -gt 0 ]; then
    _pct=$(( OMCI_RETX * 100 / OMCI_REQ ))
    [ "$_pct" -ge 5 ] && warn "UPSTREAM LOSS ${_pct}% — OLT retransmitted ${OMCI_RETX}/${OMCI_REQ} OMCI requests (our replies are not reaching it; DDM cannot see this direction)"
fi
RAW=$(printf '%s\n' "$RAW" | sed '/__OMCILOG_S__/,/__OMCILOG_E__/d')

# ── parsers (against real 2026-08-08 output) ────────────────────────────────
# `<label> : <value>` — grep the label, take the last colon-separated integer.
val() {
    printf '%s\n' "$RAW" | grep -m1 -- "$1" \
        | sed -n 's/.*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}
# alarm: `Alarm <TYPE>, status: clear|<other>` → 0 clear, 1 otherwise, null absent
alarm() {
    _l=$(printf '%s\n' "$RAW" | grep -m1 -- "Alarm $1,")
    [ -z "$_l" ] && { echo null; return; }
    case "$_l" in *clear*) echo 0 ;; *) echo 1 ;; esac
}
nz() { case "$1" in ''|*[!0-9]*) echo null ;; *) echo "$1" ;; esac; }

UPTIME=$(printf '%s\n' "$RAW" | sed -n 's/^\([0-9][0-9]*\)\.[0-9].*/\1/p' | head -1)
# Match the state number generically, NOT just "Operation State(O5)". Each
# state has its own label — "Standby State(O2)", "Serial Number State(O3)",
# "Ranging State(O4)", "Emergency Stop State(O7)" — so an O5-only regex left
# every non-operational state parsing as null, i.e. indistinguishable from a
# broken parser AND from each other. That mattered on 2026-08-11: O7 (the OLT
# sent Disable_Serial_Number — a DELIBERATE refusal of this ONU) read exactly
# like O2 (harmless standby), so the metrics could not tell "we are banned"
# from "we are mid-activation".
ONU=$(printf '%s\n' "$RAW" | sed -n 's/.*State(O\([0-9]\)).*/\1/p' | head -1)

# O7 is the ONE state that says the OLT is refusing us ON PURPOSE: it is
# entered only on a Disable_Serial_Number PLOAM (ban, SN conflict, or a
# deprovisioned line). Every other non-O5 state is the activation cycle
# failing to complete — a link problem, not a decision. Alerting on them
# separately is the whole point: "they cut us off" and "the link won't hold"
# need opposite responses, and the O5-only regex above used to make the two
# look identical. Emitted-error alert (never a silence check) — the string is
# stable, ops may key a rule on it.
if [ "$ONU" = "7" ]; then
    warn "onu_state=O7 EMERGENCY STOP — OLT sent Disable_Serial_Number: deliberate refusal of this ONU (ban/SN-conflict/deprovision), NOT a link fault"
fi

BIP_BITS=$(val "BIP Error bits")
BIP_BLK=$(val "BIP Error blocks")
FEC_COR=$(val "FEC Correct codewords")
FEC_UNC=$(val "FEC codewords Uncor")
SF_LOS=$(val "Superframe LOS")
PLOAM_RX=$(val "Total RX PLOAM")
PLOAM_CRC=$(val "CRC Err RX PLOAM")
ROGUE_LONG=$(val "SD too long count")
ROGUE_MIS=$(val "SD mismatch count")

# ── activation / upstream / OMCI / BWMAP counters ───────────────────────────
# Added 2026-08-11 after an outage that took an hour to characterise using
# exactly these five counter groups, read by hand. They answer the questions
# the ds-phy/ds-plm set cannot:
#   active   RANGING_REQ is the loop detector. A healthy ONU ranges ONCE and
#            stays in O5, so a sustained non-zero rate IS the "activating and
#            being dropped" fault, named directly instead of inferred from a
#            state that happens to read O2 at each 60-s sample.
#   us-plm   TX_SN_PLOAM proves OUR side answers the OLT -- it separates "our
#            laser is dead" from "the OLT will not keep us", which the local
#            DDM cannot do (it reads emitted light, never what the OLT hears).
#   us-phy   TX_BOH: upstream bursts actually leaving.
#   ds-omci  provisioning progress. OMCI only starts AFTER activation
#            succeeds, so ~0 here while ranging churns places the failure
#            before OMCI -- which is what pointed at the pre-OMCI gate.
#   ds-bw    grant-layer integrity; BWMAP CRC/invalid can rise while ds-phy
#            BIP/FEC stay clean.
SN_REQ=$(val "SN Req")
RANGING_REQ=$(val "Ranging Req")
TX_SN_PLOAM=$(val "TX S/N PLOAM")
TX_BOH=$(val "TX BOH")
OMCI_PROC=$(val "Processed OMCI")
OMCI_DROP=$(val "Dropped OMCI")
BW_CRC=$(val "CRC Err RX BwMap")
BW_INV0=$(val "Invalid BwMap 0")
BW_INV1=$(val "Invalid BwMap 1")

# ── second wave: layers we were entirely blind to (added 2026-08-11) ────────
# Audit after the outage: we were exporting 14 of the ~52 counter fields the
# stick actually offers. DS GEM, DS ETH, US OMCI and US DBR were collected
# ZERO percent -- i.e. the GEM and ethernet layers of the downstream path had
# no telemetry at all, and OMCI was measured in one direction only.
#
# ⚠ RESET SEMANTICS ARE PER-FIELD, NOT PER-GROUP. Measured by double-read
# 12 s apart on 2026-08-11: within DS OMCI, `Processed OMCI` resets on read
# while `Total RX OMCI` is cumulative-since-boot. Accumulating a cumulative
# counter double-counts without bound, so the two classes are handled
# separately below. Anything reset-on-read goes through acc(); anything
# cumulative is stored raw and left for Prometheus, whose counter semantics
# already handle the reset at stick reboot.
PLEN_FAIL=$(val "PLEN fail")
PLOAM_PROC=$(val "Proc RX PLOAMd")
PLOAM_OVF=$(val "Overflow Rx PLOAM")
PLOAM_UNK=$(val "Unknown Rx PLOAM")
OMCI_CRC=$(val "CRC Error OMCI")
BW_TOTAL=$(val "Total RX BwMap")
BW_OVF=$(val "Overflow BwMap")
GEM_LOS=$(val "D/S GEM LOS")
GEM_HEC=$(val "D/S HEC correct")
GEM_MISLEN=$(val "Mis GEM Pkt Len")
GEM_OVIL=$(val "Over Interleave")
ETH_FCS=$(val "FCS Error")
US_DBRU=$(val "TX DBRu")
# cumulative-since-boot -- do NOT accumulate these two
OMCI_RX_TOT=$(val "Total RX OMCI")
OMCI_TX_TOT=$(val "total TX OMCI")

# ── third wave: the remainder, so the set is COMPLETE ───────────────────────
# Everything the stick's `show counter global` groups expose is now collected.
# The previous cut kept only what looked diagnostic and dropped 22 fields as
# "redundant" -- a judgement that does not survive 2026-08-11, where two hours
# were spent blind because the counter that mattered had been judged not worth
# collecting. Each field is ~10 B/row; optionality is worth more than the bytes.
#
# ⚠ SOME OF THESE SATURATE RATHER THAN WRAP. Observed 65535 on TX BOH, Total TX
# PLOAM, TX NoMsg PLOAM and TX GEM Blocks, and 4294967295 on D/S GEM Idle, when
# a long interval elapsed between reads. A saturated sample is a FLOOR, not a
# true count -- so a delta spanning a gap under-reports and can never be trusted
# as an absolute. Treat these as "did activity occur" signals, not volumes.
FEC_COR_BITS=$(val "FEC Correct bits")
FEC_COR_BYTES=$(val "FEC Correct bytes")
PLEN_OK=$(val "PLEN correct")
USP_TOTAL=$(val "Total TX PLOAM")
USP_PROC=$(val "Process TX PLOAM")
USP_URG=$(val "TX Urgent PLOAM")
USP_PURG=$(val "Proc Urg PLOAM")
USP_NORM=$(val "TX Normal PLOAM")
USP_PNRM=$(val "Proc Nrm PLOAM")
USP_NOMSG=$(val "TX NoMsg PLOAM")
USO_PROC=$(val "Process OMCI")
GEM_IDLE=$(val "D/S GEM Idle")
GEM_NONIDLE=$(val "D/S GEM Non Idle")
GEM_MFM=$(val "Multi Flow Match")
USG_BYTES=$(val "TX GEM Bytes")
ETH_UNI=$(val "Total Unicast")
ETH_MCAST=$(val "Total Multicast")
ETH_FWD_MC=$(val "Fwd Multicast")
ETH_LEAK_MC=$(val "Leak Multicast")
# cumulative-since-boot (measured): byte counts and TX GEM Blocks
OMCI_RX_B=$(val "RX OMCI byte")
OMCI_TX_B=$(val "TX OMCI byte")
USG_BLOCKS=$(val "TX GEM Blocks")

# Re-activation loop alert. These counters reset on read, so RANGING_REQ is
# already "rangings in the last minute" -- no rate maths needed. Threshold 3
# tolerates a legitimate one-off re-activation (recovery, stick reboot) while
# the fault case sits an order of magnitude above it (~10/min measured on
# 2026-08-11). Emitted-error alert, never a silence check.
# NOTE: deliberately NOT alerting on SN_REQ. That counts the OLT's broadcast
# discovery window and ran ~30-38/min throughout the outage; it is background
# traffic, and we have no healthy baseline for it yet, so treating it as a
# fault signal would manufacture a permanent false alarm.
case "$RANGING_REQ" in
    ''|*[!0-9]*) ;;
    *) [ "$RANGING_REQ" -ge 3 ] && warn "PON re-activation loop: ranging_req=$RANGING_REQ in this cycle (onu_state=${ONU:-?}) — OLT is ranging then dropping us; healthy is 0" ;;
esac

# ── saturation tripwire ─────────────────────────────────────────────────────
# These counters SATURATE rather than wrap: they stop at 0xFFFF / 0xFFFFFFFF.
# A saturated sample is a FLOOR, not a count, so the interval it covers is
# under-reported -- and aggregation hides that perfectly, which is the failure
# mode this whole day has been about. Detect it instead of eating it.
#
# Measured headroom at the 60 s sole-reader cadence (2026-08-11): TX BOH 12-19
# vs 65535 (~3400x), BWmap ~960k vs 4.29e9 (~4400x) -- both fine. But GEM Idle
# runs 3.44e9/min against a 4.29e9 cap: only 1.25x, so it saturates on any
# cycle longer than ~75 s. Cycles DO stretch (wedge self-heal adds ~15 s, a
# missed cron tick, a slow telnet session), so this will fire occasionally and
# legitimately. It names the field rather than silently under-counting it.
_sat=""
for _f in "bip_bits=$BIP_BITS" "bip_blocks=$BIP_BLK" "ploam_rx=$PLOAM_RX" \
          "tx_boh=$TX_BOH" "usp_total=$USP_TOTAL" "usp_nomsg=$USP_NOMSG" \
          "bw_total=$BW_TOTAL" "gem_idle=$GEM_IDLE" "gem_nonidle=$GEM_NONIDLE" \
          "usg_bytes=$USG_BYTES" "eth_unicast=$ETH_UNI"; do
    case "${_f#*=}" in
        65535|4294967295) _sat="$_sat ${_f%%=*}" ;;
    esac
done
[ -n "$_sat" ] && warn "counter SATURATED (floor, not a count -- this interval under-reports):$_sat"

# ── accumulate the ds counters into running totals ──────────────────────────
# The stick's ds-phy/ds-plm counters RESET ON EVERY READ (proven 2026-08-08:
# two reads 1 s apart returned 60 then 0) — each poll's value is "count since
# the last read", NOT a running total. The /metrics exporter publishes these
# fields as Prometheus *_total counters, and a reset-every-scrape value makes
# rate() hallucinate (the phantom humps on the first PON Grafana panel), so
# accumulate here. State is the pon_totals table of the same DB: written in
# the same sqlite3 invocation as the row insert and reboot-proof (/a). A
# missed cycle loses nothing (the next read carries the whole gap); a stick
# reboot loses at most one interval — inherent to reset-on-read. An
# out-of-band manual `gpon show counter` also steals one interval's delta;
# acceptable, pon-collect is the sole CLI user. A field that fails to parse
# stays null in the row (preserving the raw-blob anomaly trigger below) and
# leaves its total untouched. Rogue-SD counters come from a `get` (not a
# resetting `show counter`) and are stored raw. NOTE: rows before 2026-08-09
# hold the raw per-read deltas, not totals.
eval "$(sqlite3 -readonly "$DB" "SELECT 'T_'||k||'='||v FROM pon_totals;" 2>/dev/null | grep -E '^T_[a-z_]+=[0-9]+$')"
TOTAL_SQL=""
acc() {   # $1=key $2=per-read delta → sets ACC to the new total ('' if unparsable)
    ACC=''
    case "$2" in ''|*[!0-9]*) return ;; esac
    eval "_t=\${T_$1:-0}"
    ACC=$((_t + $2))
    TOTAL_SQL="${TOTAL_SQL}INSERT OR REPLACE INTO pon_totals VALUES ('$1',$ACC);"
}
acc bip_bits     "$BIP_BITS";  BIP_BITS=$ACC
acc bip_blocks   "$BIP_BLK";   BIP_BLK=$ACC
acc fec_cor_cw   "$FEC_COR";   FEC_COR=$ACC
acc fec_uncor_cw "$FEC_UNC";   FEC_UNC=$ACC
acc sf_los       "$SF_LOS";    SF_LOS=$ACC
acc ploam_rx     "$PLOAM_RX";  PLOAM_RX=$ACC
acc ploam_crc    "$PLOAM_CRC"; PLOAM_CRC=$ACC
# Same reset-on-read contract as the ds set above, so same accumulation. The
# alert above already consumed the per-cycle delta, which is why it runs
# BEFORE this point -- acc() overwrites each variable with the running total.
acc sn_req       "$SN_REQ";      SN_REQ=$ACC
acc ranging_req  "$RANGING_REQ"; RANGING_REQ=$ACC
acc tx_sn_ploam  "$TX_SN_PLOAM"; TX_SN_PLOAM=$ACC
acc tx_boh       "$TX_BOH";      TX_BOH=$ACC
acc omci_proc    "$OMCI_PROC";   OMCI_PROC=$ACC
acc omci_drop    "$OMCI_DROP";   OMCI_DROP=$ACC
acc bw_crc_err   "$BW_CRC";      BW_CRC=$ACC
acc bw_invalid0  "$BW_INV0";     BW_INV0=$ACC
acc bw_invalid1  "$BW_INV1";     BW_INV1=$ACC
acc omci_req     "$OMCI_REQ";    OMCI_REQ=$ACC
acc omci_retx    "$OMCI_RETX";   OMCI_RETX=$ACC
acc plen_fail    "$PLEN_FAIL";   PLEN_FAIL=$ACC
acc ploam_proc   "$PLOAM_PROC";  PLOAM_PROC=$ACC
acc ploam_ovf    "$PLOAM_OVF";   PLOAM_OVF=$ACC
acc ploam_unk    "$PLOAM_UNK";   PLOAM_UNK=$ACC
acc omci_crc     "$OMCI_CRC";    OMCI_CRC=$ACC
acc bw_total     "$BW_TOTAL";    BW_TOTAL=$ACC
acc bw_ovf       "$BW_OVF";      BW_OVF=$ACC
acc gem_los      "$GEM_LOS";     GEM_LOS=$ACC
acc gem_hec      "$GEM_HEC";     GEM_HEC=$ACC
acc gem_mislen   "$GEM_MISLEN";  GEM_MISLEN=$ACC
acc gem_ovil     "$GEM_OVIL";    GEM_OVIL=$ACC
acc eth_fcs      "$ETH_FCS";     ETH_FCS=$ACC
acc us_dbru      "$US_DBRU";     US_DBRU=$ACC
acc fec_cor_bits "$FEC_COR_BITS";  FEC_COR_BITS=$ACC
acc fec_cor_byte "$FEC_COR_BYTES"; FEC_COR_BYTES=$ACC
acc plen_ok      "$PLEN_OK";       PLEN_OK=$ACC
acc usp_total    "$USP_TOTAL";     USP_TOTAL=$ACC
acc usp_proc     "$USP_PROC";      USP_PROC=$ACC
acc usp_urg      "$USP_URG";       USP_URG=$ACC
acc usp_purg     "$USP_PURG";      USP_PURG=$ACC
acc usp_norm     "$USP_NORM";      USP_NORM=$ACC
acc usp_pnrm     "$USP_PNRM";      USP_PNRM=$ACC
acc usp_nomsg    "$USP_NOMSG";     USP_NOMSG=$ACC
acc uso_proc     "$USO_PROC";      USO_PROC=$ACC
acc gem_idle     "$GEM_IDLE";      GEM_IDLE=$ACC
acc gem_nonidle  "$GEM_NONIDLE";   GEM_NONIDLE=$ACC
acc gem_mfm      "$GEM_MFM";       GEM_MFM=$ACC
acc usg_bytes    "$USG_BYTES";     USG_BYTES=$ACC
acc eth_uni      "$ETH_UNI";       ETH_UNI=$ACC
acc eth_mcast    "$ETH_MCAST";     ETH_MCAST=$ACC
acc eth_fwd_mc   "$ETH_FWD_MC";    ETH_FWD_MC=$ACC
acc eth_leak_mc  "$ETH_LEAK_MC";   ETH_LEAK_MC=$ACC
# OMCI_RX_B / OMCI_TX_B / USG_BLOCKS are cumulative -- NOT accumulated
# OMCI_RX_TOT / OMCI_TX_TOT are cumulative -- deliberately NOT passed to acc()

JSON=$(printf '{"uptime":%s,"onu_state":%s,"alarm":{"los":%s,"lof":%s,"lom":%s,"sf":%s,"sd":%s,"tx_too_long":%s,"tx_mismatch":%s},"ds":{"bip_bits":%s,"bip_blocks":%s,"fec_cor_cw":%s,"fec_uncor_cw":%s,"sf_los":%s,"ploam_rx":%s,"ploam_crc":%s},"rogue":{"sd_too_long":%s,"sd_mismatch":%s},"act":{"sn_req":%s,"ranging_req":%s},"us":{"tx_sn_ploam":%s,"tx_boh":%s},"omci":{"processed":%s,"dropped":%s},"bw":{"crc_err":%s,"invalid0":%s,"invalid1":%s},"omci_tx":{"req":%s,"retx":%s},"ds2":{"plen_fail":%s,"ploam_proc":%s,"ploam_ovf":%s,"ploam_unk":%s,"bw_total":%s,"bw_ovf":%s},"gem":{"los":%s,"hec":%s,"mislen":%s,"over_il":%s},"eth":{"fcs_err":%s},"us2":{"dbru":%s},"omci2":{"crc_err":%s,"rx_total":%s,"tx_total":%s,"rx_bytes":%s,"tx_bytes":%s,"us_proc":%s},"ds3":{"fec_cor_bits":%s,"fec_cor_bytes":%s,"plen_ok":%s},"usp":{"total":%s,"proc":%s,"urg":%s,"proc_urg":%s,"normal":%s,"proc_nrm":%s,"nomsg":%s},"gem2":{"idle":%s,"nonidle":%s,"multiflow":%s,"us_blocks":%s,"us_bytes":%s},"eth2":{"unicast":%s,"multicast":%s,"fwd_mcast":%s,"leak_mcast":%s}}' \
    "$(nz "$UPTIME")" "$(nz "$ONU")" \
    "$(alarm LOS)" "$(alarm LOF)" "$(alarm LOM)" "$(alarm SF)" "$(alarm SD)" \
    "$(alarm 'TX Too Long')" "$(alarm 'TX Mismatch')" \
    "$(nz "$BIP_BITS")" "$(nz "$BIP_BLK")" "$(nz "$FEC_COR")" "$(nz "$FEC_UNC")" \
    "$(nz "$SF_LOS")" "$(nz "$PLOAM_RX")" "$(nz "$PLOAM_CRC")" \
    "$(nz "$ROGUE_LONG")" "$(nz "$ROGUE_MIS")" \
    "$(nz "$SN_REQ")" "$(nz "$RANGING_REQ")" \
    "$(nz "$TX_SN_PLOAM")" "$(nz "$TX_BOH")" \
    "$(nz "$OMCI_PROC")" "$(nz "$OMCI_DROP")" \
    "$(nz "$BW_CRC")" "$(nz "$BW_INV0")" "$(nz "$BW_INV1")" \
    "$(nz "$OMCI_REQ")" "$(nz "$OMCI_RETX")" \
    "$(nz "$PLEN_FAIL")" "$(nz "$PLOAM_PROC")" "$(nz "$PLOAM_OVF")" "$(nz "$PLOAM_UNK")" \
    "$(nz "$BW_TOTAL")" "$(nz "$BW_OVF")" \
    "$(nz "$GEM_LOS")" "$(nz "$GEM_HEC")" "$(nz "$GEM_MISLEN")" "$(nz "$GEM_OVIL")" \
    "$(nz "$ETH_FCS")" "$(nz "$US_DBRU")" \
    "$(nz "$OMCI_CRC")" "$(nz "$OMCI_RX_TOT")" "$(nz "$OMCI_TX_TOT")" \
    "$(nz "$OMCI_RX_B")" "$(nz "$OMCI_TX_B")" "$(nz "$USO_PROC")" \
    "$(nz "$FEC_COR_BITS")" "$(nz "$FEC_COR_BYTES")" "$(nz "$PLEN_OK")" \
    "$(nz "$USP_TOTAL")" "$(nz "$USP_PROC")" "$(nz "$USP_URG")" "$(nz "$USP_PURG")" \
    "$(nz "$USP_NORM")" "$(nz "$USP_PNRM")" "$(nz "$USP_NOMSG")" \
    "$(nz "$GEM_IDLE")" "$(nz "$GEM_NONIDLE")" "$(nz "$GEM_MFM")" \
    "$(nz "$USG_BLOCKS")" "$(nz "$USG_BYTES")" \
    "$(nz "$ETH_UNI")" "$(nz "$ETH_MCAST")" "$(nz "$ETH_FWD_MC")" "$(nz "$ETH_LEAK_MC")")

# Store the raw diag blob ONLY when a field failed to parse (JSON contains a
# null). Parsers are verified against real output, so a healthy row is all
# numbers and needs no raw copy — which keeps the 1-min cadence cheap: a clean
# row is ~200 B (≈0.3 MB/day, ~9 MB over the 30-day window) instead of ~6 KB.
# A parse anomaly is exactly the case worth keeping full context for.
#
# Wedge handling: on a wedged CLI, self-heal via stick-unwedge (no reboot),
# rate-limited to once/5min; if that fails, warn on TRANSITION to unreachable
# and event on recovery (never every cycle). So a healthy steady state is a
# 60-s cadence; a wedge costs ~1-2 cycles, not an open-ended stall.
#
# Also kept whenever the ONU is NOT in O5. Until 2026-08-11 those rows carried
# a raw blob only as a side effect of the O5-only state regex (every other
# state parsed as null); generalising that regex would have silently dropped
# the one blob worth having — the 2026-08-11 outage was diagnosed entirely
# from raws captured during the O2/O3/O4 cycle. A non-operational PON is a
# bounded window, so the ~6 KB/min only applies while something is wrong.
# Only rows with actual OMCI text are stored -- an empty drain writes nothing,
# so the table stays empty rather than filling with blank per-minute rows.
# 7-day retention, NOT the 30 d the other tables use. Measured 2026-08-11:
# a faulting PON produces ~9.6 KB/min of OMCI text = ~13.8 MB/day, so 30 d
# would be ~415 MB against a 500 MB /a/obs budget. That does not merely
# overflow -- it makes the stats-archive janitor trim OLDEST across all of
# /a/obs, so bulk forensic text would evict the downsampled 2-year rollups.
# Backwards: the raw log is the thing with the shortest useful life here.
#
# Nothing durable is lost by the shorter window, because the SIGNAL is already
# rolled up elsewhere at full retention: omci_tx.req / omci_tx.retx are
# per-minute counts in the `pon` row (30 d) and exported as
# route10_pon_omci_{requests,retransmits}_total. This table holds the TEXT,
# which is forensic and wanted for days. 7 d worst case is ~97 MB (19% of
# budget) and only while continuously faulting; a healthy PON is far quieter.
OMCI_SQL=""
[ -n "$OMCILOG" ] && OMCI_SQL="INSERT OR IGNORE INTO omci VALUES($TS,'$OMCILOG');DELETE FROM omci WHERE ts < $TS - 7*86400;"

_raw_keep() { printf '%s' "$RAW" | head -c 6000 | sed "s/'/''/g"; }
case "$JSON" in
    *null*)             RAW_COL=$(_raw_keep) ;;
    *'"onu_state":5,'*) RAW_COL='' ;;
    *)                  RAW_COL=$(_raw_keep) ;;
esac
sqlite3 "$DB" "
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS pon (ts INTEGER PRIMARY KEY, json TEXT, raw TEXT);
CREATE TABLE IF NOT EXISTS pon_totals (k TEXT PRIMARY KEY, v INTEGER);
CREATE TABLE IF NOT EXISTS omci (ts INTEGER PRIMARY KEY, log TEXT);
INSERT OR IGNORE INTO pon VALUES ($TS, '$JSON', '$RAW_COL');
$TOTAL_SQL
$OMCI_SQL
DELETE FROM pon WHERE ts < $TS - 30*86400;
" 2>&1 | grep -qi error && err "pon insert issue (see stderr)"

# ── optical thresholds (static; at most once a day) ─────────────────────────
# Runs HERE, inside our lock, so route10 keeps exactly ONE stick-CLI user. It
# must never get its own cron entry -- a second concurrent telnet session is
# the wedge class this script is built to avoid. Self-rate-limits internally.
[ -x /cfg/scripts/optical-thresholds.sh ] && /cfg/scripts/optical-thresholds.sh >/dev/null 2>&1

# Stick reboot: uptime going backwards is worth a line (and resets the counters).
# Both operands must be validated separately — an empty PREV_UP (first run) fed to
# `[ -lt ]` is a shell error, not a skip.
PREV_UP=$(sqlite3 -readonly "$DB" "SELECT json_extract(json,'\$.uptime') FROM pon WHERE ts < $TS ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
case "$UPTIME" in ''|*[!0-9]*) : ;; *)
    case "$PREV_UP" in ''|*[!0-9]*) : ;; *)
        if [ "$UPTIME" -lt "$PREV_UP" ]; then
            event "stick REBOOTED: uptime ${PREV_UP}s -> ${UPTIME}s (PON counters reset)"
            # The OMCI logger is RUNTIME-ONLY: omci_app is started with
            # `-f off 0`, so every reboot silently disarms it and the drain
            # above would quietly return nothing forever. Re-assert it here --
            # on reboot only, so the steady state stays one session per minute.
            python3 "$STICK_EXEC" "omcicli set logfile $OMCI_LOGMODE $OMCI_LOGMASK" >/dev/null 2>&1 \
                && event "OMCI logfile re-armed after stick reboot (mode $OMCI_LOGMODE mask $OMCI_LOGMASK)"
        fi ;;
    esac ;;
esac

# ── raw OMCI lines → syslog, unfiltered ─────────────────────────────────────
# Separate tag `route10.omci` on purpose: this is BULK DATA, not events, and it
# must stay routable/droppable independently of route10.pon-collect, which
# carries the alerts. Never mix a firehose into an alert stream.
#
# NOTHING IS TRUNCATED. busybox syslogd cuts the payload at a hard 221 B for
# this tag (measured directly, not assumed -- our notes said "~256 B" and were
# wrong). OMCI lines run avg 81 B / max 329 B, so ~1% would otherwise clip:
# exactly the long hex attribute dumps. Rather than accept a lossy sink, over-
# long lines are SPLIT into numbered chunks that rejoin losslessly:
#
#     c<seq>.<i>/<n>|<chunk>
#
# Rejoin (chunks of one cycle arrive adjacent and in order):
#     grep 'route10.omci:' messages | sed -E 's/.*route10\.omci: //' \
#       | awk '/^c[0-9]+\.[0-9]+\/[0-9]+\|/{ split($0,a,"|"); split(a[1],b,/[c.\/]/);
#              buf[b[2]]=buf[b[2]] substr($0, index($0,"|")+1);
#              if (b[3]==b[4]) { print buf[b[2]]; delete buf[b[2]] }; next } {print}'
#
# No ambiguity with real content: every genuine OMCI line begins with `[`
# (the timestamp), so a leading `c<digits>.` can only be our marker.
#
# busybox `logger` reading stdin emits ONE syslog entry PER LINE (verified),
# so the whole batch costs a single process rather than one spawn per line.
#
# Volume: ~164 lines/min while faulting. `fault` therefore ships unfiltered
# CONTENT but only while the PON is not in O5 -- the window where it is worth
# anything -- instead of a permanent firehose into the collector. `all` is
# there if the full stream is genuinely wanted; `off` disables shipping.
OMCI_SYSLOG=all              # off | fault | all
OMCI_SYSLOG_MAXLINES=500

_ship=0
case "$OMCI_SYSLOG" in
    all)   _ship=1 ;;
    fault) [ "${ONU:-x}" != "5" ] && _ship=1 ;;
esac
if [ "$_ship" = 1 ] && [ -n "$_omci_body" ]; then
    _n=$(printf '%s\n' "$_omci_body" | grep -c '')
    printf '%s\n' "$_omci_body" | head -n "$OMCI_SYSLOG_MAXLINES" \
        | awk -v LIM=221 -v MK=16 '
            BEGIN { CH = LIM - MK }
            length($0) <= LIM { print; next }
            {
                seq++
                total = int((length($0) + CH - 1) / CH)
                for (i = 1; i <= total; i++)
                    printf "c%d.%d/%d|%s\n", seq, i, total, substr($0, (i-1)*CH + 1, CH)
            }' \
        | logger -t route10.omci -p daemon.info 2>/dev/null
    [ "$_n" -gt "$OMCI_SYSLOG_MAXLINES" ] \
        && warn "OMCI syslog ship capped: $_n lines drained, $OMCI_SYSLOG_MAXLINES shipped (full text is in the omci table)"
fi

# Alarm surfacing: any non-clear PON alarm is worth an event even between scrapes.
for a in LOS LOF LOM SF SD; do
    [ "$(alarm $a)" = 1 ] && warn "PON alarm $a is RAISED (onu_state=O${ONU:-?})"
done

exit 0
