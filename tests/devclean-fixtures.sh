# shellcheck shell=bash
# Caller must provide disposable HOME/cwd and pgrep/launchctl/pnpm shims.
reviewed_devclean() {
  local script="$1" preview id
  shift
  local selected=()
  preview="$(AFTERPARTY_STYLE=never bash "$script" "$@")"
  while IFS= read -r id; do
    [ -z "$id" ] || selected+=(--target "$id")
  done < <(printf '%s\n' "$preview" | awk '$1 == "target:" {print $2}')
  # Refusal tests can have no eligible target. Keep the apply path entered;
  # a deliberately missing ID never grants blanket approval.
  [ "${#selected[@]}" -gt 0 ] || selected=(--target fixture-unavailable)
  bash "$script" "$@" --apply "${selected[@]}"
}

# Add independent positive evidence to an existing synthetic PID fixture.
# The original ps shim still controls identity changes and exit postconditions.
devclean_policy_fixture() {
  local shim="$1" pid="$2" workspace="$T/devclean-workspace"
  mkdir -p "$workspace" "$T/devclean-transcripts/fixture"
  workspace="$(cd "$workspace" && pwd -P)"
  printf '{"cwd":"%s"}\n' "$workspace" > "$T/devclean-transcripts/fixture/old.jsonl"
  touch -t 202001010000 "$T/devclean-transcripts/fixture/old.jsonl"
  export AFTERPARTY_TRANSCRIPT_ROOT="$T/devclean-transcripts"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in "-o uid=,etime=,tty=,%%cpu= -p %s") printf "%%s 03:00:00 ? 0.0\\n" "$(id -u)"; exit 0 ;; esac\n' "$pid"
    sed '1d' "$shim/ps"
  } > "$shim/ps.policy"
  mv "$shim/ps.policy" "$shim/ps"; chmod +x "$shim/ps"
  printf '#!/usr/bin/env bash\nprintf "p%s\\nfcwd\\nn%s\\n"\n' "$pid" "$workspace" > "$shim/lsof"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/launchctl"
  chmod +x "$shim/lsof" "$shim/launchctl"
}
