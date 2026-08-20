#!/usr/bin/env bash
# Guards on the kill path, exercised END TO END without signalling anything.
#
# `kill` is a bash builtin, so a PATH shim cannot intercept it — but bash
# exports functions to bash children, so an exported `kill` function shadows
# the builtin inside audit-processes.sh. That makes the real code path
# observable, including the reserved-pgid case, which could not otherwise be
# tested: proving `kill -TERM -1` is refused by actually running it is not a
# test anyone can afford to have wrong.
#
# The interception is PROVED before any case runs. If it is not working the
# suite skips rather than proceeding — a false-negative test is worth far less
# than a mistakenly-signalled machine.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/afterparty/lib"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
pass() { echo "ok: $*"; }
T="$(mktemp -d)"
trap 'cd /; rm -rf "$T"' EXIT
cd "$REPO" || exit 1

KILLLOG="$T/kills"
: > "$KILLLOG"
export KILLLOG
# local IFS: audit's kill loop runs under IFS=',' and "$*" joins on the FIRST
# character of IFS, so without this the log reads "kill -TERM,-77700" and every
# space-separated assertion below silently matches nothing.
kill() { local IFS=' '; echo "kill $*" >> "$KILLLOG"; return 0; }
export -f kill

# ---------- interception probe: refuse to continue unless it works ----------
printf '#!/usr/bin/env bash\nkill -TERM -424242 2>/dev/null\n' > "$T/probe.sh"
bash "$T/probe.sh"
if ! grep -q -- '-424242' "$KILLLOG"; then
  echo "SKIP: kill interception unavailable here — refusing to run kill-path tests live"
  exit 0
fi
: > "$KILLLOG"
pass "KG0: kill is intercepted, so no case below can signal anything"

mkshim() {  # mkshim <pgid> <drift:0|1>
  SHIM="$T/shim"; rm -rf "$SHIM"; mkdir -p "$SHIM"
  cat > "$SHIM/ps" <<PS
#!/usr/bin/env bash
PG=$1
DRIFT=$2
CTR="$T/ctr"
case "\$*" in
  *pid,ppid,pgid,%cpu,etime,command*)
    printf '%s 1 %s 0.0 01:00:00 /usr/local/bin/nodemon server.js\n' "\$PG" "\$PG" ;;
  *pgid=,lstart=,command=*)
    n=0; [ -f "\$CTR" ] && n=\$(cat "\$CTR"); echo \$((n + 1)) > "\$CTR"
    if [ "\$DRIFT" = "1" ] && [ "\$n" -ge 1 ]; then
      printf '%s Wed Aug 19 11:11:11 2026 /usr/local/bin/nodemon server.js\n' "\$PG"
    else
      printf '%s Tue Aug 18 09:00:00 2026 /usr/local/bin/nodemon server.js\n' "\$PG"
    fi ;;
  *-Ao\ pgid=,command=*) printf '%s /usr/local/bin/nodemon server.js\n' "\$PG" ;;
  *-Ao\ pgid=*)          printf '%s\n' "\$PG" ;;
  *-o\ pgid=*)           printf '99999\n' ;;
  *) exit 1 ;;
esac
PS
  chmod +x "$SHIM/ps"
  rm -f "$T/ctr"
}

run_kill() { PATH="$SHIM:$PATH" AFTERPARTY_STYLE=never bash "$LIB/audit-processes.sh" "$@" 2>&1; }

# ---------- KG1: an empty --pgid must not widen the kill ----------
_b=$FAILS
mkshim 77700 0
: > "$KILLLOG"
OUT="$(run_kill --kill dev --pgid '')"; rc=$?
[ "$rc" -eq 2 ] || fail "KG1: empty --pgid exited $rc, want 2"
printf '%s\n' "$OUT" | grep -qi 'empty value' || fail "KG1: refusal did not explain the empty value: $OUT"
[ -s "$KILLLOG" ] && fail "KG1: signalled something despite refusing the flag"
[ "$FAILS" -eq "$_b" ] && pass "KG1: an empty --pgid is refused, and nothing is signalled"

# ---------- KG2: process groups 0 and 1 are never signalled ----------
# -1 means every process the user owns; -0 means afterparty's own group.
for reserved in 1 0; do
  _b=$FAILS
  mkshim "$reserved" 0
  : > "$KILLLOG"
  OUT="$(run_kill --kill dev)"
  grep -qE -- "kill -(TERM|KILL) -$reserved(\$| )" "$KILLLOG" \
    && fail "KG2: SIGNALLED reserved process group $reserved"
  # Positive control: prove the log is capable of recording a kill at all, so
  # the absence above means "refused" and not "nothing was ever logged".
  bash -c 'kill -TERM -424242 2>/dev/null' || true
  grep -q -- '-424242' "$KILLLOG" || fail "KG2: kill log is not recording — the check above proved nothing"
  printf '%s\n' "$OUT" | grep -q "refusing process group $reserved" \
    || fail "KG2: no refusal message for reserved group $reserved (said: $OUT)"
  [ "$FAILS" -eq "$_b" ] && pass "KG2: process group $reserved refused, and said so"
done

# ---------- KG3: identity is revalidated on an ORDINARY kill ----------
# No --expect here. Identity enforcement used to exist only for plan-driven
# kills, so `audit --kill dev` — the documented command — signalled whatever
# held the pgid by the time the snapshot was acted on.
_b=$FAILS
mkshim 77700 1
: > "$KILLLOG"
OUT="$(run_kill --kill dev)"
grep -q -- 'kill -TERM -77700' "$KILLLOG" \
  && fail "KG3: signalled a group whose identity changed after selection"
bash -c 'kill -TERM -424242 2>/dev/null' || true
grep -q -- '-424242' "$KILLLOG" || fail "KG3: kill log is not recording — the check above proved nothing"
printf '%s\n' "$OUT" | grep -q 'identity changed' \
  || fail "KG3: identity gate never ran on an ordinary kill (said: $OUT)"
[ "$FAILS" -eq "$_b" ] && pass "KG3: an ordinary category kill revalidates identity before signalling"

# ---------- KG4: a stable group IS still killed ----------
# Proves KG3 is the gate doing the work, not some incidental refusal.
_b=$FAILS
mkshim 77700 0
: > "$KILLLOG"
OUT="$(run_kill --kill dev)"
grep -q -- 'kill -TERM -77700' "$KILLLOG" \
  || fail "KG4: an unchanged group was not killed (said: $OUT)"
[ "$FAILS" -eq "$_b" ] && pass "KG4: an unchanged group is still killed"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; exit 1; fi
