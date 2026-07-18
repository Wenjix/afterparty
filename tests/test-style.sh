#!/usr/bin/env bash
# Style-layer tests: plain mode equivalence (piped auto == AFTERPARTY_STYLE=never),
# styled mode via AFTERPARTY_STYLE=always, JSON immunity, NO_COLOR precedence,
# and card placement.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
BIN="$REPO/bin/afterparty"
PY="$(command -v python3 || command -v python)"
ESC=$'\033'
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$REPO" || exit 1

LEDGER="$T/ledger.tsv"
printf '2026-07-14T00:00:00Z\t%s\t%s\t999999\t999999\tdev\t3000\tverify UI\tpnpm dev\n' \
  "$(git -C "$REPO" rev-parse --show-toplevel)" "$REPO" > "$LEDGER"

# ---------- plain-mode equivalence ----------
# Piped auto output must equal AFTERPARTY_STYLE=never output byte-for-byte.
# Only deterministic commands qualify (process listings embed live cpu/etime).
eq() { # name command...
  local name="$1"; shift
  "$@" > "$T/a-$name" 2>/dev/null
  AFTERPARTY_STYLE=never "$@" > "$T/b-$name" 2>/dev/null
  diff -q "$T/a-$name" "$T/b-$name" >/dev/null || fail "plain drift (auto vs never): $name"
  grep -q "$ESC" "$T/a-$name" && fail "ANSI leaked into piped auto output: $name"
}
eq git bash "$LIB/audit-git.sh"
eq artifacts bash "$LIB/clean-artifacts.sh"
AGENT_PROCESS_LEDGER="$LEDGER" eq list bash "$LIB/process-ledger.sh" list
AGENT_PROCESS_LEDGER="$LEDGER" eq stop bash "$LIB/process-ledger.sh" stop
pass "plain mode: piped auto == never, no ANSI"

# Non-deterministic commands: piped auto must at least be ANSI-free.
for c in "$LIB/audit-processes.sh" "$LIB/devclean.sh"; do
  bash "$c" > "$T/nd.out" 2>/dev/null
  grep -q "$ESC" "$T/nd.out" && fail "ANSI leaked into piped output: $c"
done
pass "plain mode: process listings ANSI-free when piped"

# ---------- A1-A4: styled git run ----------
OUT="$(AFTERPARTY_STYLE=always bash "$LIB/audit-git.sh" 2>/dev/null)"
case "$OUT" in *"$ESC["*) : ;; *) fail "A1: no ANSI in styled output" ;; esac
echo "$OUT" | grep -q 'DRY RUN'             || fail "A2: DRY RUN lost in styled mode"
echo "$OUT" | grep -q 'Summary:'            || fail "A2: Summary: lost in styled mode"
echo "$OUT" | grep -q 'Nothing was changed.' || fail "A2: Nothing was changed. lost"
echo "$OUT" | grep -q '● Worktrees'          || fail "A3: styled header missing"
echo "$OUT" | grep -q '=== Worktrees ==='    && fail "A3: legacy header leaked into styled mode"
echo "$OUT" | grep -q '╭'                    || fail "A4: card frame missing"
echo "$OUT" | grep -Eq 'spotless|the damage' || fail "A4: card verdict missing"
pass "A1-A4: styled git output (ANSI, contracts, glyph header, card)"

# ---------- A5: JSON immune to styling ----------
for c in "bash $LIB/audit-git.sh --json" "bash $LIB/audit-processes.sh --json"; do
  J="$(AFTERPARTY_STYLE=always $c 2>/dev/null)"
  case "$J" in *"$ESC"*) fail "A5: ESC leaked into JSON: $c" ;; esac
  printf '%s\n' "$J" | "$PY" -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' || fail "A5: invalid JSONL: $c"
done
J="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" bash "$LIB/process-ledger.sh" list --json 2>/dev/null)"
case "$J" in *"$ESC"*) fail "A5: ESC leaked into ledger JSON" ;; esac
printf '%s\n' "$J" | "$PY" -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' || fail "A5: invalid ledger JSONL"
pass "A5: --json byte-clean under AFTERPARTY_STYLE=always"

# ---------- A6: NO_COLOR precedence ----------
OUT="$(NO_COLOR=1 AFTERPARTY_STYLE=always bash "$LIB/audit-git.sh" 2>/dev/null)"
case "$OUT" in *"$ESC["*) : ;; *) fail "A6: AFTERPARTY_STYLE=always should beat NO_COLOR" ;; esac
OUT="$(NO_COLOR=1 bash "$LIB/audit-git.sh" 2>/dev/null)"
case "$OUT" in *"$ESC["*) fail "A6: NO_COLOR alone must stay plain" ;; esac
pass "A6: NO_COLOR precedence both directions"

# ---------- A7: composite = exactly one card, banner, no tally litter ----------
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" "$BIN" audit 2>/dev/null)"
N_CARDS="$(printf '%s\n' "$OUT" | grep -c '╭')"
[ "$N_CARDS" = "1" ] || fail "A7: composite should show exactly 1 card, got $N_CARDS"
echo "$OUT" | grep -q 'afterparty — last call' || fail "A7: banner missing"
ls "${TMPDIR:-/tmp}"/afterparty-tally.* >/dev/null 2>&1 && fail "A7: tally tmp files left behind"
pass "A7: composite audit (one card, banner, tally cleaned)"

# ---------- A8: stop styled ----------
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" bash "$LIB/process-ledger.sh" stop 2>/dev/null)"
echo "$OUT" | grep -q 'DRY RUN' || fail "A8: stop styled lost DRY RUN"
echo "$OUT" | grep -q '╭'       || fail "A8: stop card missing"
pass "A8: stop styled banner + card"

# ---------- A9: doctor shows no cards ----------
OUT="$(AFTERPARTY_STYLE=always AGENT_PROCESS_LEDGER="$LEDGER" "$BIN" doctor 2>/dev/null)"
N_CARDS="$(printf '%s\n' "$OUT" | grep -c '╭' || true)"
[ "$N_CARDS" = "0" ] || fail "A9: doctor should show 0 cards, got $N_CARDS"
pass "A9: doctor card-free"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
