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
_b=$FAILS
V="$(veto_for artifact "$PWD/vendored" "$PWD")"
[ "$V" = "tracked" ] || fail "V1: tracked dir gave '$V', want 'tracked'"
V="$(veto_for artifact "$PWD/node_modules" "$PWD")"
[ -z "$V" ] || fail "V1: control — an untracked artifact was vetoed as '$V'"
[ "$FAILS" -eq "$_b" ] && pass "V1: git-tracked target is vetoed, untracked control passes"

# ---------- V2: the scan root itself is never a target ----------
_b=$FAILS
V="$(veto_for artifact "$PWD" "$PWD")"
[ "$V" = "scope-root" ] || fail "V2: the root gave '$V', want 'scope-root'"
[ "$FAILS" -eq "$_b" ] && pass "V2: the scan root is never selectable"

# ---------- V3: a repo root is never a target ----------
_b=$FAILS
mkdir -p "$T/other"
git init -q "$T/other/inner"
V="$(veto_for artifact "$T/other/inner" "$T/other")"
[ "$V" = "repo-root" ] || fail "V3: a repo root gave '$V', want 'repo-root'"
[ "$FAILS" -eq "$_b" ] && pass "V3: a git repository root is never deletable"

# ---------- V4: nested repositories are boundaries ----------
_b=$FAILS
mkdir -p build/plugin
git init -q build/plugin
echo 'p' > build/plugin/p.txt
git -C build/plugin add p.txt
git -C build/plugin -c user.email=t@t.local -c user.name=t commit -qm p
V="$(veto_for artifact "$PWD/build" "$PWD")"
[ "$V" = "nested-repo" ] || fail "V4: a dir containing a nested repo gave '$V', want 'nested-repo'"
[ "$FAILS" -eq "$_b" ] && pass "V4: an artifact dir containing a nested repository is vetoed"

# ---------- V5: symlink escape is physical, not lexical ----------
_b=$FAILS
# The lexical path sits under the root; the physical one does not. A check
# written as a string prefix test passes this and deletes outside the scope.
mkdir -p "$T/outside/precious"
echo 'irreplaceable' > "$T/outside/precious/data"
if ln -s "$T/outside/precious" "$PWD/escape" 2>/dev/null && [ -L "$PWD/escape" ]; then
  V="$(veto_for artifact "$PWD/escape" "$PWD")"
  [ "$V" = "symlink" ] || fail "V5: a symlink target gave '$V', want 'symlink'"
  [ -f "$T/outside/precious/data" ] || fail "V5: the file outside the scope is gone"
  # and the physical escape is caught even when the symlink is a path COMPONENT
  mkdir -p "$T/outside/holder"
  ln -s "$T/outside/holder" "$PWD/via"
  [ -L "$PWD/via" ] || fail "V5: the component fixture is not a symlink"
  mkdir -p "$T/outside/holder/node_modules"
  V="$(veto_for artifact "$PWD/via/node_modules" "$PWD")"
  [ "$V" = "scope-escape" ] || fail "V5: escape through a symlinked component gave '$V', want 'scope-escape'"
  [ "$FAILS" -eq "$_b" ] && pass "V5: symlink targets and symlinked path components are both vetoed"
else
  echo "SKIP: V5: this filesystem does not create real symlinks"
fi

# ---------- V6: a dirty worktree is a hard veto for the worktree type ----------
_b=$FAILS
git worktree add -q "$T/wt" -b agent/x HEAD
MAP="$T/cwdmap"; : > "$MAP" # Explicit, complete empty map for unit fixtures.
echo 'uncommitted' > "$T/wt/scratch.txt"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ "$V" = "dirty" ] || fail "V6: a dirty worktree gave '$V', want 'dirty'"
rm -f "$T/wt/scratch.txt"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ -z "$V" ] || fail "V6: control — a clean worktree was vetoed as '$V'"
[ "$FAILS" -eq "$_b" ] && pass "V6: uncommitted work vetoes a worktree, clean control passes"

# ---------- V7: the current worktree is never removable ----------
_b=$FAILS
V="$(cd "$T/wt" && veto_for worktree "$T/wt" "$T/wt")"
[ "$V" = "current" ] || fail "V7: removing the worktree you stand in gave '$V', want 'current'"
[ "$FAILS" -eq "$_b" ] && pass "V7: the worktree the caller occupies is vetoed"

# ---------- V10: a worktree with a live process inside it is vetoed ----------
_b=$FAILS
MAP="$T/cwdmap"
printf '4242\t%s/nested/deep\n' "$T/wt" > "$MAP"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ "$V" = "occupied" ] || fail "V10: a worktree hosting a live process gave '$V', want 'occupied'"
# control: the same map, a worktree nobody is standing in
printf '4242\t%s/elsewhere\n' "$T" > "$MAP"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ -z "$V" ] || fail "V10: control — an unoccupied worktree was vetoed as '$V'"
# and a SIBLING path that merely shares a prefix must not count as inside it
printf '4242\t%s-sibling/x\n' "$T/wt" > "$MAP"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ -z "$V" ] || fail "V10: a sibling sharing the path prefix was read as inside: '$V'"
# The PHYSICAL form too. On macOS $T is under /var, whose physical path is
# /private/var, so a check written against one form only never fires for the
# other -- and every temp dir on the platform takes that branch.
PHYS_WT="$(cd "$T/wt" && pwd -P)"
printf '4242\t%s/nested\n' "$PHYS_WT" > "$MAP"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ "$V" = "occupied" ] || fail "V10: a cwd recorded in physical form gave '$V', want 'occupied'"
[ "$PHYS_WT" != "$T/wt" ] || echo "  note: /tmp is not symlinked here, so the two forms coincide" >&2
[ "$FAILS" -eq "$_b" ] && pass "V10: a live process inside a worktree vetoes it, in either path form"

# ---------- V11: unavailable occupancy evidence is a veto ----------
_b=$FAILS
V="$(veto_for worktree "$T/wt" "$PWD" "$T/missing-map")"
[ "$V" = "occupancy-unavailable" ] || fail "V11: missing map gave '$V', want 'occupancy-unavailable'"
V="$(veto_for worktree "$T/wt" "$PWD")"
[ "$V" = "occupancy-unavailable" ] || fail "V11: omitted map gave '$V', want 'occupancy-unavailable'"
[ "$FAILS" -eq "$_b" ] && pass "V11: missing occupancy evidence fails closed"

# ---------- V12: ignored nested history is protected in worktrees ----------
_b=$FAILS
: > "$MAP"
printf 'private/\n' >> .git/info/exclude
git init -q "$T/wt/private"
printf 'unique history\n' > "$T/wt/private/only-copy"
git -C "$T/wt/private" add only-copy
git -C "$T/wt/private" -c user.email=t@t.local -c user.name=t commit -qm unique
[ -z "$(git -C "$T/wt" status --porcelain)" ] || fail "V12: ignored nested fixture is not clean to its outer repo"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ "$V" = "nested-repo" ] || fail "V12: ignored nested repository gave '$V', want 'nested-repo'"
mv "$T/wt/private" "$T/saved-private"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ -z "$V" ] || fail "V12: control — worktree root .git was mistaken for a nested repo: '$V'"
[ "$FAILS" -eq "$_b" ] && pass "V12: nested repos are vetoed while root worktree metadata is excluded"

# ---------- V13: incomplete filesystem scans cannot prove safety ----------
_b=$FAILS
V="$(find() { return 1; }; veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ "$V" = "scan-incomplete" ] || fail "V13: failed worktree scan gave '$V', want 'scan-incomplete'"
V="$(find() { return 1; }; veto_for artifact "$PWD/node_modules" "$PWD")"
[ "$V" = "scan-incomplete" ] || fail "V13: failed artifact scan gave '$V', want 'scan-incomplete'"
[ "$FAILS" -eq "$_b" ] && pass "V13: failed nested repository scans fail closed"

# ---------- V14: bare repository backups are also nested repositories ----------
_b=$FAILS
printf 'archive.git/\nplain-dir/\n' >> .git/info/exclude
git init --bare -q "$T/wt/archive.git"
[ -z "$(git -C "$T/wt" status --porcelain)" ] || fail "V14: bare fixture is not ignored"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ "$V" = "nested-repo" ] || fail "V14: ignored bare repository gave '$V', want 'nested-repo'"
mv "$T/wt/archive.git" "$T/saved-archive.git"
mkdir -p "$T/wt/plain-dir"
printf 'ordinary file\n' > "$T/wt/plain-dir/HEAD"
V="$(veto_for worktree "$T/wt" "$PWD" "$MAP")"
[ -z "$V" ] || fail "V14: an ordinary HEAD file was mistaken for a repository: '$V'"
[ "$FAILS" -eq "$_b" ] && pass "V14: bare repositories are protected and ordinary HEAD files are not repositories"

# ---------- V8: a missing path is 'gone', not a silent pass ----------
_b=$FAILS
V="$(veto_for artifact "$PWD/never-existed" "$PWD")"
[ "$V" = "gone" ] || fail "V8: an absent path gave '$V', want 'gone'"
[ "$FAILS" -eq "$_b" ] && pass "V8: an absent target reports gone rather than passing"

# ---------- V9: an unknown type fails closed ----------
_b=$FAILS
V="$(veto_for wormhole "$PWD/node_modules" "$PWD")"
[ "$V" = "unknown-type" ] || fail "V9: an unknown type gave '$V', want 'unknown-type'"
[ "$FAILS" -eq "$_b" ] && pass "V9: an unrecognized target type fails closed"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
