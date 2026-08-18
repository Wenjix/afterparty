#!/usr/bin/env bash
# Synthetic-repo test for audit-git.sh (dry-run, --clean, idempotency, edges).
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
OUT2="$(bash "$LIB/audit-git.sh" --clean 2>stderr2.txt)"; RC=$?
[ "$RC" -eq 0 ] || fail "clean exit=$RC"
[ ! -d ../wt-stale ]                                   || fail "wt-stale survived --clean"
git worktree list | grep -q 'wt-gone'                  && fail "wt-gone not pruned"
git rev-parse -q --verify claude/done >/dev/null 2>&1  && fail "claude/done survived --clean"
git rev-parse -q --verify codex-wip  >/dev/null 2>&1   || fail "codex-wip was deleted (unmerged!)"
[ ! -f a.orig ] && [ ! -f b.rej ] && [ ! -f sub/c.BACKUP.123.txt ] || fail "litter survived --clean"
[ -f tracked.orig ]                                    || fail "tracked.orig was deleted"
[ ! -f .git/index.lock ]                               || fail "aged index.lock survived --clean"
[ "$(git stash list | wc -l | tr -d ' ')" = "1" ]      || fail "stash was dropped"
git rev-parse -q --verify agent/stale >/dev/null 2>&1  && fail "agent/stale survived first clean (worktree removed same run)"
git rev-parse -q --verify agent/gone  >/dev/null 2>&1  && fail "agent/gone survived first clean (worktree pruned same run)"
pass "--clean applied safe subset only, converging in one pass"

# ---------- repeat cleans are idempotent no-ops ----------
bash "$LIB/audit-git.sh" --clean >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "second clean exit=$RC"
bash "$LIB/audit-git.sh" --clean >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "third (idempotent) clean exit=$RC"
pass "repeat --clean stays a no-op at exit 0"

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
