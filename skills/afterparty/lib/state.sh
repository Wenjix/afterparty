# shellcheck shell=bash
# state.sh - shared locations and private-state helpers.

state_cache_root() {
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    printf '%s/agent-processes' "$XDG_CACHE_HOME"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.cache/agent-processes' "$HOME"
  else
    return 2
  fi
}

state_workspace_scope() {
  local dir="${1:-$PWD}" root
  if root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$root"
  elif [ -d "$dir" ]; then
    (cd "$dir" && pwd -P)
  else
    printf '%s' "$dir"
  fi
}

state_workspace_key() {
  local scope digest sum bytes
  scope="$(state_workspace_scope "${1:-$PWD}")" || return
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$scope" | sha256sum)" || return
    printf '%s' "${digest%% *}"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$scope" | shasum -a 256)" || return
    printf '%s' "${digest%% *}"
    return 0
  fi
  # POSIX fallback for minimal systems. Including byte length makes accidental
  # collisions less likely than a bare checksum, while SHA-256 is preferred.
  read -r sum bytes _ < <(printf '%s' "$scope" | cksum)
  printf '%s-%s' "$sum" "$bytes"
}

state_report_is_available() {
  local report="$1" first=""
  [ ! -e "$report" ] && return 0
  [ -f "$report" ] || return 1
  IFS= read -r first < "$report" || true
  case "$first" in '# afterparty report'*) return 0 ;; *) return 1 ;; esac
}

state_report_path() {
  local dir="${1:-$PWD}" root cache key report
  if root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
    && git -C "$root" check-ignore -q "$root/report.md" 2>/dev/null \
    && report="$root/report.md" \
    && state_report_is_available "$report"; then
    printf '%s\n' "$report"
    return 0
  fi

  cache="$(state_cache_root)" || return
  key="$(state_workspace_key "$dir")" || return
  printf '%s/reports/%s/report.md\n' "$cache" "$key"
}

state_actions_path() {
  local cache
  cache="$(state_cache_root)" || return
  printf '%s/actions.jsonl\n' "$cache"
}

state_secure_dir() {
  local dir="$1"
  (umask 077 && mkdir -p "$dir") || return
  chmod 700 "$dir" 2>/dev/null || true
}

# Portable advisory lock based on atomic mkdir. The owner is represented by an
# empty PID-named directory so releasing the lock does not depend on `rm` (the
# cleanup commands may deliberately be running with a failing rm shim).
state_lock_acquire() {
  local lock="$1" tries="${2:-200}" owner_dir="" owner="" i=0 parent
  parent="${lock%/*}"
  if [ "$parent" = "$lock" ]; then parent="."; fi
  if [ -z "$parent" ]; then parent="/"; fi
  [ -d "$parent" ] || state_secure_dir "$parent" || return
  while [ "$i" -lt "$tries" ]; do
    if (umask 077 && mkdir "$lock") 2>/dev/null; then
      if ! mkdir "$lock/$$" 2>/dev/null; then
        rmdir "$lock" 2>/dev/null || true
        return 1
      fi
      return 0
    fi
    for owner_dir in "$lock"/[0-9]*; do
      [ -d "$owner_dir" ] || continue
      owner="${owner_dir##*/}"
      case "$owner" in
        ''|*[!0-9]*) ;;
        *)
          if ! kill -0 "$owner" 2>/dev/null; then
            rmdir "$owner_dir" 2>/dev/null || true
            rmdir "$lock" 2>/dev/null || true
          fi
          ;;
      esac
    done
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

state_lock_release() {
  local lock="$1"
  rmdir "$lock/$$" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}
