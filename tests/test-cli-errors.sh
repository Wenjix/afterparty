#!/usr/bin/env bash
# Invalid options must identify the command, the option, and a recovery step.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/cache" "$T/repo" "$T/shim"
export HOME="$T/home" XDG_CACHE_HOME="$T/cache" AFTERPARTY_STYLE=never
export AGENT_PROCESS_LEDGER="$T/ledger.tsv"
git -C "$T/repo" init -q
# No process or native cleanup command can reach the host through this fixture.
for tool in ps pgrep lsof kill launchctl pnpm; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/shim/$tool"
  chmod +x "$T/shim/$tool"
done
export PATH="$T/shim:$PATH"
cd "$T/repo"

check_error() {
  local expected_rc="$1" context="$2" value="$3" recovery="$4" actual_rc=0
  shift 4
  bash "$REPO/bin/afterparty" "$@" > "$T/out" 2> "$T/err" || actual_rc=$?
  [ "$actual_rc" -eq "$expected_rc" ] || {
    echo "FAIL: $context returned $actual_rc, expected $expected_rc" >&2
    exit 1
  }
  for text in "$context:" "$value" "$recovery"; do
    grep -Fq -- "$text" "$T/err" || {
      echo "FAIL: $context error does not contain: $text" >&2
      cat "$T/err" >&2
      exit 1
    }
  done
}

for command in add list stop prune git artifacts doctor devclean; do
  check_error 2 "$command" --unknown-option "afterparty $command --help" "$command" --unknown-option
done
for option in --pid --kind --port --purpose; do
  check_error 2 add "$option" 'afterparty add --help' add "$option"
done
for command in list stop prune git artifacts; do
  check_error 2 "$command" --root "afterparty $command --help" "$command" --root
done
for command in list stop; do
  check_error 2 "$command" --kind "afterparty $command --help" "$command" --kind
done
check_error 2 stop --keep 'afterparty stop --help' stop --keep
check_error 2 git --age 'afterparty git --help' git --age
for option in --target --documents-root --project-maxdepth; do
  check_error 2 devclean "$option" 'afterparty devclean --help' devclean "$option"
done
# The composite audit reports child invocation failures with exit status 1.
check_error 1 audit --unknown-option 'afterparty audit --help' audit --unknown-option
check_error 2 report --unknown-option 'afterparty report --show' report --unknown-option
check_error 2 afterparty unknown-command 'afterparty --help' unknown-command
check_error 2 audit --json 'Choose one output format' audit --report --json
grep -Fq -- '--report' "$T/err"
check_error 1 report 'No saved audit exists' 'afterparty audit --report' report --show
echo 'ALL CLI ERROR CASES PASS'
