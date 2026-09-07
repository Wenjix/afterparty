#!/usr/bin/env bash
# The two surfaces that used to discover-and-destroy in one step are now
# report-only. Both cases assert a POSITIVE refusal signal alongside survival:
# "the file is still there" is satisfied by a run that did nothing at all.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tests/devclean-fixtures.sh"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
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

# HOME does not isolate orphan processes, launchd services, or pnpm's shared
# store. Intercept all three machine-wide tools before any --apply, and run
# the current-repo artifact pass from a disposable non-repository directory.
SHIM="$T/shim"
mkdir -p "$SHIM" "$T/run" || exit 1
for tool in pgrep launchctl pnpm; do
  cat > "$SHIM/$tool" <<'SH' || exit 1
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "${0##*/}" "$PWD" "$*" >> "$AFTERPARTY_TEST_MACHINE_CALLS"
exit 1
SH
  chmod +x "$SHIM/$tool" || exit 1
done

run_disk_apply() (
  cd "$T/run" || exit 1
  export PATH="$SHIM:$PATH"
  local tool
  for tool in pgrep launchctl pnpm; do
    [ "$(command -v "$tool")" = "$SHIM/$tool" ] || {
      echo "refusing test apply: $tool is not intercepted" >&2
      exit 1
    }
  done
  HOME="$1" XDG_CACHE_HOME="$2" AFTERPARTY_TEST_MACHINE_CALLS="$3" \
    reviewed_devclean "$LIB/devclean.sh" --disk
)

# ---------- R2: the roaming project scan withholds under --apply ----------
_b=$FAILS
H="$T/home"; mkdir -p "$H/Documents/proj/node_modules/pkg"
dd if=/dev/zero of="$H/Documents/proj/node_modules/pkg/big.bin" bs=1024 count=2048 2>/dev/null
printf '{"name":"x"}\n' > "$H/Documents/proj/package.json"
OUT="$(run_disk_apply "$H" "$T/cache" "$T/r2-tools.log" 2>&1)"
[ -d "$H/Documents/proj/node_modules" ] \
  || fail "R2: node_modules in an unnamed project was deleted"
printf '%s\n' "$OUT" | grep -q 'withheld project node_modules/' \
  || fail "R2: no withholding message — the scan may simply not have run"
printf '%s\n' "$OUT" | grep -q 'report-only; review this directory manually' \
  || fail "R2: withholding does not explain manual review of unsupported roaming targets"
[ "$FAILS" -eq "$_b" ] && pass "R2: the roaming project scan reports and withholds under --apply"

# ---------- R3: exact allowlisted cache paths still work ----------
# The cut is roaming-vs-named, not apply-vs-report. ~/.gradle/caches is a cache
# by definition; if this stops working the change went too far.
_b=$FAILS
H2="$T/home2"; mkdir -p "$H2/.gradle/caches/modules"
dd if=/dev/zero of="$H2/.gradle/caches/modules/blob.bin" bs=1024 count=2048 2>/dev/null
run_disk_apply "$H2" "$T/cache2" "$T/r3-tools.log" >/dev/null 2>&1
[ -d "$H2/.gradle/caches" ] \
  && fail "R3: an exact allowlisted cache path was NOT cleaned — the cut went too far"
[ "$FAILS" -eq "$_b" ] && pass "R3: exact allowlisted cache paths are still cleaned"

# ---------- R4: each apply really used the machine-tool shims ----------
_b=$FAILS
for calls in "$T/r2-tools.log" "$T/r3-tools.log"; do
  for tool in pnpm; do
    grep -q "^$tool$(printf '\t')" "$calls" \
      || fail "R4: $tool was not intercepted during $(basename "$calls")"
  done
  grep -q '^pgrep' "$calls" && fail "R4: --disk unexpectedly scanned orphan processes"
  awk -F '\t' -v want="$T/run" '$2 != want { bad = 1 } END { exit bad }' "$calls" \
    || fail "R4: an apply ran outside the disposable working directory"
done
[ "$FAILS" -eq "$_b" ] && pass "R4: apply uses intercepted machine tools from a disposable cwd"

# ---------- R5: compatibility refusal cannot silently become success ----------
_b=$FAILS
mkdir -p "$T/outside"
for mode in plain json; do
  if [ "$mode" = json ]; then
    OUT="$(cd "$T/outside" && bash "$LIB/audit-git.sh" --clean --json 2>&1)"; rc=$?
  else
    OUT="$(cd "$T/outside" && bash "$LIB/audit-git.sh" --clean 2>&1)"; rc=$?
  fi
  [ "$rc" -eq 2 ] || fail "R5: non-repository --clean ($mode) returned $rc"
  printf '%s\n' "$OUT" | grep -q 'git --clean is report-only' \
    || fail "R5: non-repository refusal ($mode) did not explain the flag"
done
OUT="$(cd "$T/outside" && bash "$LIB/audit-git.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'not a git repository' \
  || fail 'R5: ordinary non-repository reporting should remain successful'
OUT="$(bash "$LIB/clean-artifacts.sh" --root "$T/g/repo" --plan --clean 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail 'R5: --plan --clean silently emitted a successful proposal'
printf '%s\n' "$OUT" | grep -q -- '--plan and --clean cannot be combined' \
  || fail 'R5: incompatible artifact modes did not reach the argument guard'
[ "$FAILS" -eq "$_b" ] && pass 'R5: report-only refusals hold outside Git and for conflicting modes'

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
