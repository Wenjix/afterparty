#!/usr/bin/env bash
# Destructive occupancy checks require complete lsof output, never a partial
# attribution map. All tools here inspect disposable fixtures only.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/skills/afterparty/lib/workspace.sh"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim"
export TEST_CWD_SCAN_MODE=good TEST_CWD_SCAN_PATH="$T/path with spaces"
cat > "$T/shim/lsof" <<'LSOF'
#!/usr/bin/env bash
case "$TEST_CWD_SCAN_MODE" in
  failed) exit 1 ;;
  empty) exit 0 ;;
  warning) printf 'cannot inspect filesystem\n' >&2 ;;
  bad-pid) printf 'pnot-a-pid\nfcwd\nn%s\n' "$TEST_CWD_SCAN_PATH"; exit 0 ;;
  relative) printf 'p4242\nfcwd\nnrelative/path\n'; exit 0 ;;
  orphan-name) printf 'n%s\n' "$TEST_CWD_SCAN_PATH"; exit 0 ;;
  escaped) printf 'p4242\nfcwd\nn/a\\tb\n'; exit 0 ;;
  missing-name) printf 'p4242\nfcwd\n'; exit 0 ;;
  missing-descriptor) printf 'p4242\nn%s\n' "$TEST_CWD_SCAN_PATH"; exit 0 ;;
  readlink-error) printf 'p4242\nfcwd\nn/proc/4242/cwd (readlink: Permission denied)\n'; exit 0 ;;
  stat-error) printf 'p4242\nfcwd\nn/proc/4242/cwd (stat: Permission denied)\n'; exit 0 ;;
esac
printf 'p4242\nfcwd\nn%s\n' "$TEST_CWD_SCAN_PATH"
case "$TEST_CWD_SCAN_MODE" in
  partial-error) exit 1 ;;
  missing-last-name) printf 'p4343\nfcwd\n' ;;
  duplicate) printf 'p4242\nfcwd\nn/another/path\n' ;;
  unknown-field) printf 'eunexpected-error\n' ;;
esac
exit 0
LSOF
chmod +x "$T/shim/lsof"
export PATH="$T/shim:$PATH"

OUT="$(ws_pid_cwd --strict)"; RC=$?
[ "$RC" -eq 0 ] || fail "CS1: valid cwd output was rejected"
[ "$OUT" = "$(printf '4242\t%s' "$TEST_CWD_SCAN_PATH")" ] || fail "CS1: valid path was changed: '$OUT'"

for mode in failed empty warning bad-pid relative orphan-name escaped missing-name missing-descriptor readlink-error stat-error partial-error missing-last-name duplicate unknown-field; do
  OUT="$(TEST_CWD_SCAN_MODE="$mode" ws_pid_cwd --strict)"; RC=$?
  [ "$RC" -ne 0 ] || fail "CS2/$mode: incomplete or malformed discovery reported success"
  [ -z "$OUT" ] || fail "CS2/$mode: failed discovery published a partial map: '$OUT'"
done

OUT="$(PATH=/afterparty-no-such-bin ws_pid_cwd --strict)"; RC=$?
[ "$RC" -ne 0 ] || fail "CS3: missing lsof reported a complete scan"
[ -z "$OUT" ] || fail "CS3: missing lsof emitted a map"

# Read-only consumers still keep the attribution rows they can discover.
OUT="$(TEST_CWD_SCAN_MODE=missing-last-name ws_pid_cwd)"
[ "$OUT" = "$(printf '4242\t%s' "$TEST_CWD_SCAN_PATH")" ] || fail "CS4: best-effort discovery lost its valid row"

if [ "$FAILS" -eq 0 ]; then
  echo 'ALL PASS: strict cwd discovery rejects unavailable and incomplete evidence'
else
  echo "$FAILS FAILURE(S)"; exit 1
fi
