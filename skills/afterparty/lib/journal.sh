# shellcheck shell=bash
# journal.sh - append privacy-preserving local mutation outcomes as JSON Lines.

JOURNAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$JOURNAL_DIR/state.sh"
. "$JOURNAL_DIR/json.sh"

journal_version() {
  local version_file="$JOURNAL_DIR/../VERSION"
  if [ -f "$version_file" ]; then
    sed -n '1p' "$version_file"
  else
    printf 'development'
  fi
}

journal_escape_in_place() {
  local name="$1" value="${!1}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf -v "$name" '%s' "$value"
}

journal_action() {
  local operation="$1" target="$2" status="$3" detail="${4:-}" path lock row workspace timestamp version cache
  [ "${AFTERPARTY_JOURNAL:-1}" != "0" ] || return 0
  path="$(state_actions_path)" || return 0
  lock="${path}.lock"
  if [ -z "${AFTERPARTY_JOURNAL_WORKSPACE_INITIALIZED:-}" ]; then
    AFTERPARTY_JOURNAL_WORKSPACE="$(state_workspace_scope "$PWD")" || AFTERPARTY_JOURNAL_WORKSPACE="$PWD"
    AFTERPARTY_JOURNAL_WORKSPACE_INITIALIZED=1
  fi
  workspace="$AFTERPARTY_JOURNAL_WORKSPACE"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  if [ -z "${AFTERPARTY_JOURNAL_VERSION_INITIALIZED:-}" ]; then
    AFTERPARTY_JOURNAL_VERSION="$(journal_version)"
    AFTERPARTY_JOURNAL_VERSION_INITIALIZED=1
  fi
  version="$AFTERPARTY_JOURNAL_VERSION"
  journal_escape_in_place timestamp
  journal_escape_in_place version
  journal_escape_in_place operation
  journal_escape_in_place target
  journal_escape_in_place status
  journal_escape_in_place detail
  journal_escape_in_place workspace
  printf -v row '{"schema_version":1,"timestamp":"%s","version":"%s","operation":"%s","target":"%s","status":"%s","detail":"%s","workspace":"%s"}' \
    "$timestamp" "$version" "$operation" "$target" "$status" "$detail" "$workspace"

  cache="${path%/*}"
  if [ -z "${AFTERPARTY_JOURNAL_READY:-}" ]; then
    state_secure_dir "$cache" || {
      printf 'afterparty: could not create action journal directory\n' >&2
      return 0
    }
    AFTERPARTY_JOURNAL_READY=1
  fi
  if ! state_lock_acquire "$lock"; then
    # return 1, not 0. A dropped receipt is a mutation that happened with no
    # record of it, and a caller that cannot detect the drop will go on to
    # print a confident summary describing work the journal never saw. The
    # warning alone was invisible in any run whose stderr nobody reads.
    printf 'afterparty: action journal is busy; outcome was not recorded\n' >&2
    return 1
  fi
  if ! (umask 077 && printf '%s\n' "$row" >> "$path"); then
    state_lock_release "$lock"
    printf 'afterparty: could not append to the action journal\n' >&2
    return 0
  fi
  if [ -z "${AFTERPARTY_JOURNAL_MODE_SET:-}" ]; then
    chmod 600 "$path" 2>/dev/null || true
    AFTERPARTY_JOURNAL_MODE_SET=1
  fi
  state_lock_release "$lock"
  return 0
}
