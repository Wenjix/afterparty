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

# Args go to glance; style comes from $STYLE. An assignment prefix on a
# FUNCTION call works (STYLE=always run), unlike `VAR=x "$@" cmd`, where the
# prefix is parsed before expansion and bash hunts for a command named "VAR=x".
run() {
  PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$R" \
    AFTERPARTY_STYLE="${STYLE:-never}" bash "$LIB/glance.sh" "$@"
}
# Same world, but with AFTERPARTY_STYLE left unset, for the auto-vs-never check.
run_auto() { PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$R" bash "$LIB/glance.sh" "$@"; }

OUT="$(run 2>/dev/null)"

# ---------- G1: workspaces with processes appear, empty ones do not ----------
_b=$FAILS
printf '%s\n' "$OUT" | grep -q 'fresh'  || fail "G1: /w/fresh missing"
printf '%s\n' "$OUT" | grep -q 'forgot' || fail "G1: /w/forgot missing"
printf '%s\n' "$OUT" | grep -q 'quiet'  && fail "G1: /w/quiet has no processes and must not be listed"
[ "$FAILS" -eq "$_b" ] && pass "G1: only workspaces holding processes are listed"

# ---------- G2: a subdirectory cwd attributes to its workspace ----------
# pid 4003 sits in /w/forgot/packages/web; it belongs to /w/forgot, so the
# workspace holds 2 processes, not 1.
#
# Assert the PROCS COLUMN, never a substring: `grep -qE 'forgot[^0-9]*2'` used
# to stop at the first digit after the name, which is the 2 of "2421d 17h" in
# LAST TOUCHED, so the process count was never inspected at all. The row is
# "<name> <age...> <procs> <cpu> <ports>" and the fixture gives this workspace
# exactly one port, so PROCS is $(NF-2) however many fields the age took.
_b=$FAILS
G2_ROW="$(printf '%s\n' "$OUT" | grep 'forgot' | head -1)"
G2_PROCS="$(printf '%s\n' "$G2_ROW" | awk '{print $(NF-2)}')"
[ "$G2_PROCS" = "2" ] || fail "G2: PROCS column is '$G2_PROCS', want 2 (row: $G2_ROW)"
# 3001 is listened on by the NESTED pid only, so it can only appear here via
# the longest-prefix attribution under test.
printf '%s\n' "$G2_ROW" | grep -q '3001' || fail "G2: nested pid's port missing from the row"
[ "$FAILS" -eq "$_b" ] && pass "G2: nested cwd attributed to the enclosing workspace"

# ---------- G3: sorted by staleness, forgotten last ----------
FRESH=$(printf '%s\n' "$OUT" | grep -n 'fresh'  | head -1 | cut -d: -f1)
FORG=$( printf '%s\n' "$OUT" | grep -n 'forgot' | head -1 | cut -d: -f1)
if [ -n "$FRESH" ] && [ -n "$FORG" ] && [ "$FORG" -gt "$FRESH" ]; then
  pass "G3: sorted by staleness, forgotten sinks last"
else
  fail "G3: staleness order wrong (fresh=$FRESH forgot=$FORG)"
fi

# ---------- G4: read-only by construction ----------
# Each flag is passed ALONE. The old form passed a trailing "dev", which would
# itself have tripped the unknown-option arm, so the assertion would have kept
# passing the moment someone added a real --kill arm -- the exact regression it
# exists to catch. Asserting the message NAMES the flag proves the rejection
# was entered for the flag rather than for a stray positional.
_b=$FAILS
for flag in --kill --apply --clean; do
  err="$(PATH="$SHIM:$PATH" bash "$LIB/glance.sh" "$flag" 2>&1 >/dev/null)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "G4: glance accepted $flag"
  printf '%s\n' "$err" | grep -q -- "$flag" \
    || fail "G4: rejection of $flag did not name it (said: $err)"
done
# Structural backstop: no mutation verb may appear as an option arm at all.
grep -Eq '^[[:space:]]*--(kill|apply|clean)\)' "$LIB/glance.sh" \
  && fail "G4: glance.sh has grown a mutation option arm"
[ "$FAILS" -eq "$_b" ] && pass "G4: glance refuses every mutation flag, by name"

# ---------- G5: piped output plain and stable ----------
_b=$FAILS
run_auto > "$T/a" 2>/dev/null
run > "$T/b" 2>/dev/null
diff -q "$T/a" "$T/b" >/dev/null || fail "G5: plain drift between auto and never"
grep -q "$ESC" "$T/a" && fail "G5: ANSI leaked into piped output"
[ "$FAILS" -eq "$_b" ] && pass "G5: piped output plain and byte-stable"

# ---------- G6: styled mode tints the hot cpu, plain does not ----------
_b=$FAILS
SOUT="$(STYLE=always run 2>/dev/null)"
printf '%s\n' "$SOUT" | grep -q "$ESC" || fail "G6: styled mode produced no ANSI"
printf '%s\n' "$OUT"  | grep -q '87.3' || fail "G6: plain lost the cpu value"
[ "$FAILS" -eq "$_b" ] && pass "G6: styled adds tint, plain keeps the value"

# ---------- G7: status-line density is exactly one line ----------
_b=$FAILS
ONE="$(run --oneline 2>/dev/null)"
[ "$(printf '%s\n' "$ONE" | grep -c .)" -eq 1 ] || fail "G7: --oneline emitted more than one line"
printf '%s\n' "$ONE" | grep -q 'idle' || fail "G7: --oneline hid the idle workspace"
printf '%s\n' "$ONE" | grep -q "$ESC" && fail "G7: ANSI in piped --oneline"
[ "$FAILS" -eq "$_b" ] && pass "G7: --oneline is one line and names the idle count"

# ---------- G8: --json is parseable JSON Lines with numeric idle ----------
_b=$FAILS
PY_BIN="$(command -v python3 || command -v python)"
JOUT="$(run --json 2>/dev/null)"
printf '%s\n' "$JOUT" | grep -q "$ESC" && fail "G8: ANSI leaked into --json"
if [ -n "$PY_BIN" ]; then
  printf '%s\n' "$JOUT" | "$PY_BIN" -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
assert rows, "no json rows"
# Two sections now: capability rows let a consumer tell "unknown" from "empty".
# Validate each on its own terms rather than loosening the workspace schema.
ws = [r for r in rows if r["section"] == "workspace"]
caps = [r for r in rows if r["section"] == "capability"]
assert ws, "no workspace rows"
assert caps, "no capability rows"
for r in rows:
    assert r["schema_version"] == 1, r
    assert r["section"] in ("workspace", "capability"), r
for r in caps:
    assert r["status"] in ("ok", "unavailable"), r
    assert r["name"], r
for r in ws:
    assert isinstance(r["idle_seconds"], int), "idle_seconds must be a number: %r" % r
    assert r["path"].startswith("/"), "path must be absolute: %r" % r
    assert isinstance(r["procs"], int), r
stale = [r for r in ws if r["path"] == "/w/forgot"]
assert stale and stale[0]["idle_seconds"] > 3600, "forgot should be deeply idle: %r" % stale
' || fail "G8: json rows malformed"
fi
[ "$FAILS" -eq "$_b" ] && pass "G8: --json parses with numeric idle_seconds and absolute paths"

# ---------- G9: a scanner that could not run means UNKNOWN, not "nothing" ----------
# glance printed an empty table and exited 0 when lsof was missing — a
# confident all-clear for a machine it never inspected. This is the surface
# read first after switching context, so "quiet" is exactly what tells someone
# it is safe to stop looking.
_b=$FAILS
NOLSOF="$T/nolsof"; mkdir -p "$NOLSOF"
# a PATH with ps but deliberately no lsof
cp "$SHIM/ps" "$NOLSOF/ps"
OUT9="$(PATH="$NOLSOF:/usr/bin:/bin" AFTERPARTY_TRANSCRIPT_ROOT="$R" AFTERPARTY_STYLE=never \
  bash "$LIB/glance.sh" 2>&1)"
printf '%s\n' "$OUT9" | grep -qi 'incomplete' \
  || fail "G9: no incompleteness notice when lsof is unavailable: $OUT9"
printf '%s\n' "$OUT9" | grep -qi 'lsof' \
  || fail "G9: the notice does not name the missing scanner"
ONE9="$(PATH="$NOLSOF:/usr/bin:/bin" AFTERPARTY_TRANSCRIPT_ROOT="$R" AFTERPARTY_STYLE=never \
  bash "$LIB/glance.sh" --oneline 2>&1)"
printf '%s\n' "$ONE9" | grep -qi 'incomplete' \
  || fail "G9: --oneline claimed a clean machine it could not see: $ONE9"
# positive control: with lsof present the same world reports workspaces, so the
# notice above is about capability and not about an empty fixture
printf '%s\n' "$OUT" | grep -q 'forgot' \
  || fail "G9: control — the normal run should still list workspaces"
[ "$FAILS" -eq "$_b" ] && pass "G9: missing capability reports unknown, never a clean bill of health"

# ---------- G10: --json carries capability rows ----------
_b=$FAILS
J9="$(PATH="$NOLSOF:/usr/bin:/bin" AFTERPARTY_TRANSCRIPT_ROOT="$R" bash "$LIB/glance.sh" --json 2>/dev/null)"
printf '%s\n' "$J9" | grep -q '"section":"capability"' \
  || fail "G10: --json has no capability rows, so a consumer cannot tell unknown from empty"
printf '%s\n' "$J9" | grep -q '"status":"unavailable"' \
  || fail "G10: --json did not mark the missing scanner unavailable"
if [ -n "${PY_BIN:-$(command -v python3)}" ]; then
  printf '%s\n' "$J9" | "${PY_BIN:-$(command -v python3)}" -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' \
    || fail "G10: --json stopped parsing once capability rows were added"
fi
[ "$FAILS" -eq "$_b" ] && pass "G10: --json exposes capability so consumers can tell unknown from empty"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
