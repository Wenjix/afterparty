#!/usr/bin/env bash
# Identity/lifecycle regressions; every signal is intercepted before testing.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never
export AP_CASE=normal AP_FIXTURE="$T" AP_COMMAND='npm run dev'
mkdir -p "$HOME" "$T/shim"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
kill() {
  local IFS=' '
  printf '%s\n' "$*" >> "$AP_FIXTURE/signals"
  case "${1:-}" in -TERM) touch "$AP_FIXTURE/term" ;; -KILL) touch "$AP_FIXTURE/killed" ;; esac
  return 0
}
export -f kill
bash -c 'kill -TERM -424242'
grep -q -- '-TERM -424242' "$T/signals" || exit 99
cat > "$T/shim/ps" <<'PS'
#!/usr/bin/env bash
start='Sun Sep 6 10:00:00 2026'
[ "$AP_CASE" = recycled ] && start='Sun Sep 6 11:00:00 2026'
members() {
  printf '99999 99999 Sun Sep 6 09:00:00 2026 bash\n'
  [ -f "$AP_FIXTURE/killed" ] && return
  if { [ "$AP_CASE" = replacement ] && [ -f "$AP_FIXTURE/term" ]; } || [ -f "$AP_FIXTURE/capture-replaced" ]; then
    printf '77900 77800 Sun Sep 6 11:00:00 2026 node replacement.js\n'; return
  fi
  if [ ! -f "$AP_FIXTURE/term" ] && [ ! -f "$AP_FIXTURE/leader-dead" ]; then
    printf '77800 77800 %s %s\n' "$start" "$AP_COMMAND"
  fi
  printf '77801 77800 %s node worker.js\n' "$start"
}
case "$*" in
  *pid=,pgid=,lstart=,command=*) [ "$AP_CASE" = unavailable ] && exit 2; [ "$AP_CASE" = capture-replacement ] && touch "$AP_FIXTURE/capture-replaced"; members ;;
  *pgid=,lstart=,command=*) [ "$AP_CASE" = no-fingerprint ] && exit 2; members | cut -d' ' -f2- ;;
  *pid,ppid,pgid,%cpu,etime,command*) printf '77800 1 77800 0.0 00:00:20 %s\n' "$AP_COMMAND" ;;
  *-Ao\ pgid=,command=*) members | awk '{printf "%s ",$2;for(i=8;i<=NF;i++)printf "%s ",$i;print ""}' ;;
  *-Ao\ pgid=*) members | awk '{print $2}' ;;
  *-o\ pgid=*-p\ 77800*) printf '77800\n' ;;
  *-o\ command=*-p\ 77800*) printf '%s\n' "$AP_COMMAND" ;;
  *-o\ pgid=*-p*) printf '99999\n' ;;
  *-p\ 77800*) [ -f "$AP_FIXTURE/leader-dead" ] && exit 1; [ "$AP_CASE" = unavailable ] && exit 2; exit 0 ;;
  *) exit 1 ;;
esac
PS
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/shim/sleep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/shim/lsof"
chmod +x "$T/shim/"*
export PATH="$T/shim:$PATH" AGENT_PROCESS_LEDGER="$T/ledger.tsv"
reset_world() { rm -f "$T/term" "$T/killed" "$T/leader-dead" "$T/ledger.tsv" "$T/capture-replaced"; : > "$T/signals"; export AP_CASE=normal AP_COMMAND='npm run dev'; }
record() { bash "$LIB/process-ledger.sh" add --pid 77800 --kind dev --port 3000 >/dev/null || fail 'record failed'; }
stop_now() { bash "$LIB/process-ledger.sh" stop --kill --all 2>&1; }
audit_now() { bash "$LIB/audit-processes.sh" --kill dev --pgid 77800 2>&1; }

reset_world; record; AP_CASE=recycled
# The original group is completely replaced, including its worker.
AP_CASE=recycled OUT="$(stop_now)"; RC=$?
[ ! -s "$T/signals" ] || fail 'PS1: recycled ledger process was signalled'
printf '%s\n' "$OUT" | grep -Eq 'identity|unverified' || fail "PS1: no identity refusal: $OUT"

reset_world; record; touch "$T/leader-dead"
OUT="$(stop_now)"; RC=$?
grep -q -- '-TERM -77800' "$T/signals" || fail "PS2: living worker was ignored after launcher exit: $OUT"
[ "$RC" -eq 0 ] || fail "PS2: original surviving worker was not stopped: $OUT"

reset_world; record; AP_CASE=unavailable
OUT="$(bash "$LIB/process-ledger.sh" prune --all 2>&1)"; RC=$?
[ -s "$T/ledger.tsv" ] && [ "$RC" -ne 0 ] || fail "PS3: failed inspection pruned ownership or returned success: $OUT"

reset_world; AP_CASE=no-fingerprint
OUT="$(audit_now)"; RC=$?
[ ! -s "$T/signals" ] && [ "$RC" -ne 0 ] || fail "PS4: missing fingerprint permitted signalling: $OUT"

reset_world
OUT="$(audit_now)"; RC=$?
grep -q -- '-KILL -77800' "$T/signals" || fail "PS5: launcher exit prevented original-worker escalation: $OUT"
[ "$RC" -eq 0 ] || fail "PS5: original group cleanup failed: $OUT"

reset_world; AP_CASE=replacement
OUT="$(audit_now)"
grep -q -- '-TERM -77800' "$T/signals" || fail 'PS6: fixture never reached TERM'
grep -q -- '-KILL -77800' "$T/signals" && fail 'PS6: replacement group received KILL'
printf '%s\n' "$OUT" | grep -q 'identity' || fail "PS6: replacement refusal missing: $OUT"

reset_world; AP_COMMAND='git clone https://github.com/encode/uvicorn.git'
OUT="$(audit_now)"
[ ! -s "$T/signals" ] || fail 'PS7: argument text classified git as a dev server'

reset_world; AP_COMMAND='node /Users/u/.codex/worktrees/abc/web/node_modules/.bin/vite'
OUT="$(audit_now)"; RC=$?
grep -q -- '-TERM -77800' "$T/signals" || fail "PS8: Codex workspace path protected a dev server: $OUT"

reset_world
bash "$LIB/process-ledger.sh" add --pid 77800 --port not-a-port >/dev/null 2>&1 && fail 'PS9: invalid port was recorded'
for invalid_port in 0 65536 1e3 -1; do
  bash "$LIB/process-ledger.sh" add --pid 77800 --port "$invalid_port" >/dev/null 2>&1 \
    && fail "PS9: invalid port $invalid_port was recorded"
done

reset_world
bash "$LIB/process-ledger.sh" add --pid 77800 --port 00080 >/dev/null || fail 'PS10: a valid leading-zero port was rejected'
OUT="$(bash "$LIB/process-ledger.sh" list --all --json)"
printf '%s\n' "$OUT" | grep -q '"port":80' || fail "PS10: port was not canonical JSON numeric: $OUT"
OUT="$(bash "$LIB/process-ledger.sh" list --all)"
printf '%s\n' "$OUT" | grep -q 'Scope: all workspaces' || fail 'PS10: list scope is invisible'

# Historical rows stay visible without granting authority to a recycled PID.
cut -f1-9 "$T/ledger.tsv" > "$T/legacy.tsv"; mv "$T/legacy.tsv" "$T/ledger.tsv"
OUT="$(stop_now)"; RC=$?
[ ! -s "$T/signals" ] && [ "$RC" -ne 0 ] || fail "PS11: an unverified legacy row authorized signalling: $OUT"
printf '%s\n' "$OUT" | grep -q unverified || fail 'PS11: legacy refusal is not explained'

reset_world; record; touch "$T/killed"
OUT="$(bash "$LIB/process-ledger.sh" prune --all)"; RC=$?
[ ! -s "$T/ledger.tsv" ] && [ "$RC" -eq 0 ] || fail "PS12: a positively absent group was not pruned: $OUT"

cat > "$T/shim/lsof" <<'LSOF'
#!/usr/bin/env bash
echo 'simulated permission failure' >&2
exit 1
LSOF
OUT="$(bash "$LIB/audit-processes.sh" --json --strict)"; RC=$?
[ "$RC" -ne 0 ] || fail 'PS13: failed listener scan returned strict success'
printf '%s\n' "$OUT" | grep -q '"name":"listeners","status":"unavailable"' \
  || fail "PS13: failed listener scan claims availability: $OUT"
OUT="$(bash "$LIB/audit-processes.sh")"
printf '%s\n' "$OUT" | grep -q 'unavailable: lsof could not complete' || fail 'PS13: human listener failure is invisible'

reset_world; AP_CASE=capture-replacement
OUT="$(audit_now)"; RC=$?
[ -f "$T/capture-replaced" ] || fail 'PS15: fixture never reached member capture'
[ ! -s "$T/signals" ] && [ "$RC" -ne 0 ] || fail "PS15: replacement during member capture was signalled: $OUT"
printf '%s\n' "$OUT" | grep -q identity || fail 'PS15: capture-time replacement refusal missing'

reset_world; record
rm -f "$XDG_CACHE_HOME/agent-processes/actions.jsonl"
mkdir -p "$XDG_CACHE_HOME/agent-processes/actions.jsonl"
OUT="$(stop_now)"; RC=$?
grep -q -- '-TERM -77800' "$T/signals" || fail 'PS14: receipt failure fixture never reached mutation'
[ "$RC" -ne 0 ] || fail "PS14: lost mutation receipt returned success: $OUT"
printf '%s\n' "$OUT" | grep -q 'receipt could not be recorded' || fail 'PS14: lost receipt is not explained'

if [ "$FAILS" -eq 0 ]; then echo 'ALL PASS'; else echo "$FAILS FAILURE(S)"; exit 1; fi
