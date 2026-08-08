#!/bin/sh
# stick-unwedge.sh — clear a wedged ODI-stick CLI WITHOUT a reboot, via the
# Boa formPing command injection.
#
# TWO distinct wedge mechanisms, both cleared here (2026-08-08 rewrite):
#
#   1. ORPHANED LOCK FILE — /bin/login wrote /var/run/cli.pid and never cleared
#      it after an ungraceful close. Removing the file is enough. (The only case
#      the 2026-07-09 version handled.)
#
#   2. ORPHANED LOGIN SESSION — a telnet login that ran an *interactive* command
#      (`diag` drops into its own `RTK.0>` prompt; `omcicli` with no sentinel)
#      leaves a live `/bin/login` + `/bin/sh` pair the custom login never reaps
#      on socket close. That live session holds the single CLI, and cli.pid may
#      not even exist — so `rm cli.pid` does nothing and only killing the
#      orphaned processes recovers it. This is the case that stranded the CLI on
#      2026-08-08 (a `diag gpon get onu-state` via stick-exec went interactive).
#
# Both are cleared over HTTP in ~10 s — no reboot, no pppd kill, no WAN blip.
#
# Mechanism (full writeup: docs/reference/odi-wedge-recovery-and-ddm-source.md):
#   Boa POST /boaform/formPing builds  `ping <pingAddr> -c 4 -I <wanif> ... > /tmp/ping.tmp`
#   and runs it via system(). Boa's validator rejects spaces/;/backtick in
#   pingAddr but ALLOWS newline (%0a, command separator) and tab (%09, argument
#   separator). So an injected `<cmd>%09<arg>%09<arg>%0a` runs as its own line.
#   The result of `ps > /tmp/ping.tmp` is then readable at
#   /diag_ping_admin_result.asp — which is how this script enumerates the
#   orphaned PIDs before killing exactly those.
#
# WHY enumerate-then-kill rather than a blind `killall login`: killall would
# also drop a legitimately-active console/telnet session and cannot see a stuck
# `diag`/`omcicli`. Reading `ps` first lets us target only the wedged processes
# and never touch telnetd (the listener we need for recovery), boa, omci_app
# (the GPON MAC — the fibre), configd, systemd, spppd, etc.
#
# Runs ON Route10: curls Boa from 192.168.1.2 (the ont_mgmt0 MACVLAN path),
# verifies via /cfg/scripts/stick-exec.py (clean-exit telnet).
#
# Source-of-truth: scripts/stick-unwedge.sh  →  deploy: scp to /cfg/scripts/stick-unwedge.sh
#
# Usage:
#   /cfg/scripts/stick-unwedge.sh            # detect; clear only if wedged
#   /cfg/scripts/stick-unwedge.sh --force    # clear regardless of detection

set -u

STICK_IP=192.168.1.1
SRC_IP=192.168.1.2
LOGIN_URL="http://${STICK_IP}/boaform/admin/formLogin"
PING_URL="http://${STICK_IP}/boaform/formPing"
RESULT_URL="http://${STICK_IP}/diag_ping_admin_result.asp"
LOGIN_POST='username=admin&password=admin&challenge=&save=Login&submit-url=%2Fadmin%2Flogin.asp'
STICK_EXEC=/cfg/scripts/stick-exec.py
FORCE=0
[ "${1-}" = "--force" ] && FORCE=1

log() { echo "$(date '+%H:%M:%S') $*"; }

# small wrappers so the intent reads clearly
boa_login() {
    curl --http0.9 -s -m 5 --interface "$SRC_IP" -o /dev/null \
        -X POST -d "$LOGIN_POST" "$LOGIN_URL" 2>/dev/null
}
# Run one injected command line on the stick via formPing. $1 = the pingAddr
# payload AFTER `127.0.0.1%0a` and BEFORE the trailing `%0a%23`. Caller supplies
# a tab-separated, %0a-joined command string (no spaces — Boa rejects them).
boa_inject() {
    curl --http0.9 -s -m 15 --interface "$SRC_IP" -o /dev/null \
        --data "pingAddr=127.0.0.1%0a${1}%0a%23&wanif=65535&go=Go&postSecurityFlag=&submit-url=/ping.asp" \
        "$PING_URL" 2>/dev/null
}
# Fetch the last /tmp/ping.tmp render (where our injected `... > /tmp/ping.tmp` lands).
boa_result() { curl --http0.9 -s -m 8 --interface "$SRC_IP" "$RESULT_URL" 2>/dev/null | sed -e 's/<[^>]*>//g'; }

# Clean-exit CLI probe. 0 = CLI healthy; 3 = stick-exec missing; other = wedged.
# stick-exec raises WEDGED without engaging /bin/login, so this never deepens a wedge.
cli_up() { [ -x "$STICK_EXEC" ] || return 3; python3 "$STICK_EXEC" "true" >/dev/null 2>&1; }

# --- decide whether to act ----------------------------------------------------
if [ "$FORCE" -eq 0 ]; then
    case "$(cli_up; echo $?)" in
        0) log "stick CLI is healthy (stick-exec OK) — not wedged. Use --force to clear anyway."; exit 0 ;;
        3) log "WARN: $STICK_EXEC not found — skipping detection, attempting clear anyway." ;;
        *) log "stick CLI is wedged (stick-exec got no banner). Diagnosing..." ;;
    esac
else
    log "--force: clearing regardless of detection..."
fi

# --- 1. Boa login (IP-bound session from the mgmt path) -----------------------
log "Boa login from ${SRC_IP}..."
if ! boa_login; then
    log "ERROR: Boa login failed — is the stick reachable at ${STICK_IP} via ${SRC_IP}?"; exit 1
fi

# --- 2. Enumerate the process table via injected `ps` -------------------------
# Parsing happens HERE, in a full shell on Route10 (spaces/awk/grep all fine) —
# only the final kill payload needs tab-encoding.
log "reading stick process table..."
boa_inject "ps%09%3e%09/tmp/ping.tmp" >/dev/null
sleep 5
PS=$(boa_result)

# Targets = the wedge-holding processes, and ONLY those:
#   - /bin/login and /bin/login -p   (the CLI gate; console + telnet logins)
#   - bare /bin/sh                    (an orphaned login shell; the injection's
#                                      own sh always has args `-c ping...`, so a
#                                      COMMAND of exactly `/bin/sh` is a session)
#   - diag / omcicli                  (a stuck interactive diagnostic holding CLI;
#                                      safe to kill — NOT omci_app, the GPON MAC)
# Explicitly never matched: telnetd, boa, omci_app, configd, systemd, inetd,
# spppd, dnsmasq, udhcpd, pondetect, init, kernel threads.
# NB: build cmd with `cmd = cmd " " $i` — NOT `cmd (i>5?...)`. busybox awk parses
# a variable immediately followed by `(` as a function call and dies with
# "Call to undefined function". This form is plain string concatenation.
TARGETS=$(printf '%s\n' "$PS" | awk '
    $1 ~ /^[0-9]+$/ {
        cmd = $5
        for (i = 6; i <= NF; i++) cmd = cmd " " $i
        if (cmd == "/bin/login" || cmd == "/bin/login -p" ||
            cmd == "/bin/sh" ||
            cmd ~ /^diag( |$)/ || cmd ~ /^\/bin\/diag/ ||
            cmd ~ /^omcicli( |$)/) print $1
    }
')

if [ -n "$TARGETS" ]; then
    log "orphaned CLI holders found: $(echo $TARGETS | tr '\n' ' ')— killing them + clearing cli.pid"
    # tab-separate the pids for the space-free injection
    KILL_ARGS=$(echo "$TARGETS" | tr '\n' ' ' | sed 's/ *$//' | sed 's/ /%09/g')
    boa_inject "kill%09-9%09${KILL_ARGS}%0arm%09-f%09/var/run/cli.pid" >/dev/null
else
    log "no orphaned login/sh/diag processes — treating as a pure lock-file wedge, removing cli.pid"
    boa_inject "rm%09-f%09/var/run/cli.pid" >/dev/null
fi

# --- 3. Poll for the CLI to come back -----------------------------------------
if [ ! -x "$STICK_EXEC" ]; then
    log "INJECTED. (verify skipped: $STICK_EXEC not present). Run 'stick-exec.py uptime' to confirm."
    exit 0
fi
log "polling stick-exec for recovery (up to ~12 s)..."
i=0
while [ "$i" -lt 6 ]; do
    sleep 2
    i=$((i + 1))
    if cli_up; then
        log "SUCCESS — stick CLI is back after ~$((i * 2)) s. No reboot, no WAN blip."
        exit 0
    fi
done

# --- 4. Fallback --------------------------------------------------------------
log "FAILED — stick CLI still wedged after kill + cli.pid clear + ${i}x2 s polling."
log "Re-run with --force, or reboot fallback (~85 s, WAN3 blip — needs operator OK):"
log "  curl --http0.9 -s -m 5 --interface $SRC_IP -X POST -d 'reboot_now=Reboot' http://$STICK_IP/boaform/admin/formReboot"
exit 1
