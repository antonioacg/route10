#!/bin/sh
# optical-thresholds.sh — publish each optical module's OWN declared alarm and
# warning thresholds as data, instead of hardcoding them anywhere.
#
# WHY THIS EXISTS (2026-08-11): I asserted "W2 Rx sits at -25.4 dBm against
# ~-27 dBm B+ sensitivity, ~1.5 dB of headroom" all day -- in an incident
# diagnosis, in seam mail, and in a dashboard spec asking ops to draw a
# threshold line at -27. The module's OWN declared floor is -30.00 dBm, so the
# real headroom was ~3.5 dB, roughly 3x what I claimed. The correct numbers had
# been measured and written down on 2026-07-09; I quoted a remembered standard
# over our own recorded measurement.
#
# The fix is structural, not a better memory: a hardcoded constant can drift
# from the hardware, a value read out of the hardware cannot. Swap a module and
# the thresholds follow it. Nothing downstream should ever contain a literal
# dBm figure again -- Grafana computes margin as
#     route10_optical_power_dbm - route10_optical_threshold_dbm
#
# ⚠ The two modules have WILDLY different floors -- W2 -30.00/-28.86 dBm,
# L4 -18.01/-16.00 dBm. A single shared threshold line would be wrong for both,
# which is exactly why this is per-module data rather than a constant.
#
# Sources differ, and neither is a substitute for the other:
#   W2 = the GPON stick's own bus, reachable ONLY through the stick CLI
#        (`i2c get port 1 dev 0x51 reg <n>`, one register per command).
#   L4 = the cage SFP+, on route10's own i2c bus 0 (`i2cget -y 0 0x51 <n>`).
#
# Thresholds are STATIC -- they change only if a module is physically swapped --
# so this runs at most once a day. It is invoked BY pon-collect, inside that
# script's lock, so route10 keeps exactly one stick-CLI user (see the wedge
# notes in pon-collect.sh); it must never be given its own cron entry.
#
# Layout: SFF-8472 A2h bytes 0-39, big-endian uint16 pairs, in the fixed order
# temp / vcc / bias / tx power / rx power, each as
# {high alarm, low alarm, high warning, low warning}.

DB=/a/obs/rt.sql
STATE=/a/obs/.optical-thr.ts
STICK_EXEC=/cfg/scripts/stick-exec.py
MAX_AGE=86400

. /cfg/scripts/lib-observability.sh 2>/dev/null && obs_init optical-thr /cfg/scripts/pon-collect.log \
  || { log(){ :; }; event(){ :; }; warn(){ :; }; err(){ :; }; }

NOW=$(date +%s)
LAST=$(cat "$STATE" 2>/dev/null || echo 0)
case "$LAST" in *[!0-9]*|'') LAST=0 ;; esac
[ "$1" = "--force" ] || [ $((NOW - LAST)) -ge "$MAX_AGE" ] || exit 0

# ── L4: route10's own i2c bus ───────────────────────────────────────────────
# ⛔ THE REGISTER ARGUMENT MUST BE 0x-PREFIXED. This i2cget parses a bare
# argument as HEX, not decimal: `i2cget -y 0 0x51 24` reads register 0x24 (36),
# not 24, and `... 32` reads 0x32 (50) -- past the threshold block entirely.
# Measured 2026-08-11 by reading the same register both ways. It fails
# SILENTLY and plausibly: decimal args returned real-looking bytes from the
# wrong offsets, which decoded into a threshold set that was internally
# consistent and completely wrong. Only the cross-check against a known-good
# manual read caught it.
L4=""
for r in $(seq 0 39); do
    v=$(i2cget -y 0 0x51 "$(printf '0x%02x' "$r")" 2>/dev/null)
    case "$v" in 0x*) L4="$L4 $v" ;; *) L4="$L4 -" ;; esac
done

# ── W2: only reachable through the stick CLI, one register per command ──────
# ⚠ CHUNKED IN TENS, and that is not cosmetic. A single 40-command batch
# OVERRUNS stick-exec's timeout, which closes the socket mid-session and
# strands an orphaned /bin/login+/bin/sh holding the single CLI lock -- i.e.
# it WEDGES THE STICK. Done exactly that on 2026-08-11 building this; recovery
# needed stick-unwedge.sh. A ~20-command batch was previously observed fine, so
# 10 leaves real headroom. Chunks are sequential inside pon-collect's lock, so
# they never overlap each other or anything else.
W2RAW=""
for _base in 0 10 20 30; do
    _cmd='printf "'
    _r=$_base
    while [ "$_r" -lt $((_base + 10)) ]; do
        _cmd="${_cmd}i2c get port 1 dev 0x51 reg $_r\\n"
        _r=$((_r + 1))
    done
    _cmd="${_cmd}exit\\n\" | diag"
    W2RAW="$W2RAW
$(python3 "$STICK_EXEC" "$_cmd" 2>&1)"
    case "$W2RAW" in
        *WEDGED*) warn "optical thresholds: stick CLI wedged mid-read — aborting, previous values kept"; exit 0 ;;
    esac
done

JSON=$(printf '%s' "$W2RAW" | L4="$L4" python3 -c '
import sys, os, re, math, json

def dbm(raw):                      # 0.1 uW -> dBm; 0 is "off", not -inf
    return round(10 * math.log10(raw / 10000.0), 2) if raw > 0 else None

PARAMS = ["temp", "vcc", "bias", "tx", "rx"]        # SFF-8472 A2h byte order
LEVELS = ["high_alarm", "low_alarm", "high_warning", "low_warning"]

def decode(b):
    """b = 40 ints -> {param: {level: value}} in real units."""
    out = {}
    for pi, p in enumerate(PARAMS):
        out[p] = {}
        for li, lv in enumerate(LEVELS):
            i = pi * 8 + li * 2
            if i + 1 >= len(b) or b[i] is None or b[i+1] is None:
                out[p][lv] = None; continue
            raw = (b[i] << 8) | b[i+1]
            if p == "temp":
                out[p][lv] = round((raw - 65536 if raw > 32767 else raw) / 256.0, 2)
            elif p == "vcc":
                out[p][lv] = round(raw / 10000.0, 3)
            elif p == "bias":
                out[p][lv] = round(raw * 2 / 1000.0, 3)
            else:
                out[p][lv] = dbm(raw)
    return out

# W2 comes back as "dev: 0x51, reg: 0xNN, data: 0xNN" lines -- index BY REG,
# never by arrival order: a dropped line would otherwise shift every later
# threshold onto the wrong field and produce plausible-looking nonsense.
w2 = [None] * 40
for m in re.finditer(r"reg:\s*(0x[0-9a-fA-F]+),\s*data:\s*(0x[0-9a-fA-F]+)", sys.stdin.read()):
    r = int(m.group(1), 16)
    if 0 <= r < 40:
        w2[r] = int(m.group(2), 16)

l4 = [None if t == "-" else int(t, 16) for t in os.environ.get("L4", "").split()]
l4 = (l4 + [None] * 40)[:40]

print(json.dumps({
    "w2": decode(w2), "l4": decode(l4),
    "w2_read": sum(1 for x in w2 if x is not None),
    "l4_read": sum(1 for x in l4 if x is not None),
}))
' 2>/dev/null)

case "$JSON" in
    '{'*) ;;
    *) warn "optical thresholds: decode produced nothing, keeping previous values"; exit 0 ;;
esac

# Refuse to publish a partial read. A half-populated threshold set is worse than
# a stale one: the missing half exports as absent and a margin panel silently
# loses its floor. Stale-but-complete is the safer failure, and thresholds are
# static so staleness costs nothing.
W2N=$(printf '%s' "$JSON" | sed -n 's/.*"w2_read":[[:space:]]*\([0-9]*\).*/\1/p')
L4N=$(printf '%s' "$JSON" | sed -n 's/.*"l4_read":[[:space:]]*\([0-9]*\).*/\1/p')
if [ "${W2N:-0}" -lt 40 ] || [ "${L4N:-0}" -lt 40 ]; then
    warn "optical thresholds: partial read (w2=$W2N/40 l4=$L4N/40) — NOT published, previous kept"
    exit 0
fi

sqlite3 "$DB" "
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS optical (ts INTEGER PRIMARY KEY, json TEXT);
INSERT OR REPLACE INTO optical VALUES ($NOW, '$(printf '%s' "$JSON" | sed "s/'/''/g")');
DELETE FROM optical WHERE ts < (SELECT max(ts) FROM optical);
" 2>&1 | grep -qi error && { err "optical thresholds insert failed"; exit 1; }

echo "$NOW" > "$STATE"
event "optical thresholds refreshed (w2 $W2N/40, l4 $L4N/40 registers)"
