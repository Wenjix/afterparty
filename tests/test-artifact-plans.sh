#!/usr/bin/env bash
# Exercise approved filesystem cleanup through its actual entry points.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
. "$LIB/fingerprint.sh"
T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache"
export TEST_FS_LOG="$T/tools" TEST_FS_ROOT="$T/repo with spaces"
mkdir -p "$HOME" "$T/shim" "$TEST_FS_ROOT"
TEST_FS_ROOT="$(cd "$TEST_FS_ROOT" && pwd -P)"
: > "$TEST_FS_LOG"
for tool in pgrep launchctl pnpm; do
  cat > "$T/shim/$tool" <<'SHIM'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$TEST_FS_LOG"
exit 1
SHIM
done
cat > "$T/shim/lsof" <<'SHIM'
#!/usr/bin/env bash
[ "${TEST_FS_SCAN:-ok}" != fail ] || { echo 'permission denied' >&2; exit 1; }
printf 'p9001\nfcwd\nn%s\n' "${TEST_FS_BUSY:-$TEST_FS_ROOT}"
SHIM
cat > "$T/shim/ps" <<'SHIM'
#!/usr/bin/env bash
printf '9001 9001 Mon Aug 10 00:00:00 2026 bash\n'
SHIM
chmod +x "$T/shim/"*
export PATH="$T/shim:$PATH" AFTERPARTY_STYLE=never
git -C "$TEST_FS_ROOT" init -qb main
git -C "$TEST_FS_ROOT" -c user.name=test -c user.email=t@t commit --allow-empty -qm init
cd "$TEST_FS_ROOT" || exit 1

artifact_plan() {
  printf '# afterparty plan schema: 1\n'
  printf -- '- [x] artifact path %s\n' "$1"
  printf '      type: artifact  fingerprint: %s  root: %s\n' "$(fp_for_artifact "$1")" "$TEST_FS_ROOT"
}
apply() { bash "$LIB/apply.sh" "$1" 2>&1; }

# The generated unchecked proposal is inert; checking its exact item removes it.
mkdir build; printf 'rebuildable\n' > build/output
bash "$LIB/plan.sh" --artifacts-only --root "$TEST_FS_ROOT" > "$T/plan"
grep -Fq -- "- [ ] artifact path $TEST_FS_ROOT/build" "$T/plan" || fail 'AP1: artifact not offered unchecked'
OUT="$(apply "$T/plan")"; RC=$?
[ "$RC" -eq 0 ] && [ -f build/output ] && printf '%s' "$OUT" | grep -q '0 applied' || fail "AP1: unchecked proposal acted: $OUT"
sed 's/^- \[ \]/- [x]/' "$T/plan" > "$T/approved"
OUT="$(apply "$T/approved")"; RC=$?
[ "$RC" -eq 0 ] && [ ! -e build ] && printf '%s' "$OUT" | grep -q '1 applied' || fail "AP1: checked control failed: $OUT"
pass 'AP1: generated artifact plans require an explicit checkbox'

# A nested repository under the selected ancestor retains its only commit.
mkdir -p build/plugin
git -C build/plugin init -q
printf 'unique nested history\n' > build/plugin/keep
git -C build/plugin add keep
git -C build/plugin -c user.name=test -c user.email=t@t commit -qm unique
NESTED="$(git -C build/plugin rev-parse HEAD)"
artifact_plan "$PWD/build" > "$T/nested"
OUT="$(apply "$T/nested")"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'nested-repo veto' || fail "AP2: nested guard not reached: $OUT"
[ "$(git -C build/plugin rev-parse HEAD)" = "$NESTED" ] || fail 'AP2: nested history lost'
mv build "$T/saved-nested"
pass 'AP2: containing artifacts preserve nested repositories'

# A corrupt index cannot authorize deletion of a tracked local modification.
mkdir build; printf 'committed\n' > build/valuable
git add build/valuable; git -c user.name=test -c user.email=t@t commit -qm tracked
printf 'unique uncommitted edit\n' > build/valuable
artifact_plan "$PWD/build" > "$T/tracked"
cp .git/index "$T/index"; printf 'corrupt\n' > .git/index
OUT="$(apply "$T/tracked")"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'git-unavailable veto' || fail "AP3: failed Git inspection passed: $OUT"
grep -q 'unique uncommitted' build/valuable || fail 'AP3: local edit lost'
cp "$T/index" .git/index
pass 'AP3: Git inspection failure preserves tracked edits'

# Full validation precedes even otherwise legitimate checked items.
mkdir dist; printf 'keep until valid approval\n' > dist/output
artifact_plan "$PWD/dist" > "$T/invalid"
printf -- '- [x] stop my server\n' >> "$T/invalid"
OUT="$(apply "$T/invalid")"; RC=$?
[ "$RC" -eq 2 ] && [ -f dist/output ] && printf '%s' "$OUT" | grep -q 'invalid plan' || fail "AP4: malformed approval allowed partial mutation: $OUT"
artifact_plan "$PWD/dist" > "$T/duplicate"
artifact_plan "$PWD/dist" >> "$T/duplicate"
OUT="$(apply "$T/duplicate")"; RC=$?
[ "$RC" -eq 2 ] && [ -f dist/output ] && printf '%s' "$OUT" | grep -q 'duplicate checked target' || fail "AP4: duplicate approval not rejected: $OUT"
pass 'AP4: invalid and duplicate approvals reject the whole plan before mutation'

# Occupancy and scan failures are separately observable hard vetoes.
artifact_plan "$PWD/dist" > "$T/busy"
OUT="$(TEST_FS_BUSY="$PWD/dist" apply "$T/busy")"; RC=$?
[ "$RC" -ne 0 ] && [ -f dist/output ] && printf '%s' "$OUT" | grep -q 'occupied veto' || fail "AP5: occupancy bypassed: $OUT"
OUT="$(TEST_FS_SCAN=fail apply "$T/busy")"; RC=$?
[ "$RC" -ne 0 ] && [ -f dist/output ] && printf '%s' "$OUT" | grep -q 'occupancy-unavailable veto' || fail "AP5: scan failure bypassed: $OUT"
pass 'AP5: occupied and unverifiable artifact targets are preserved'

# Legacy broad cleanup flags report the refusal in both rendering formats.
OUT="$(bash "$LIB/clean-artifacts.sh" --clean 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && [ -f dist/output ] && printf '%s' "$OUT" | grep -q 'report-only' || fail "AP6: direct artifact deletion remains enabled: $OUT"
for format in human json; do
  args=(--clean); [ "$format" != json ] || args+=(--json)
  OUT="$(bash "$LIB/audit-git.sh" "${args[@]}" 2>&1)"; RC=$?
  [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'report-only' || fail "AP6: Git $format hides cleanup refusal: $OUT"
done
pass 'AP6: direct cleanup refusal has consistent exit semantics'

# Ignored local configuration added after approval survives worktree apply.
git worktree add -qb local-data "$T/worktree" HEAD
printf '.env\n.next/\n' >> .git/info/exclude
FP="$(fp_for_worktree "$T/worktree")" || FP=""
if [ -n "$FP" ]; then
  printf -- '- [x] eligible path %s\n      type: worktree  fingerprint: %s  path: %s\n' "$T/worktree" "$FP" "$T/worktree" > "$T/worktree-plan"
  printf 'local-only configuration\n' > "$T/worktree/.env"
  OUT="$(apply "$T/worktree-plan")"; RC=$?
  [ "$RC" -ne 0 ] && [ -f "$T/worktree/.env" ] && printf '%s' "$OUT" | grep -q 'ignored-local-data veto' || fail "AP7: ignored config was not protected: $OUT"
  rm "$T/worktree/.env"
  mkdir "$T/worktree/.next"; printf 'rebuildable\n' > "$T/worktree/.next/output"
  OUT="$(apply "$T/worktree-plan")"; RC=$?
  [ "$RC" -eq 0 ] && [ ! -e "$T/worktree" ] || fail "AP7: known rebuildable output blocked clean control: $OUT"
  pass 'AP7: newly added ignored config is protected; known build cache permits removal'
else
  echo 'SKIP: AP7 native worktree creation identity unavailable (covered by identity suite)'
fi
[ ! -s "$TEST_FS_LOG" ] || fail 'machine tools escaped filesystem-only fixtures'
[ "$FAILS" -eq 0 ]
