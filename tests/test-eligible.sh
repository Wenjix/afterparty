#!/usr/bin/env bash
# Process-plan eligibility combines transcript age and observed CPU. These
# tests verify policy decisions; neither observation proves abandonment.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
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

# ---------- E4: a malformed threshold falls back, it never zeroes ----------
# The value reaches $(( )) directly. "0.5" errors, "08" misparses as octal, and
# a zero idle window makes EVERY live workspace instantly eligible for cleanup
# — a safety threshold silently disabled by a typo. 5h is chosen so the default
# (4h) and a raised value (8h) disagree, giving the assertion discriminating
# power that a 9h fixture would not have.
FIVE=$((NOW - 5 * H))
_b=$FAILS
[ "$(AFTERPARTY_IDLE_HOURS=4 elig_verdict "$FIVE" 0.0 "$NOW" 2>/dev/null)" = "eligible" ] \
  || fail "E4: control — 5h idle under a 4h threshold should be eligible"
[ "$(AFTERPARTY_IDLE_HOURS=8 elig_verdict "$FIVE" 0.0 "$NOW" 2>/dev/null)" = "in-use" ] \
  || fail "E4: control — 5h idle under an 8h threshold should be in-use"
# "08" is not malformed — it is 8 hours written with a leading zero, and base-10
# forcing must read it that way rather than erroring on invalid octal.
[ "$(AFTERPARTY_IDLE_HOURS=08 elig_verdict "$FIVE" 0.0 "$NOW" 2>/dev/null)" = "in-use" ] \
  || fail "E4: '08' should read as 8 hours, not error or fall back"
[ "$(AFTERPARTY_IDLE_HOURS=008 elig_verdict "$FIVE" 0.0 "$NOW" 2>/dev/null)" = "in-use" ] \
  || fail "E4: '008' should read as 8 hours (octal would error here)"
for bad in 0.5 abc -1 ''; do
  got="$(AFTERPARTY_IDLE_HOURS="$bad" elig_verdict "$FIVE" 0.0 "$NOW" 2>/dev/null)"
  [ "$got" = "eligible" ] \
    || fail "E4: threshold '$bad' gave '$got'; should fall back to the 4h default"
  # and it must not have zeroed the window: a 1-minute-idle workspace stays in use
  got2="$(AFTERPARTY_IDLE_HOURS="$bad" elig_verdict "$((NOW - 60))" 0.0 "$NOW" 2>/dev/null)"
  [ "$got2" = "in-use" ] \
    || fail "E4: threshold '$bad' zeroed the idle window — a 1-minute-old workspace read as '$got2'"
done
[ "$FAILS" -eq "$_b" ] && pass "E4: a malformed idle threshold falls back to the default, never to zero"

# Startup overrides must be present BEFORE the library is sourced. Setting an
# override only on an already-loaded function cannot catch a poisoned default.
startup_verdict() {
  env AFTERPARTY_IDLE_HOURS="$1" AFTERPARTY_BUSY_CPU="$2" \
    bash -c '. "$1"; elig_verdict "$2" "$3" "$4"' _ \
    "$LIB/eligible.sh" "$3" "$4" "$NOW"
}

# ---------- E5: invalid startup idle thresholds restore the 4h window ----------
_b=$FAILS
for bad in 0 000 invalid 0.5 -1; do
  got="$(startup_verdict "$bad" 20 "$FRESH" 0 2> "$T/idle.err")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = in-use ] \
    || fail "E5: startup idle '$bad' gave '$got' (exit $rc) for a fresh workspace"
  grep -Fq "AFTERPARTY_IDLE_HOURS='$bad'" "$T/idle.err" && grep -Fq 'using 4' "$T/idle.err" \
    || fail "E5: startup idle '$bad' did not explain its default fallback"
  got="$(startup_verdict "$bad" 20 "$FIVE" 0 2> "$T/idle.err")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = eligible ] \
    || fail "E5: startup idle '$bad' did not restore the 4h window for a 5h-old workspace"
done
got="$(startup_verdict 08 20 "$FIVE" 0 2> "$T/idle.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = in-use ] && [ ! -s "$T/idle.err" ] \
  || fail "E5: valid startup idle '08' did not retain its 8h window quietly"
[ "$FAILS" -eq "$_b" ] && pass "E5: startup idle overrides validate before changing eligibility"

# ---------- E6: invalid startup CPU thresholds restore the 20% boundary ----------
_b=$FAILS
for bad in invalid 1.2.3 . -1 NaN; do
  got="$(startup_verdict 4 "$bad" "$FIVE" 19.9 2> "$T/busy.err")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = eligible ] \
    || fail "E6: startup CPU '$bad' gave '$got' (exit $rc) below the default boundary"
  grep -Fq "AFTERPARTY_BUSY_CPU='$bad'" "$T/busy.err" && grep -Fq 'using 20' "$T/busy.err" \
    || fail "E6: startup CPU '$bad' did not explain its default fallback"
  got="$(startup_verdict 4 "$bad" "$FIVE" 21 2> "$T/busy.err")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = working ] \
    || fail "E6: startup CPU '$bad' did not withhold above the default boundary"
done
got="$(startup_verdict 4 20.5 "$FIVE" 20.4 2> "$T/busy.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = eligible ] && [ ! -s "$T/busy.err" ] \
  || fail "E6: valid fractional startup CPU threshold was not retained quietly"
got="$(startup_verdict 4 20.5 "$FIVE" 20.6 2> "$T/busy.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = working ] \
  || fail "E6: valid fractional startup CPU threshold did not withhold above its boundary"
[ "$FAILS" -eq "$_b" ] && pass "E6: startup CPU overrides validate before changing eligibility"

# ---------- E7: an oversized idle interval must never wrap to a short one ----------
_b=$FAILS
for huge in 5124095576030432 2562047788015216 18446744073709551620; do
  got="$(startup_verdict "$huge" 20 "$((NOW - 2 * H))" 0 2> "$T/overflow.err")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = unknown ] \
    || fail "E7: overflowing idle '$huge' gave '$got' (exit $rc) instead of withholding"
  grep -Fq "AFTERPARTY_IDLE_HOURS='$huge'" "$T/overflow.err" && grep -Fq 'cleanup is withheld' "$T/overflow.err" \
    || fail "E7: overflowing idle '$huge' did not explain the refusal"
done
for valid in 2562047788015215 00000000000000000000000008; do
  got="$(startup_verdict "$valid" 20 "$FIVE" 0 2> "$T/overflow.err")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = in-use ] && [ ! -s "$T/overflow.err" ] \
    || fail "E7: representable decimal idle '$valid' was not accepted quietly"
done
[ "$FAILS" -eq "$_b" ] && pass "E7: large idle thresholds never shorten the cleanup interval"

# ---------- E8: CPU evidence must be present, numeric and finite ----------
_b=$FAILS
for bad in '' unavailable -1 NaN inf 1e309 . 1.2.3 "$(printf '%0400d' 1 | tr 0 9)"; do
  got="$(elig_verdict "$IDLE" "$bad" "$NOW")"
  [ "$got" = unknown ] \
    || fail "E8: unavailable CPU '$bad' gave '$got' instead of withholding"
done
[ "$(elig_verdict "$IDLE")" = unknown ] || fail "E8: omitted CPU must never default to zero activity"
for valid in 0 .5 19.9 20.; do
  [ "$(elig_verdict "$IDLE" "$valid" "$NOW")" = eligible ] \
    || fail "E8: valid idle CPU '$valid' should remain eligible"
done
[ "$FAILS" -eq "$_b" ] && pass "E8: unavailable CPU evidence never becomes idle activity"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
