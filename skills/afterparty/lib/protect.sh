# protect.sh - shared protect list, sourced (not executed) by
# process-ledger.sh and audit-processes.sh so both use the same regex.
# Never signal these: editors, agent runtimes, and IDE-managed MCP servers whose
# death breaks live tool connections in this or other sessions.
PROTECT_RE='Cursor|Code Helper|Electron|/MacOS/Code|Codex|node_repl|extension-host|chrome-devtools-mcp|playwright-mcp|@playwright/mcp|cursor-server'

# True if any live process in process group $1 matches PROTECT_RE. Group kills
# must check this: filtering protected rows out of a listing does not stop a
# protected sibling in the same group from dying with it. Returns 1 when ps
# cannot enumerate (Git Bash) — kills are not usable there anyway.
pgid_has_protected() {
  local members
  members="$(ps -Ao pgid=,command= 2>/dev/null | awk -v pg="$1" '$1 == pg { $1 = ""; print }')"
  [ -n "$members" ] || return 1
  if command -v rg >/dev/null 2>&1; then
    printf '%s\n' "$members" | rg -iq -- "$PROTECT_RE"
  else
    printf '%s\n' "$members" | grep -Eiq -- "$PROTECT_RE"
  fi
}
