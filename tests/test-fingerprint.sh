#!/usr/bin/env bash
# Fingerprint identity: the thing that makes an approval bind to what was
# reviewed. A fingerprint must be stable across time but change when a pgid is
# recycled by a different process -- otherwise apply kills whatever drifted
# into the slot.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT

# shellcheck source=/dev/null
. "$LIB/fingerprint.sh"

# ---------- F1: fp_hash is stable, short, and input-sensitive ----------
_b=$FAILS
A="$(printf 'same input' | fp_hash)"
B="$(printf 'same input' | fp_hash)"
C="$(printf 'other input' | fp_hash)"
[ -n "$A" ] || fail "F1: fp_hash produced nothing"
[ "$A" = "$B" ] || fail "F1: fp_hash not deterministic ($A vs $B)"
[ "$A" != "$C" ] || fail "F1: different input hashed the same"
case "$A" in [0-9a-f]*) : ;; *) fail "F1: hash is not hex: $A" ;; esac
[ "${#A}" -eq 12 ] || fail "F1: hash length ${#A}, want 12"
[ "$FAILS" -eq "$_b" ] && pass "F1: fp_hash deterministic, hex, 12 chars"

# ---------- F2: a group fingerprints stably, and recycling changes it ----------
# Fake ps so the "same group, later" and "same pgid, different process" cases
# are exact rather than timing-dependent.
SHIM="$T/shim"; mkdir -p "$SHIM"
mkps() {
  cat > "$SHIM/ps" <<PS
#!/usr/bin/env bash
case "\$*" in
  *pgid=,lstart=,command=*) printf '5150 $1 $2\n' ;;
  *) exit 1 ;;
esac
PS
  chmod +x "$SHIM/ps"
}
_b=$FAILS
mkps "Tue Aug 18 09:00:00 2026" "npm run dev"
FP1="$(PATH="$SHIM:$PATH" fp_for_pgid 5150)"
FP2="$(PATH="$SHIM:$PATH" fp_for_pgid 5150)"
[ -n "$FP1" ] || fail "F2: no fingerprint for a live group"
[ "$FP1" = "$FP2" ] || fail "F2: same group fingerprinted differently"

# same pgid, same command, but started later -- a recycled pgid
mkps "Tue Aug 18 11:30:00 2026" "npm run dev"
FP3="$(PATH="$SHIM:$PATH" fp_for_pgid 5150)"
[ "$FP1" != "$FP3" ] || fail "F2: recycled pgid kept the old fingerprint"

# same pgid, same start, different command
mkps "Tue Aug 18 09:00:00 2026" "rm -rf /"
FP4="$(PATH="$SHIM:$PATH" fp_for_pgid 5150)"
[ "$FP1" != "$FP4" ] || fail "F2: different command kept the old fingerprint"
[ "$FAILS" -eq "$_b" ] && pass "F2: stable per group, changes on recycle or command swap"

# ---------- F3: a gone group fails closed ----------
_b=$FAILS
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/ps"; chmod +x "$SHIM/ps"
if PATH="$SHIM:$PATH" fp_for_pgid 5150 >/dev/null 2>&1; then
  fail "F3: fingerprinted a group that no longer exists"
else
  pass "F3: absent group fails closed"
fi

# ---------- F4: survives a long ps under pipefail ----------
# The shims above emit a handful of lines, which is exactly the condition that
# HIDES this bug. Callers run with `set -o pipefail`, and an awk that quits
# mid-stream SIGPIPEs ps, so the pipeline reports failure even though the value
# was captured. Against a real ps -- hundreds of lines -- every fingerprint
# came back empty and every eligible item was withheld as "vanished".
_b=$FAILS
cat > "$SHIM/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  *pgid=,lstart=,command=*)
    printf '5150 Tue Aug 18 09:00:00 2026 npm run dev
'
    i=0; while [ "$i" -lt 5000 ]; do printf '9%03d Tue Aug 18 09:00:00 2026 filler %s
' "$((i % 1000))" "$i"; i=$((i + 1)); done
    ;;
  *) exit 1 ;;
esac
PS
chmod +x "$SHIM/ps"
LONG="$(PATH="$SHIM:$PATH" bash -c 'set -uo pipefail; . '"$LIB"'/fingerprint.sh; fp_for_pgid 5150')"
[ -n "$LONG" ] || fail "F4: fingerprint empty when ps output is long and pipefail is set"
[ "$FAILS" -eq "$_b" ] && pass "F4: long ps output under pipefail still fingerprints"

# ---------- F5: a worktree fingerprint binds to its committed state ----------
# The identity question for a worktree is not "is this path still here" -- it is
# "is this still the worktree I looked at". Someone committing inside it, or
# dirtying it, between plan and apply means the thing under review changed.
_b=$FAILS
W="$T/wtrepo"
git init -qb main "$W" >/dev/null 2>&1
git -C "$W" config user.email t@t.local
git -C "$W" config user.name tester
git -C "$W" commit -q --allow-empty -m one
git -C "$W" worktree add -q "$T/wt-a" -b agent/a HEAD 2>/dev/null

WA1="$(fp_for_worktree "$T/wt-a")"
WA2="$(fp_for_worktree "$T/wt-a")"
[ -n "$WA1" ] || fail "F5: no fingerprint for a live worktree"
[ "$WA1" = "$WA2" ] || fail "F5: same worktree fingerprinted differently ($WA1 vs $WA2)"

printf 'scratch\n' > "$T/wt-a/untracked.txt"
WA3="$(fp_for_worktree "$T/wt-a")"
[ "$WA1" != "$WA3" ] || fail "F5: dirtying the worktree left the fingerprint unchanged"
rm -f "$T/wt-a/untracked.txt"

git -C "$T/wt-a" commit -q --allow-empty -m two
WA4="$(fp_for_worktree "$T/wt-a")"
[ "$WA1" != "$WA4" ] || fail "F5: a new commit left the fingerprint unchanged"

# Two worktrees that differ ONLY by path must not collide. Branching them
# apart would make this pass on the branch name alone -- verified: dropping the
# path from the hash entirely left the case green. Detached at the same commit
# is the fixture that isolates path, since HEAD, branch ("HEAD") and
# cleanliness are then identical.
git -C "$W" worktree add -q --detach "$T/wt-c" HEAD 2>/dev/null
git -C "$W" worktree add -q --detach "$T/wt-d" HEAD 2>/dev/null
[ "$(git -C "$T/wt-c" rev-parse HEAD)" = "$(git -C "$T/wt-d" rev-parse HEAD)" ] \
  || fail "F5: fixture broken — the two detached worktrees are not at the same commit"
[ "$(git -C "$T/wt-c" rev-parse --abbrev-ref HEAD)" = "$(git -C "$T/wt-d" rev-parse --abbrev-ref HEAD)" ] \
  || fail "F5: fixture broken — the two detached worktrees report different branches"
[ "$(fp_for_worktree "$T/wt-c")" != "$(fp_for_worktree "$T/wt-d")" ] \
  || fail "F5: two worktrees differing only by path share a fingerprint"
[ "$FAILS" -eq "$_b" ] && pass "F5: worktree identity tracks path, HEAD, branch and cleanliness"

# ---------- F6: a removed worktree fails closed ----------
_b=$FAILS
if fp_for_worktree "$T/no-such-worktree" >/dev/null 2>&1; then
  fail "F6: fingerprinted a worktree that does not exist"
fi
[ "$FAILS" -eq "$_b" ] && pass "F6: absent worktree fails closed"

# ---------- F7: an artifact fingerprint detects a swapped directory ----------
# A path is a name, not a thing. Between plan and apply the name can come to
# point at a different directory -- a reinstall, a checkout, a restore from
# backup. Same name, different inode: that is not the item that was reviewed.
_b=$FAILS
mkdir -p "$T/proj/node_modules"
printf 'a\n' > "$T/proj/node_modules/pkg"
A1="$(fp_for_artifact "$T/proj/node_modules")"
A2="$(fp_for_artifact "$T/proj/node_modules")"
[ -n "$A1" ] || fail "F7: no fingerprint for an existing artifact dir"
[ "$A1" = "$A2" ] || fail "F7: same directory fingerprinted differently"

rm -rf "$T/proj/node_modules"
mkdir -p "$T/proj/node_modules"
printf 'a\n' > "$T/proj/node_modules/pkg"
A3="$(fp_for_artifact "$T/proj/node_modules")"
[ "$A1" != "$A3" ] || fail "F7: a replaced directory kept the old fingerprint"
[ "$FAILS" -eq "$_b" ] && pass "F7: artifact identity moves when the directory is replaced"

# ---------- F8: an absent artifact fails closed ----------
_b=$FAILS
if fp_for_artifact "$T/proj/never-here" >/dev/null 2>&1; then
  fail "F8: fingerprinted an artifact that does not exist"
fi
[ "$FAILS" -eq "$_b" ] && pass "F8: absent artifact fails closed"

# ---------- F9: filesystem fingerprints survive pipefail ----------
# Same hazard F4 pins for processes: these run inside scripts with
# `set -o pipefail`, so any internal pipe that closes early would report
# failure with the value correctly captured.
_b=$FAILS
OUT="$(bash -c 'set -uo pipefail; . '"$LIB"'/fingerprint.sh; fp_for_artifact "'"$T"'/proj/node_modules"')" ||   fail "F9: fp_for_artifact returned nonzero under pipefail"
[ -n "$OUT" ] || fail "F9: fp_for_artifact empty under pipefail"
OUT2="$(bash -c 'set -uo pipefail; . '"$LIB"'/fingerprint.sh; fp_for_worktree "'"$T"'/wt-c"')" || \
  fail "F9: fp_for_worktree returned nonzero under pipefail"
[ -n "$OUT2" ] || fail "F9: fp_for_worktree empty under pipefail"
[ "$FAILS" -eq "$_b" ] && pass "F9: filesystem fingerprints survive pipefail"

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
