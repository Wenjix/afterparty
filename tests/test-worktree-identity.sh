#!/usr/bin/env bash
# An old approval must not delete a different worktree at the same pathname.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_STATE_HOME="$T/state"
mkdir -p "$HOME" "$T/shim"
W="$T/repo"
git init -qb main "$W"
git -C "$W" config user.email t@t.local
git -C "$W" config user.name tester
git -C "$W" commit -q --allow-empty -m identity
git clone -q "$W" "$T/other-clone"
export FP_TEST_CWD="$W" FP_TEST_LOG="$T/tool-log"
: > "$FP_TEST_LOG"
cat > "$T/shim/lsof" <<'LSOF'
#!/usr/bin/env bash
cd "$FP_TEST_CWD" || exit 1
printf 'p%s\nfcwd\nn%s\n' "$$" "$(pwd -P)"
LSOF
for tool in pgrep pnpm launchctl audit-processes.sh; do
  cat > "$T/shim/$tool" <<'SHIM'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$FP_TEST_LOG"
exit 1
SHIM
done
chmod +x "$T/shim/"*
export PATH="$T/shim:$PATH"
# shellcheck source=/dev/null
. "$LIB/fingerprint.sh"

plan_for() {
  printf '# afterparty plan\n\n## Worktrees\n\n'
  printf -- '- [x] eligible  path %s  detached · idle 300d\n' "$1"
  printf '      type: worktree  fingerprint: %s  path: %s\n' "$2" "$1"
}
run_apply() { (cd "$W" && AFTERPARTY_STYLE=never bash "$LIB/apply.sh" "$1" 2>&1); }

git -C "$W" worktree add -q --detach "$T/probe" HEAD
NATIVE_BIRTH="$(LC_ALL=C stat -c '%w' -- "$T/probe" 2>/dev/null || LC_ALL=C stat -f '%B' -- "$T/probe" 2>/dev/null)" || NATIVE_BIRTH=""
HAS_BIRTH=1
case "$NATIVE_BIRTH" in ''|'-'|'?'|0|0.*|-1|-1.*) HAS_BIRTH=0 ;; esac
if [ "$HAS_BIRTH" -eq 0 ]; then
  # This is a supported refusal on filesystems without creation identity.
  # Exercise apply with a nonempty old token, and prove that the extant target
  # is explicitly withheld rather than reported gone or removed.
  if fp_for_worktree "$T/probe" >/dev/null 2>&1; then
    fail "WI0: unsupported creation identity still issued a fingerprint"
  fi
  plan_for "$T/probe" 012345abcdef > "$T/probe-plan"
  OUT="$(run_apply "$T/probe-plan")"; RC=$?
  [ "$RC" -ne 0 ] || fail "WI0: missing creation identity returned success: $OUT"
  [ -d "$T/probe" ] || fail "WI0: worktree without creation identity was removed"
  printf '%s\n' "$OUT" | grep -q 'identity-unavailable' \
    || fail "WI0: refusal does not name unavailable identity: $OUT"
  [ "$FAILS" -eq 0 ] || exit 1
  echo "SKIP: WI1/WI2 live replacement tests require filesystem birth time; WI0 fail-closed apply verified"
  exit 0
fi
FP="$(fp_for_worktree "$T/probe")" || fail "WI1: native creation identity is available but fingerprinting failed"

# Positive control: the same environment really permits an unchanged target.
_b=$FAILS
plan_for "$T/probe" "$FP" > "$T/probe-plan"
OUT="$(run_apply "$T/probe-plan")"; RC=$?
[ "$RC" -eq 0 ] && [ ! -e "$T/probe" ] \
  || fail "WI1: unchanged approved worktree was not removed: $OUT"
printf '%s\n' "$OUT" | grep -q '1 applied' || fail "WI1: removal was not confirmed: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "WI1: unchanged worktree is removed in the isolated environment"

for replacement_owner in same other; do
  _b=$FAILS
  TARGET="$T/reused-$replacement_owner"
  git -C "$W" worktree add -q --detach "$TARGET" HEAD
  APPROVED="$(fp_for_worktree "$TARGET")"
  plan_for "$TARGET" "$APPROVED" > "$T/replacement-plan"
  EXPECT_HEAD="$(git -C "$TARGET" rev-parse HEAD)"
  git -C "$W" worktree move "$TARGET" "$T/retired-$replacement_owner"
  OWNER="$W"; [ "$replacement_owner" = other ] && OWNER="$T/other-clone"
  git -C "$OWNER" worktree add -q --detach "$TARGET" HEAD
  [ "$(git -C "$TARGET" rev-parse HEAD)" = "$EXPECT_HEAD" ] \
    || fail "WI2: replacement changed HEAD, so physical identity is not isolated"
  [ "$(git -C "$TARGET" rev-parse --abbrev-ref HEAD)" = HEAD ] \
    || fail "WI2: replacement is not at the same detached branch state"
  # Git Bash's shell path (/c/...) and Git's worktree path (C:/...) differ.
  # Capture Git's canonical spelling before apply so the registration check
  # compares the same representation and still catches a removed target.
  REGISTERED_TARGET="$(git -C "$TARGET" rev-parse --show-toplevel)"
  OUT="$(run_apply "$T/replacement-plan")"
  [ -d "$TARGET" ] || fail "WI2: $replacement_owner-repo replacement was deleted by an old approval"
  printf '%s\n' "$OUT" | grep -q 'fingerprint moved' \
    || fail "WI2: $replacement_owner-repo replacement did not reach the identity refusal: $OUT"
  git -C "$OWNER" worktree list --porcelain | grep -Fxq -- "worktree $REGISTERED_TARGET" \
    || fail "WI2: replacement's owning repo lost the worktree registration"
  [ "$FAILS" -eq "$_b" ] && pass "WI2: old approval refuses a replacement from the $replacement_owner repo"
done

if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
