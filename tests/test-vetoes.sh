#!/usr/bin/env bash
# Hard vetoes: the checks a human ticking a checkbox cannot override.
#
# Every case asserts the POSITIVE token, not just that nothing was deleted.
# A veto that fires for the wrong reason, or an item withheld by an earlier
# rule than the one under test, both look identical to "the target survived" --
# that is how five assertions in this suite were previously found unable to
# fail. veto_for prints its reason so each case can name the rule it pins.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }

# shellcheck source=/dev/null
. "$LIB/vetoes.sh"

T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$T" || exit 1

git init -qb main proj
cd proj || exit 1
git config user.email t@t.local
git config user.name tester
mkdir -p node_modules/.bin src vendored
echo 'x' > node_modules/.bin/thing
echo 'src' > src/main.js
echo 'tracked' > vendored/keep.js
git add src vendored
git commit -qm init

# ---------- V1: a tracked path is never a target ----------
V="$(veto_for artifact "$PWD/vendored" "$PWD")"
[ "$V" = "tracked" ] || fail "V1: tracked dir gave '$V', want 'tracked'"
V="$(veto_for artifact "$PWD/node_modules" "$PWD")"
[ -z "$V" ] || fail "V1: control — an untracked artifact was vetoed as '$V'"
pass "V1: git-tracked target is vetoed, untracked control passes"

# ---------- V2: the scan root itself is never a target ----------
V="$(veto_for artifact "$PWD" "$PWD")"
[ "$V" = "scope-root" ] || fail "V2: the root gave '$V', want 'scope-root'"
pass "V2: the scan root is never selectable"

# ---------- V3: a repo root is never a target ----------
mkdir -p "$T/other"
git init -q "$T/other/inner"
V="$(veto_for artifact "$T/other/inner" "$T/other")"
[ "$V" = "repo-root" ] || fail "V3: a repo root gave '$V', want 'repo-root'"
pass "V3: a git repository root is never deletable"

# ---------- V4: nested repositories are boundaries ----------
mkdir -p build/plugin
git init -q build/plugin
echo 'p' > build/plugin/p.txt
git -C build/plugin add p.txt
git -C build/plugin -c user.email=t@t.local -c user.name=t commit -qm p
V="$(veto_for artifact "$PWD/build" "$PWD")"
[ "$V" = "nested-repo" ] || fail "V4: a dir containing a nested repo gave '$V', want 'nested-repo'"
pass "V4: an artifact dir containing a nested repository is vetoed"

# ---------- V5: symlink escape is physical, not lexical ----------
# The lexical path sits under the root; the physical one does not. A check
# written as a string prefix test passes this and deletes outside the scope.
mkdir -p "$T/outside/precious"
echo 'irreplaceable' > "$T/outside/precious/data"
ln -s "$T/outside/precious" "$PWD/escape"
V="$(veto_for artifact "$PWD/escape" "$PWD")"
[ "$V" = "symlink" ] || fail "V5: a symlink target gave '$V', want 'symlink'"
[ -f "$T/outside/precious/data" ] || fail "V5: the file outside the scope is gone"
# and the physical escape is caught even when the symlink is a path COMPONENT
mkdir -p "$T/outside/holder"
ln -s "$T/outside/holder" "$PWD/via"
mkdir -p "$T/outside/holder/node_modules"
V="$(veto_for artifact "$PWD/via/node_modules" "$PWD")"
[ "$V" = "scope-escape" ] || fail "V5: escape through a symlinked component gave '$V', want 'scope-escape'"
pass "V5: symlink targets and symlinked path components are both vetoed"

# ---------- V6: a dirty worktree is a hard veto for the worktree type ----------
git worktree add -q "$T/wt" -b agent/x HEAD
echo 'uncommitted' > "$T/wt/scratch.txt"
V="$(veto_for worktree "$T/wt" "$PWD")"
[ "$V" = "dirty" ] || fail "V6: a dirty worktree gave '$V', want 'dirty'"
rm -f "$T/wt/scratch.txt"
V="$(veto_for worktree "$T/wt" "$PWD")"
[ -z "$V" ] || fail "V6: control — a clean worktree was vetoed as '$V'"
pass "V6: uncommitted work vetoes a worktree, clean control passes"

# ---------- V7: the current worktree is never removable ----------
V="$(cd "$T/wt" && veto_for worktree "$T/wt" "$T/wt")"
[ "$V" = "current" ] || fail "V7: removing the worktree you stand in gave '$V', want 'current'"
pass "V7: the worktree the caller occupies is vetoed"

# ---------- V8: a missing path is 'gone', not a silent pass ----------
V="$(veto_for artifact "$PWD/never-existed" "$PWD")"
[ "$V" = "gone" ] || fail "V8: an absent path gave '$V', want 'gone'"
pass "V8: an absent target reports gone rather than passing"

# ---------- V9: an unknown type fails closed ----------
V="$(veto_for wormhole "$PWD/node_modules" "$PWD")"
[ "$V" = "unknown-type" ] || fail "V9: an unknown type gave '$V', want 'unknown-type'"
pass "V9: an unrecognized target type fails closed"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
