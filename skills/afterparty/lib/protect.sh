# shellcheck shell=bash
# protect.sh - shared command-text protection patterns. Ledger/audit/plan use
# them for group checks; devclean uses the same regex for individual orphan
# candidates. Coverage includes selected editors, Claude/Codex command tokens,
# selected MCP servers and bare interactive shells, not every program in those
# classes. The shell alternative is end-anchored: it matches a bare
# interactive shell ("-zsh", "bash", "/bin/bash") but never the argumented
# "sh -c ..." wrappers inside dev-server and test-runner groups, which must
# stay killable.
#
# The claude/codex alternative uses token and path-basename boundaries.
# Claude Code puts a ".claude/shell-snapshots/..." path in the argv of every
# shell it spawns, so a bare "claude" substring would match the wrapper
# sharing a dev server's process group; pgid_has_protected would then refuse
# that group forever and dev servers would become unkillable. Requiring a
# space or "/" before and a space or end after matches "claude ...", and
# "/usr/local/bin/claude ...", but never "/Users/x/.claude/anything".
# This is command-text matching, not parsed executable identity: a matching
# token later in argv can also protect a process. Devclean withholds matching
# orphan PIDs; it does not apply this group-level helper to unrelated siblings.
PROTECT_RE='Cursor|Code Helper|Electron|/MacOS/Code|node_repl|extension-host|chrome-devtools-mcp|playwright-mcp|@playwright/mcp|cursor-server|(^|[[:space:]/])(claude|codex)([[:space:]]|$)|(^|[[:space:]/])-?(bash|zsh|fish|sh|dash|ksh)([[:space:]]+(-l|-i|--login|--interactive))*$'

# True if any live process in process group $1 matches PROTECT_RE. Group kills
# must check this: filtering protected rows out of a listing does not stop a
# protected sibling in the same group from dying with it. Return values:
# 0 protected member found; 1 inspected and clear; 2 inspection unavailable;
# 3 the group is not present at all.
#
# 3 exists because ps succeeding with no members for this pgid is not the same
# as ps failing. The group simply exited between discovery and the kill loop --
# which is the common case on a busy machine, since the loop drains 2s per
# group. Folding it into 2 made the caller report "could not inspect" and
# count a FAILURE for a group that had already gone away on its own, inflating
# the failure count and the exit status of an otherwise clean run.
pgid_has_protected() {
  local snapshot members rc
  if ! snapshot="$(ps -Ao pgid=,command= 2>/dev/null)"; then
    return 2
  fi
  members="$(printf '%s\n' "$snapshot" | awk -v pg="$1" '$1 == pg { $1 = ""; print }')" || return 2
  [ -n "$members" ] || return 3
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
