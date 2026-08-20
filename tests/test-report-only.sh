#!/usr/bin/env bash
# The two surfaces that used to discover-and-destroy in one step are now
# report-only. Both cases assert a POSITIVE refusal signal alongside survival:
# "the file is still there" is satisfied by a run that did nothing at all.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

age() {  # GNU then BSD
  touch -d "$1 days ago" "$2" 2>/dev/null || touch -t "$(date -v -"$1"d +%Y%m%d%H%M)" "$2"
}

# ---------- R1: git --clean reports but never removes ----------
_b=$FAILS
mkdir -p "$T/g"; cd "$T/g" || exit 1
git init -qb main repo >/dev/null 2>&1
cd repo || exit 1
git config user.email t@t.local; git config user.name tester
git commit -q --allow-empty -m base
git worktree add -q ../wt-stale -b agent/stale HEAD 2>/dev/null
age 30 ../wt-stale
# gitignored-but-precious state, the thing removal would have taken silently
printf 'SECRET=keep-me\n' > ../wt-stale/.env
git branch claude/merged 2>/dev/null

OUT="$(bash "$LIB/audit-git.sh" --clean 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "R1: --clean exited $rc, want 2 (a refusal, not a silent success)"
printf '%s\n' "$OUT" | grep -q 'report-only' \
  || fail "R1: no refusal message explaining --clean is report-only"
printf '%s\n' "$OUT" | grep -q 'afterparty plan' \
  || fail "R1: refusal does not point at the approval surface"
[ -d ../wt-stale ] || fail "R1: the stale worktree was removed anyway"
[ -f ../wt-stale/.env ] || fail "R1: gitignored .env was destroyed"
git show-ref --verify -q refs/heads/claude/merged \
  || fail "R1: a merged agent branch was deleted"
# positive control: the audit still REPORTS, so this is report-only and not a no-op
printf '%s\n' "$OUT" | grep -q 'wt-stale' \
  || fail "R1: the worktree was not even reported — that is a no-op, not report-only"
[ "$FAILS" -eq "$_b" ] && pass "R1: git --clean reports the worktree and refuses to remove it"
cd "$REPO" || exit 1

# ---------- R2: the roaming project scan withholds under --apply ----------
_b=$FAILS
H="$T/home"; mkdir -p "$H/Documents/proj/node_modules/pkg"
dd if=/dev/zero of="$H/Documents/proj/node_modules/pkg/big.bin" bs=1024 count=2048 2>/dev/null
printf '{"name":"x"}\n' > "$H/Documents/proj/package.json"
OUT="$(HOME="$H" XDG_CACHE_HOME="$T/cache" bash "$LIB/devclean.sh" --disk --apply 2>&1)"
[ -d "$H/Documents/proj/node_modules" ] \
  || fail "R2: node_modules in an unnamed project was deleted"
printf '%s\n' "$OUT" | grep -q 'withheld project node_modules/' \
  || fail "R2: no withholding message — the scan may simply not have run"
printf '%s\n' "$OUT" | grep -q 'afterparty plan' \
  || fail "R2: withholding does not point at the approval surface"
[ "$FAILS" -eq "$_b" ] && pass "R2: the roaming project scan reports and withholds under --apply"

# ---------- R3: exact allowlisted cache paths still work ----------
# The cut is roaming-vs-named, not apply-vs-report. ~/.gradle/caches is a cache
# by definition; if this stops working the change went too far.
_b=$FAILS
H2="$T/home2"; mkdir -p "$H2/.gradle/caches/modules"
dd if=/dev/zero of="$H2/.gradle/caches/modules/blob.bin" bs=1024 count=2048 2>/dev/null
HOME="$H2" XDG_CACHE_HOME="$T/cache2" bash "$LIB/devclean.sh" --disk --apply >/dev/null 2>&1
[ -d "$H2/.gradle/caches" ] \
  && fail "R3: an exact allowlisted cache path was NOT cleaned — the cut went too far"
[ "$FAILS" -eq "$_b" ] && pass "R3: exact allowlisted cache paths are still cleaned"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
