#!/bin/sh
# tools/deploy-preflight.sh — validate that shell script(s) are safe to deploy to
# Route10 (busybox **ash**) BEFORE copying them to /cfg.
#
# Why this exists: macOS /bin/sh is bash in POSIX mode, so a local `sh -n` can
# accept bashisms that real ash rejects. The authoritative check here is running
# busybox `sh -n` ON THE ROUTER itself.
#
# Per-script checks:
#   1. shebang is /bin/sh or /bin/ash  (not bash)            [FAIL]
#   2. LF (not CRLF) line endings                            [FAIL]
#   3. local `sh -n` syntax                                  [FAIL]
#   4. shellcheck -s dash  (if installed) — POSIX/bashism lint [WARN]
#   5. bashism heuristic scan                                [WARN]
#   6. REAL busybox-ash `sh -n` on the router — ground truth [FAIL]
#
# Exit 0 = all scripts pass. Non-zero = at least one HARD failure (FAIL).
# WARNs are advisory and never fail the run.

set -u

HOST=route10
REMOTE=1

usage() {
  cat <<'EOF'
deploy-preflight.sh — validate shell scripts for the Route10 (busybox ash) env.

Usage: tools/deploy-preflight.sh [-H host] [-n|--no-remote] <script> [<script>...]
  -H HOST          ssh host for the real-ash check (default: route10)
  -n, --no-remote  skip the on-router ash check (local checks only)

Checks: shebang, LF endings, local 'sh -n', shellcheck -s dash (if present),
bashism heuristic, and the authoritative busybox-ash 'sh -n' on the router.
EOF
  exit "${1:-0}"
}

files=
while [ $# -gt 0 ]; do
  case "$1" in
    -H) HOST=${2:?'-H needs a host'}; shift 2 ;;
    -n|--no-remote) REMOTE=0; shift ;;
    -h|--help) usage 0 ;;
    --) shift; for a in "$@"; do files="$files $a"; done; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; usage 2 ;;
    *) files="$files $1"; shift ;;
  esac
done
[ -n "$files" ] || usage 2

if [ -t 1 ]; then
  R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
  B=$(printf '\033[1m'); Z=$(printf '\033[0m')
else
  R=; G=; Y=; B=; Z=
fi
CR=$(printf '\r')
TMP=$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

gfail=0
P() { printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
W() { printf '  %sWARN%s %s\n' "$Y" "$Z" "$1"; }
F() { printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; ffile=1; gfail=1; }

for f in $files; do
  ffile=0
  printf '%s== %s ==%s\n' "$B" "$f" "$Z"
  if [ ! -f "$f" ]; then F "file not found"; continue; fi

  # 1. shebang
  sb=$(head -n1 "$f")
  case "$sb" in
    '#!/bin/sh'|'#!/bin/ash'|'#! /bin/sh') P "shebang: $sb" ;;
    *bash*) F "shebang targets bash ($sb) — Route10 runs ash" ;;
    '#!'*) W "non-standard shebang: $sb" ;;
    *) F "no shebang (first line: $sb)" ;;
  esac

  # 2. line endings
  if grep -q "$CR" "$f"; then F "CRLF line endings — convert to LF (dos2unix)"
  else P "LF line endings"; fi

  # 3. local POSIX syntax
  if sh -n "$f" 2>"$TMP/err"; then P "local 'sh -n' syntax"
  else F "local 'sh -n':"; sed 's/^/        /' "$TMP/err"; fi

  # 4. shellcheck (dash ~= ash)
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s dash -S warning "$f" >"$TMP/sc" 2>&1; then P "shellcheck -s dash (POSIX)"
    else W "shellcheck -s dash findings:"; sed 's/^/        /' "$TMP/sc"; fi
  else
    W "shellcheck not installed — 'brew install shellcheck' for POSIX lint"
  fi

  # 5. bashism heuristic (advisory; the router ash -n below is authoritative for syntax)
  bish=$(grep -nE '\[\[|=~|function |<\(|>\(|declare |mapfile|readarray|echo -e|&>' "$f" 2>/dev/null) || true
  if [ -n "$bish" ]; then W "possible bashisms (confirm they work under ash):"; printf '%s\n' "$bish" | sed 's/^/        /'
  else P "no obvious bashisms"; fi

  # 6. REAL busybox-ash syntax check on the router (ground truth)
  if [ "$REMOTE" = 1 ]; then
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" 'sh -n' <"$f" 2>"$TMP/rem"; then
      P "router busybox-ash 'sh -n' ($HOST) — ground truth"
    elif grep -qiE 'syntax|unexpected|parse' "$TMP/rem" 2>/dev/null; then
      F "router ash 'sh -n' ($HOST):"; sed 's/^/        /' "$TMP/rem"
    else
      W "could not reach $HOST for real-ash check — local checks stand (use -n to skip)"
    fi
  else
    W "remote ash check skipped (--no-remote)"
  fi

  if [ "$ffile" = 0 ]; then printf '  %s%s-> OK%s\n' "$G" "$B" "$Z"
  else printf '  %s%s-> FAILED%s\n' "$R" "$B" "$Z"; fi
done

if [ "$gfail" = 0 ]; then
  printf '%s%spreflight: all checks passed%s\n' "$G" "$B" "$Z"; exit 0
else
  printf '%s%spreflight: FAILURES present - do not deploy%s\n' "$R" "$B" "$Z"; exit 1
fi
