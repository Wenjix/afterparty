# protect.sh - shared protect list, sourced (not executed) by
# process-ledger.sh and audit-processes.sh so both use the same regex.
# Never signal these: editors, agent runtimes, and IDE-managed MCP servers whose
# death breaks live tool connections in this or other sessions.
PROTECT_RE='Cursor|Code Helper|Electron|/MacOS/Code|Codex|node_repl|extension-host|chrome-devtools-mcp|playwright-mcp|@playwright/mcp|cursor-server'
