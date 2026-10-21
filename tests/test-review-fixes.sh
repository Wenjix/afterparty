#!/usr/bin/env bash
# Targeted tests for the 0.3.1 review fixes: C6 (TSV padding), C3 (report
# plain-forced), C4 (optimize card), C1 (codex age gate).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tests/devclean-fixtures.sh"
LIB="$REPO/skills/afterparty/lib"
BIN="$REPO/bin/afterparty"
PY="$(command -v python3 || command -v python)"
ESC=$'\033'
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
trap 'cd /; rm -rf "$T"' EXIT
cd "$REPO" || exit 1

# ---------- C6: empty pgid/port/purpose fields must not shift columns ----------
FAKE="$T/ledger.tsv"
printf '2026-07-14T00:00:00Z\t%s\t%s\t999999\t\tdev\t\t\tpnpm dev\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" > "$FAKE"
OUT="$(AGENT_PROCESS_LEDGER="$FAKE" bash "$LIB/process-ledger.sh" list 2>/dev/null)"
printf '%s\n' "$OUT" | grep -Eq '^unknown[[:space:]]+999999[[:space:]]+\?[[:space:]]+dev ' || fail "C6: list columns shifted: $(printf '%s' "$OUT" | tail -1)"
printf '%s\n' "$OUT" | grep -q 'pnpm dev' || fail "C6: command column lost"
J="$(AGENT_PROCESS_LEDGER="$FAKE" bash "$LIB/process-ledger.sh" list --json 2>/dev/null)"
printf '%s\n' "$J" | "$PY" -c '
import json, sys
r = json.loads(sys.stdin.readline())
assert r["pgid"] is None, "pgid should be null, got %r" % r["pgid"]
assert r["port"] is None, "port should be null, got %r" % r["port"]
assert r["purpose"] == "", "purpose should be empty, got %r" % r["purpose"]
assert r["command"] == "pnpm dev", "command shifted: %r" % r["command"]
assert r["kind"] == "dev", "kind shifted: %r" % r["kind"]
' || fail "C6: json row fields wrong"
SOUT="$(AGENT_PROCESS_LEDGER="$FAKE" bash "$LIB/process-ledger.sh" stop 2>&1)"; SRC=$?
[ "$SRC" -ne 0 ] && printf '%s\n' "$SOUT" | grep -q 'identity unavailable' \
  || fail "C6: missing group identity was not explicitly withheld: $SOUT"
POUT="$(AGENT_PROCESS_LEDGER="$FAKE" bash "$LIB/process-ledger.sh" prune 2>/dev/null)"
printf '%s\n' "$POUT" | grep -q 'kept pid 999999 pgid unknown: inspection unavailable' || fail "C6: prune miscounted: $POUT"
[ -s "$FAKE" ] || fail 'C6: prune discarded an entry without group identity'
pass "C6: empty TSV fields parse without shifting (list/json/stop/prune)"

# ---------- C3: --report stays plain even under AFTERPARTY_STYLE=always ----------
rm -f "$REPO/report.md"
AFTERPARTY_STYLE=always "$BIN" audit --report > "$T/r.out" 2>/dev/null; RC=$?
[ "$RC" -eq 0 ] || { [ "$RC" -eq 1 ] && grep -q 'Status: incomplete' "$REPO/report.md"; } || fail "C3: audit --report exit=$RC without persisted incomplete status"
[ -f "$REPO/report.md" ] || fail "C3: report.md not written"
grep -q "$ESC" "$REPO/report.md" && fail "C3: ANSI leaked into report.md"
grep -q '^## Worktrees$' "$REPO/report.md" || fail "C3: H2 rewrite defeated"
grep -q '^# afterparty report — what the last session left behind$' "$REPO/report.md" || fail "C3: H1 wrong"
grep -q "$ESC" "$T/r.out" && fail "C3: ANSI leaked into report-mode stdout"
rm -f "$REPO/report.md"
pass "C3: report.md forced plain under AFTERPARTY_STYLE=always"

# ---------- C4: optimize work shows in damage + receipt cards ----------
H="$T/opt-home"
mkdir -p "$H/.vscode"
printf '{\n  "enable-crash-reporter": true\n}\n' > "$H/.vscode/argv.json"
# Two devclean surfaces ignore HOME and address the real machine, so every
# --apply below must be shimmed away from them -- the same discipline
# test-hardening.sh already applies to its own --apply cases:
#
#   pgrep    run_safe_orphans runs on EVERY devclean invocation, and in apply
#            mode cleanup_pattern SIGTERMs/SIGKILLs what it finds. ORPHAN_PATTERNS
#            includes '(^| )claude( |$)' and 'codex.*--dangerously', so an
#            unshimmed apply kills the developer's own orphaned agent processes.
#            It is also why this block was flaky: whichever processes another
#            suite left orphaned decided whether the second apply was spotless.
#   launchctl  the background-agent step addresses the real login session via
#            gui/<uid>/<label>, disabling actual ChatGPT/Figma agents.
#
# Both report "nothing found"; no case here asserts on either branch, so this
# only removes the side effect. (Leaves both populated branches uncovered --
# they need their own shimmed cases.)
SHIM="$T/opt-shim"
mkdir -p "$SHIM"
# pnpm resolves its store from the OS passwd entry, NOT $HOME or XDG vars, so
# the fixture isolation every other binary here relies on does not apply to it.
# Without this shim `bash tests/run.sh` runs `pnpm store prune` against the
# developer's real shared store. Third HOME-immune surface after pgrep and
# launchctl.
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/pnpm"
chmod +x "$SHIM/pnpm"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/launchctl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/pgrep"
chmod +x "$SHIM/launchctl" "$SHIM/pgrep"
OUT="$(PATH="$SHIM:$PATH" HOME="$H" AFTERPARTY_STYLE=always bash "$LIB/devclean.sh" --optimize 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q 'would disable crash reporter in vscode' || fail "C4: dry optimize missed argv"
printf '%s\n' "$OUT" | grep -q '1 additional cleanup target found' || fail "C4: damage card missing optimize line"
OUT="$(PATH="$SHIM:$PATH" HOME="$H" AFTERPARTY_STYLE=always reviewed_devclean "$LIB/devclean.sh" --optimize 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q 'disabled crash reporter in vscode' || fail "C4: apply did not act"
printf '%s\n' "$OUT" | grep -q 'Completed 1 additional cleanup action' || fail "C4: receipt missing optimize line"
grep -q '"enable-crash-reporter": false' "$H/.vscode/argv.json" || fail "C4: argv.json not patched"
OUT="$(PATH="$SHIM:$PATH" HOME="$H" AFTERPARTY_STYLE=always bash "$LIB/devclean.sh" --optimize 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q '(none enabled)' || fail "C4: second apply should be spotless"
pass "C4: optimize counted in damage and receipt cards"

# ---------- C1: codex sessions age gate ----------
H2="$T/codex-home"
OLD_DAY="$(date -d '45 days ago' +%Y/%m/%d 2>/dev/null || date -v -45d +%Y/%m/%d)"
NEW_DAY="$(date -d '3 days ago' +%Y/%m/%d 2>/dev/null || date -v -3d +%Y/%m/%d)"
mkdir -p "$H2/.codex/sessions/$OLD_DAY" "$H2/.codex/sessions/$NEW_DAY"
dd if=/dev/zero of="$H2/.codex/sessions/$OLD_DAY/rollout-old.jsonl" bs=1024 count=2048 2>/dev/null
dd if=/dev/zero of="$H2/.codex/sessions/$NEW_DAY/rollout-new.jsonl" bs=1024 count=2048 2>/dev/null
touch -t 202001010000 "$H2/.codex/sessions/$OLD_DAY/rollout-old.jsonl"
OUT="$(PATH="$SHIM:$PATH" HOME="$H2" bash "$LIB/devclean.sh" --history --no-repo-artifacts 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q "would clean Codex sessions (>30d since activity): .*$OLD_DAY" || fail "C1: old date dir not flagged"
printf '%s\n' "$OUT" | grep -q "$NEW_DAY" && fail "C1: recent date dir wrongly flagged"
PATH="$SHIM:$PATH" HOME="$H2" reviewed_devclean "$LIB/devclean.sh" --history --no-repo-artifacts >/dev/null 2>&1
[ ! -d "$H2/.codex/sessions/$OLD_DAY" ] || fail "C1: old dir survived apply"
[ -d "$H2/.codex/sessions/$NEW_DAY" ] || fail "C1: recent dir was deleted!"
pass "C1: codex sessions age-gated at 30 days"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
