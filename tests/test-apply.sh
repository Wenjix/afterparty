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
  *) exit 1 ;;
esac
PS
chmod +x "$SHIM/ps"

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

run_apply() { PATH="$SHIM:$PATH" AFTERPARTY_STYLE=never bash "$LIB/apply.sh" "$T/plan.md" 2>&1; }

# ---------- A1: only the checked, unmoved item is delegated ----------
_b=$FAILS
: > "$T/delegated"; mkplan "$FP7001"
OUT="$(run_apply)"
grep -q '7001' "$T/delegated" || fail "A1: approved item was not delegated"
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
printf '%s\n' "$OUT" | grep -qi 'refus\|moved\|drift' || fail "A2: drift was not reported: $OUT"
[ "$FAILS" -eq "$_b" ] && pass "A2: drifted item refused and reported"

# ---------- A3: a vanished group is refused, never re-targeted ----------
_b=$FAILS
: > "$T/delegated"; mkplan "$FP7001"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/ps"; chmod +x "$SHIM/ps"
OUT="$(run_apply)"
[ -s "$T/delegated" ] && fail "A3: acted on a group that no longer exists"
[ "$FAILS" -eq "$_b" ] && pass "A3: vanished group refused"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*) printf '7001 Tue Aug 18 09:00:00 2026 npm run dev\n' ;;
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

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
