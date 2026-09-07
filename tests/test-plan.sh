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
# Isolate automatic Codex discovery even when CODEX_HOME is inherited.
export AFTERPARTY_CODEX_ROOT="$T/codex-index"
trap 'cd /; rm -rf "$T"' EXIT

# world: /w/gone is idle+quiet (offer it), /w/here is fresh (never offer),
# /w/busy is idle but burning cpu (a long task, not an abandonment),
# /w/nosig has processes but NO transcript (no signal -> never offer).
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,command=*) printf '9001 npm run dev\n9002 vitest --watch\n9003 next dev\n' ;;
  *pgid=,lstart=,command=*)
    printf '9001 Tue Aug 18 09:00:00 2026 npm run dev\n'
    printf '9002 Tue Aug 18 09:00:00 2026 vitest --watch\n'
    printf '9003 Tue Aug 18 09:00:00 2026 next dev\n'
    printf '9004 Tue Aug 18 09:00:00 2026 node server.js\n'
    printf '9005 Tue Aug 18 09:00:00 2026 /usr/libexec/systemdaemon\n'
    printf '9006 Tue Aug 18 09:00:00 2026 npm run dev\n'
    printf '9010 Tue Aug 18 09:00:00 2026 node server.js\n'
    ;;
  *pid,pgid,%cpu,command*)
    printf '9001 9001  0.0 npm run dev\n'
    printf '9002 9002  1.0 vitest --watch\n'
    printf '9003 9003 95.0 next dev\n'
    printf '9004 9004  0.0 node server.js\n'
    printf '9005 9005  0.0 /usr/libexec/systemdaemon\n'
    printf '9006 9006  0.0 npm run dev\n'
    printf '9010 9010  0.0 node server.js\n'
    printf '9007 9006  0.0 node worker.js\n'
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
    printf 'p9005\nfcwd\nn/\n'
    printf 'p9006\nfcwd\nn/w/gone\n'
    printf 'p9010\nfcwd\nn/w/gone\n'
    printf 'p9007\nfcwd\nn/w/here\n'
    ;;
  *) exit 1 ;;
esac
LS
# A hand-driven project: no transcript, but a real repo. That is the "unknown"
# case worth surfacing -- no staleness signal, so never offered, but shown.
# Everything else (system daemons at "/") is not a repo and drops out.
cat > "$SHIM/git" <<'GT'
#!/usr/bin/env bash
case "$*" in
  *-C\ /w/nosig*rev-parse*) exit 0 ;;
  *rev-parse*) exit 1 ;;
esac
exec /usr/bin/git "$@"
GT
chmod +x "$SHIM/ps" "$SHIM/lsof" "$SHIM/git"

R="$T/projects"; mkdir -p "$R/-w-gone" "$R/-w-here" "$R/-w-busy"
printf '{"cwd":"/w/gone"}\n' > "$R/-w-gone/a.jsonl"
printf '{"cwd":"/w/here"}\n' > "$R/-w-here/b.jsonl"
printf '{"cwd":"/w/busy"}\n' > "$R/-w-busy/c.jsonl"
for f in "$R/-w-gone/a.jsonl" "$R/-w-busy/c.jsonl"; do
  touch -t 202001010000 "$f" 2>/dev/null || touch -t "$(date -v -300d +%Y%m%d%H%M)" "$f"
done

OUT="$(PATH="$SHIM:$PATH" AFTERPARTY_TRANSCRIPT_ROOT="$R" AFTERPARTY_STYLE=never \
  bash "$LIB/plan.sh" --all 2>/dev/null)"

# ---------- P1: idle and quiet is proposed, unchecked ----------
if printf '%s\n' "$OUT" | grep -qE '^- \[ \].*9001'; then
  pass "P1: idle+quiet workspace is proposed unchecked"
else
  fail "P1: pgid 9001 should be unchecked: $(printf '%s\n' "$OUT" | grep 9001)"
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
N_OFFERED="$(printf '%s\n' "$OUT" | grep -cE '^- \[ \]')"
N_FP="$(printf '%s\n' "$OUT" | grep -cE 'fingerprint: [0-9a-f]{12}')"
[ "$N_OFFERED" -ge 1 ] || fail "P3: nothing was offered at all"
[ "$N_FP" -ge "$N_OFFERED" ] || fail "P3: $N_OFFERED offered but only $N_FP fingerprints"
[ "$FAILS" -eq "$_b" ] && pass "P3: every offered item carries a fingerprint"

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

# ---------- P6: processes outside any workspace are not the plan's business ----------
# Every system daemon has cwd "/". Listing them would bury the handful of
# groups a person actually left behind.
_b=$FAILS
printf '%s\n' "$OUT" | grep -q '9005' && fail "P6: a daemon rooted at / reached the plan"
[ "$FAILS" -eq "$_b" ] && pass "P6: groups outside any workspace are excluded"

# ---------- P7b: an ELIGIBLE group with no kill discipline renders no-rule ----------
# pgid 9010 runs `node server.js` (no category) inside /w/gone, whose transcript
# is stale — so it passes the two-signal gate and the CATEGORY branch is the
# only thing that can withhold it. The old P7 used 9004, which lives in a
# workspace with no transcript at all: the staleness rule withheld it first as
# `unknown`, so the category guard was never entered and the no-rule branch had
# zero coverage.
_b=$FAILS
P7B_LINE="$(printf '%s\n' "$OUT" | grep '9010' | head -1)"
[ -n "$P7B_LINE" ] || fail "P7b: eligible category-less group missing from the plan"
case "$P7B_LINE" in
  '- [x]'*) fail "P7b: offered a group apply cannot execute: $P7B_LINE" ;;
esac
printf '%s\n' "$P7B_LINE" | grep -q 'no-rule' \
  || fail "P7b: verdict token is not no-rule (got: $P7B_LINE)"
printf '%s\n' "$OUT" | grep -A1 '9010' | grep -q 'no kill discipline' \
  || fail "P7b: the no-rule reason was not stated"
[ "$FAILS" -eq "$_b" ] && pass "P7b: an eligible group with no category renders no-rule, with its reason"

# ---------- P7: only groups apply can actually kill are offered ----------
# --pgid narrows WITHIN a category, so approving a group that matches no
# category would be approved and then silently not killed. 9001 is "npm run
# dev" (dev); 9004 is "node server.js", which matches nothing.
_b=$FAILS
printf '%s\n' "$OUT" | grep -A1 -E '^- \[ \].*9001' | grep -q 'category: dev' \
  || fail "P7: checked item did not record its kill category"
printf '%s\n' "$OUT" | grep -qE '^- \[x\].*9004' \
  && fail "P7: offered a group with no kill discipline"
[ "$FAILS" -eq "$_b" ] && pass "P7: only category-matching groups are offered, with the category recorded"

# ---------- P8: a group spanning two workspaces is withheld ----------
# owner was resolved per member, so the LAST row decided the whole group. A
# group with a foot in a stale workspace and a foot in an active one could be
# marked eligible off the stale member and kill work in the active one.
_b=$FAILS
printf '%s\n' "$OUT" | grep -qE '^- \[x\].*9006' && fail "P8: offered a group spanning two workspaces"
printf '%s\n' "$OUT" | grep -q 'mixed' || fail "P8: mixed ownership not reported as the reason"
[ "$FAILS" -eq "$_b" ] && pass "P8: mixed-workspace groups are withheld, with the reason"

# ---------- P9: help advertises only what the parser accepts ----------
_b=$FAILS
for flag in --all --artifacts-only --caches-only; do
  PATH="$SHIM:$PATH" bash "$LIB/plan.sh" "$flag" >/dev/null 2>&1 || fail "P9: parser rejects $flag"
done
PATH="$SHIM:$PATH" bash "$LIB/plan.sh" --root "$T" >/dev/null 2>&1 || fail 'P9: parser rejects --root DIR'
[ "$FAILS" -eq "$_b" ] && pass "P9: every advertised flag is accepted"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
