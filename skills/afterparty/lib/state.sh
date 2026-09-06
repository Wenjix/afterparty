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

state_ledger_path() {
  if [ -n "${AGENT_PROCESS_LEDGER:-}" ]; then
    printf '%s' "$AGENT_PROCESS_LEDGER"
  else
    printf '%s/ledger.tsv' "$(state_cache_root)"
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
# A lock held longer than this is treated as abandoned. Deliberately generous:
# the longest legitimate hold is a ledger prune, which is milliseconds.
STATE_LOCK_STALE_SECONDS="${AFTERPARTY_LOCK_STALE_SECONDS:-300}"
# A lock directory with no owner inside is the crash window between the two
# mkdirs. Short grace so a genuine racer is never mistaken for a crash.
STATE_LOCK_ORPHAN_SECONDS="${AFTERPARTY_LOCK_ORPHAN_SECONDS:-10}"

state_lock_age() {
  local now mt
  mt="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
  [ -n "$mt" ] || return 1
  now="$(date +%s)" || return 1
  printf '%s' "$(( now - mt ))"
}

# Reclaim by ATOMIC RENAME, never by rmdir in place. Two reapers racing on the
# same abandoned lock both call this; only one wins the rename, so the loser
# cannot delete a lock the winner (or a fresh legitimate owner) now holds.
# Removing the directory in place had no such interlock, which is how two
# processes could come to hold the same lock at once.
state_lock_reclaim() {
  local lock="$1" tmp="$1.stale.$$.$RANDOM"
  if mv "$lock" "$tmp" 2>/dev/null; then
    rm -rf "$tmp" 2>/dev/null || true
    return 0
  fi
  return 1
}

# True when the lock looks abandoned rather than held.
state_lock_is_stale() {
  local lock="$1" owner_dir owner age owners=0
  for owner_dir in "$lock"/[0-9]*; do
    [ -d "$owner_dir" ] || continue
    owners=$((owners + 1))
    owner="${owner_dir##*/}"
    case "$owner" in
      ''|*[!0-9]*) continue ;;
    esac
    # A live PID still holding it past the stale window counts as abandoned
    # too: PIDs are recycled, so "the number is alive" is not proof that THIS
    # holder is alive. Without an age bound a recycled pid wedged it forever.
    if ! kill -0 "$owner" 2>/dev/null; then return 0; fi
    age="$(state_lock_age "$owner_dir")" || return 1
    [ "$age" -gt "$STATE_LOCK_STALE_SECONDS" ] && return 0
    return 1
  done
  # No owner inside at all: the holder died between creating the lock and
  # claiming it. The old reaper globbed for owner dirs, found none, and so
  # never removed anything -- the lock stayed forever and every writer after it
  # failed silently.
  if [ "$owners" -eq 0 ]; then
    age="$(state_lock_age "$lock")" || return 1
    [ "$age" -gt "$STATE_LOCK_ORPHAN_SECONDS" ] && return 0
  fi
  return 1
}

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
    if state_lock_is_stale "$lock"; then
      state_lock_reclaim "$lock" || true
    fi
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
