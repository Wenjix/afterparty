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
# ---------- 4. member-identity guard refuses a recycled group ----------
. "$LIB/fingerprint.sh"
P4="$(spawn_group sleep 300)"
[ -n "$P4" ] || fail "spawn failed (recycle test)"
SPAWNED_GROUPS="$SPAWNED_GROUPS $P4"
AGENT_PROCESS_LEDGER="$T/verified.tsv" bash "$LIB/process-ledger.sh" add --pid "$P4" \
  --kind dev --purpose "recycle test" -- sleep 300 >/dev/null || fail "recycle guard: recording failed"
# Keep the real PGID and current schema, changing only the saved member proof.
# An invented PGID exits at the absent-group check, while a legacy nine-field
# row tests missing evidence rather than a verified identity that changed.
STALE_MEMBER="$P4:$(printf 'earlier process identity for %s' "$P4" | fp_hash)"
CURRENT_MEMBERS="$(awk -F '\t' 'NF == 10 { print $10 }' "$T/verified.tsv")"
[ -n "$CURRENT_MEMBERS" ] && [ "$CURRENT_MEMBERS" != "$STALE_MEMBER" ] \
  || fail "recycle guard: fixture must change a recorded member identity"
awk -F '\t' -v OFS='\t' -v stale="$STALE_MEMBER" '{$10=stale; print}' \
  "$T/verified.tsv" > "$T/recycled.tsv"
OUT="$(AGENT_PROCESS_LEDGER="$T/recycled.tsv" bash "$LIB/process-ledger.sh" stop --kill 2>&1)"
RC=$?
[ "$RC" -ne 0 ] || fail "recycle guard: refused identity reported success"
printf '%s\n' "$OUT" | grep -q "pgid $P4: refused, identity changed or unverified" \
  || fail "recycle guard: identity refusal missing"
printf '%s\n' "$OUT" | grep -q "SIGTERM -> pgid $P4" && fail "recycle guard: group was signaled anyway"
kill -0 "$P4" 2>/dev/null || fail "recycle guard: process was killed despite mismatch"
# Positive control: the original proof must let this same group reach SIGTERM.
OUT="$(AGENT_PROCESS_LEDGER="$T/verified.tsv" bash "$LIB/process-ledger.sh" stop --kill 2>&1)"
[ "$?" -eq 0 ] || fail "recycle guard: matching identity failed"
printf '%s\n' "$OUT" | grep -q "SIGTERM -> pgid $P4" || fail "recycle guard: positive control did not signal"
wait_dead "$P4" || fail "recycle guard: positive control survived"
[ "$FAILS" -eq "$B4" ] && pass "member-identity guard refuses a recycled group and accepts the original proof"

echo
# ---------- K-expect: identity is enforced at the signal boundary ----------
# This must use a command that MATCHES a kill category. An earlier version
# spawned `sleep`, which matches nothing, so audit exited at "nothing to kill"
# before kill_group ever ran -- the group survived for the wrong reason and the
# test asserted nothing. nodemon is in DEV_RE, so the gate is actually reached.
_b=$FAILS
PG_A="$(spawn_group "$T/bin/nodemon")"
SPAWNED_GROUPS="$SPAWNED_GROUPS $PG_A"
if [ -z "$PG_A" ]; then
  fail "K-expect: could not spawn a dev-category group"
else
  FP_A="$(fp_for_pgid "$PG_A")"
  [ -n "$FP_A" ] || fail "K-expect: could not fingerprint a live group"

  # Wrong fingerprint: the group matches dev, so kill_group IS reached, and
  # only the identity gate can save it.
  OUT="$(AFTERPARTY_STYLE=never bash "$LIB/audit-processes.sh" --kill dev \
    --pgid "$PG_A" --expect "$PG_A:ffffffffffff" 2>&1)"
  if kill -0 -"$PG_A" 2>/dev/null; then
    pass "K-expect: a mismatched fingerprint prevented the signal"
  else
    fail "K-expect: group was killed despite a mismatched fingerprint"
  fi
  printf '%s\n' "$OUT" | grep -q 'identity changed' \
    || fail "K-expect: identity gate never ran (audit said: $(printf '%s' "$OUT" | tr '\n' '|'))"

  # Matching fingerprint on a second, equivalent group: proves the gate is what
  # spared the first one, and not merely that nothing was killable.
  PG_B="$(spawn_group "$T/bin/nodemon")"
  SPAWNED_GROUPS="$SPAWNED_GROUPS $PG_B"
  FP_B="$(fp_for_pgid "$PG_B")"
  AFTERPARTY_STYLE=never bash "$LIB/audit-processes.sh" --kill dev \
    --pgid "$PG_B" --expect "$PG_B:$FP_B" >/dev/null 2>&1
  sleep 1
  if kill -0 -"$PG_B" 2>/dev/null; then
    fail "K-expect: a matching fingerprint failed to kill a dev group"
  else
    pass "K-expect: a matching fingerprint let the kill through"
  fi
fi
[ "$FAILS" -eq "$_b" ] && pass "K-expect: identity decides, not category alone"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
