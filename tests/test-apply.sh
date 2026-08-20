#!/usr/bin/env bash
# apply executes only what was checked, only if it is still what was reviewed,
# and it never signals anything itself -- it delegates to the audit path that
# already carries the protect list and postcondition receipts.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

# A stand-in for audit-processes.sh that records the argv it was handed instead
# of killing anything. Nothing in this suite may signal a real process.
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/audit-processes.sh" <<AP
#!/usr/bin/env bash
echo "\$*" >> "$T/delegated"
exit 0
AP
chmod +x "$SHIM/audit-processes.sh"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*)
    printf '7001 Tue Aug 18 09:00:00 2026 npm run dev\n'
    printf '7002 Tue Aug 18 09:00:00 2026 vitest --watch\n'
    ;;
  *pid,pgid,%cpu*)
    printf '7001 7001 0.0 npm run dev\n'
    printf '7002 7002 0.0 vitest --watch\n'
    ;;
  *) exit 1 ;;
esac
PS
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in
  *-d\ cwd*) printf 'p7001\nfcwd\nn/w/loupe\np7002\nfcwd\nn/w/loupe\n' ;;
  *) exit 1 ;;
esac
LS
chmod +x "$SHIM/ps" "$SHIM/lsof"

# Default world: /w/loupe was last touched long ago and is quiet, so an
# approved group in it is still eligible when apply runs. A8 overrides this
# with a freshly-touched root to prove the re-check bites.
RIDLE="$T/proj-idle"; mkdir -p "$RIDLE/-w-loupe"
printf '{"cwd":"/w/loupe"}\n' > "$RIDLE/-w-loupe/a.jsonl"
touch -t 202001010000 "$RIDLE/-w-loupe/a.jsonl" 2>/dev/null \
  || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$RIDLE/-w-loupe/a.jsonl"

# shellcheck source=/dev/null
. "$LIB/fingerprint.sh"
FP7001="$(PATH="$SHIM:$PATH" fp_for_pgid 7001)"

mkplan() {
  cat > "$T/plan.md" <<PL
# afterparty plan

## Process groups

- [x] eligible  pgid 7001  loupe · 3 procs · idle 6h · cpu 0.0
      category: dev  fingerprint: $1
- [ ] eligible  pgid 7002  streams · 1 proc · idle 9h · cpu 0.0
      category: tests  fingerprint: deadbeef1234
- [⊘] in-use    pgid 7003  here · 2 procs · idle just now · cpu 1.0
      not offered: that workspace was touched recently
PL
}

run_apply() {
  PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$RIDLE" AFTERPARTY_STYLE=never \
    bash "$LIB/apply.sh" "$T/plan.md" 2>&1
}

# ---------- A1: only the checked, unmoved item is delegated ----------
_b=$FAILS
: > "$T/delegated"; mkplan "$FP7001"
OUT="$(run_apply)"
if ! grep -q '7001' "$T/delegated"; then
  fail "A1: approved item was not delegated"
  echo "    apply said: $(printf '%s' "$OUT" | tr '\n' '|')" >&2
  echo "    ps: [$(PATH="$SHIM:$PATH" ps -Ao pid,pgid,%cpu 2>&1 | head -1)]" >&2
  echo "    ws: [$(AFTERPARTY_TRANSCRIPT_ROOT="$RIDLE" bash -c '. '"$LIB"'/workspace.sh; ws_index' 2>&1 | head -1)]" >&2
fi
grep -q '7002' "$T/delegated" && fail "A1: an UNCHECKED item was delegated"
grep -q '7003' "$T/delegated" && fail "A1: a withheld item was delegated"
grep -q 'kill' "$T/delegated"  || fail "A1: delegation did not use the kill path"
grep -q 'dev'  "$T/delegated"  || fail "A1: delegation lost the category"
[ "$FAILS" -eq "$_b" ] && pass "A1: only the checked item is delegated, with its category"

# ---------- A2: a moved fingerprint is refused, not re-targeted ----------
_b=$FAILS
: > "$T/delegated"; mkplan "0000deadbeef"
OUT="$(run_apply)"
[ -s "$T/delegated" ] && fail "A2: acted on an item whose fingerprint moved"
# Anchored on the pgid-bearing per-item line. The receipt summary hardcodes the
# words "refused", "drift" and "held" in its format string regardless of the
# counters, so a bare word match passed on every exit path and the per-item
# explanations were entirely uncovered. At 20 workspaces the operator needs to
# know WHICH group drifted, not that some number did.
printf '%s\n' "$OUT" | grep -q 'pgid 7001 .*fingerprint moved' \
  || fail "A2: no per-item drift line naming pgid 7001: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "A2: drifted item refused and reported"

# ---------- A3: a vanished group is refused, never re-targeted ----------
_b=$FAILS
: > "$T/delegated"; mkplan "$FP7001"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/ps"; chmod +x "$SHIM/ps"
OUT="$(run_apply)"
[ -s "$T/delegated" ] && fail "A3: acted on a group that no longer exists"
printf '%s\n' "$OUT" | grep -q 'pgid 7001 .*gone' \
  || fail "A3: no per-item line explaining the group is gone: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "A3: vanished group refused, and said so per item"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*) printf '7001 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
  *pid,pgid,%cpu*)          printf '7001 7001 0.0 npm run dev\n' ;;
  *) exit 1 ;;
esac
PS
chmod +x "$SHIM/ps"

# ---------- A4: a missing plan fails loudly, never "nothing to do" ----------
_b=$FAILS
if PATH="$SHIM:$PATH" bash "$LIB/apply.sh" "$T/absent.md" >/dev/null 2>&1; then
  fail "A4: a missing plan exited 0"
fi
[ "$FAILS" -eq "$_b" ] && pass "A4: a missing plan is an error, not a no-op"

# ---------- A5: apply reports a receipt naming each outcome ----------
_b=$FAILS
: > "$T/delegated"; mkplan "$FP7001"
OUT="$(run_apply)"
printf '%s\n' "$OUT" | grep -q '7001' || fail "A5: receipt does not name the item acted on"
[ "$FAILS" -eq "$_b" ] && pass "A5: receipt names what happened"

# ---------- A6: a withheld item is inert even with a valid fingerprint ----------
# The adversarial edit: someone unchecks a box but leaves its fingerprint line
# intact. The box is the authority; the fingerprint only proves identity.
_b=$FAILS
: > "$T/delegated"
cat > "$T/plan.md" <<PL
# afterparty plan

## Process groups

- [⊘] in-use    pgid 7001  loupe · 3 procs · idle 6h · cpu 0.0
      category: dev  fingerprint: $FP7001
PL
OUT="$(run_apply)"
[ -s "$T/delegated" ] && fail "A6: acted on a withheld item that still had a fingerprint"
[ "$FAILS" -eq "$_b" ] && pass "A6: the checkbox is the authority, not the fingerprint"

# ---------- A7: apply never signals directly ----------
# It must reach the audit path for every kill; a bare "kill" in apply.sh would
# mean a second kill discipline drifting from the protect list.
_b=$FAILS
grep -nE '^[^#]*\bkill -' "$LIB/apply.sh" && fail "A7: apply signals a process directly"
[ "$FAILS" -eq "$_b" ] && pass "A7: apply delegates every kill, never signals"

# ---------- A8: eligibility is re-checked at apply time ----------
# A group can go from idle to active without its fingerprint changing: the
# same processes, but the human came back. The plan header promises apply
# re-checks eligibility; it must actually do it.
_b=$FAILS
: > "$T/delegated"
R2="$T/proj2"; mkdir -p "$R2/-w-loupe"
printf '{"cwd":"/w/loupe"}\n' > "$R2/-w-loupe/a.jsonl"   # touched NOW -> in-use
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in
  *-d\ cwd*) printf 'p7001\nfcwd\nn/w/loupe\n' ;;
  *) exit 1 ;;
esac
LS
chmod +x "$SHIM/lsof"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*) printf '7001 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
  *pid,pgid,%cpu*)          printf '7001 7001 0.0 npm run dev\n' ;;
  *) exit 1 ;;
esac
PS
chmod +x "$SHIM/ps"
FPNOW="$(PATH="$SHIM:$PATH" fp_for_pgid 7001)"
mkplan "$FPNOW"
OUT="$(PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$R2" AFTERPARTY_STYLE=never bash "$LIB/apply.sh" "$T/plan.md" 2>&1)"
[ -s "$T/delegated" ] && fail "A8: killed a group whose workspace became active again"
printf '%s\n' "$OUT" | grep -q 'pgid 7001 .*no longer eligible' \
  || fail "A8: no per-item line naming pgid 7001 as no longer eligible: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "A8: eligibility re-checked at apply time, not just fingerprint"

# ---------- A9: a failed delegation must not exit 0 ----------
# Mutation receipts are postcondition-based; swallowing a failure reports
# success for work that did not happen.
_b=$FAILS
: > "$T/delegated"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 3\n' "$T/delegated" > "$SHIM/audit-processes.sh"
chmod +x "$SHIM/audit-processes.sh"
mkplan "$FPNOW"
run_apply >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail "A9: delegation failed but apply exited 0"
[ "$FAILS" -eq "$_b" ] && pass "A9: a failed delegation exits nonzero"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$T/delegated" > "$SHIM/audit-processes.sh"
chmod +x "$SHIM/audit-processes.sh"

# ---------- A10: apply passes the expected identity to audit ----------
# apply's own last check still leaves a window before audit signals. Identity
# must be enforced where the signal happens, so it has to travel with it.
_b=$FAILS
: > "$T/delegated"; mkplan "$FPNOW"
run_apply >/dev/null 2>&1
grep -q -- '--expect' "$T/delegated" || fail "A10: delegation did not carry --expect"
grep -q "$FPNOW" "$T/delegated" || fail "A10: delegation did not carry the approved fingerprint"
[ "$FAILS" -eq "$_b" ] && pass "A10: the approved identity travels to the signal boundary"

# ---------- A11: a group that gained a member elsewhere is held ----------
# The leader is unchanged, so the fingerprint still matches -- but the group
# now has a foot in a workspace someone is using, and killing it would take
# that with it. plan withholds mixed groups; apply must re-check the same way.
_b=$FAILS
: > "$T/delegated"
RMIX="$T/proj-mix"; mkdir -p "$RMIX/-w-loupe" "$RMIX/-w-active"
printf '{"cwd":"/w/loupe"}\n'  > "$RMIX/-w-loupe/a.jsonl"
printf '{"cwd":"/w/active"}\n' > "$RMIX/-w-active/b.jsonl"
touch -t 202001010000 "$RMIX/-w-loupe/a.jsonl" 2>/dev/null \
  || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$RMIX/-w-loupe/a.jsonl"
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in
  *-d\ cwd*) printf 'p7001\nfcwd\nn/w/loupe\np7009\nfcwd\nn/w/active\n' ;;
  *) exit 1 ;;
esac
LS
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*) printf '7001 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
  *pid,pgid,%cpu*)
    printf '7001 7001 0.0 npm run dev\n'
    printf '7009 7001 0.0 node child.js\n'
    ;;
  *) exit 1 ;;
esac
PS
chmod +x "$SHIM/ps" "$SHIM/lsof"
FPMIX="$(PATH="$SHIM:$PATH" fp_for_pgid 7001)"
mkplan "$FPMIX"
OUT="$(PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$RMIX" AFTERPARTY_STYLE=never bash "$LIB/apply.sh" "$T/plan.md" 2>&1)"
[ -s "$T/delegated" ] && fail "A11: killed a group that had gained a member in another workspace"
printf '%s\n' "$OUT" | grep -qi 'mixed\|more than one workspace' || fail "A11: mixed ownership not reported: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "A11: a group spanning workspaces is held at apply time too"

# ---------- A12: the free-text reason is recorded, not dropped ----------
_b=$FAILS
J="$T/journal"; mkdir -p "$J"
# restore the single-group world so A12 exercises the reason path, not A11's
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in
  *-d\ cwd*) printf 'p7001\nfcwd\nn/w/loupe\n' ;;
  *) exit 1 ;;
esac
LS
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*) printf '7001 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
  *pid,pgid,%cpu*)          printf '7001 7001 0.0 npm run dev\n' ;;
  *) exit 1 ;;
esac
PS
chmod +x "$SHIM/ps" "$SHIM/lsof"
mkplan "$(PATH="$SHIM:$PATH" fp_for_pgid 7001)"
cat >> "$T/plan.md" <<'PL'

## Why
> keeping the loupe server off until Monday
PL
XDG_CACHE_HOME="$J" run_apply >/dev/null 2>&1
if grep -rq 'keeping the loupe server off' "$J" 2>/dev/null; then
  pass "A12: the reason reaches the journal"
else
  fail "A12: plan promises apply records '## Why'; it was dropped"
fi

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
