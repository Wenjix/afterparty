#!/usr/bin/env bash
# A failed replacement write must preserve the complete original ledger.
# All machine tools and signals are intercepted in disposable state.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/workspace" "$T/shim"
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never
export AGENT_PROCESS_LEDGER="$T/ledger.tsv" BASH_ENV="$T/bash-env"
export LEDGER_WRITE_LOG="$T/write.log" LEDGER_TOOL_LOG="$T/tools.log" LEDGER_WRITE_FAIL=0

cat > "$BASH_ENV" <<'ENV'
kill() { builtin printf 'kill %s\n' "$*" >> "$LEDGER_TOOL_LOG"; return 1; }
printf() {
  if [ "${1-}" = '%s\n' ] && [ "${2-}" = "$LEDGER_FAULT_ROW" ]; then
    builtin printf 'replacement append entered\n' >> "$LEDGER_WRITE_LOG"
    if [ "$LEDGER_WRITE_FAIL" = 1 ]; then return 1; fi
  fi
  builtin printf "$@"
}
ENV
cat > "$T/shim/ps" <<'PS'
#!/usr/bin/env bash
case "$*" in
  '-o pgid= -p '*) printf '888886\n' ;;
  '-Ao pid=,pgid=,lstart=,command=')
    printf '999991 999991 Tue Jan 1 00:00:00 2020 sleep 999\n'
    printf '999992 999992 Tue Jan 1 00:00:00 2020 sleep 999\n' ;;
  *) exit 1 ;;
esac
PS
for tool in pgrep launchctl pnpm; do
  cat > "$T/shim/$tool" <<'TOOL'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$LEDGER_TOOL_LOG"
exit 1
TOOL
done
chmod +x "$T/shim/"*
export PATH="$T/shim:$PATH"
printf -v ROW1 '2020-01-01T00:00:00Z\t%s\t%s\t999991\t999991\tdev\t-\tfirst\tsleep 999\t-' "$T/workspace" "$T/workspace"
printf -v ROW2 '2020-01-01T00:00:00Z\t%s\t%s\t999992\t999992\tdev\t-\tsecond\tsleep 999\t-' "$T/workspace" "$T/workspace"
export LEDGER_FAULT_ROW="$ROW2"
printf '%s\n%s\n' "$ROW1" "$ROW2" > "$AGENT_PROCESS_LEDGER"
cp "$AGENT_PROCESS_LEDGER" "$T/original.tsv"
cd "$T/workspace"

# A successful control reaches the second append and keeps both live rows.
bash "$REPO/bin/afterparty" prune --all > "$T/control.out" 2>&1
grep -Fq 'replacement append entered' "$LEDGER_WRITE_LOG"
grep -Fq 'kept 2' "$T/control.out"
cmp "$AGENT_PROCESS_LEDGER" "$T/original.tsv"

# Fail after the first row has already been copied. A partial replacement
# would silently discard the second row if its append status were ignored.
export LEDGER_WRITE_FAIL=1
: > "$LEDGER_WRITE_LOG"
if bash "$REPO/bin/afterparty" prune --all > "$T/failure.out" 2>&1; then
  echo 'FAIL: prune returned success after a replacement append failed' >&2
  exit 1
fi
grep -Fq 'replacement append entered' "$LEDGER_WRITE_LOG"
grep -Fq 'Could not write the replacement ledger' "$T/failure.out"
cmp "$AGENT_PROCESS_LEDGER" "$T/original.tsv"
[ ! -e "$AGENT_PROCESS_LEDGER.lock" ]
[ "$(find "$T" -name '.ledger.tsv.*' -print | wc -l | tr -d '[:space:]')" -eq 0 ]

# Recovery proves the lock was released and the original remains readable.
export LEDGER_WRITE_FAIL=0
bash "$REPO/bin/afterparty" prune --all > "$T/recovery.out" 2>&1
grep -Fq 'kept 2' "$T/recovery.out"
cmp "$AGENT_PROCESS_LEDGER" "$T/original.tsv"
[ ! -e "$LEDGER_TOOL_LOG" ]
echo 'ALL PASS: failed ledger replacement writes preserve rows and release the lock'
