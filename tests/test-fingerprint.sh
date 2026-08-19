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

[ "$FAILS" -eq 0 ] || echo "$FAILS check(s) failed" >&2
exit $((FAILS > 0))
