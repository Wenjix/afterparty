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
# Match the physical cwd spelling emitted by real lsof and the shared index.
T="$(cd "$T" && pwd -P)"
if command -v cygpath >/dev/null 2>&1; then T="$(cygpath -u "$(cygpath -am "$T")")"; fi
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
trap 'cd /; rm -rf "$T"' EXIT

export XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" HOME="$T/home"
mkdir -p "$HOME"

# Every apply fixture uses harmless process/service/package shims, even when
# the intended plan contains only filesystem targets.
SHIM="$T/shim"; mkdir -p "$SHIM"
export TEST_SIDE_EFFECT_LOG="$T/side-effects" TEST_LSOF_LOG="$T/lsof-calls"
export TEST_LSOF_MODE=clean TEST_AUDIT_MARKER="$T/audit-ran"
: > "$TEST_SIDE_EFFECT_LOG"; : > "$TEST_LSOF_LOG"
for tool in pgrep launchctl pnpm; do
  cat > "$SHIM/$tool" <<'SAFE'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$TEST_SIDE_EFFECT_LOG"
case "${0##*/}" in pgrep) exit 1 ;; esac
exit 0
SAFE
done
cat > "$SHIM/lsof" <<'LSOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_LSOF_MODE" >> "$TEST_LSOF_LOG"
case "$TEST_LSOF_MODE" in
  failed) exit 1 ;;
  empty) exit 0 ;;
  malformed) printf 'p4242\nfcwd\nnrelative-path\n'; exit 0 ;;
  missing-descriptor) printf 'p4242\nn%s\n' "$TEST_REPO"; exit 0 ;;
  readlink-error) printf 'p4242\nfcwd\nn/proc/4242/cwd (readlink: Permission denied)\n'; exit 0 ;;
  incomplete) printf 'p4242\nfcwd\nn%s\np4343\nfcwd\n' "$TEST_REPO"; exit 0 ;;
  warning) printf 'lsof: WARNING: cannot inspect a filesystem\n' >&2 ;;
  after-audit)
    if [ -e "$TEST_AUDIT_MARKER" ]; then
      printf 'p9902\nfcwd\nn%s\n' "$TEST_BUSY_PATH"; exit 0
    fi ;;
  replace-during-scan)
    if [ -e "$TEST_REPLACEMENT_SEEN" ]; then
      branch="$(git -C "$TEST_BUSY_PATH" symbolic-ref --short HEAD)" || exit 1
      git -C "$TEST_REPO" worktree move "$TEST_BUSY_PATH" "$TEST_BUSY_PATH-old" || exit 1
      git -C "$TEST_BUSY_PATH-old" checkout -q --detach HEAD || exit 1
      git -C "$TEST_REPO" worktree add -q "$TEST_BUSY_PATH" "$branch" || exit 1
    else
      : > "$TEST_REPLACEMENT_SEEN"
    fi ;;
esac
printf 'p9901\nfcwd\nn%s\n' "$TEST_REPO"
[ "$TEST_LSOF_MODE" != partial-error ]
LSOF
cat > "$SHIM/audit-processes.sh" <<'AUDIT'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_AUDIT_MARKER"
exit 0
AUDIT
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
[ ! -e "$TEST_AUDIT_MARKER" ] || exit 0
case "$*" in
  *pgid=,lstart=,command=*) printf '9901 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
  *pid,pgid,%cpu*) printf '9901 9901 0.0\n' ;;
  *) exit 1 ;;
esac
PS
chmod +x "$SHIM/"*
export PATH="$SHIM:$PATH"

W="$T/proj"
git init -qb main "$W"
git -C "$W" config user.email t@t.local
git -C "$W" config user.name tester
git -C "$W" commit -q --allow-empty -m one
export TEST_REPO="$W"

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

# No supported creation identity must mean refusal, not "gone" or success.
# If this host cannot provide it, test that production refusal first, then
# supply a deterministic birth field so the independent veto tests still run.
_b=$FAILS
if ! fp_for_worktree "$T/gozip" >/dev/null 2>&1; then
  plan_for "$T/gozip" deadbeef > "$T/no-identity.md"
  OUT="$(cd "$W" && run_apply "$T/no-identity.md")"; RC=$?
  printf '%s\n' "$OUT" | grep -q 'identity-unavailable' || fail "AW0: unsupported identity was not named: $OUT"
  [ "$RC" -ne 0 ] && [ -d "$T/gozip" ] || fail "AW0: unsupported identity did not preserve the worktree and fail"
  export TEST_REAL_STAT="$(command -v stat)"
  cat > "$SHIM/stat" <<'STAT'
#!/usr/bin/env bash
case "$1:$2" in
  '-c:%d:%i:%w') exec "$TEST_REAL_STAT" -c '%d:%i:2000-01-01 00:00:00.123456789 +0000' "${@:3}" ;;
  '-f:%d:%i:%.9FB') exec "$TEST_REAL_STAT" -f '%d:%i:946684800.123456789' "${@:3}" ;;
esac
exec "$TEST_REAL_STAT" "$@"
STAT
  chmod +x "$SHIM/stat"
  echo '  note: native creation identity unavailable; remaining veto fixtures supply a deterministic birth field'
fi
[ "$FAILS" -eq "$_b" ] || exit 1

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

# ---------- AW7: ignored nested repositories retain their unique history ----------
_b=$FAILS
mkwt nested
printf 'private/\n' >> "$W/.git/info/exclude"
git init -q "$T/nested/private"
printf 'only copy\n' > "$T/nested/private/keep"
git -C "$T/nested/private" add keep
git -C "$T/nested/private" -c user.email=t@t.local -c user.name=t commit -qm unique
NESTED_HEAD="$(git -C "$T/nested/private" rev-parse HEAD)"
[ -z "$(git -C "$T/nested" status --porcelain)" ] || fail "AW7: fixture is not clean to its outer repo"
plan_for "$T/nested" "$(fp_for_worktree "$T/nested")" > "$T/p7.md"
OUT="$(cd "$W" && run_apply "$T/p7.md")"; RC=$?
printf '%s\n' "$OUT" | grep -q 'nested-repo veto' || fail "AW7: nested guard was not reached: $OUT"
[ "$RC" -ne 0 ] || fail "AW7: nested refusal exited 0"
[ -f "$T/nested/private/keep" ] || fail "AW7: ignored nested history was deleted"
[ "$(git -C "$T/nested/private" rev-parse HEAD 2>/dev/null)" = "$NESTED_HEAD" ] \
  || fail "AW7: unique nested commit is no longer available"
[ "$FAILS" -eq "$_b" ] && pass "AW7: ignored nested history survives approved worktree removal"

# ---------- AW8: broken cwd discovery never becomes an empty safe map ----------
_b=$FAILS
for mode in failed partial-error empty malformed missing-descriptor readlink-error incomplete warning; do
  mkwt "scan-$mode"
  plan_for "$T/scan-$mode" "$(fp_for_worktree "$T/scan-$mode")" > "$T/p8-$mode.md"
  OUT="$(cd "$W" && TEST_LSOF_MODE="$mode" run_apply "$T/p8-$mode.md")"; RC=$?
  printf '%s\n' "$OUT" | grep -q 'occupancy-unavailable veto' \
    || fail "AW8/$mode: occupancy refusal was not reached: $OUT"
  [ -d "$T/scan-$mode" ] || fail "AW8/$mode: worktree was removed without complete occupancy evidence"
  [ "$RC" -ne 0 ] || fail "AW8/$mode: unavailable occupancy exited 0"
done
[ "$FAILS" -eq "$_b" ] && pass "AW8: failed, partial, empty, malformed and incomplete cwd scans refuse removal"

# ---------- AW9: refresh occupancy after process cleanup, at removal ----------
_b=$FAILS
mkwt refreshed
export TEST_BUSY_PATH="$T/refreshed"
R="$T/transcripts"; mkdir -p "$R/proj"
printf '{"cwd":"%s"}\n' "$W" > "$R/proj/a.jsonl"
touch -d '300 days ago' "$R/proj/a.jsonl" 2>/dev/null \
  || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$R/proj/a.jsonl"
{
  printf -- '- [x] eligible pgid 9901\n      category: dev  fingerprint: %s\n' "$(fp_for_pgid 9901)"
  plan_for "$T/refreshed" "$(fp_for_worktree "$T/refreshed")"
} > "$T/p9.md"
OUT="$(cd "$W" && TEST_LSOF_MODE=after-audit AFTERPARTY_TRANSCRIPT_ROOT="$R" run_apply "$T/p9.md")"; RC=$?
[ -s "$TEST_AUDIT_MARKER" ] || fail "AW9: process cleanup delegation was not reached: $OUT"
printf '%s\n' "$OUT" | grep -q 'occupied veto' || fail "AW9: refreshed occupancy was not checked: $OUT"
[ -d "$T/refreshed" ] || fail "AW9: worktree became occupied during cleanup and was still removed"
[ "$RC" -ne 0 ] || fail "AW9: occupied refusal exited 0"
[ "$FAILS" -eq "$_b" ] && pass "AW9: occupancy is refreshed after process cleanup before worktree removal"

# ---------- AW10: incomplete filesystem scans cannot authorize deletion ----------
_b=$FAILS
mkwt unscannable
plan_for "$T/unscannable" "$(fp_for_worktree "$T/unscannable")" > "$T/p10.md"
cat > "$SHIM/find" <<'FIND'
#!/usr/bin/env bash
exit 1
FIND
chmod +x "$SHIM/find"
OUT="$(cd "$W" && run_apply "$T/p10.md")"; RC=$?
rm -f "$SHIM/find"
printf '%s\n' "$OUT" | grep -q 'scan-incomplete veto' || fail "AW10: failed scan refusal was not reached: $OUT"
[ -d "$T/unscannable" ] || fail "AW10: incompletely scanned worktree was removed"
[ "$RC" -ne 0 ] || fail "AW10: incomplete scan exited 0"
[ "$FAILS" -eq "$_b" ] && pass "AW10: an incomplete filesystem scan vetoes worktree removal"

# ---------- AW11: unavailable identity on an extant target is a failed refusal ----------
_b=$FAILS
mkwt noidentity
plan_for "$T/noidentity" deadbeef > "$T/p11.md"
[ ! -e "$SHIM/stat" ] || mv "$SHIM/stat" "$SHIM/stat-saved"
cat > "$SHIM/stat" <<'STAT'
#!/usr/bin/env bash
exit 1
STAT
chmod +x "$SHIM/stat"
OUT="$(cd "$W" && run_apply "$T/p11.md")"; RC=$?
rm -f "$SHIM/stat"
[ ! -e "$SHIM/stat-saved" ] || mv "$SHIM/stat-saved" "$SHIM/stat"
printf '%s\n' "$OUT" | grep -q 'identity-unavailable' || fail "AW11: unavailable identity was not named: $OUT"
[ "$RC" -ne 0 ] || fail "AW11: unavailable identity exited 0"
[ -d "$T/noidentity" ] || fail "AW11: unavailable identity removed the worktree"
[ "$FAILS" -eq "$_b" ] && pass "AW11: extant worktrees with unavailable identity are refused visibly"

# ---------- AW12: ignored bare repository backups retain unique commits ----------
_b=$FAILS
mkwt bare
printf 'archive.git/\n' >> "$W/.git/info/exclude"
git init -q "$T/bare-seed"
printf 'unique bare history\n' > "$T/bare-seed/keep"
git -C "$T/bare-seed" add keep
git -C "$T/bare-seed" -c user.email=t@t.local -c user.name=t commit -qm unique
BARE_HEAD="$(git -C "$T/bare-seed" rev-parse HEAD)"
git clone --bare -q "$T/bare-seed" "$T/bare/archive.git"
rm -rf "$T/bare-seed"
[ -z "$(git -C "$T/bare" status --porcelain)" ] || fail "AW12: bare fixture is not clean to the outer repository"
plan_for "$T/bare" "$(fp_for_worktree "$T/bare")" > "$T/p12.md"
OUT="$(cd "$W" && run_apply "$T/p12.md")"; RC=$?
printf '%s\n' "$OUT" | grep -q 'nested-repo veto' || fail "AW12: bare repository guard was not reached: $OUT"
[ "$RC" -ne 0 ] || fail "AW12: bare repository refusal exited 0"
[ "$(git --git-dir="$T/bare/archive.git" rev-parse HEAD 2>/dev/null)" = "$BARE_HEAD" ] \
  || fail "AW12: unique bare repository history was deleted"
[ "$FAILS" -eq "$_b" ] && pass "AW12: ignored bare repositories retain unique history"

# ---------- AW13: recheck identity after potentially slow safety scans ----------
_b=$FAILS
mkwt raced
export TEST_BUSY_PATH="$T/raced" TEST_REPLACEMENT_SEEN="$T/replacement-scan-seen"
plan_for "$T/raced" "$(fp_for_worktree "$T/raced")" > "$T/p13.md"
OUT="$(cd "$W" && TEST_LSOF_MODE=replace-during-scan run_apply "$T/p13.md")"
[ -d "$T/raced-old" ] || fail "AW13: the scan did not replace the worktree fixture: $OUT"
printf '%s\n' "$OUT" | grep -q 'identity changed during safety checks' \
  || fail "AW13: removal-boundary identity guard was not reached: $OUT"
[ -d "$T/raced" ] || fail "AW13: a worktree replaced during safety checks was removed"
[ "$FAILS" -eq "$_b" ] && pass "AW13: replacement during safety scans invalidates approval before removal"

[ ! -s "$TEST_SIDE_EFFECT_LOG" ] || fail "apply reached a HOME-immune mutation command: $(cat "$TEST_SIDE_EFFECT_LOG")"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
