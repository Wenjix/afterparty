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

# ---------- W3: identity comes from the recorded cwd, not the dir name ----------
# The slug is lossy -- both "/" and "." become "-" -- so decoding it is
# ambiguous. The transcript stamps its own cwd; read that instead.
R="$T/projects"
mkdir -p "$R/-Users-x-alpha" "$R/-Users-x-beta" "$R/empty"
printf '{"type":"user","cwd":"/Users/x/alpha","sessionId":"a"}\n' > "$R/-Users-x-alpha/a.jsonl"
printf '{"type":"user","cwd":"/Users/x/beta","sessionId":"b"}\n'  > "$R/-Users-x-beta/b.jsonl"
_b=$FAILS
OUT="$(AFTERPARTY_TRANSCRIPT_ROOT="$R" ws_index)"
printf '%s\n' "$OUT" | grep -q '/Users/x/alpha' || fail "W3: alpha missing from index"
printf '%s\n' "$OUT" | grep -q '/Users/x/beta'  || fail "W3: beta missing from index"
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 2 ] || fail "W3: a transcript-less dir contributed a row"
# A literal tab, not "\t": GNU grep reads \t in a BRE as the letter t, while
# BSD grep reads it as a tab -- so the escaped form passes on macOS and fails
# on Linux.
TAB="$(printf '\t')"
printf '%s\n' "$OUT" | grep -q "^[0-9][0-9]*${TAB}/Users/x/alpha$" \
  || fail "W3: row is not <epoch>TAB<cwd>"
[ "$FAILS" -eq "$_b" ] && pass "W3: workspaces indexed by transcript-recorded cwd"

# ---------- W4: newest transcript in a workspace decides last-touched ----------
printf '{"cwd":"/Users/x/alpha"}\n' > "$R/-Users-x-alpha/older.jsonl"
touch -t 202001010000 "$R/-Users-x-alpha/older.jsonl" 2>/dev/null \
  || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$R/-Users-x-alpha/older.jsonl"
TS="$(AFTERPARTY_TRANSCRIPT_ROOT="$R" ws_index | awk -F'\t' '$2=="/Users/x/alpha"{print $1}')"
NOW="$(date +%s)"
if [ -n "$TS" ] && [ "$((NOW - TS))" -lt 3600 ]; then
  pass "W4: newest transcript decides last-touched"
else
  fail "W4: index used a stale transcript instead of the newest"
fi

# ---------- W5: no transcript root degrades quietly ----------
if AFTERPARTY_TRANSCRIPT_ROOT="$T/absent" ws_index >/dev/null 2>&1; then
  pass "W5: missing transcript root degrades to empty"
else
  fail "W5: missing transcript root errored instead of degrading"
fi

# ---------- W6: pid attribution needs lsof and fails closed without it ----------
SHIM="$T/wsshim"; mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nprintf "p7001\\nn/w/attributed\\n"\n' > "$SHIM/lsof"
chmod +x "$SHIM/lsof"
_b=$FAILS
GOT="$(PATH="$SHIM:$PATH" ws_for_pid 7001)"
[ "$GOT" = "/w/attributed" ] || fail "W6: ws_for_pid returned '$GOT', want /w/attributed"
if PATH="$T/nothing" ws_for_pid 7001 >/dev/null 2>&1; then
  fail "W6: ws_for_pid claimed a workspace with no lsof"
else
  [ "$FAILS" -eq "$_b" ] && pass "W6: pid attributed via lsof, fails closed without it"
fi

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
