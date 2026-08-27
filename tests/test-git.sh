#!/usr/bin/env bash
# Synthetic-repo test for audit-git.sh (dry run, report-only --clean, edges).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
PY="$(command -v python3 || command -v python)"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

# Backdate a path's mtime. GNU touch takes -d 'N units ago'; BSD touch does
# not, so fall back to the POSIX -t form with a BSD-computed stamp -- same
# GNU-then-BSD shape as the date calls in devclean.sh and test-review-fixes.sh.
# Without this the staleness fixtures never age on macOS and every age-gated
# assertion below fails for a reason that has nothing to do with audit-git.sh.
age() { # age <gnu-spec> <bsd-date-spec> <path>
  touch -d "$1" "$3" 2>/dev/null \
    || touch -t "$(date -v "$2" +%Y%m%d%H%M)" "$3" \
    || fail "age: cannot backdate $3 (neither GNU nor BSD touch worked)"
}

T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$T" || exit 1

git init -qb main repo
cd repo || exit 1
git config user.email t@t.local
git config user.name tester

GIT_COMMITTER_DATE='2026-07-01T00:00:00' GIT_AUTHOR_DATE='2026-07-01T00:00:00' \
  git commit -q --allow-empty -m old
git branch claude/done                     # merged agent branch
git checkout -qb codex-wip
git commit -q --allow-empty -m wip         # unmerged agent branch
git checkout -q main
git worktree add -q ../wt-stale -b agent/stale HEAD
age '10 days ago' -10d ../wt-stale         # stale + clean worktree
git worktree add -q ../wt-gone -b agent/gone HEAD
rm -rf ../wt-gone                          # prunable worktree
echo x > a.orig
echo y > b.rej
mkdir -p sub
echo z > sub/c.BACKUP.123.txt
echo keep > tracked.orig
git add tracked.orig
git commit -qm 'track a control .orig'
echo data > f
git add f
git commit -qm 'add f with "quote" and \backslash'
echo edit >> f
git stash -q
age '2 hours ago' -2H .git/index.lock

# ---------- dry run ----------
OUT="$(bash "$LIB/audit-git.sh" 2>stderr.txt)"; RC=$?
[ "$RC" -eq 0 ] || fail "dry run exit=$RC"
echo "$OUT" | grep -q 'DRY RUN'                              || fail "banner missing"
echo "$OUT" | grep -q 'would remove .*wt-stale'              || fail "wt-stale not a remove candidate"
echo "$OUT" | grep -q 'would prune .*wt-gone'                || fail "wt-gone not prunable"
echo "$OUT" | grep -q 'would delete branch claude/done'      || fail "claude/done not deletable"
echo "$OUT" | grep -q 'would delete branch agent/stale'      || fail "agent/stale not predicted deletable (its worktree would be removed)"
echo "$OUT" | grep -q 'would delete branch agent/gone'       || fail "agent/gone not predicted deletable (its worktree would be pruned)"
echo "$OUT" | grep -q 'unmerged: codex-wip'                  || fail "codex-wip not report-only"
echo "$OUT" | grep -q 'would remove a.orig'                  || fail "a.orig missing"
echo "$OUT" | grep -q 'b.rej'                                || fail "b.rej missing"
echo "$OUT" | grep -q 'c.BACKUP.123.txt'                     || fail "BACKUP file missing"
echo "$OUT" | grep -q 'tracked.orig'                         && fail "tracked.orig leaked into litter"
echo "$OUT" | grep -q 'would remove .*index.lock'            || fail "aged index.lock not flagged"
echo "$OUT" | grep -q 'stash@{0}'                            || fail "stash not listed"
echo "$OUT" | grep -q 'Nothing was changed.'                 || fail "dry footer missing"
echo "$OUT" | grep -q 'main: .* never pruned or removed'     || fail "main worktree guard line missing"
[ -d ../wt-stale ]                    || fail "dry run deleted wt-stale"
[ -f a.orig ]                         || fail "dry run deleted a.orig"
[ -f .git/index.lock ]                || fail "dry run deleted index.lock"
git rev-parse -q --verify claude/done >/dev/null || fail "dry run deleted claude/done"
pass "dry run report + nothing changed"

# ---------- JSON dry run ----------
JOUT="$(bash "$LIB/audit-git.sh" --json 2>/dev/null)"
echo "$JOUT" | "$PY" -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
assert rows, "no json rows"
assert all("section" in r for r in rows), "row without section"
secs = {r["section"] for r in rows}
for want in ("git.worktree", "git.branch", "git.lock", "git.conflict", "git.stash"):
    assert want in secs, "missing section " + want
subj = [r for r in rows if r["section"] == "git.stash"][0]["subject"]
assert chr(34) in subj and chr(92) in subj, "escaped chars did not round-trip: " + subj
print("json ok:", len(rows), "rows")
' || fail "json dry run invalid"
pass "json dry run parses + escaping round-trips"

# ---------- clean ----------
# ---------- --clean is REPORT-ONLY (0.9.0) ----------
# It used to apply the safe subset here. It discovered targets and destroyed
# them in one step from heuristics that could not carry the weight -- a
# worktree's staleness came from a top-directory mtime that does not move when
# files inside it change, so a worktree in active use read as idle forever.
#
# Removal is moving behind plan/apply as a typed worktree target with hard
# vetoes. Until then this asserts the refusal. NOTE: coverage of the removal
# logic itself is deliberately reduced in the meantime -- audit-git still
# contains it, unreachable, for plan/apply to re-home with vetoes attached.
OUT2="$(bash "$LIB/audit-git.sh" --clean 2>stderr2.txt)"; RC=$?
[ "$RC" -eq 2 ] || fail "--clean exit=$RC, want 2 (a refusal, not silent success)"
grep -q 'report-only' stderr2.txt || fail "--clean did not say it is report-only"
grep -q 'afterparty plan' stderr2.txt || fail "--clean did not point at the approval surface"
# every candidate must SURVIVE...
[ -d ../wt-stale ]                                    || fail "wt-stale was removed by a report-only run"
git rev-parse -q --verify claude/done >/dev/null 2>&1 || fail "claude/done was deleted by a report-only run"
[ -f a.orig ]                                         || fail "conflict litter was deleted by a report-only run"
[ -f .git/index.lock ]                                || fail "index.lock was deleted by a report-only run"
# ...and must still be REPORTED, or this is a no-op rather than report-only
printf '%s\n' "$OUT2" | grep -q 'wt-stale'    || fail "wt-stale was not reported"
printf '%s\n' "$OUT2" | grep -q 'claude/done' || fail "claude/done was not reported"
pass "--clean reports every candidate and removes none"

# ---------- dirty and broken worktrees are classified, not just refused ----------
# --clean is report-only today, but the dirty check is the ONLY afterparty-side
# guard standing between `git worktree remove` and an agent's uncommitted work,
# and it has never been pinned. A refactor that adds --force to make removal
# "more reliable", or that changes how `git status --porcelain` is captured,
# would pass every other case in this file. When removal moves behind
# plan/apply as a typed worktree target, this is the classification it inherits.
# Branch from the OLD-dated root commit, as wt-stale effectively does.
# Staleness is derived from the worktree's HEAD commit date as well as its
# directory mtime, so a worktree created at HEAD is "idle 0d" no matter how far
# back its mtime is pushed — which is why the first version of this case never
# reached the branch it was written to pin.
WT_OLD="$(git rev-list --max-parents=0 HEAD | head -1)"
git worktree add -q --detach ../wt-dirty "$WT_OLD" 2>/dev/null
# Write the dirty content BEFORE ageing. Writing into the worktree updates its
# directory mtime, so ageing first left it looking ACTIVE — the row never
# reached the stale-and-dirty branch and this whole case passed without
# exercising the guard it exists to pin.
printf 'uncommitted\n' > ../wt-dirty/untracked.txt
printf 'edited\n' >> ../wt-dirty/f 2>/dev/null || printf 'edited\n' > ../wt-dirty/f
age '30 days ago' -30d ../wt-dirty
OUT3="$(bash "$LIB/audit-git.sh" 2>/dev/null)"
printf '%s\n' "$OUT3" | grep -q 'wt-dirty' \
  || fail "dirty worktree was not reported at all"
printf '%s\n' "$OUT3" | grep -q 'stale but DIRTY:.*wt-dirty' \
  || fail "wt-dirty did not reach the stale-and-dirty branch: $(printf '%s\n' "$OUT3" | grep wt-dirty)"
printf '%s\n' "$OUT3" | grep -q 'would remove .*wt-dirty' \
  && fail "dirty worktree was offered for removal"
# positive control: a CLEAN stale worktree in the same run IS offered, so the
# absence above is the dirty check and not the section failing to run
printf '%s\n' "$OUT3" | grep -q 'would remove .*wt-stale' \
  || fail "control: the clean stale worktree was not offered, so nothing was classified"
[ -f ../wt-dirty/untracked.txt ] || fail "the dirty worktree's untracked file vanished during a dry run"
pass "a dirty stale worktree is reported, marked, and never offered for removal"

bash "$LIB/audit-git.sh" --clean >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "second --clean exit=$RC, want a stable refusal"
[ -d ../wt-stale ] || fail "a repeat --clean removed the worktree"
pass "repeat --clean stays a stable refusal"

# ---------- fresh lock is protected ----------
touch .git/index.lock
OUT3="$(bash "$LIB/audit-git.sh")"
echo "$OUT3" | grep -q 'left alone: .*index.lock' || fail "fresh lock not left alone in report"
bash "$LIB/audit-git.sh" --clean >/dev/null 2>&1
[ -f .git/index.lock ] || fail "fresh lock deleted (age gate broken)"
rm -f .git/index.lock
pass "fresh index.lock protected by age gate"

# ---------- from inside a linked worktree ----------
git worktree add -q ../wt2 -b agent/current HEAD
OUT4="$(cd ../wt2 && bash "$LIB/audit-git.sh")"
echo "$OUT4" | grep -q 'current: .*wt2'  || fail "current worktree not marked current"
echo "$OUT4" | grep -q 'would remove .*wt2' && fail "current worktree offered for removal"
pass "running from a linked worktree is safe"
git worktree remove ../wt2 >/dev/null 2>&1
git branch -d agent/current >/dev/null 2>&1

# ---------- flags + non-repo ----------
bash "$LIB/audit-git.sh" --age x >/dev/null 2>&1; [ $? -eq 2 ] || fail "--age x should exit 2"
bash "$LIB/audit-git.sh" --bogus >/dev/null 2>&1; [ $? -eq 2 ] || fail "unknown arg should exit 2"
H="$(bash "$LIB/audit-git.sh" --help)"
echo "$H" | grep -q 'Usage:'    || fail "help missing Usage"
echo "$H" | grep -q 'Exit codes' || fail "help missing Exit codes line"
echo "$H" | grep -q 'set -uo'    && fail "help overshoots into code"
NR="$(cd "$T" && bash "$LIB/audit-git.sh")"; RC=$?
[ "$RC" -eq 0 ] || fail "non-repo exit=$RC"
echo "$NR" | grep -q 'not a git repository' || fail "non-repo note missing"
NRJ="$(cd "$T" && bash "$LIB/audit-git.sh" --json)"
[ -z "$NRJ" ] || fail "non-repo --json should emit nothing"
pass "flags, help range, non-repo behavior"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
