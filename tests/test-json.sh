#!/usr/bin/env bash
# Tests for --json (JSON Lines) output and audit --report routing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
BIN="$REPO/bin/afterparty"
PY="$(command -v python3 || command -v python)"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

# ---------- shared escaper: whitespace flattening + control stripping ----------
. "$LIB/json.sh"
CONTROL_VALUE=$'a\tb\nc\001d"e\\f'
ESCAPED_ROW="$(json_row "$(json_kv value "$CONTROL_VALUE")")"
printf '%s\n' "$ESCAPED_ROW" | "$PY" -c '
import json, sys
r = json.loads(sys.stdin.readline())
assert r["schema_version"] == 1
assert r["value"] == "a b cd\"e\\f", repr(r["value"])
' || fail "shared JSON escaping changed control-character semantics"
pass "shared JSON escaper preserves valid single-line JSON"

PYCHECK='
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
assert all("section" in r for r in rows), "row without section"
print(len(rows))
'

# ---------- audit-processes --json ----------
bash "$LIB/audit-processes.sh" --json >"$T/p.jsonl" 2>"$T/p.err"; RC=$?
[ "$RC" -eq 0 ] || fail "audit-processes --json exit=$RC"
"$PY" -c "$PYCHECK" <"$T/p.jsonl" >/dev/null || fail "audit-processes --json invalid"
bash "$LIB/audit-processes.sh" --json --kill tests >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "--json --kill should exit 2 (got $RC)"
H="$(bash "$LIB/audit-processes.sh" --help)"
echo "$H" | grep -q -- '--json' || fail "audit-processes help missing --json"
echo "$H" | grep -q 'set -uo' && fail "audit-processes help overshoots into code"
pass "audit-processes --json + guardrails"

# ---------- ledger list --json (fake ledger with hostile chars) ----------
FAKE="$T/ledger.tsv"
printf '2026-07-14T00:00:00Z\t%s\t%s\t999999\t999999\tdev\t3000\tsay "hi" \\ done\tpnpm dev\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" > "$FAKE"
OUT="$(cd "$REPO" && AGENT_PROCESS_LEDGER="$FAKE" bash "$LIB/process-ledger.sh" list --json)"
N="$(printf '%s\n' "$OUT" | "$PY" -c "$PYCHECK")" || fail "ledger --json invalid"
[ "$N" = "1" ] || fail "ledger --json expected 1 row, got $N"
printf '%s\n' "$OUT" | "$PY" -c '
import json, sys
r = json.loads(sys.stdin.readline())
assert r["section"] == "ledger" and r["status"] == "dead", r
assert r["cpu"] is None, "dead row cpu should be null"
assert chr(34) in r["purpose"] and chr(92) in r["purpose"], "purpose escaping broken: " + r["purpose"]
' || fail "ledger row content wrong"
pass "ledger list --json escapes and nulls correctly"

# ---------- composite audit --json ----------
OUT="$(cd "$REPO" && AGENT_PROCESS_LEDGER="$FAKE" "$BIN" audit --json 2>/dev/null)"
N="$(printf '%s\n' "$OUT" | "$PY" -c "$PYCHECK")" || fail "composite audit --json invalid"
printf '%s\n' "$OUT" | "$PY" -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
secs = {r["section"] for r in rows}
assert "ledger" in secs, "ledger rows missing from composite"
assert "git.worktree" in secs, "git rows missing from composite"
' || fail "composite sections incomplete"
pass "composite audit --json composes ledger+git rows ($N rows)"

# ---------- audit --report exclusivity ----------
(cd "$REPO" && "$BIN" audit --report --json) >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "audit --report --json should exit 2 (got $RC)"
pass "--report/--json mutually exclusive"

# ---------- audit --report in an opted-in repo (report.md gitignored) ----------
rm -f "$REPO/report.md"
(cd "$REPO" && AGENT_PROCESS_LEDGER="$FAKE" "$BIN" audit --report) >"$T/r.out" 2>"$T/r.err"; RC=$?
[ "$RC" -eq 0 ] || fail "audit --report exit=$RC"
[ -f "$REPO/report.md" ] || fail "report.md not written at opted-in repo root"
grep -q '^# afterparty report — what the last session left behind$' "$REPO/report.md" || fail "report header missing"
grep -q '^## Worktrees$' "$REPO/report.md" || fail "git section missing from report"
grep -q 'Ledger:' "$REPO/report.md" || fail "ledger section missing from report"
grep -q "note: writing audit report to .*report.md" "$T/r.err" || fail "stderr note missing"
git -C "$REPO" status --porcelain | grep -q 'report.md' && fail "report.md shows up in git status"
grep -q '^## Worktrees$' "$T/r.out" || fail "report mode suppressed stdout"
rm -f "$REPO/report.md"
pass "audit --report writes gitignored repo-root report.md"

# ---------- audit --report in a NON-opted-in repo -> ledger home ----------
mkdir -p "$T/plain" && cd "$T/plain" && git init -q
FALLBACK_REPORT="$(XDG_CACHE_HOME="$T/cache" "$BIN" report-path)"
XDG_CACHE_HOME="$T/cache" AGENT_PROCESS_LEDGER="$FAKE" "$BIN" audit --report >/dev/null 2>"$T/r2.err"; RC=$?
[ "$RC" -eq 0 ] || fail "audit --report (plain repo) exit=$RC"
[ -f "$FALLBACK_REPORT" ] || fail "fallback report.md not written to repo-scoped cache"
[ -f "$T/plain/report.md" ] && fail "litter: report.md written into non-opted-in repo"
pass "litter guard: non-opted-in repo falls back to ledger home"

# ---------- audit --report outside any repo ----------
cd "$T"
NO_REPO_REPORT="$(XDG_CACHE_HOME="$T/cache2" "$BIN" report-path)"
XDG_CACHE_HOME="$T/cache2" "$BIN" audit --report >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "audit --report (no repo) exit=$RC"
[ -f "$NO_REPO_REPORT" ] || fail "no-repo report not written to workspace-scoped cache"
pass "audit --report outside a repo still lands in ledger home"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
