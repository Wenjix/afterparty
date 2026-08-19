#!/usr/bin/env bash
# plan writes a proposal, not a decision. What it checks by default, and what
# it refuses to check, is the whole point of the surface.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

# world: /w/gone is idle+quiet (offer it), /w/here is fresh (never offer),
# /w/busy is idle but burning cpu (a long task, not an abandonment),
# /w/nosig has processes but NO transcript (no signal -> never offer).
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*)
    printf '9001 Tue Aug 18 09:00:00 2026 npm run dev\n'
    printf '9002 Tue Aug 18 09:00:00 2026 vitest --watch\n'
    printf '9003 Tue Aug 18 09:00:00 2026 next dev\n'
    printf '9004 Tue Aug 18 09:00:00 2026 node server.js\n'
    ;;
  *pid,pgid,%cpu,command*)
    printf '9001 9001  0.0 npm run dev\n'
    printf '9002 9002  1.0 vitest --watch\n'
    printf '9003 9003 95.0 next dev\n'
    printf '9004 9004  0.0 node server.js\n'
    ;;
  *) exit 1 ;;
esac
PS
cat > "$SHIM/lsof" <<'LS'
#!/usr/bin/env bash
case "$*" in
  *-d\ cwd*)
    printf 'p9001\nfcwd\nn/w/gone\n'
    printf 'p9002\nfcwd\nn/w/here\n'
    printf 'p9003\nfcwd\nn/w/busy\n'
    printf 'p9004\nfcwd\nn/w/nosig\n'
    ;;
  *) exit 1 ;;
esac
LS
chmod +x "$SHIM/ps" "$SHIM/lsof"

R="$T/projects"; mkdir -p "$R/-w-gone" "$R/-w-here" "$R/-w-busy"
printf '{"cwd":"/w/gone"}\n' > "$R/-w-gone/a.jsonl"
printf '{"cwd":"/w/here"}\n' > "$R/-w-here/b.jsonl"
printf '{"cwd":"/w/busy"}\n' > "$R/-w-busy/c.jsonl"
for f in "$R/-w-gone/a.jsonl" "$R/-w-busy/c.jsonl"; do
  touch -t 202001010000 "$f" 2>/dev/null || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$f"
done

OUT="$(PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$R" AFTERPARTY_STYLE=never \
  bash "$LIB/plan.sh" 2>/dev/null)"

# ---------- P1: idle and quiet is proposed, checked ----------
if printf '%s\n' "$OUT" | grep -qE '^- \[x\].*9001'; then
  pass "P1: idle+quiet workspace is proposed checked"
else
  fail "P1: pgid 9001 should be checked: $(printf '%s\n' "$OUT" | grep 9001)"
fi

# ---------- P2: the three not-offered verdicts are never checked ----------
_b=$FAILS
while IFS='|' read -r pg why; do
  line="$(printf '%s\n' "$OUT" | grep "$pg" | head -1)"
  case "$line" in
    '- [x]'*) fail "P2: $pg ($why) was offered checked: $line" ;;
    '') fail "P2: $pg ($why) missing from the plan entirely" ;;
  esac
done <<'CASES'
9002|fresh workspace, in use
9003|idle but burning cpu, still working
9004|processes but no transcript, no signal
CASES
[ "$FAILS" -eq "$_b" ] && pass "P2: in-use, working, and unknown are never pre-checked"

# ---------- P3: every actionable line carries a fingerprint ----------
_b=$FAILS
N_CHECKED="$(printf '%s\n' "$OUT" | grep -cE '^- \[x\]')"
N_FP="$(printf '%s\n' "$OUT" | grep -cE 'fingerprint: [0-9a-f]{12}')"
[ "$N_CHECKED" -ge 1 ] || fail "P3: nothing was checked at all"
[ "$N_FP" -ge "$N_CHECKED" ] || fail "P3: $N_CHECKED checked but only $N_FP fingerprints"
[ "$FAILS" -eq "$_b" ] && pass "P3: every checked item carries a fingerprint"

# ---------- P4: the reason a thing was withheld is stated, not implied ----------
_b=$FAILS
printf '%s\n' "$OUT" | grep -q 'in-use'  || fail "P4: no in-use reason shown"
printf '%s\n' "$OUT" | grep -q 'working' || fail "P4: no working reason shown"
printf '%s\n' "$OUT" | grep -q 'unknown' || fail "P4: no unknown reason shown"
[ "$FAILS" -eq "$_b" ] && pass "P4: each withheld item states why"

# ---------- P5: planning is not acting ----------
_b=$FAILS
printf '%s\n' "$OUT" | grep -qi 'killed\|removed\|reclaimed' && fail "P5: plan claimed to have done something"
[ "$FAILS" -eq "$_b" ] && pass "P5: plan proposes, never reports action"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
