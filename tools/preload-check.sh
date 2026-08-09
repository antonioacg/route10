#!/bin/sh
# preload-check.sh — how many bytes of context every session pays before any work.
#
# WORKSTATION TOOL. Never deployed to the router; it measures this repo's
# documentation, not the box.
#
# WHY. Caps agreed with ops 2026-08-09 (seam thread doc-hygiene, P1/P7). The whole
# point of P7 is that the caps themselves drift exactly like the documents they
# govern — silently, with no symptom — and unlike a stale runbook a byte ceiling
# has NO failure mode at all until someone measures it. A cap you never measure is
# a rendered ceiling: it proves what you would enforce, never what you enforce.
#
# Committed FAILING on purpose, matching ops. A checker that lands green next to
# its own cleanup cannot tell you whether the cleanup held — only that somebody
# once made it pass.
#
# Per-file caps are NOT a shared standard. ops derived theirs from a declarative
# cluster where CLAUDE.md can be thin because the manifests are the source of
# truth. This box is partly tmpfs with cloud-mastered config overwritten on boot,
# so the deployed-daemon inventory exists ONLY in CLAUDE.md and in the running
# state — hence 12k here against their 8k. The rule we landed on:
#   THE CAP FOLLOWS WHAT THE FILE IS THE SOLE RECORD OF, NOT WHAT IT IS CALLED.
#
# Usage: tools/preload-check.sh   (exit 1 on any breach)

REPO=$(cd "$(dirname "$0")/.." && pwd)
MEM="$HOME/.claude/projects/-Users-antoniocasagrande-git-route10/memory"

# file:cap — every file loaded into context on EVERY session.
#
# SEAM.md is jointly owned: its cap is charged to both sides, so it is agreed with
# ops and not ours to raise unilaterally. 3,500 replaces the original 3,000 — and
# deliberately WITHOUT the "exempt verbatim blocks" mechanism ops proposed, because
# measuring killed the premise for it. The worry was that a total cap would pressure
# us into compressing the copy-pasteable blocks (the monitor loop, the timestamp
# snippet, the front-matter format), which is the one edit we agreed is unsafe: a
# subtly-wrong monitor silently loses mail. That worry rested on blocks being ~60%
# of the file. Measured, they are 27% (1,208 of 4,535 B), so 3,500 still leaves
# ~2,300 for prose and the cut can be met on narrative alone. An exemption would
# also have made the cap green on day one — prose is already 3,327 — enforcing
# nothing. The split is printed below so that if blocks ever DO come to dominate,
# we see it and revisit rather than discovering it as pressure to compress them.
set -- \
  "$REPO/CLAUDE.md:12000" \
  "$MEM/MEMORY.md:12000" \
  "$HOME/git/agent-seam/SEAM.md:3500" \
  "$HOME/.claude/CLAUDE.md:6000" \
  "$REPO/CLAUDE.local.md:1000" \
  "$HOME/.claude/CLAUDE.local.md:1000"

TOTAL_CAP=40000
total=0
fail=0

printf '%-6s %8s %8s  %s\n' STATUS BYTES CAP FILE
for entry in "$@"; do
    f=${entry%:*}; cap=${entry##*:}
    [ -f "$f" ] || { printf '%-6s %8s %8s  %s\n' MISSING - "$cap" "${f#$HOME/}"; continue; }
    b=$(wc -c < "$f" | tr -d ' ')
    total=$((total + b))
    if [ "$b" -gt "$cap" ]; then
        st=OVER; fail=1
    else
        st=ok
    fi
    printf '%-6s %8d %8d  %s\n' "$st" "$b" "$cap" "${f#$HOME/}"
done

echo "─────"
if [ "$total" -gt "$TOTAL_CAP" ]; then
    printf '%-6s %8d %8d  TOTAL (~%dk tokens)\n' OVER "$total" "$TOTAL_CAP" "$((total / 4000))"
    fail=1
else
    printf '%-6s %8d %8d  TOTAL (~%dk tokens)\n' ok "$total" "$TOTAL_CAP" "$((total / 4000))"
fi

# Prose vs verbatim-block split for the joint file. Shown, not enforced: the cap is
# on the total, and this is here so the assumption behind that choice stays visible.
# If blocks ever grow to dominate, the total cap starts pushing toward compressing
# them — which is the unsafe edit — and we revisit the number instead of obeying it.
SEAM="$HOME/git/agent-seam/SEAM.md"
if [ -f "$SEAM" ]; then
    # Fences are matched with leading whitespace allowed: SEAM.md's blocks sit
    # inside list items and are indented. An anchored /^```/ silently reported
    # 0% blocks — a verification failing in the REASSURING direction, which would
    # have made the "blocks don't dominate" argument look stronger than it is.
    awk '
      /^[ \t]*```/ { inb = !inb; b += length($0)+1; next }
      { if (inb) b += length($0)+1; else p += length($0)+1 }
      END { printf "(SEAM.md split: %d prose / %d verbatim blocks — blocks are %d%%, cap is on the total)\n", p, b, (p+b) ? 100*b/(p+b) : 0 }
    ' "$SEAM"
fi

# The tier that does NOT cost per-turn — shown for contrast, deliberately uncapped.
# Recalled on demand, so a large corpus here is fine; the index above is what pays.
if [ -d "$MEM" ]; then
    n=$(find "$MEM" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
    b=$(find "$MEM" -maxdepth 1 -name '*.md' -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    echo "(on-demand memory: $n files, $b bytes — uncapped by design, not preloaded)"
fi

exit "$fail"
