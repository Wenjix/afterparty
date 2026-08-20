#!/usr/bin/env bash
# The two-signal rule. A workspace is only forgotten when nobody has spoken to
# it for hours AND nothing in it is working. Either signal alone lies: a long
# tool call goes quiet while still working, and a finished agent leaves its dev
# server running long after anyone cared.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

# shellcheck source=/dev/null
. "$LIB/eligible.sh"

NOW=1800000000
H=3600
# defaults: idle after 4h, busy at 20% cpu
FRESH=$((NOW - 600))        # 10m ago
IDLE=$((NOW - 9 * H))       # 9h ago

_b=$FAILS
while IFS='|' read -r touched cpu want why; do
  got="$(elig_verdict "$touched" "$cpu" "$NOW")"
  if [ "$got" = "$want" ]; then
    pass "E1: $why -> $want"
  else
    fail "E1: $why -> '$got', want '$want'"
  fi
done <<CASES
$FRESH|0.0|in-use|touched 10m ago, quiet
$FRESH|95.0|in-use|touched 10m ago, busy
$IDLE|95.0|working|idle 9h but cpu 95 (a long tool call)
$IDLE|21.0|working|idle 9h, cpu just over the busy line
$IDLE|19.9|eligible|idle 9h, cpu just under the busy line
$IDLE|0.0|eligible|idle 9h and quiet
|0.0|unknown|no transcript at all
|95.0|unknown|no transcript, busy
CASES
[ "$FAILS" -eq "$_b" ] && pass "E1: all four verdicts"

# ---------- E2: unknown is never eligible, whatever the cpu ----------
_b=$FAILS
for c in 0.0 0.1 19 20 100; do
  v="$(elig_verdict "" "$c" "$NOW")"
  [ "$v" = "unknown" ] || fail "E2: empty last-touched with cpu $c gave '$v'"
done
[ "$FAILS" -eq "$_b" ] && pass "E2: a workspace with no signal is never offered"

# ---------- E3: thresholds are env-tunable ----------
_b=$FAILS
v="$(AFTERPARTY_IDLE_HOURS=24 elig_verdict "$IDLE" 0.0 "$NOW")"
[ "$v" = "in-use" ] || fail "E3: raising the idle threshold should make 9h in-use, got '$v'"
v="$(AFTERPARTY_BUSY_CPU=99 elig_verdict "$IDLE" 95.0 "$NOW")"
[ "$v" = "eligible" ] || fail "E3: raising the busy line should make cpu 95 eligible, got '$v'"
[ "$FAILS" -eq "$_b" ] && pass "E3: idle and busy thresholds are env-tunable"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
