#!/usr/bin/env bash
# workspace.sh unit tests: age formatting, mtime, transcript indexing, and pid
# attribution. READ-ONLY throughout -- workspace.sh never signals or deletes.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

# shellcheck source=/dev/null
. "$LIB/workspace.sh"

# ---------- W1: age bands the glance table renders ----------
while IFS='|' read -r secs want; do
  got="$(ws_human_age "$secs")"
  if [ "$got" = "$want" ]; then
    pass "W1: ${secs}s -> $want"
  else
    fail "W1: ${secs}s -> '$got', want '$want'"
  fi
done <<'CASES'
0|just now
59|just now
60|1m
900|15m
3600|1h 00m
24000|6h 40m
86400|1d 00h
183600|2d 03h
CASES

# ---------- W2: mtime reads real files and fails closed on missing ----------
touch "$T/f"
if [ -n "$(ws_mtime "$T/f")" ]; then pass "W2: mtime of a real file"; else fail "W2: no mtime for a real file"; fi
if ws_mtime "$T/nope" >/dev/null 2>&1; then
  fail "W2: missing file reported a mtime"
else
  pass "W2: missing file fails closed"
fi

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
