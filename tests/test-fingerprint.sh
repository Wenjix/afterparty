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

WORKTREE_ID_SUPPORTED=1
NATIVE_BIRTH="$(LC_ALL=C stat -c '%w' -- "$T/wt-a" 2>/dev/null || LC_ALL=C stat -f '%B' -- "$T/wt-a" 2>/dev/null)" || NATIVE_BIRTH=""
case "$NATIVE_BIRTH" in ''|'-'|'?'|0|0.*|-1|-1.*) WORKTREE_ID_SUPPORTED=0 ;; esac
if [ "$WORKTREE_ID_SUPPORTED" -eq 0 ]; then
  if fp_for_worktree "$T/wt-a" >/dev/null 2>&1; then
    fail "F5: host lacks creation identity but a worktree fingerprint was issued"
  fi
  echo "SKIP: F5/F11/F12/F13 live worktree identity: host stat/filesystem has no usable birth time; refusal verified"
fi
if [ "$WORKTREE_ID_SUPPORTED" -eq 1 ]; then
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
fi

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

# Keep the original inode allocated. Delete/recreate can immediately recycle
# the inode on Linux, which belongs to the controlled F10 case below.
mv "$T/proj/node_modules" "$T/proj/retired-node_modules"
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
if [ "$WORKTREE_ID_SUPPORTED" -eq 1 ]; then
  OUT2="$(bash -c 'set -uo pipefail; . '"$LIB"'/fingerprint.sh; fp_for_worktree "'"$T"'/wt-c"')" || \
    fail "F9: fp_for_worktree returned nonzero under pipefail"
  [ -n "$OUT2" ] || fail "F9: fp_for_worktree empty under pipefail"
fi
[ "$FAILS" -eq "$_b" ] && pass "F9: filesystem fingerprints survive pipefail"

# ---------- F10: same-inode replacement inside one second still drifts ----------
# Model stat's filesystem facts instead of depending on the host allocator to
# recycle an inode. Both generations have identical whole-second timestamps;
# only their fractional timestamps distinguish the replacement.
_b=$FAILS
STATSHIM="$T/stat-shim"; mkdir -p "$STATSHIM"
cat > "$STATSHIM/stat" <<'STAT'
#!/usr/bin/env bash
case "${FP_STAT_DIALECT:-gnu}:$1" in gnu:-c|bsd:-f) : ;; *) exit 1 ;; esac
fmt="$2"
ns=123456781
[ "${FP_STAT_GENERATION:-1}" = 2 ] && ns=123456789
fmt="${fmt//%d/42}"; fmt="${fmt//%i/12345}"
fmt="${fmt//%Y/1780000000}"; fmt="${fmt//%Z/1780000000}"
fmt="${fmt//%W/1780000000}"
stamp="2026-05-28 20:26:40.$ns +0000"
fmt="${fmt//%y/$stamp}"; fmt="${fmt//%z/$stamp}"
birth="$stamp"; [ "${FP_STAT_BIRTH_MISSING:-0}" = 1 ] && birth=-
fmt="${fmt//%w/$birth}"
for field in m c B; do
  fmt="${fmt//%.9F$field/1780000000.$ns}"
  fmt="${fmt//%F$field/1780000000.123456}"
  fmt="${fmt//%$field/1780000000}"
done
printf '%s\n' "$fmt"
STAT
chmod +x "$STATSHIM/stat"
for dialect in gnu bsd; do
  S1="$(PATH="$STATSHIM:$PATH" FP_STAT_DIALECT="$dialect" FP_STAT_GENERATION=1 fp_for_artifact "$T/proj/node_modules")"
  S2="$(PATH="$STATSHIM:$PATH" FP_STAT_DIALECT="$dialect" FP_STAT_GENERATION=1 fp_for_artifact "$T/proj/node_modules")"
  S3="$(PATH="$STATSHIM:$PATH" FP_STAT_DIALECT="$dialect" FP_STAT_GENERATION=2 fp_for_artifact "$T/proj/node_modules")"
  [ -n "$S1" ] && [ "$S1" = "$S2" ] || fail "F10: $dialect controlled identity is not stable"
  [ "$S1" != "$S3" ] || fail "F10: $dialect same-inode replacement within one second kept the approval"
done
[ "$FAILS" -eq "$_b" ] && pass "F10: fractional timestamps detect controlled inode reuse"

# ---------- F11: same path and commit cannot authorize a replacement ----------
if [ "$WORKTREE_ID_SUPPORTED" -eq 1 ]; then
_b=$FAILS
git -C "$W" worktree add -q --detach "$T/identity-wt" HEAD
I1="$(fp_for_worktree "$T/identity-wt")"
git -C "$W" worktree move "$T/identity-wt" "$T/retired-identity-wt"
git -C "$W" worktree add -q --detach "$T/identity-wt" HEAD
I2="$(fp_for_worktree "$T/identity-wt")"
[ "$I1" != "$I2" ] || fail "F11: replacement from the same repo kept the old approval"
git clone -q "$W" "$T/other-owner"
git -C "$W" worktree move "$T/identity-wt" "$T/retired-identity-wt-2"
git -C "$T/other-owner" worktree add -q --detach "$T/identity-wt" HEAD
I3="$(fp_for_worktree "$T/identity-wt")"
[ "$I2" != "$I3" ] || fail "F11: replacement from another clone kept the old approval"
[ "$I3" = "$(fp_for_worktree "$T/identity-wt")" ] \
  || fail "F11: an unchanged replacement does not fingerprint stably"
[ "$FAILS" -eq "$_b" ] && pass "F11: same-path replacements from either repo invalidate approval"

# ---------- F12: changing only the owning Git identity invalidates approval ----------
# Repoint the existing physical directory to an equivalent worktree's admin
# directory. HEAD, branch, cleanliness and the target inode remain unchanged;
# a path/inode-only hash would miss the changed repository ownership.
_b=$FAILS
git -C "$W" worktree add -q --detach "$T/owner-a" HEAD
git -C "$T/other-owner" worktree add -q --detach "$T/owner-b" HEAD
O1="$(fp_for_worktree "$T/owner-a")"
cat "$T/owner-b/.git" > "$T/owner-a/.git"
O2="$(fp_for_worktree "$T/owner-a")"
[ "$O1" != "$O2" ] || fail "F12: switching Git ownership kept the old approval"
[ "$FAILS" -eq "$_b" ] && pass "F12: Git administrative ownership is part of identity"

# ---------- F13: status refresh and ignored builds preserve identity ----------
_b=$FAILS
printf 'tracked\n' > "$W/tracked"
printf '.cache/\n' > "$W/.gitignore"
git -C "$W" add tracked .gitignore
git -C "$W" commit -q -m 'tracked stability fixture'
git -C "$W" worktree add -q --detach "$T/status-stable" HEAD
R1="$(fp_for_worktree "$T/status-stable")"
touch -t 202001010000 "$T/status-stable/tracked"
mkdir "$T/status-stable/.cache"
git -C "$T/status-stable" status --porcelain > "$T/status-output"
[ ! -s "$T/status-output" ] || fail "F13: fixture is not clean after metadata-only changes"
R2="$(fp_for_worktree "$T/status-stable")"
[ -n "$R1" ] && [ "$R1" = "$R2" ] \
  || fail "F13: status refresh or ignored output invalidated an unchanged worktree"
[ "$FAILS" -eq "$_b" ] && pass "F13: mutable Git metadata and ignored output do not cause drift"
fi

# ---------- F14: missing creation identity cannot authorize deletion ----------
_b=$FAILS
if PATH="$STATSHIM:$PATH" FP_STAT_BIRTH_MISSING=1 fp_for_worktree "$T/wt-a" > "$T/no-birth-fp"; then
  fail "F14: fingerprinted a worktree without usable creation identity"
fi
[ ! -s "$T/no-birth-fp" ] || fail "F14: missing creation identity produced an approval token"
[ "$FAILS" -eq "$_b" ] && pass "F14: unavailable creation identity fails closed"

# ---------- F15: worktree creation identity detects controlled inode reuse ----------
_b=$FAILS
for dialect in gnu bsd; do
  G1="$(PATH="$STATSHIM:$PATH" FP_STAT_DIALECT="$dialect" FP_STAT_GENERATION=1 fp_for_worktree "$T/wt-a")"
  G2="$(PATH="$STATSHIM:$PATH" FP_STAT_DIALECT="$dialect" FP_STAT_GENERATION=2 fp_for_worktree "$T/wt-a")"
  [ -n "$G1" ] && [ -n "$G2" ] && [ "$G1" != "$G2" ] \
    || fail "F15: $dialect worktree creation time was lost when the inode was reused"
done
[ "$FAILS" -eq "$_b" ] && pass "F15: worktree identity retains fractional creation time"

# ---------- F16: a new physical directory cannot inherit existing Git identity ----------
if [ "$WORKTREE_ID_SUPPORTED" -eq 1 ]; then
  _b=$FAILS
  INITIAL="$(git -C "$W" rev-list --max-parents=0 HEAD)"
  git -C "$W" worktree add -q --detach "$T/physical-wt" "$INITIAL"
  P1="$(fp_for_worktree "$T/physical-wt")"
  # A plain move retains the Git administration at exactly the same path and
  # inode. Recreating only the worktree directory isolates its physical ID.
  mv "$T/physical-wt" "$T/retired-physical-wt"
  mkdir "$T/physical-wt"
  cp "$T/retired-physical-wt/.git" "$T/physical-wt/.git"
  P2="$(fp_for_worktree "$T/physical-wt")"
  [ -n "$P1" ] && [ -n "$P2" ] && [ "$P1" != "$P2" ] \
    || fail "F16: replacing only the physical worktree directory inherited approval"
  [ "$FAILS" -eq "$_b" ] && pass "F16: the physical target is bound independently of Git administration"
fi

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
