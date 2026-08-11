# rdns-logfilter.awk — collapse a sustained routedns failure storm into
# "first occurrence + periodic counted rollup", without touching routedns itself.
#
# WHY THIS EXISTS (2026-08-11 outage): when every upstream is dead, routedns logs
# a WARN per failed resolution and per late-arriving answer. Measured 1629
# lines/min — 92% of route10's entire syslog — which collapsed the local
# /var/log/messages ring to 14 SECONDS and evicted every other component's
# alerts. The information content of those 1629 lines is about three facts.
#
# WHAT IT PRESERVES, deliberately:
#   - The STATE TRANSITION. The first occurrence of each distinct condition is
#     emitted verbatim and immediately, so "we just started failing over" is
#     never delayed or lost. That is the event ops alerts on.
#   - The COUNT. Sustained repeats become one rollup line carrying an integer,
#     which is a better input to an alert than raw volume was.
#   - Severity. Rollups carry the original level= token so the wrapper's
#     sev-mapping keeps working unchanged.
#
# SIGNATURE = severity + the msg="..." text. It must NOT include qname/client/
# duration: those vary per line and would defeat dedup entirely. And it must be
# per-signature rather than "last line repeated", because the three conditions
# INTERLEAVE constantly — a naive last-line comparison collapses nothing here.
#
# Measured on 600 real captured lines from the outage: 600 -> 24 (96%). That
# test used line-count windows and is conservative; on a 60 s wall-clock window
# at the live rate it is ~1629 lines/min -> ~6.
#
# ⚠ fflush() after every emit is LOAD-BEARING. awk block-buffers when stdout is
# a pipe, and this feeds a `logger` loop — without the flush, an alert could sit
# in a buffer for an arbitrary time, which is precisely the failure this whole
# file is meant to prevent.
#
# TESTMODE=1 substitutes NR for wall-clock so the filter can be tested against a
# static capture deterministically.

{
    sev = "info"; lvl = "INFO"
    if      (index($0, "level=ERROR")) { sev = "err";     lvl = "ERROR" }
    else if (index($0, "level=WARN"))  { sev = "warning"; lvl = "WARN"  }
    else if (index($0, "level=DEBUG")) { sev = "debug";   lvl = "DEBUG" }
    else if (index($0, "level=TRACE")) { sev = "debug";   lvl = "TRACE" }

    sig = "other"
    if (match($0, /msg="[^"]*"/)) sig = substr($0, RSTART, RLENGTH)
    key = sev "|" sig

    # Emitted as `original_msg="<text>"`, NOT `original=msg="<text>"`.
    # logfmt reads key=value, so a value that itself begins unquoted with `msg=`
    # terminates at the first space -- yielding original="msg=\"failing" and
    # leaving `over`, `to`, `resolver"` as stray tokens. A nested key=value
    # inside an unquoted value is not representable in logfmt. Caught by ops
    # before the format was ever seen in anger; it would first have been parsed
    # mid-incident, which is the worst possible time to discover a bad parser.
    sigval = sig
    sub(/^msg=/, "", sigval)
    if (sigval == "other") sigval = "\"other\""

    now = (TESTMODE ? NR : systime())

    if (!(key in seen)) {                 # new condition => emit verbatim, now
        seen[key] = 1; cnt[key] = 0; t0[key] = now
        print $0
        fflush()
        next
    }

    cnt[key]++
    if (now - t0[key] >= WINDOW) {        # sustained => one counted line
        printf "level=%s msg=\"routedns-rollup\" suppressed=%d window=%d%s original_msg=%s\n", \
               lvl, cnt[key], (now - t0[key]), (TESTMODE ? "lines" : "s"), sigval
        fflush()
        cnt[key] = 0; t0[key] = now
    }
}
