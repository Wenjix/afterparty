# shellcheck shell=bash
# workspace.sh - workspace attribution and staleness, sourced (not executed) by
# glance.sh, the same way protect.sh and json.sh are shared.
#
# Answers the two questions the kill paths cannot: which workspace does this
# process belong to, and how long since anyone worked there. Staleness matters
# because process liveness is the wrong signal -- a finished agent leaves its
# dev server running long after you stopped caring, and a long tool call goes
# quiet while very much still working. Callers combine last-touched with cpu.
#
# A workspace with no agent transcript has NO last-touched time. That is
# "cannot tell", never "forgotten" -- callers must not treat unknown as stale.

WS_TRANSCRIPT_ROOT="${AFTERPARTY_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"
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

# Emit "<epoch>\t<cwd>" per workspace that has an agent transcript.
#
# Identity comes from the cwd the transcript records, never from the directory
# name: the slug is lossy (both "/" and "." collapse to "-") and undocumented,
# so decoding it is ambiguous. grep -m1 stops at the first match, which keeps
# this cheap even against multi-megabyte transcripts.
ws_index() {
  local root="${AFTERPARTY_TRANSCRIPT_ROOT:-$WS_TRANSCRIPT_ROOT}"
  local dir f newest cwd ts
  [ -d "$root" ] || return 0
  for dir in "$root"/*/; do
    [ -d "$dir" ] || continue
    newest=""
    for f in "$dir"*.jsonl; do
      [ -f "$f" ] || continue
      if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
    done
    [ -n "$newest" ] || continue
    cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$newest" 2>/dev/null)" || continue
    cwd="${cwd#\"cwd\":\"}"
    cwd="${cwd%\"}"
    [ -n "$cwd" ] || continue
    ts="$(ws_mtime "$newest")" || continue
    printf '%s\t%s\n' "$ts" "$cwd"
  done
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
# Shared by glance and plan so the attribution model has a single definition.
ws_pid_cwd() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -a -d cwd -Fpn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2); next }
    /^n/ { if (pid != "") { print pid "\t" substr($0, 2); pid = "" } }
  '
}

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

# Display label for a workspace path. Bare basename is ambiguous the moment two
# projects share a leaf name -- monorepos and scaffolds make "web", "api" and
# "server" extremely common -- and on the APPROVAL surface an ambiguous label
# is a wrong approval waiting to happen: two rows read identically and you
# cannot tell which one you are ticking. Uses parent/leaf, which disambiguates
# every realistic collision while staying far shorter than a full path.
ws_label() {
  local path="${1:-}" parent leaf
  [ -n "$path" ] || { printf '(unknown)'; return 0; }
  leaf="${path##*/}"
  [ -n "$leaf" ] || leaf="$path"
  parent="${path%/*}"
  parent="${parent##*/}"
  if [ -n "$parent" ] && [ "$parent" != "$leaf" ]; then
    printf '%s/%s' "$parent" "$leaf"
  else
    printf '%s' "$leaf"
  fi
}
