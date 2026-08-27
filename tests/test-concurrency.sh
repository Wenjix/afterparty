#!/usr/bin/env bash
# The portable lock under real contention. This user runs 16-22 agent sessions
# against ONE machine-wide journal and ledger, so a lock that wedges silences
# every session at once — yet nothing in the suite ever ran two writers.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

# shellcheck source=/dev/null
. "$LIB/state.sh"

# ---------- C1: an orphaned lock is reclaimed, not wedged forever ----------
# The crash window: a run killed between creating the lock and claiming it
# leaves a lock directory with no owner inside. The old reaper globbed for
# owner dirs, found none, and removed nothing — so the lock outlived the
# process forever and every later writer failed silently.
_b=$FAILS
mkdir -p "$T/orphan.lock"
touch -t 202001010000 "$T/orphan.lock" 2>/dev/null || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$T/orphan.lock"
if state_lock_acquire "$T/orphan.lock" 60; then
  state_lock_release "$T/orphan.lock"
else
  fail "C1: an orphaned lock could not be reclaimed — it wedges every writer"
fi
[ "$FAILS" -eq "$_b" ] && pass "C1: a lock orphaned by a crash is reclaimed"

# ---------- C2: a live lock is never stolen ----------
# The counterweight to C1. Reclamation that cannot tell abandoned from held
# would let two processes hold the same lock and interleave their writes.
_b=$FAILS
mkdir -p "$T/live.lock/$$"
if state_lock_acquire "$T/live.lock" 6; then
  fail "C2: acquired a lock that a LIVE process already holds"
  state_lock_release "$T/live.lock"
fi
[ "$FAILS" -eq "$_b" ] && pass "C2: a live lock is refused, not stolen"

# ---------- C3: a lock held past the stale window is reclaimed ----------
# PIDs are recycled, so "the owner number is alive" is not proof this holder
# is. Without an age bound a recycled pid wedged the lock indefinitely.
_b=$FAILS
mkdir -p "$T/old.lock/$$"
touch -t 202001010000 "$T/old.lock/$$" 2>/dev/null || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$T/old.lock/$$"
if AFTERPARTY_LOCK_STALE_SECONDS=1 state_lock_acquire "$T/old.lock" 60; then
  state_lock_release "$T/old.lock"
else
  fail "C3: a lock held far past the stale window was not reclaimed"
fi
[ "$FAILS" -eq "$_b" ] && pass "C3: a lock older than the stale window is reclaimed"

# ---------- C4: concurrent writers do not lose or interleave rows ----------
# Eight writers appending under the lock, as eight sessions ending at once
# would. Every row must survive intact: a lost row is a mutation with no
# receipt, and a torn row is a receipt nobody can parse.
_b=$FAILS
WRITERS=8
PER=25
LEDGER="$T/rows.tsv"; : > "$LEDGER"
LOCK="$T/rows.lock"
for w in $(seq 1 "$WRITERS"); do
  (
    . "$LIB/state.sh"
    i=0
    while [ "$i" -lt "$PER" ]; do
      if state_lock_acquire "$LOCK" 400; then
        printf 'writer-%s\trow-%s\tpadding-to-make-a-torn-write-visible\n' "$w" "$i" >> "$LEDGER"
        state_lock_release "$LOCK"
        i=$((i + 1))
      else
        break
      fi
    done
  ) &
done
wait
EXPECTED=$((WRITERS * PER))
GOT="$(wc -l < "$LEDGER" | tr -d '[:space:]')"
[ "$GOT" -eq "$EXPECTED" ] || fail "C4: $GOT of $EXPECTED rows survived — writers lost rows under contention"
TORN="$(awk -F'\t' 'NF != 3 { n++ } END { print n + 0 }' "$LEDGER")"
[ "$TORN" -eq 0 ] || fail "C4: $TORN torn/interleaved rows"
UNIQ="$(sort -u "$LEDGER" | wc -l | tr -d '[:space:]')"
[ "$UNIQ" -eq "$EXPECTED" ] || fail "C4: $UNIQ unique rows of $EXPECTED — rows were duplicated"
[ "$FAILS" -eq "$_b" ] && pass "C4: $WRITERS concurrent writers wrote $EXPECTED intact rows"

# ---------- C5: an interrupted prune leaves no copy of the ledger ----------
# Each leftover is a full 0600 copy of the machine-wide ledger — every
# workspace path, purpose string and command line of every agent session — and
# nothing in the tool ever sweeps that directory.
#
# The first version of this guard was INERT: the trap existed, was commented,
# and swept nothing, because LEDGER_TMP was assigned inside the mktemp FAILURE
# branch where the variable is empty. A plausible-looking trap that does
# nothing is worse than no trap, so this asserts the sweep rather than the
# presence of a trap.
_b=$FAILS
PT="$T/prune"; mkdir -p "$PT/shim"
printf '#!/usr/bin/env bash\nsleep 0.3\nexit 1\n' > "$PT/shim/ps"; chmod +x "$PT/shim/ps"
PL="$PT/ledger.tsv"
i=1; while [ "$i" -le 30 ]; do
  printf '2026-01-01T00:00:00Z\t/r\t/r\t9%04d\t\tdev\t\t\tsleep\n' "$i" >> "$PL"
  i=$((i + 1))
done
( PATH="$PT/shim:$PATH" AGENT_PROCESS_LEDGER="$PL" bash "$LIB/process-ledger.sh" prune --all >/dev/null 2>&1 ) &
PRUNE_PID=$!
sleep 2
MID="$(find "$PT" -name '.ledger.tsv.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
kill -TERM "$PRUNE_PID" 2>/dev/null
wait "$PRUNE_PID" 2>/dev/null
PRUNE_STATUS=$?
LEFT="$(find "$PT" -name '.ledger.tsv.*' 2>/dev/null | wc -l | tr -d '[:space:]')"

# (i) the temp must have EXISTED mid-flight, or the absence check below is
# vacuous — a prune that never created one also leaves none behind
[ "$MID" -ge 1 ] || fail "C5: no temp existed mid-prune, so the cleanup assertion would prove nothing"
# (ii) the run must have been INTERRUPTED, or a completed prune passes trivially
[ "$PRUNE_STATUS" -eq 143 ] || fail "C5: prune was not interrupted (status $PRUNE_STATUS) — the TERM trap never ran"
# (iii) and nothing may remain
[ "$LEFT" -eq 0 ] || fail "C5: $LEFT ledger copy/copies survived an interrupted prune"
# The lock too: an interrupted prune that keeps it held blocks every other
# session until the stale window expires. Nothing here looked at it before.
[ ! -e "$PL.lock" ] || fail "C5: the ledger lock survived an interrupted prune"
# the real ledger must be intact — cleanup must not have taken the original
[ "$(wc -l < "$PL" | tr -d '[:space:]')" -eq 30 ] || fail "C5: the ledger itself lost rows"
[ "$FAILS" -eq "$_b" ] && pass "C5: an interrupted prune sweeps its temp and leaves the ledger intact"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
