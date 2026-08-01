#!/usr/bin/env bash
# Live kill-path coverage: real processes, real signals. Needs a full ps
# (-Ao) and setsid — present on Linux CI runners; self-skips on Git Bash /
# Windows and on systems without setsid.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"

if ! ps -Ao pid= >/dev/null 2>&1 || ! command -v setsid >/dev/null 2>&1; then
  echo "SKIP: ps -Ao or setsid unavailable — kill paths not live-testable here"
  exit 0
fi

FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

T="$(mktemp -d)"
SPAWNED_GROUPS=""
cleanup() {
  local pg
  for pg in $SPAWNED_GROUPS; do kill -9 -"$pg" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
cd "$REPO" || exit 1

# Spawn a command as its own session/group leader; echo the leader pid
# (which equals the pgid). The spawned process MUST be detached from our
# stdout/stderr: callers capture this function with $(...) and a background
# child holding the substitution pipe would block the capture until the
# child exits (sleep 300 = a five-minute hang per spawn).
spawn_group() {
  local pf="$T/pid.$RANDOM.$RANDOM" i=0
  setsid bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pf" "$@" >/dev/null 2>&1 </dev/null &
  while [ ! -s "$pf" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  cat "$pf" 2>/dev/null
}

wait_dead() { # pid — up to ~5s
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  ! kill -0 "$1" 2>/dev/null
}

mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$T/bin/nodemon"        # matches DEV_RE
printf '#!/usr/bin/env bash\nsleep 300\n' > "$T/bin/cursor-server"  # matches PROTECT_RE
printf '#!/usr/bin/env bash\n"$(dirname "$0")/cursor-server" &\nexec "$(dirname "$0")/nodemon"\n' > "$T/bin/party"
chmod +x "$T/bin/nodemon" "$T/bin/cursor-server" "$T/bin/party"

B1=$FAILS
# ---------- 1. ledger stop --kill really kills the recorded group ----------
LEDGER="$T/ledger.tsv"
P1="$(spawn_group sleep 300)"
[ -n "$P1" ] || fail "spawn failed (ledger test)"
SPAWNED_GROUPS="$SPAWNED_GROUPS $P1"
AGENT_PROCESS_LEDGER="$LEDGER" bash "$LIB/process-ledger.sh" add --pid "$P1" --kind dev --purpose "kill test" -- sleep 300 >/dev/null
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" bash "$LIB/process-ledger.sh" stop --kill 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q "SIGTERM -> pgid $P1" || fail "ledger kill: SIGTERM line missing"
printf '%s\n' "$OUT" | grep -q '1 process group sent home' || fail "ledger kill: receipt count wrong"
wait_dead "$P1" || fail "ledger kill: process survived"
[ "$FAILS" -eq "$B1" ] && pass "ledger stop --kill kills the recorded group and counts it"

B2=$FAILS
# ---------- 2. audit --kill dev really kills a matching group ----------
P2="$(spawn_group "$T/bin/nodemon")"
[ -n "$P2" ] || fail "spawn failed (category test)"
SPAWNED_GROUPS="$SPAWNED_GROUPS $P2"
OUT="$(bash "$LIB/audit-processes.sh" 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q 'nodemon' || fail "category kill: dry run did not list nodemon"
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/audit-processes.sh" --kill dev 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q "SIGTERM -> pgid $P2" || fail "category kill: SIGTERM line missing"
printf '%s\n' "$OUT" | grep -q '1 process group shown the door' || fail "category kill: receipt count wrong"
wait_dead "$P2" || fail "category kill: process survived"
[ "$FAILS" -eq "$B2" ] && pass "audit --kill dev kills the matching group and counts real kills"

B3=$FAILS
# ---------- 3. protected sibling shields the whole group ----------
P3="$(spawn_group "$T/bin/party")"
[ -n "$P3" ] || fail "spawn failed (protect test)"
SPAWNED_GROUPS="$SPAWNED_GROUPS $P3"
sleep 0.3   # let the cursor-server sibling start
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/audit-processes.sh" --kill dev 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q "protect pgid $P3: shares its group with a protected process" \
  || fail "protect: guard message missing"
printf '%s\n' "$OUT" | grep -q "SIGTERM -> pgid $P3" && fail "protect: group was signaled anyway"
kill -0 "$P3" 2>/dev/null || fail "protect: nodemon leader died"
pgrep -f "bin/cursor-server" >/dev/null 2>&1 || fail "protect: cursor-server sibling died"
[ "$FAILS" -eq "$B3" ] && pass "a protected sibling shields the whole group from --kill"

B4=$FAILS
# ---------- 4. recycled-pid guard refuses a mismatched group ----------
P4="$(spawn_group sleep 300)"
[ -n "$P4" ] || fail "spawn failed (recycle test)"
SPAWNED_GROUPS="$SPAWNED_GROUPS $P4"
RECORDED_PGID=$((P4 + 1))
TEST_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')"
if [ "$RECORDED_PGID" = "$TEST_PGID" ]; then
  RECORDED_PGID=$((RECORDED_PGID + 1))
fi
printf '2026-07-14T00:00:00Z\t%s\t%s\t%s\t%s\tdev\t-\trecycle test\tsleep 300\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" "$P4" "$RECORDED_PGID" > "$T/recycled.tsv"
OUT="$(AGENT_PROCESS_LEDGER="$T/recycled.tsv" bash "$LIB/process-ledger.sh" stop --kill 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q "skip pid $P4: group changed since it was recorded" \
  || fail "recycle guard: skip message missing"
kill -0 "$P4" 2>/dev/null || fail "recycle guard: process was killed despite mismatch"
[ "$FAILS" -eq "$B4" ] && pass "recycled-pid guard refuses a group that no longer matches"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
