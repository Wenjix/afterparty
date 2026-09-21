# shellcheck shell=bash
# workspace.sh - workspace attribution and staleness, sourced (not executed) by
# glance.sh, the same way protect.sh and json.sh are shared.
#
# Associates process cwd paths with workspaces found in Claude and Codex files
# and reports the newest observed transcript file's mtime. This is observed
# agent-file activity, not verified human use or exclusive process ownership.
# Process-plan callers combine that activity time with observed CPU.
#
# A workspace with no readable transcript has NO last-touched time. That is
# "cannot tell", never "forgotten" -- callers must not treat unknown as stale.

WS_TRANSCRIPT_ROOT="${AFTERPARTY_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"
WS_CODEX_ROOT="$HOME/.codex"
WS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_IDLE_HOURS="${AFTERPARTY_IDLE_HOURS:-4}"
WS_STALE_HOURS="${AFTERPARTY_STALE_HOURS:-24}"

# Epoch mtime, GNU then BSD. Empty output plus nonzero when unavailable.
ws_mtime() {
  local t
  t="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}

# Seconds -> the bands the glance table renders. Deliberately coarse: the
# reader is deciding "did I walk away from this", not measuring uptime.
ws_human_age() {
  local s="${1:-0}"
  if   [ "$s" -lt 60 ];    then printf 'just now'
  elif [ "$s" -lt 3600 ];  then printf '%dm' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%dh %02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  else                          printf '%dd %02dh' "$((s / 86400))" "$(((s % 86400) / 3600))"
  fi
}

# Emit one "<epoch>\t<cwd>" row per normalized workspace. --sources adds a third
# column naming the contributing transcript providers. The Python reader merges
# every session's mtime, including resumed Codex cwd changes and newer ancestor
# activity. It emits no rows if any present provider cannot be fully inspected.
# Missing optional roots are okay; directories and files are never modified.
ws_index() {
  local root="${AFTERPARTY_TRANSCRIPT_ROOT:-$WS_TRANSCRIPT_ROOT}"
  local codex_root="${AFTERPARTY_CODEX_ROOT:-${CODEX_HOME:-$WS_CODEX_ROOT}}"
  command -v python3 >/dev/null 2>&1 || {
    echo 'workspace activity unavailable: Python 3 is required to inspect transcripts' >&2
    return 1
  }
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1 python3 "$WS_LIB_DIR/workspace-index.py" \
    --claude-root "$root" --codex-root "$codex_root" "$@"
}

# Working directory of a live pid. Requires lsof; without it the caller keeps
# the process unattributed rather than guessing an owner, because a wrong owner
# is worse than none -- it is what would make a plan kill someone else's work.
ws_for_pid() {
  local cwd
  command -v lsof >/dev/null 2>&1 || return 1
  cwd="$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  [ -n "$cwd" ] || return 1
  printf '%s' "$cwd"
}

# Emit "<pid>\t<cwd>" for every process, from ONE lsof call. Per-pid lookup
# would be ~500 forks on a normal machine; this is ~0.4s for all of them.
# Default discovery is best-effort for read-only attribution. Filesystem
# removal uses --strict: only a complete, validated scan may establish that a
# directory is unoccupied. A failed strict scan emits nothing and returns 1;
# callers must remove its output file rather than retain an empty safe map.
ws_pid_cwd() {
  if [ "${1:-}" = --strict ]; then
    ws_pid_cwd_strict
    return $?
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -a -d cwd -Fpn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2); next }
    /^n/ { if (pid != "") { print pid "\t" substr($0, 2); pid = "" } }
  '
}

ws_pid_cwd_strict() (
  local scan
  command -v lsof >/dev/null 2>&1 || return 1
  scan="$(mktemp -d)" || return 1
  trap 'rm -rf "$scan"' EXIT
  lsof -a -d cwd -Fpn > "$scan/raw" 2> "$scan/errors" || return 1
  # lsof can exit 0 while warning that part of a filesystem was inaccessible.
  # An empty global scan is not positive evidence either: at least the scanner
  # itself has a cwd. Neither case authorizes removal.
  [ ! -s "$scan/errors" ] && [ -s "$scan/raw" ] || return 1
  awk '
    /^p[1-9][0-9]*$/ {
      if (pid != "" || seen[$0]++) bad = 1
      pid = substr($0, 2); file = 0; next
    }
    /^fcwd$/ {
      if (pid == "" || file++) bad = 1
      next
    }
    /^n\// {
      # Tabs cannot be represented in the TSV contract. lsof also escapes
      # unusual filename bytes with backslashes; do not mistake those escaped
      # names for another physical directory and declare the real one vacant.
      if (pid == "" || file != 1 || $0 ~ /[[:cntrl:]]/ || index($0, "\\") != 0) bad = 1
      # Linux can report /proc/<pid>/cwd (readlink: Permission denied) as
      # the name, even without a failing exit status or stderr warning.
      if ($0 ~ / \((readlink|stat|lstat):/) bad = 1
      rows[++count] = pid "\t" substr($0, 2)
      pid = ""; next
    }
    { bad = 1 }
    END {
      if (bad || pid != "" || count == 0) exit 1
      for (i = 1; i <= count; i++) print rows[i]
    }
  ' "$scan/raw"
)

# Longest workspace path prefixing <cwd> wins, so a process in
# repo/packages/web belongs to repo rather than to a shorter ancestor.
# Reads the index on stdin as "<epoch>\t<path>" lines.
ws_owner_of() {
  local dir="$1" best="" ts path
  while IFS=$'\t' read -r ts path; do
    [ -n "$path" ] || continue
    case "$dir" in
      "$path"|"$path"/*) [ "${#path}" -gt "${#best}" ] && best="$path" ;;
    esac
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Display label for a workspace path, unambiguous BY CONSTRUCTION.
#
# Two earlier attempts were not. A bare basename collides whenever two projects
# share a leaf name, and "web"/"api"/"server" are the most common leaf names
# there are. parent/leaf is no better in the layout it was meant to fix:
# /client-one/apps/web and /client-two/apps/web both render as apps/web, and
# /repo/web/web collapses to a single segment because parent and leaf match.
#
# On the APPROVAL surface an ambiguous label is a wrong approval waiting to
# happen -- two rows read identically and you cannot tell which you are
# ticking -- so the label is now the whole path, abbreviated only at $HOME.
# Truncation for width happens in ws_label_fit and cuts from the LEFT, keeping
# the tail that actually distinguishes one workspace from another.
ws_label() {
  local path="${1:-}" home="${HOME%/}"
  [ -n "$path" ] || { printf '(unknown)'; return 0; }
  if [ -n "$home" ]; then
    case "$path" in
      "$home") printf '~'; return 0 ;;
      "$home"/*) printf '~/%s' "${path#"$home"/}"; return 0 ;;
    esac
  fi
  printf '%s' "$path"
}

# Fit a label into WIDTH columns by dropping LEADING segments, never trailing
# ones: the head of a path is the part workspaces have in common and the tail
# is the part that tells them apart. Right-truncating would reintroduce exactly
# the collision this label exists to prevent.
#
# Callers that render a TABLE should not use this at all -- they should use
# ws_unique_labels, which is table-scoped, and pad without truncating. Cutting
# a label to a fixed width can merge two labels that ws_unique_labels had just
# made distinct, and a byte-wise cut can land mid-codepoint. This remains only
# for single-value display where no set exists to be unique within.
ws_label_fit() {
  local label width cut
  label="$(ws_label "$1")"
  width="${2:-28}"
  [ "$width" -ge 4 ] || width=4
  if [ "${#label}" -le "$width" ]; then
    printf '%s' "$label"
    return 0
  fi
  # ASCII marker, not "…": ${#var} counts BYTES under a non-UTF-8 locale, so a
  # 3-byte ellipsis silently overflowed the column by 2 on Git Bash. A width
  # helper must not itself contain a character whose width it cannot count.
  cut=$(( ${#label} - (width - 3) ))
  [ "$cut" -gt 0 ] || cut=0
  printf '...%s' "${label:$cut}"
}

# Shortest suffix that is unique among the paths given. Reads paths on stdin,
# writes "<path>\t<label>".
#
# ws_label alone is unambiguous but unreadable in a column: every row of a
# machine like this shares "~/Documents/GitHub/", so the distinguishing part is
# whatever survives truncation. Uniqueness only ever needs to hold among the
# rows actually being displayed, so compute it there: one segment where that
# suffices ("afterparty"), two where it does not ("client-one/apps/web").
# Falls back to the full path if even that collides.
ws_unique_labels() {
  awk -F/ '
    # Deduplicate first. Uniqueness is a property of the SET of workspaces on
    # screen, but callers pass one row per finding -- and two process groups in
    # one workspace is the normal case, not the exception. Counting the same
    # path twice made every suffix look ambiguous, so that workspace fell all
    # the way back to its absolute path exactly when it was busiest.
    !seen_path[$0]++ { paths[++n] = $0 }
    function suffix(p, k,   parts, m, i, out) {
      m = split(p, parts, "/")
      out = ""
      for (i = m - k + 1; i <= m; i++) {
        if (parts[i] == "") continue
        out = (out == "" ? parts[i] : out "/" parts[i])
      }
      return out
    }
    END {
      maxk = 1
      for (i = 1; i <= n; i++) {
        m = split(paths[i], parts, "/")
        if (m > maxk) maxk = m
      }
      for (k = 1; k <= maxk; k++) {
        delete seen
        for (i = 1; i <= n; i++) seen[suffix(paths[i], k)]++
        for (i = 1; i <= n; i++) {
          if (label[i] != "") continue
          s = suffix(paths[i], k)
          if (s != "" && seen[s] == 1) label[i] = s
        }
      }
      for (i = 1; i <= n; i++)
        printf "%s\t%s\n", paths[i], (label[i] != "" ? label[i] : paths[i])
    }
  '
}
