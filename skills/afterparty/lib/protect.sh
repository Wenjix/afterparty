# shellcheck shell=bash
# protect.sh - shared protect list, sourced (not executed) by
# process-ledger.sh and audit-processes.sh so both use the same regex.
# Never signal these: editors, agent runtimes, IDE-managed MCP servers whose
# death breaks live tool connections in this or other sessions, and interactive
# shells. The shell alternative is end-anchored on purpose: it matches a bare
# interactive shell ("-zsh", "bash", "/bin/bash") but never the argumented
# "sh -c ..." wrappers inside dev-server and test-runner groups, which must
# stay killable.
#
# The claude alternative is anchored on the executable for the same reason.
# Claude Code puts a ".claude/shell-snapshots/..." path in the argv of every
# shell it spawns, so a bare "claude" substring would match the wrapper
# sharing a dev server's process group; pgid_has_protected would then refuse
# that group forever and dev servers would become unkillable. Requiring a
# space or "/" before and a space or end after matches "claude ...", and
# "/usr/local/bin/claude ...", but never "/Users/x/.claude/anything".
# This is an audit/ledger kill guard only -- devclean does not source this
# file, so its deliberate orphan-targeting of agent processes is unaffected.
PROTECT_RE='Cursor|Code Helper|Electron|/MacOS/Code|Codex|node_repl|extension-host|chrome-devtools-mcp|playwright-mcp|@playwright/mcp|cursor-server|(^|[[:space:]/])claude([[:space:]]|$)|(^|[[:space:]/])-?(bash|zsh|fish)$'

# True if any live process in process group $1 matches PROTECT_RE. Group kills
# must check this: filtering protected rows out of a listing does not stop a
# protected sibling in the same group from dying with it. Return values:
# 0 protected member found; 1 inspected and clear; 2 inspection unavailable.
pgid_has_protected() {
  local snapshot members rc
  if ! snapshot="$(ps -Ao pgid=,command= 2>/dev/null)"; then
    return 2
  fi
  members="$(printf '%s\n' "$snapshot" | awk -v pg="$1" '$1 == pg { $1 = ""; print }')" || return 2
  [ -n "$members" ] || return 2
  if command -v rg >/dev/null 2>&1; then
    # --no-config: ripgrep prepends flags from RIPGREP_CONFIG_PATH to every
    # invocation, and --fixed-strings or a small --regex-size-limit makes
    # PROTECT_RE stop matching -- so a user's own ripgrep config could silently
    # disable the protect list on a kill path. Verified: both defeat it.
    printf '%s\n' "$members" | rg --no-config -iq -- "$PROTECT_RE"
  else
    printf '%s\n' "$members" | grep -Eiq -- "$PROTECT_RE"
  fi
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}
