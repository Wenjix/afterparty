#!/usr/bin/env bash
# glance rendering, with fake ps/lsof on PATH so the table is deterministic.
# glance is READ-ONLY by construction: there is no --kill/--apply to guard, and
# G3 pins that fact so a future flag cannot quietly make it a mutation surface.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
ESC=$'\033'
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$REPO" || exit 1

# ---------- canned world ----------
# /w/fresh   : touched now, one hot vitest
# /w/forgot  : touched long ago, a dev server and a child, listening on 3001
# /w/quiet   : touched long ago, NO processes -- must not appear
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pid,pgid,%cpu,command*|*pid,ppid,pgid,%cpu,etime,command*)
    printf '4001 4001 87.3 node /w/fresh/node_modules/.bin/vitest --watch\n'
    printf '4002 4002  0.0 npm run dev\n'
    printf '4003 4002  1.5 node /w/forgot/node_modules/.bin/vite\n'
    ;;
  *) exit 1 ;;
esac
PS
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in
  *-d\ cwd*)
    printf 'p4001\nfcwd\nn/w/fresh\n'
    printf 'p4002\nfcwd\nn/w/forgot\n'
    printf 'p4003\nfcwd\nn/w/forgot/packages/web\n'
    ;;
  *LISTEN*) printf 'node 4003 u 26u IPv6 0x1 0t0 TCP *:3001 (LISTEN)\n' ;;
  *) exit 1 ;;
esac
LS
chmod +x "$SHIM/ps" "$SHIM/lsof"

R="$T/projects"; mkdir -p "$R/-w-fresh" "$R/-w-forgot" "$R/-w-quiet"
printf '{"cwd":"/w/fresh"}\n'  > "$R/-w-fresh/a.jsonl"
printf '{"cwd":"/w/forgot"}\n' > "$R/-w-forgot/b.jsonl"
printf '{"cwd":"/w/quiet"}\n'  > "$R/-w-quiet/c.jsonl"
for f in "$R/-w-forgot/b.jsonl" "$R/-w-quiet/c.jsonl"; do
  touch -t 202001010000 "$f" 2>/dev/null || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$f"
done

# env, not a bare "$@": assignment prefixes are parsed before expansion, so
# `VAR=x "$@" bash ...` looks for a command literally named "VAR=x".
run() { PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$R" env "$@" bash "$LIB/glance.sh"; }

OUT="$(run AFTERPARTY_STYLE=never 2>/dev/null)"

# ---------- G1: workspaces with processes appear, empty ones do not ----------
_b=$FAILS
printf '%s\n' "$OUT" | grep -q 'fresh'  || fail "G1: /w/fresh missing"
printf '%s\n' "$OUT" | grep -q 'forgot' || fail "G1: /w/forgot missing"
printf '%s\n' "$OUT" | grep -q 'quiet'  && fail "G1: /w/quiet has no processes and must not be listed"
[ "$FAILS" -eq "$_b" ] && pass "G1: only workspaces holding processes are listed"

# ---------- G2: a subdirectory cwd attributes to its workspace ----------
# pid 4003 sits in /w/forgot/packages/web; it belongs to /w/forgot, and the
# workspace therefore holds 2 processes, not 1.
if printf '%s\n' "$OUT" | grep -qE 'forgot[^0-9]*2'; then
  pass "G2: nested cwd attributed to the enclosing workspace"
else
  fail "G2: /w/forgot should hold 2 procs: $(printf '%s\n' "$OUT" | grep forgot)"
fi

# ---------- G3: sorted by staleness, forgotten last ----------
FRESH=$(printf '%s\n' "$OUT" | grep -n 'fresh'  | head -1 | cut -d: -f1)
FORG=$( printf '%s\n' "$OUT" | grep -n 'forgot' | head -1 | cut -d: -f1)
if [ -n "$FRESH" ] && [ -n "$FORG" ] && [ "$FORG" -gt "$FRESH" ]; then
  pass "G3: sorted by staleness, forgotten sinks last"
else
  fail "G3: staleness order wrong (fresh=$FRESH forgot=$FORG)"
fi

# ---------- G4: read-only by construction ----------
_b=$FAILS
for flag in --kill --apply --clean; do
  if PATH="$SHIM:$PATH" bash "$LIB/glance.sh" "$flag" dev >/dev/null 2>&1; then
    fail "G4: glance accepted $flag"
  fi
done
[ "$FAILS" -eq "$_b" ] && pass "G4: glance refuses every mutation flag"

# ---------- G5: piped output plain and stable ----------
_b=$FAILS
run > "$T/a" 2>/dev/null
run AFTERPARTY_STYLE=never > "$T/b" 2>/dev/null
diff -q "$T/a" "$T/b" >/dev/null || fail "G5: plain drift between auto and never"
grep -q "$ESC" "$T/a" && fail "G5: ANSI leaked into piped output"
[ "$FAILS" -eq "$_b" ] && pass "G5: piped output plain and byte-stable"

# ---------- G6: styled mode tints the hot cpu, plain does not ----------
_b=$FAILS
SOUT="$(run AFTERPARTY_STYLE=always 2>/dev/null)"
printf '%s\n' "$SOUT" | grep -q "$ESC" || fail "G6: styled mode produced no ANSI"
printf '%s\n' "$OUT"  | grep -q '87.3' || fail "G6: plain lost the cpu value"
[ "$FAILS" -eq "$_b" ] && pass "G6: styled adds tint, plain keeps the value"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
