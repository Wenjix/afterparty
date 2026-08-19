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
