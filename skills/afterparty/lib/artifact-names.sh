# shellcheck shell=bash
# Shared artifact names. Loading this registry does not inspect the filesystem.
artifact_names_load() {
  local entry_type pattern kind extra registry literal existing prefix
  ARTIFACT_NAMES_AVAILABLE=0
  registry="${BASH_SOURCE[0]%/*}/artifact-kinds.tsv"
  ARTIFACT_DIRS=() ARTIFACT_FILE_PATTERNS=()
  ARTIFACT_NAME_PATTERNS=() ARTIFACT_NAME_KINDS=()
  [ -r "$registry" ] || return 1
  # Bash drops NUL bytes during ordinary reads. Reject them before parsing.
  if IFS= read -r -d '' prefix < "$registry"; then return 1; fi
  while IFS=$'\t' read -r entry_type pattern kind extra || [ -n "$entry_type$pattern$kind$extra" ]; do
    case "$entry_type" in ''|'#'*) continue ;; esac
    case "$entry_type" in directory|file) : ;; *) return 1 ;; esac
    [ -n "$pattern" ] && [ -z "$extra" ] || return 1
    literal="$pattern"
    if [ "$entry_type" = file ]; then literal="${pattern#\*.}"; fi
    case "$literal" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    case "$kind" in cache|build|test) : ;; *) return 1 ;; esac
    for existing in ${ARTIFACT_NAME_PATTERNS[@]+"${ARTIFACT_NAME_PATTERNS[@]}"}; do
      [ "$existing" != "$pattern" ] || return 1
    done
    if [ "$entry_type" = directory ]; then
      ARTIFACT_DIRS+=("$pattern")
    else
      ARTIFACT_FILE_PATTERNS+=("$pattern")
    fi
    ARTIFACT_NAME_PATTERNS+=("$pattern")
    ARTIFACT_NAME_KINDS+=("$kind")
  done < "$registry" || return 1
  [ "${#ARTIFACT_DIRS[@]}" -gt 0 ] && [ "${#ARTIFACT_FILE_PATTERNS[@]}" -gt 0 ] || return 1
  ARTIFACT_NAMES_AVAILABLE=1
}

# Match basenames only, as the original collector and apply allowlist did.
# The entry type selects scan rules; it does not widen the apply policy.
artifact_kind_for_name() {
  local name="${1##*/}" index=0 pattern
  [ "${ARTIFACT_NAMES_AVAILABLE:-0}" -eq 1 ] || return 1
  for pattern in "${ARTIFACT_NAME_PATTERNS[@]}"; do
    case "$name" in
      $pattern) printf '%s\n' "${ARTIFACT_NAME_KINDS[$index]}"; return 0 ;;
    esac
    index=$((index + 1))
  done
  return 1
}

artifact_name_supported() { artifact_kind_for_name "$1" >/dev/null; }

artifact_names_load || return 1
