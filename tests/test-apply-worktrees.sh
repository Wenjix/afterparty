#!/usr/bin/env bash
# apply executing an approved worktree removal.
#
# The contract that matters: approval is necessary, not sufficient. A ticked
# box gets the item CONSIDERED; the vetoes still run at apply time, against the
# world as it is then, and a failing one refuses the item no matter who
# approved it. Every case here ticks the box deliberately and asserts the
# refusal anyway.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

export XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" HOME="$T/home"
mkdir -p "$HOME"

W="$T/proj"
git init -qb main "$W"
git -C "$W" config user.email t@t.local
git -C "$W" config user.name tester
git -C "$W" commit -q --allow-empty -m one

mkwt() { git -C "$W" worktree add -q "$T/$1" -b "agent/$1" HEAD; }
for n in gozip stayput dirtied swapped; do mkwt "$n"; done

# shellcheck source=/dev/null
. "$LIB/fingerprint.sh"

# A plan naming one item, ticked. Written by hand so each case controls exactly
# what apply is asked to do.
plan_for() { # plan_for <path> <fingerprint> [checked]
  local path="$1" fp="$2" box="${3:-x}"
  printf '# afterparty plan — test\n\n## Worktrees\n\n'
  printf -- '- [%s] eligible  path %s  agent/x · idle 300d\n' "$box" "$path"
  printf -- '      type: worktree  fingerprint: %s  path: %s\n' "$fp" "$path"
  printf '\n## Why\n> restoring disk after a long agent run\n'
}

run_apply() { AFTERPARTY_STYLE=never bash "$LIB/apply.sh" "$1" 2>&1; }

# ---------- AW1: an approved, clean, unoccupied worktree is removed ----------
_b=$FAILS
plan_for "$T/gozip" "$(fp_for_worktree "$T/gozip")" > "$T/p1.md"
OUT="$(cd "$W" && run_apply "$T/p1.md")"; RC=$?
[ "$RC" -eq 0 ] || fail "AW1: exit=$RC on a clean removal: $OUT"
[ ! -e "$T/gozip" ] || fail "AW1: the approved worktree still exists"
printf '%s\n' "$OUT" | grep -q '1 applied' || fail "AW1: receipt does not count it: $OUT"
git -C "$W" worktree list --porcelain | grep -q "$T/gozip" \
  && fail "AW1: git still lists the worktree — admin data was not pruned"
[ "$FAILS" -eq "$_b" ] && pass "AW1: an approved clean worktree is removed and deregistered"

# ---------- AW2: an UNCHECKED item is never acted on ----------
_b=$FAILS
plan_for "$T/stayput" "$(fp_for_worktree "$T/stayput")" ' ' > "$T/p2.md"
OUT="$(cd "$W" && run_apply "$T/p2.md")"
[ -d "$T/stayput" ] || fail "AW2: an unchecked worktree was removed"
printf '%s\n' "$OUT" | grep -q '0 applied' \
  || fail "AW2: receipt claims work on an unchecked plan: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "AW2: an unchecked worktree is left alone"

# ---------- AW3: a tick does NOT override the dirty veto ----------
# Order matters here, and the first version of this case had it wrong. Dirtying
# a worktree also MOVES its fingerprint, because cleanliness is part of
# worktree identity -- so a plan fingerprinted while clean is refused for drift
# and the veto never runs. That is correct behaviour and good defence, but it
# means the case proved nothing about the veto.
#
# The veto's real job is the plan that is internally consistent and still
# wrong: a hand-written or hand-edited one that ticks a worktree which is
# dirty RIGHT NOW. Fingerprinting after dirtying constructs exactly that, and
# then the veto is the only thing between the tick and `git worktree remove`.
_b=$FAILS
printf 'work in progress\n' > "$T/dirtied/notes.md"
plan_for "$T/dirtied" "$(fp_for_worktree "$T/dirtied")" > "$T/p3.md"
OUT="$(cd "$W" && run_apply "$T/p3.md")"; RC=$?
[ -d "$T/dirtied" ] || fail "AW3: a dirty worktree was removed despite the veto"
[ -f "$T/dirtied/notes.md" ] || fail "AW3: the uncommitted file is gone"
printf '%s\n' "$OUT" | grep -q 'dirty' \
  || fail "AW3: the refusal does not name the veto: $OUT"
printf '%s\n' "$OUT" | grep -q "$T/dirtied" \
  || fail "AW3: the refusal does not name the target"
[ "$RC" -ne 0 ] || fail "AW3: exit 0 after refusing approved work — a caller cannot tell"
[ "$FAILS" -eq "$_b" ] && pass "AW3: a ticked box does not override the dirty veto"

# ---------- AW4: a fingerprint that moved refuses the item ----------
_b=$FAILS
plan_for "$T/swapped" "$(fp_for_worktree "$T/swapped")" > "$T/p4.md"
git -C "$T/swapped" commit -q --allow-empty -m "someone kept working"
OUT="$(cd "$W" && run_apply "$T/p4.md")"
[ -d "$T/swapped" ] || fail "AW4: a worktree whose fingerprint moved was removed"
printf '%s\n' "$OUT" | grep -qi 'fingerprint' \
  || fail "AW4: the refusal does not mention the fingerprint: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "AW4: a worktree that changed since planning is refused"

# ---------- AW5: the plan's Why reaches the journal ----------
_b=$FAILS
JOURNAL="$(find "$T/state" "$T/cache" "$HOME" -type f -name '*.jsonl' 2>/dev/null | head -1)"
if [ -n "$JOURNAL" ]; then
  grep -q 'restoring disk after a long agent run' "$JOURNAL" \
    || fail "AW5: the stated reason never reached the journal at $JOURNAL"
  # The OPERATION field, not the word. The first version grepped for
  # 'worktree' against a journal that also holds the free-text reason -- and
  # the reason said "restoring disk after a long agent run", so the assertion was
  # satisfied by the person's own prose and passed with the receipt deleted.
  grep -q '"operation":"worktree.remove"' "$JOURNAL" \
    || fail "AW5: no worktree.remove receipt was journaled: $(tr '\n' '|' < "$JOURNAL" | cut -c1-300)"
  grep -q '"operation":"worktree.remove","target":"[^"]*gozip"' "$JOURNAL" \
    || fail "AW5: the receipt does not name the worktree that was removed"
else
  fail "AW5: no journal was written at all"
fi
[ "$FAILS" -eq "$_b" ] && pass "AW5: the reason and the outcome are both recorded"

# ---------- AW6: apply never removes the worktree it is standing in ----------
_b=$FAILS
mkwt standingin
FP="$(fp_for_worktree "$T/standingin")"
plan_for "$T/standingin" "$FP" > "$T/p6.md"
OUT="$(cd "$T/standingin" && run_apply "$T/p6.md")"
[ -d "$T/standingin" ] || fail "AW6: apply removed the worktree it was running in"
printf '%s\n' "$OUT" | grep -q 'current' \
  || fail "AW6: the refusal does not name 'current': $OUT"
[ "$FAILS" -eq "$_b" ] && pass "AW6: apply refuses to remove its own working directory"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
