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
# Also drop the nc capture: it is up to ~2.5 MB of mostly-NUL in tmpfs and there
# is no reason to hold it between cycles. Expanded at trap time, so it is fine
# that OMCI_RAW is defined further down (and harmless if we exit before that).
trap 'rm -rf "$LOCK"; rm -f "$OMCI_RAW"' EXIT

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
# ⛔ ROOT CAUSE 2026-08-11, and it was OURS. The previous drain was one shell
# line: `cat file1 file2; : > file1; : > file2` -- an UNCONDITIONAL truncate.
# Measured by holding the collector lock across one OLT poll: the log is not a
# steady ~6 KB/min as the old comment claimed, it is BURSTY and reached
# **1,733,379 bytes in 150 s**. `cat` of 1.7 MB over telnet blows stick-exec's
# timeout, the session dies -- and the stick's shell runs the truncate anyway.
# So every burst we destroyed the OLT's messages WITHOUT READING THEM, recorded
# zero lines, and the logger_dead latch then reported the silence we had just
# manufactured. The 12/12 wedge-to-burst correlation was this `cat`, not a fault.
#
# Two changes, and the second matters more than the first:
#   1. BOUNDED read via dd, so the transfer cannot blow the timeout. (`head`,
#      `tr` and `wc` do not exist on this busybox; dd does -- verified.)
#   2. The true on-disk SIZE is reported inside the drain, before the read, so
#      any shortfall is a logged number instead of silence. Losing data is
#      sometimes unavoidable at 1.7 MB/burst over telnet; NOT KNOWING we lost it
#      is what turned a volume problem into six hours of "the logger is dead".
# Paths are /var/tmp (the real location -- /tmp is a symlink to it, and omci_app
# holds its fd on /var/tmp/omcilog).
# ⛔ NO `dd` ON THIS STICK. Nor head, tail, wc, tr, du, od. busybox v1.12.4 here
# is minimal; `cat`, `ls`, `echo`, `grep`, `nc` exist. A previous version of this
# used `dd ... 2>/dev/null` and I "verified" dd with
# `dd ... 2>/dev/null; echo DD_OK` -- the redirect ate the "not found" and the
# echo ran anyway. A test that cannot fail proves nothing; that one shipped a
# drain which read ZERO bytes and truncated regardless, i.e. guaranteed 100%
# loss. Verify a tool by its OUTPUT, never by a following command's success.
#
# So: read with `cat` (bounded reads are not available), and TRUNCATE SEPARATELY,
# only after we have the bytes in hand. Read and destroy must never share a
# command line -- that coupling is the original bug: on a timeout the socket
# dies before we get the output while the stick's shell still runs the truncate.
# ⭐ FILTER ON THE STICK. Measured 2026-08-11 by pulling a whole file byte-exact
# over nc: apparent size 1,781,963 B, of which **1,769,817 were NUL** and only
# 4,126 were text. The file is ~99% hole, and the hole is OUR doing: `: > file`
# resets the size but NOT omci_app's retained file offset, so its next write
# lands at the old offset and re-creates a hole of exactly the previous length.
# `cat` then drags ~1.7 MB of zeros through telnet and times out -- which is the
# "wedge", the empty drains, and the six hours of "the logger is dead".
#
# Every real line begins with the `[monotonic.ms]` stamp, so one sed collapses
# it: 1,781,963 B -> 12,191 B, a 146x reduction, and 12 KB crosses telnet
# comfortably. This is why nc turned out to be unnecessary for the routine path:
# there was never 1.7 MB of data to move, only 1.7 MB of our own padding.
# (nc IS the right tool for a one-off byte-exact pull -- it is what diagnosed
# this, since telnet strips NULs and the stick has no od/wc/du to see them.)
# ⭐ nc TRANSPORT 2026-08-12 — filtering on the stick was the WRONG SIDE.
# Measured on the live 2,559,307 B file, CLI-alive asserted before each run
# (a wedged CLI returns an error in ~0 s and will happily masquerade as a fast
# tool -- three of these "timings" were that error before I put a control in):
#     sed -n '/^\[/p'   10379 ms   <- OVER the 10 s timeout: the wedge loop
#     grep -a '^\['      8792 ms   <- only ~1.2 s of headroom
#     awk  '/^\[/'      19456 ms
#     nc (whole file)    1835 ms   + 1 ms to filter the same bytes HERE
# The hole is ~99% of the file, so every stick-side tool drags a regex engine
# over 2.5 MB of NUL on a Lexra MIPS. nc never parses: it is read()/write().
#
# ⭐ Why this is a fix and a reboot is not: the hole equals every byte omci_app
# has written SINCE STICK BOOT -- NOT a function of our truncate cadence -- and
# only an omci_app restart clears it. Growth is ~2.5 MB/day at mask 0x3FFFFFFF.
# A reboot resets the offset and we are back at the same wall inside a day, for
# an ~80 s WAN outage on a single fibre. Moving the bytes cheaply is what
# actually scales; cutting the action mask (slower growth) is the complement.
#
# ⛔ DIRECTION IS A SAFETY DECISION, not a preference. route10 LISTENS and the
# stick CONNECTS OUT. The inverse was measured and is dangerous: an `nc -l` on
# the stick that nobody connects to OUTLIVES its stick-exec session (observed --
# a later probe was answered by an earlier round's listener), and the abandoned
# session then holds the single CLI. This way, if our listener is missing the
# stick's connect is REFUSED instantly and the command returns.
# ⚠ That fast-refuse depends on the ACCEPT rule below: the kernel must see the
# SYN to answer RST. If the stick's packets were DROPped instead, its nc would
# hang until TCP timeout, blow the 45 s limit, and orphan the session -- i.e.
# the firewall rule is load-bearing for STICK SAFETY, not only for security.
OMCI_NC_PORT=9099
OMCI_NC_BIND=192.168.1.2       # route10's ont_mgmt0 address; what the stick dials
OMCI_NC_PEER=192.168.1.1       # the stick
OMCI_RAW=/var/run/.pon-omci.raw

# ⛔ `nc -s` binds an ADDRESS, not an interface. VERIFIED by injection: a LAN
# host reached 192.168.1.2:9099 and its bytes landed in the capture. That is an
# ALERTING-integrity hole, not merely a data one -- injected text feeds the
# write-verb detector that pages on "OLT SENT A FIRMWARE/REBOOT COMMAND". So the
# port is closed to everyone but the stick. Own chain: order-safe and idempotent
# without caring where in INPUT it lands (fw3 reloads flush it; we re-add next
# cycle, which is a 1-minute self-heal).
omci_fw_ensure() {
    iptables -w -n -L RT10_OMCIPULL >/dev/null 2>&1 || {
        iptables -w -N RT10_OMCIPULL 2>/dev/null
        iptables -w -A RT10_OMCIPULL -i ont_mgmt0 -s "$OMCI_NC_PEER" -j ACCEPT
        iptables -w -A RT10_OMCIPULL -j DROP
    }
    iptables -w -C INPUT -p tcp --dport "$OMCI_NC_PORT" -j RT10_OMCIPULL 2>/dev/null \
        || iptables -w -I INPUT 1 -p tcp --dport "$OMCI_NC_PORT" -j RT10_OMCIPULL
}

OMCI_NC_PID=
# Must be silent on stdout: poll_stick's output is captured into $RAW.
omci_listen_start() {
    rm -f "$OMCI_RAW"
    timeout 60 /usr/bin/nc -l -p "$OMCI_NC_PORT" -s "$OMCI_NC_BIND" > "$OMCI_RAW" 2>/dev/null &
    OMCI_NC_PID=$!
    _i=0
    while [ "$_i" -lt 30 ]; do
        netstat -ltn 2>/dev/null | grep -q "$OMCI_NC_BIND:$OMCI_NC_PORT " && return 0
        _i=$(( _i + 1 )); sleep 0.1
    done
    kill "$OMCI_NC_PID" 2>/dev/null; OMCI_NC_PID=
    return 1
}
omci_listen_finish() {
    [ -n "$OMCI_NC_PID" ] || return 0
    _j=0
    while [ "$_j" -lt 100 ] && kill -0 "$OMCI_NC_PID" 2>/dev/null; do _j=$(( _j + 1 )); sleep 0.1; done
    kill "$OMCI_NC_PID" 2>/dev/null
    wait "$OMCI_NC_PID" 2>/dev/null
    OMCI_NC_PID=
}

# The stick now only REPORTS the size over telnet and PIPES the bytes over nc.
OMCISIZE="echo __OMCI''LOG_S__; ls -l /var/tmp/omcilog.par /var/tmp/omcilog 2>/dev/null; echo __OMCI''LOG_E__"
OMCIPULL="cat /var/tmp/omcilog.par /var/tmp/omcilog 2>/dev/null | nc $OMCI_NC_BIND $OMCI_NC_PORT"
# ── MIB state poll — the durable half of the management-plane record ────────
# The OMCI log is EPHEMERAL by construction: /tmp on the stick is tmpfs, the
# logger is runtime-only, and an `ActivateSw` REBOOTS the stick -- so the one
# event most worth catching is also the one most able to erase its own evidence.
# The MIB is the durable complement: it is the state the log describes, it
# survives the reboot, and it cannot be missed by a truncated drain or a dead
# recorder. Log = early warning (StartSwDownload arrives before Activate);
# MIB = authoritative after the fact. Neither alone is enough.
#
# ME 7  = software images, two banks. Measured 2026-08-11:
#           slot 0  Active 0 Committed 0 Valid 1  V5R022C00S265
#           slot 1  Active 1 Committed 1 Valid 1  V1.2.2-221209  <- running
#         A push lands in the INACTIVE bank (slot 0 here), so a Version change
#         there is the earliest durable evidence. Activate flips Active; only
#         Commit makes it survive a power cycle.
# ME 340 = the TR-069/ACS hook. Measured: AdminState 1 (locked), AcsAddress
#         0xffff (null), AssociateTag 0xffff (null) -- i.e. present, wired to
#         the VEIP at the same entity id 0x0601, and switched OFF. Any movement
#         off those three values is the ISP turning on remote management.
# Sentinel-wrapped (written __MIB''_* so the echoed command cannot self-match)
# and stripped from RAW before the counter parsers run, for the same reason the
# OMCI drain is: `Key: value` text must never collide with a counter label.
# ME 329 = VEIP, and ME 137/148/157 = the ACS chain hanging off ME 340:
#   340 --AcsAddress--> 137 --SecurityPointer--> 148 (username/password/realm)
#                           \--AddressPointer--> 157 (the ACS URL, <=375 B)
# All three read EMPTY today (no instances). We poll them so that if the ISP
# ever populates them we capture the ACTUAL PAYLOAD -- the URL and credentials
# they intend for this line -- durably, instead of only noticing that a write
# happened. That distinction matters because the log that would have shown the
# write is precisely the thing that can be dark (it is dark right now).
#
# ⛔ Reading the ACS pointer is NOT following it. Nothing here dials out.
MIBPOLL="echo __MIB''_S__; omcicli mib get 7; omcicli mib get 340; omcicli mib get 329; omcicli mib get 137; omcicli mib get 148; omcicli mib get 157; echo __MIB''_E__"
# --timeout 45 (default 10) because the drain legitimately takes ~9 s against a
# 2.5 MB hole. Raising it does NOT slow wedge detection: a wedged CLI fails at
# BANNER stage inside open_session (~0 s, "empty banner"), never at the per-command
# timeout — verified live. What the old 10 s bought was the opposite of safety: the
# drain overran it, stick-exec closed the socket abruptly, and that ORPHANED a
# /bin/login+/bin/sh holding the single CLI. i.e. the timeout was manufacturing the
# very wedge it was blamed on. 4x45 s worst case is bounded by the collector lock.
# The listener is armed around EVERY poll, because poll_stick is also called a
# second time by the unwedge path -- a retry with no listener would leave the
# stick dialling a closed port and lose that cycle's log.
poll_stick() {
    omci_fw_ensure 2>/dev/null
    omci_listen_start 2>/dev/null
    python3 "$STICK_EXEC" --timeout 45 "cat /proc/uptime" "$DIAG" "$OMCISIZE" "$MIBPOLL" "$OMCIPULL" 2>&1
    omci_listen_finish 2>/dev/null
}
# ⚠ FAIL CLOSED, and this is the whole point of the function.
# It used to ENUMERATE the failures we had seen -- `WEDGED:`, `ERR:`, empty --
# and 2026-08-19 produced the one that was not on the list. When the stick
# stopped answering TCP altogether (not just refusing to spawn a shell),
# stick-exec started returning `FATAL: timeout: timed out`, which matches none
# of those. The collector then parsed a dead stick's empty output into a full
# row of NULLs, once a minute, so route10_pon_sample_timestamp_seconds kept
# advancing while every value read NaN -- ops's staleness alert CLEARED ITSELF
# on a stick that was dark, and pon-collect logged a false "CLI recovered".
# The sicker the stick got, the healthier the telemetry looked.
#
# So do not decide liveness by listing the ways it can fail; that list is only
# ever as complete as the outages you have already had. Demand PROOF of a live
# session: /proc/uptime is the first command in the batch and only a running
# kernel answers it with two floats. No proof => wedged, whatever the text says.
is_wedged() {
    case "$1" in *WEDGED*|*"ERR:"*|'') return 0 ;; esac
    printf '%s\n' "$1" | grep -qE '^[0-9]+\.[0-9]+[[:space:]]+[0-9]+\.[0-9]+' && return 1
    return 0
}

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
# The header is what the stick HAD; the nc capture is what we actually GOT.
# ⭐ Under nc these are finally the SAME QUANTITY -- both whole-file byte counts
# -- so the comparison is a true integrity check. It was NOT comparable while we
# filtered on the stick (apparent size ~99% hole vs filtered text), and the old
# code carried an explicit warning never to compare them. nc inverts that.
_omci_hdr=$(printf '%s\n' "$RAW" | sed -n '/__OMCILOG_S__/,/__OMCILOG_E__/p' | sed '1d;$d')
# busybox `ls -l` size is field 5. Sum both files; absent/unparsable -> 0.
_omci_ondisk=$(printf '%s\n' "$_omci_hdr" | awk '/omcilog/ {s += $5} END {print s+0}')
_omci_xfer=$(wc -c < "$OMCI_RAW" 2>/dev/null || echo 0)
case "$_omci_xfer" in ''|*[!0-9]*) _omci_xfer=0 ;; esac
# The filter runs HERE, where it costs ~1 ms instead of ~9 s on the stick.
_omci_body=$(grep -a '^\[' "$OMCI_RAW" 2>/dev/null)
_omci_got=${#_omci_body}
OMCILOG=$(printf '%s' "$_omci_body" | head -c 64000 | sed "s/'/''/g")

# Never lose data silently. Two DISTINCT losses, reported separately because
# they have different fixes: the transfer bound (raise OMCI_DRAIN_KB, or reduce
# the logger's action mask so it stops emitting 1.7 MB per burst) and the row
# storage bound (a /a/obs budget decision).
# ── truncate ONLY on proof we have the bytes ────────────────────────────────
# Separate round trip, deliberately. If the read failed or came back short we
# leave the file alone and try again next cycle; nothing is destroyed unread.
#
# The one exception is a RAM guard, and it is a real risk not a theoretical one:
# /var on the stick is ramfs (23 MB TOTAL, ~2.8 MB free) so an undrained log
# competes with omci_app itself -- and omci_app IS the GPON MAC. Losing text is
# survivable; OOM-ing the process that terminates our only fibre is not. Above
# the guard we truncate anyway and say so at err.
OMCI_RAMGUARD=$(( 4 * 1024 * 1024 ))
if [ "${_omci_ondisk:-0}" -le 0 ] 2>/dev/null; then
    # Nothing on the stick. Normal between bursts: after a good drain the file
    # is genuinely 0 until omci_app's next write re-creates the hole.
    :
elif [ "${_omci_xfer:-0}" -ge "${_omci_ondisk:-0}" ] 2>/dev/null; then
    # Proof we hold every byte the stick reported. `-ge` not `-eq` on purpose:
    # the file can only GROW between the `ls` and the pull, never shrink.
    python3 "$STICK_EXEC" ": > /var/tmp/omcilog.par; : > /var/tmp/omcilog" >/dev/null 2>&1
elif [ "${_omci_ondisk:-0}" -gt "$OMCI_RAMGUARD" ] 2>/dev/null; then
    python3 "$STICK_EXEC" ": > /var/tmp/omcilog.par; : > /var/tmp/omcilog" >/dev/null 2>&1
    err "OMCI log ${_omci_ondisk} B UNPULLABLE (nc delivered ${_omci_xfer} B) and past the ${OMCI_RAMGUARD} B ram guard — truncated UNREAD to protect omci_app (ramfs is 23 MB total and omci_app is the GPON MAC). This is data loss, chosen deliberately over risking the fibre."
    # We discarded these bytes ourselves. The logger_dead latch below must not
    # then read the empty drain as "the recorder is dead" — see its note.
    _omci_guard_drop=1
elif [ "${_omci_ondisk:-0}" -gt 0 ] 2>/dev/null; then
    warn "OMCI pull SHORT: stick held ${_omci_ondisk} B, nc delivered ${_omci_xfer} B — NOT truncating; will retry next cycle."
fi
[ "${_omci_got:-0}" -gt 64000 ] && warn "OMCI row truncated: ${_omci_got} B drained, 64000 B stored"

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
# ── the OLT's INSTRUCTIONS, not just its transport health ──────────────────
# Everything above measures the CHANNEL (did our replies arrive). This measures
# the CONTENT. OMCI is GPON's management plane -- the equivalent of TR-069 on a
# DSL CPE -- so a WRITE from the OLT is the ISP reconfiguring us. Missing one is
# the difference between "edit a config" and a 48 h SLA visit that swaps a
# working modem and hopes.
#
# Verbs partition cleanly. The list is exhaustive, taken from the sprintf sites
# in Realtek's omci_message.c -- the code that emits these very lines:
#   read   Get GetNext GetCurrentData MibUpload MibUploadNext GetAllAlarm(Next)
#   write  Set Create Delete
#   act    StartSwDownload DownloadSection EndSwDownload ActivateSw CommitSw
#          Reboot MibReset SyncTime Test
#
# ` Verb(` is anchored on BOTH sides so ` SetRsp(` cannot match ` Set(`. The
# `…Rsp` lines are OUR replies -- never mistake our own words for an
# instruction. Read the matching Rsp for `Result=0x0` to learn if it took.
#
# ⛔ Deliberately NOT alerted: `MibReset` is the normal first step of EVERY
# re-provision (MibReset -> MibUpload -> MibUploadNext xN -- we logged 159 of
# them in 52 min while the PON was churning), `SyncTime` is a routine PM
# boundary sync, `Test` is a routine optical measurement. Paging on those would
# page on healthy provisioning. `DownloadSection` is excluded as a firehose --
# `StartSwDownload` already fires at the start of the same transfer.
#
# Baseline measured 2026-08-11 over 52 min of capture: 8127 lines, and ZERO
# Set/Create/Delete. This OLT never writes in normal operation, so any hit here
# is exceptional by construction rather than by a tuned threshold.
_omci_lines=$(printf '%s\n' "$_omci_body" | grep -c '^\[')
_omci_writes=$(printf '%s\n' "$_omci_body" | grep -cE ' (Set|Create|Delete)\(')

# CRITICAL -- firmware or reboot. ActivateSw reboots onto the inactive image;
# CommitSw is what makes it survive a power cycle. Everything before Activate is
# still reversible, so StartSwDownload is the early warning worth having.
_omci_crit=$(printf '%s\n' "$_omci_body" \
    | grep -E ' (StartSwDownload|EndSwDownload|ActivateSw|CommitSw|Reboot)\(' | head -5)
# HIGH -- the management plane opening up. The ACS chain is ME 340 -> 137 ->
# 148/157 (server -> address -> credentials/URL); `Ontg Set(...AdminState` is an
# admin LOCK, which stops all traffic while PLOAM stays O5 -- i.e. it reads
# exactly like a fibre fault and would send a technician to the wrong problem.
# `UnknowME` means the OLT reached for an ME this firmware does not implement.
_omci_mgmt=$(printf '%s\n' "$_omci_body" \
    | grep -E ' (TR069ManageServer|NetworkAddress|AuthSecMethod|LargeString|IpHostCfgData|TcpUdpCfgData|OnuRemoteDebug|VEIP) (Set|Create|Delete)\(| Ontg Set\([^)]*AdminState' | head -5)

# ── UnknowME: worth knowing ONCE per ME number, never every cycle ────────────
# Measured on the first real capture: the OLT probes `UnknowME 351` every 15 min
# and retransmits it (same TCI twice) because we cannot answer. 351 is in
# G.988's vendor range 350-399, adjacent to the Huawei MEs this firmware
# emulates (350/370/373) -- the OLT is talking Huawei-vendor to what it believes
# is the EG8145X6 we present as.
#
# It was originally in the management-write tier above. That was wrong twice: it
# is a READ, not a write, and at a 15-minute cadence it would warn ~96x/day
# forever. An alert that always fires is an alert nobody reads, and it would
# bury the one that matters. So: remember which ME numbers we have seen and
# report only NEW ones. A genuinely new vendor ME is a real event -- it is the
# most likely shape for an ISP pushing config to a device it thinks is an HGU.
_seen=/cfg/scripts/.omci-unknown-me
for _me in $(printf '%s\n' "$_omci_body" | sed -n 's/.* UnknowME \([0-9]*\).*/\1/p' | sort -u); do
    if ! grep -qx "$_me" "$_seen" 2>/dev/null; then
        echo "$_me" >> "$_seen"
        warn "OLT probed a vendor ME this firmware does NOT implement: UnknowME $_me (first time seen; G.988 350-399 is vendor-specific, and we present as a Huawei EG8145X6). We cannot answer it, so the OLT retransmits. Watch for config following it."
    fi
done
# MEDIUM -- data path. A VLAN/bridge change stops our PPPoE frames being
# delivered; the symptom is an outage, the cause is a config we could match.
_omci_path=$(printf '%s\n' "$_omci_body" \
    | grep -E ' (ExtVlanTagOperCfgData|MacBriPortCfgData|VlanTagFilterData|GemPortCtp|Tcont|McastOperProf|Map8021pServProf) (Set|Create|Delete)\(' | head -5)

[ -n "$_omci_crit" ] && err "OLT SENT A FIRMWARE/REBOOT COMMAND: $(printf '%s' "$_omci_crit" | tr '\n' '|')"
[ -n "$_omci_mgmt" ] && warn "OLT WROTE THE MANAGEMENT PLANE: $(printf '%s' "$_omci_mgmt" | tr '\n' '|')"
[ -n "$_omci_path" ] && warn "OLT CHANGED THE DATA PATH: $(printf '%s' "$_omci_path" | tr '\n' '|')"

RAW=$(printf '%s\n' "$RAW" | sed '/__OMCILOG_S__/,/__OMCILOG_E__/d')

# ── MIB state: parse, then strip from RAW before the counter parsers see it ──
_mib_body=$(printf '%s\n' "$RAW" | sed -n '/__MIB_S__/,/__MIB_E__/p' | sed '1d;$d')
RAW=$(printf '%s\n' "$RAW" | sed '/__MIB_S__/,/__MIB_E__/d')

# Field out of a specific ME instance. Blocks are `EntityID: 0x..` followed by
# `Key: value` lines, so track which instance we are inside and take the first
# matching key. Empty when the ME has no instances (ME 137/148/157 read that way
# today) -- an absent value must stay empty, never default to something benign.
mibf() {   # mibf <EntityID-suffix> <Field>
    printf '%s\n' "$_mib_body" | awk -v id="EntityID: 0x$1" -v f="$2: " '
        /^EntityID:/ { cur = ($0 == id); next }
        cur && index($0, f) == 1 { print substr($0, length(f) + 1); exit }'
}
SW0_VER=$(mibf 00 Version);  SW0_ACT=$(mibf 00 Active);  SW0_COM=$(mibf 00 Committed)
SW1_VER=$(mibf 01 Version);  SW1_ACT=$(mibf 01 Active);  SW1_COM=$(mibf 01 Committed)
TR69_ADM=$(mibf 0601 AdminState); TR69_ACS=$(mibf 0601 AcsAddress); TR69_TAG=$(mibf 0601 AssociateTag)
# VEIP shares entity id 0x0601 with ME 340 (that is WHY 340 exists -- G.988 ties
# its identity to a VEIP instance), so pull its fields by their distinct names.
VEIP_ADM=$(mibf 0601 OperState)
# The ACS chain. Instance-count only: if any of these stops being 0 the ISP has
# begun configuring remote management, and the full text is in the raw blob.
_chain=$(printf '%s\n' "$_mib_body" | grep -c '^EntityID')
ACS_CHAIN=$(printf '%s\n' "$_mib_body" | sed -n '/NetworkAddress/,$p' | grep -c '^EntityID')

# ── ACS endpoint capture: record WHO, never talk to them ────────────────────
# The chain is empty today, so the per-field format of a POPULATED ME 157/148 is
# UNVERIFIED -- we have never seen one. Do not pretend to parse it. Keep the
# whole section verbatim (it is a few hundred bytes, once, on an event that has
# never happened) and pull the URL with a permissive match, so a format we
# guessed wrong degrades to "we stored everything" rather than to silence.
if [ "$ACS_CHAIN" -gt 0 ] 2>/dev/null; then
    ACS_BLOB=$(printf '%s\n' "$_mib_body" | sed -n '/NetworkAddress/,$p' | head -c 4000)
    ACS_URL=$(printf '%s\n' "$ACS_BLOB" | grep -oE 'https?://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+' | head -1)
    # `\?` is a GNU sed extension -- NOT portable, and it silently leaves the
    # scheme in place, after which the next rule cuts at the first ':' and hands
    # you the host "https". Caught by the synthetic test; it would have shipped
    # as a DNS lookup for a literal "https". Use an explicit scheme class.
    ACS_HOST=$(printf '%s' "$ACS_URL" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|[:/].*||')
    err "ISP POPULATED THE ACS CHAIN — url=${ACS_URL:-<no url matched, see blob>} host=${ACS_HOST:-?} (ME 137/148/157 instances: $ACS_CHAIN)"
    # DNS ONLY. Resolving a name is a question to the resolver, not contact with
    # the host: no TCP, no TLS, no HTTP, and above all no CWMP Inform -- an
    # Inform IS the request that makes the ACS send its queued work, so there is
    # no read-only way to "just look". Operator decision 2026-08-11: log who
    # they contracted for management; do not become their CPE.
    if [ -n "$ACS_HOST" ]; then
        ACS_ADDRS=$(timeout 3 drill -Q "$ACS_HOST" A 2>/dev/null | tr '\n' ' ')
        ACS_ADDRS="$ACS_ADDRS$(timeout 3 drill -Q "$ACS_HOST" AAAA 2>/dev/null | tr '\n' ' ')"
        [ -n "$ACS_ADDRS" ] && event "ACS host $ACS_HOST resolves to: $ACS_ADDRS"
    fi
    propose tr069 \
        "ISP configured an ACS endpoint (host=${ACS_HOST:-?})" \
        "record and analyse OFFLINE; do NOT send an Inform. An Inform is CPE-initiated and is what triggers the ACS to push its queued work (BOOTSTRAP is usually read as new-device-apply-full-template), it would present our SPOOFED serial to their management system, and a CPE that Informs then faults every RPC reads to their NOC as a failing device -- i.e. it manufactures the technician dispatch we are trying to avoid. There is still no CWMP client on this stick to comply even if we wanted to."
fi

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

# ── is the LOGGER alive? hardware counter as a positive control ─────────────
# `Total RX OMCI` is a PON-layer HARDWARE counter; the drain above is produced
# by omci_app in SOFTWARE. Two independent witnesses to the same event, which
# together answer a question neither can answer alone:
#
#   counter still + drain empty  =>  the OLT said nothing. Honest silence.
#   counter MOVED + drain empty  =>  the OLT spoke and we did not write it down.
#
# ⛔ The instrument will NOT tell you, and this is measured, not hypothetical.
# On 2026-08-11 `omcicli get logfile` reported "Parsed Mode with Time Stamp,
# ActionMask 0x3FFFFFFF" -- armed, healthy -- while /tmp/omcilog.par sat at 0
# bytes for 4.6 h during which the counter advanced by exactly 43 messages every
# 15 min. ~780 OLT messages lost with the config self-report saying fine
# throughout. Never accept an instrument's self-report; ask an independent one.
#
# The previous re-arm was gated on stick-reboot detection and had fired ZERO
# times ever -- the logger dies WITHOUT the stick rebooting (uptime climbed
# straight through the minute capture stopped: 6345 -> 6418). Reboot re-arm
# stays below (it is faster when it applies); this is the general net.
#
# Counter going BACKWARDS is a reboot (it is cumulative since stick boot), not a
# dead logger -- `-gt` alone excludes that, and the reboot handler owns it.
# ⚠ LATCHED, not edge-triggered, and that is load-bearing. Detection can only
# fire on a cycle where the counter MOVED, and this OLT speaks in a burst of ~43
# every 15 min -- so an edge flag reads 1 for one minute in fifteen while the
# logger is dead the whole time, and an ops rule of the obvious shape
# (`logger_dead == 1 for: 5m`) would NEVER fire. That is an alert wearing the
# costume of a working one. So the flag LATCHES on detection and clears only
# when a drain actually returns lines -- i.e. on proof of life, never on the
# mere absence of new evidence.
OMCI_DEAD_STATE=/var/run/.omci-dead
if [ "${_omci_lines:-0}" -gt 0 ] 2>/dev/null && [ -f "$OMCI_DEAD_STATE" ]; then
    rm -f "$OMCI_DEAD_STATE"; rm -f /var/run/.omci-rearm-n
    event "OMCI logger RECOVERED — ${_omci_lines} lines captured this cycle"
fi
PREV_RX=$(sqlite3 -readonly "$DB" "SELECT json_extract(json,'\$.omci2.rx_total') FROM pon WHERE ts < $TS ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
case "$OMCI_RX_TOT" in ''|*[!0-9]*) : ;; *)
    case "$PREV_RX" in ''|*[!0-9]*) : ;; *)
        # ⛔ NOT on a cycle where the ram guard truncated the log UNREAD. There
        # the drain is empty because WE emptied it, and the rx counter advanced
        # because it spans the whole outage that filled the log in the first
        # place -- so both halves of the "independent witnesses" test are
        # satisfied by one event we caused. Measured 2026-08-18: the first cycle
        # after a 33-min CLI wedge latched logger_dead deterministically (+86
        # rx, guard-truncated drain) while the logger was fine, which is a page
        # ops would take on every wedge recovery. A genuinely dead logger still
        # latches on the NEXT empty drain -- at most one OLT burst later.
        if [ "$OMCI_RX_TOT" -gt "$PREV_RX" ] && [ -z "$_omci_body" ] \
           && [ "${_omci_guard_drop:-0}" -eq 0 ]; then
            : > "$OMCI_DEAD_STATE"
            # Rate-limited so a stick that refuses to arm cannot turn this into
            # a per-minute extra CLI session -- that would manufacture the wedge
            # class this script exists to avoid. Detection still runs every
            # cycle and is exported, so ops alerts on the FLAG, not the re-arm.
            _last=$(cat /var/run/.omci-rearm 2>/dev/null || echo 0)
            case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
            if [ $(( TS - _last )) -ge 600 ]; then
                echo "$TS" > /var/run/.omci-rearm
                # ⛔ NEVER say "re-armed" here. Measured 2026-08-11: on this
                # firmware state `omcicli set logfile` is a NO-OP in BOTH
                # directions -- setting mode 0 (off) left `get logfile` still
                # reporting "Parsed Mode with Time Stamp, 0x3FFFFFFF", and two
                # re-arms 15 min apart restored exactly zero capture. `get` is
                # not reading live state and `set` is not writing it, so the
                # command's success tells us nothing at all.
                #
                # We still ATTEMPT it -- it demonstrably worked earlier the same
                # day, so something got stuck rather than being absent -- but the
                # claim of success belongs to the LATCH, which clears only when a
                # drain actually returns lines. Reporting a heal we have not
                # observed would make our own telemetry lie exactly the way the
                # stick's does, and that is the failure mode of the whole day.
                python3 "$STICK_EXEC" "omcicli set logfile $OMCI_LOGMODE $OMCI_LOGMASK" >/dev/null 2>&1
                _tries=$(cat /var/run/.omci-rearm-n 2>/dev/null || echo 0)
                case "$_tries" in ''|*[!0-9]*) _tries=0 ;; esac
                _tries=$(( _tries + 1 )); echo "$_tries" > /var/run/.omci-rearm-n
                if [ "$_tries" -ge 3 ]; then
                    err "OMCI logger DEAD and re-arm INEFFECTIVE after ${_tries} attempts (rx_total +$(( OMCI_RX_TOT - PREV_RX )) this cycle, empty drain). \`omcicli set logfile\` is a no-op in this state — the only known restore is a STICK REBOOT, which is an ~80 s WAN outage on a single fibre and needs an operator decision. The OLT's instructions are NOT being recorded meanwhile."
                else
                    warn "OMCI logger DEAD (rx_total +$(( OMCI_RX_TOT - PREV_RX )) this cycle with an EMPTY drain) — re-arm ATTEMPTED (attempt ${_tries}); success is unproven until a drain returns lines and clears the latch"
                fi
            fi
        fi ;;
    esac ;;
esac
# Read the LATCH, not the edge. /var/run is tmpfs, so a route10 reboot clears it
# -- correct: post-boot we have no evidence either way, and the first cycle that
# sees the counter move re-establishes it.
OMCI_LOG_DEAD=0
[ -f "$OMCI_DEAD_STATE" ] && OMCI_LOG_DEAD=1

# ── SHADOW MODE: record what we WOULD do; never do it ───────────────────────
# Operator's framing, and it is the right one: we cannot yet judge whether an
# automated response is safe, but we CAN write down the response we would have
# proposed, and then contrast it later against what the event actually turned
# out to need. That builds the evidence base for automation out of real events
# instead of imagination -- and costs nothing if we never automate.
#
# ⛔ Nothing here executes. `propose` writes a row and a log line, full stop.
# The bar for ever closing this loop is a proposal history that was RIGHT, on
# this link, repeatedly -- not a plausible-looking mapping table.
#
# ⚠ And the precondition is upstream of the mapping: you cannot automate on a
# channel whose silence you cannot verify. For 4.6 h today this one was dark
# while its own status command reported armed. Until route10_pon_omci_logger_dead
# has a track record, "no instruction arrived" and "the recorder is dead" are
# the same observation, and an automaton would act confidently on the wrong one.
PROPOSAL_SQL=""
propose() {   # propose <tier> <observed> <action we would take>
    _p_o=$(printf '%s' "$2" | sed "s/'/''/g")
    _p_a=$(printf '%s' "$3" | sed "s/'/''/g")
    PROPOSAL_SQL="$PROPOSAL_SQL INSERT INTO omci_proposal VALUES($TS,'$1','$_p_o','$_p_a');"
    warn "PROPOSED (NOT APPLIED) [$1] $2 => $3"
}

# MIB state change detection. One query, pipe-joined, so a nine-field compare
# costs one read. Empty PREV (first run after deploy) must NOT read as a change.
#
# ⚠ And neither must empty CUR -- the guard was one-sided until 2026-08-19, when
# a dark stick's NULL row diffed against real state and raised firmware-bank and
# TR-069 advisories about changes nobody made ("PROPOSED (NOT APPLIED) firmware
# already changed under us"). Same class ops hit from the other end the same
# night: their `onu_state != 5` rule paged critical on NaN, because NaN compares
# UNEQUAL to everything. Absence is not inequality. `chg` therefore demands BOTH
# sides be present: a field going to empty means we failed to read it, and a
# field arriving from empty is a first observation -- neither is a change.
chg() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]; }
PREV_MIB=$(sqlite3 -readonly "$DB" "SELECT COALESCE(json_extract(json,'\$.sw.s0_ver'),'')||'|'||COALESCE(json_extract(json,'\$.sw.s1_ver'),'')||'|'||COALESCE(json_extract(json,'\$.sw.s0_act'),'')||'|'||COALESCE(json_extract(json,'\$.sw.s1_act'),'')||'|'||COALESCE(json_extract(json,'\$.sw.s0_com'),'')||'|'||COALESCE(json_extract(json,'\$.sw.s1_com'),'')||'|'||COALESCE(json_extract(json,'\$.tr069.admin'),'')||'|'||COALESCE(json_extract(json,'\$.tr069.acs'),'')||'|'||COALESCE(json_extract(json,'\$.tr069.tag'),'') FROM pon WHERE ts < $TS ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
CUR_MIB="$SW0_VER|$SW1_VER|$SW0_ACT|$SW1_ACT|$SW0_COM|$SW1_COM|$TR69_ADM|$TR69_ACS|$TR69_TAG"
if [ -n "$PREV_MIB" ] && [ "$PREV_MIB" != "||||||||" ] && [ "$CUR_MIB" != "||||||||" ] \
   && [ "$PREV_MIB" != "$CUR_MIB" ]; then
    err "MIB STATE CHANGED: [$PREV_MIB] -> [$CUR_MIB] (sw0_ver|sw1_ver|sw0_act|sw1_act|sw0_com|sw1_com|tr069_admin|tr069_acs|tr069_tag)"
    _pv0=$(echo "$PREV_MIB" | cut -d'|' -f1); _pv1=$(echo "$PREV_MIB" | cut -d'|' -f2)
    _pa=$(echo "$PREV_MIB" | cut -d'|' -f7);  _pc=$(echo "$PREV_MIB" | cut -d'|' -f8)
    chg "$_pv0" "$SW0_VER" && propose firmware \
        "inactive bank version $_pv0 -> $SW0_VER (an OMCI push lands here first)" \
        "capture flash vars NOW (GPON_SN, MAC_KEY, LAN_SDS_MODE) before any Activate; a stock image re-pins them from libmib defaults and that is what kills PPPoE, not the flash region itself"
    chg "$_pv1" "$SW1_VER" && propose firmware \
        "RUNNING bank version $_pv1 -> $SW1_VER" \
        "firmware already changed under us; verify GPON_SN + MAC_KEY survived and re-apply from project_odi_mac_key_fix if not"
    { chg "$(echo "$PREV_MIB" | cut -d'|' -f3)" "$SW0_ACT" || chg "$(echo "$PREV_MIB" | cut -d'|' -f5)" "$SW0_COM"; } && propose firmware \
        "bank 0 active/committed flags moved" \
        "Activate reboots onto the other image and Commit makes it survive a power cycle; if Commit has NOT happened a power cycle reverts us -- decide before touching power"
    chg "$_pa" "$TR69_ADM" && propose tr069 \
        "ME 340 AdminState $_pa -> $TR69_ADM (0=unlocked, 1=locked)" \
        "ISP is enabling remote management; no route10 action -- there is no CWMP client on this stick to consume it (measured), so record the ACS chain from ME 137/148/157 and treat it as intel, not an outage"
    chg "$_pc" "$TR69_ACS" && propose tr069 \
        "ME 340 AcsAddress $_pc -> $TR69_ACS (0xffff = null)" \
        "read ME 157 for the ACS URL and ME 148 for the credentials the ISP intends for this line; still no route10 action"
fi
# Proposals for the log-derived detections (these fire on the INSTRUCTION, which
# arrives before the state moves -- the earlier of the two signals).
[ -n "$_omci_path" ] && propose datapath \
    "OLT rewrote VLAN/bridge config: $(printf '%s' "$_omci_path" | head -1)" \
    "compare the new tag against wan3's VLAN; if the C-VLAN moved, our nas0_0 bridging stops matching and PPPoE dies with NO fibre fault -- this is the case worth automating first, and the case an SLA visit would misdiagnose"
printf '%s\n' "$_omci_mgmt" | grep -q 'AdminState' && propose adminlock \
    "OLT set ONU AdminState (admin lock)" \
    "traffic stops while PLOAM stays O5 -- do NOT chase a fibre fault or accept a modem swap; this is an ISP-side administrative action"

JSON=$(printf '{"uptime":%s,"onu_state":%s,"alarm":{"los":%s,"lof":%s,"lom":%s,"sf":%s,"sd":%s,"tx_too_long":%s,"tx_mismatch":%s},"ds":{"bip_bits":%s,"bip_blocks":%s,"fec_cor_cw":%s,"fec_uncor_cw":%s,"sf_los":%s,"ploam_rx":%s,"ploam_crc":%s},"rogue":{"sd_too_long":%s,"sd_mismatch":%s},"act":{"sn_req":%s,"ranging_req":%s},"us":{"tx_sn_ploam":%s,"tx_boh":%s},"omci":{"processed":%s,"dropped":%s},"bw":{"crc_err":%s,"invalid0":%s,"invalid1":%s},"omci_tx":{"req":%s,"retx":%s},"ds2":{"plen_fail":%s,"ploam_proc":%s,"ploam_ovf":%s,"ploam_unk":%s,"bw_total":%s,"bw_ovf":%s},"gem":{"los":%s,"hec":%s,"mislen":%s,"over_il":%s},"eth":{"fcs_err":%s},"us2":{"dbru":%s},"omci2":{"crc_err":%s,"rx_total":%s,"tx_total":%s,"rx_bytes":%s,"tx_bytes":%s,"us_proc":%s},"ds3":{"fec_cor_bits":%s,"fec_cor_bytes":%s,"plen_ok":%s},"usp":{"total":%s,"proc":%s,"urg":%s,"proc_urg":%s,"normal":%s,"proc_nrm":%s,"nomsg":%s},"gem2":{"idle":%s,"nonidle":%s,"multiflow":%s,"us_blocks":%s,"us_bytes":%s},"eth2":{"unicast":%s,"multicast":%s,"fwd_mcast":%s,"leak_mcast":%s},"omcilog":{"dead":%s,"lines":%s,"writes":%s},"sw":{"s0_ver":"%s","s0_act":"%s","s0_com":"%s","s1_ver":"%s","s1_act":"%s","s1_com":"%s"},"tr069":{"admin":"%s","acs":"%s","tag":"%s"}}' \
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
    "$(nz "$ETH_UNI")" "$(nz "$ETH_MCAST")" "$(nz "$ETH_FWD_MC")" "$(nz "$ETH_LEAK_MC")" \
    "$OMCI_LOG_DEAD" "${_omci_lines:-0}" "${_omci_writes:-0}" \
    "$SW0_VER" "$SW0_ACT" "$SW0_COM" "$SW1_VER" "$SW1_ACT" "$SW1_COM" \
    "$TR69_ADM" "$TR69_ACS" "$TR69_TAG")

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
-- Shadow proposals: what we WOULD have done. Never executed. Kept a full year
-- deliberately -- the whole value is contrasting an old proposal against how
-- the event actually resolved, and these are a few rows a year, not a stream.
CREATE TABLE IF NOT EXISTS omci_proposal (ts INTEGER, tier TEXT, observed TEXT, action TEXT);
INSERT OR IGNORE INTO pon VALUES ($TS, '$JSON', '$RAW_COL');
$TOTAL_SQL
$OMCI_SQL
$PROPOSAL_SQL
DELETE FROM omci_proposal WHERE ts < $TS - 365*86400;
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
