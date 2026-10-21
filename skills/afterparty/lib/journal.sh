# shellcheck shell=bash
# journal.sh - append local mutation outcomes with common credential redaction.

JOURNAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$JOURNAL_DIR/state.sh"
. "$JOURNAL_DIR/json.sh"
. "$JOURNAL_DIR/privacy.sh"

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
  path="$(state_actions_path)" || return 1
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
  target="$(printf '%s\n' "$target" | privacy_redact)"
  detail="$(printf '%s\n' "$detail" | privacy_redact)"
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
      return 1
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
  if [ -z "${AFTERPARTY_JOURNAL_RETAINED:-}" ]; then
    if ! journal_retain "$path"; then
      state_lock_release "$lock"
      echo 'afterparty: journal retention failed; outcome was not recorded' >&2
      return 1
    fi
    AFTERPARTY_JOURNAL_RETAINED=1
  fi
  if ! (umask 077 && printf '%s\n' "$row" >> "$path"); then
    state_lock_release "$lock"
    printf 'afterparty: could not append to the action journal\n' >&2
    return 1
  fi
  if [ -z "${AFTERPARTY_JOURNAL_MODE_SET:-}" ]; then
    chmod 600 "$path" 2>/dev/null || true
    AFTERPARTY_JOURNAL_MODE_SET=1
  fi
  state_lock_release "$lock"
  return 0
}

# Retention is opt-in: 0 (the default) keeps all receipts. Run only while the
# journal lock is held, and retain unrecognized rows rather than guessing.
journal_retain() {
  local path="$1" days="${AFTERPARTY_RETENTION_DAYS:-0}" cutoff tmp
  case "$days" in ''|*[!0-9]*) echo 'afterparty: AFTERPARTY_RETENTION_DAYS must be a nonnegative integer' >&2; return 1 ;; esac
  [ "$days" -gt 0 ] || return 0
  cutoff="$(date -u -d "$days days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"${days}"d +%Y-%m-%d 2>/dev/null)" || return 1
  [ -f "$path" ] || return 0
  tmp="$(mktemp "${path}.retention.XXXXXX")" || return 1
  if ! awk -v cutoff="$cutoff" '
    /"timestamp":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {
      stamp=$0; sub(/^.*"timestamp":"/, "", stamp)
      if (substr(stamp,1,10) < cutoff) next
    }
    {print}' "$path" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"; return 1
  fi
}

journal_show() {
  local path workspace="" all=0 since="" field row stamp
  path="$(state_actions_path)" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --show) shift ;;
      --path) printf '%s\n' "$path"; return 0 ;;
      --all) all=1; shift ;;
      --workspace) [ "$#" -ge 2 ] || { echo '--workspace requires a directory' >&2; return 2; }; workspace="$2"; shift 2 ;;
      --since) [ "$#" -ge 2 ] || { echo '--since requires YYYY-MM-DD' >&2; return 2; }; since="$2"; shift 2 ;;
      *) echo "actions: unknown option: $1" >&2; return 2 ;;
    esac
  done
  if [ -n "$since" ]; then
    case "$since" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) echo '--since requires YYYY-MM-DD' >&2; return 2 ;; esac
  fi
  [ -f "$path" ] || { echo 'no afterparty actions have been recorded' >&2; return 1; }
  workspace="$(state_workspace_scope "${workspace:-$PWD}")" || return 1
  field="$(json_kv workspace "$workspace")"
  # ENVIRON preserves literal backslashes in escaped JSON paths on Windows.
  AFTERPARTY_ACTIONS_MATCH="$field" awk -v all="$all" -v since="$since" '
    !all && !index($0, ENVIRON["AFTERPARTY_ACTIONS_MATCH"]) {next}
    since != "" {
      if ($0 !~ /"timestamp":"/) next
      stamp=$0; sub(/^.*"timestamp":"/, "", stamp)
      if (substr(stamp,1,10) < since) next
    }
    {print}' "$path"
}
