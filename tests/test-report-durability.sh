#!/usr/bin/env bash
# The report must survive a failing child audit.
#
# agent-hygiene runs under `set -euo pipefail`, and the report is rendered by a
# pipeline: ( run_audit ) | sed > tmp. If any child exits non-zero, pipefail
# makes the pipeline non-zero and set -e killed the script AT THAT LINE — the
# fully rendered report was deleted by the EXIT trap and the previous one was
# left in place. A partial report is worth strictly more than a stale one, and
# the failure belongs in the exit status, not in a missing file.
#
# The children all DEGRADE rather than fail on the read-only report path, so no
# ordinary input triggers this. It is exercised here by running against a copy
# of lib/ whose audit-git.sh exits non-zero — a real child failure, not a
# simulated one.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

cp -R "$REPO/skills/afterparty/lib" "$T/lib"
printf '#!/usr/bin/env bash\necho "=== Fake git section ==="\nexit 1\n' > "$T/lib/audit-git.sh"
chmod +x "$T/lib/audit-git.sh"
mkdir -p "$T/w"
cd "$T/w" || exit 1

_b=$FAILS
HOME="$T/h" XDG_CACHE_HOME="$T/c" bash "$T/lib/agent-hygiene.sh" audit --report >"$T/out" 2>"$T/err"
RC=$?
FOUND="$(find "$T/c" -name report.md 2>/dev/null | head -1)"

[ -n "$FOUND" ] || fail "R1: a failing child destroyed the rendered report"
[ "$RC" -ne 0 ] || fail "R1: a failing child was not surfaced in the exit status (got $RC)"
if [ -n "$FOUND" ]; then
  grep -q 'afterparty report' "$FOUND" || fail "R1: the surviving report has no header — it is not a real report"
  # the section from the FAILING child must still be present: the report is
  # partial-but-written, not truncated at the first problem
  grep -q 'Fake git section' "$FOUND" \
    || fail "R1: the failing child's output was dropped from the report"
fi
grep -qi 'problem' "$T/err" || fail "R1: nothing on stderr explained why the exit status is non-zero"
[ "$FAILS" -eq "$_b" ] && pass "R1: a failing child yields a written report AND a non-zero exit"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
