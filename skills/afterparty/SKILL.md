---
name: afterparty
description: Use before starting another localhost server, before ending a turn that spawned long-running processes, when CPU or memory is high, when disk is low, or when the user says "what is running", "devclean", "orphaned MCP", "cleanup terminals", "localhosts out of control", "free disk space", "stale worktrees", or "leftover branches".
license: ./LICENSE
compatibility: Requires Bash 3.2+, Git, and standard Unix process tools. macOS/Linux terminals and WSL are supported; Git Bash provides Git/filesystem commands with degraded process audits.
metadata:
  author: Wenjix
  version: "0.6.0"
---

# Afterparty

This is the memory hook; deterministic behavior lives in the bundled CLI.
`$CLAUDE_SKILL_DIR` is this skill's directory. Requirements: a macOS/Linux
terminal (Windows: WSL, or Git Bash with degraded process audits), Git, and
standard Unix process tools.

Audit before starting duplicate services and before ending a session:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" audit
```

Record long-running commands immediately:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" add --pid <PID> --kind dev --port <PORT> --purpose "<why>" -- <command>
```

Only act after reviewing the dry run:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" stop --kill
"$CLAUDE_SKILL_DIR/bin/afterparty" audit --kill dev --pgid <reviewed-pgid>
"$CLAUDE_SKILL_DIR/bin/afterparty" git --clean
"$CLAUDE_SKILL_DIR/bin/afterparty" artifacts --clean
"$CLAUDE_SKILL_DIR/bin/afterparty" devclean --apply
```

Use `--json` for versioned JSON Lines. `audit --report` persists the next
session's report; locate it with `report-path`. `actions` shows the private
local mutation journal.

Never kill the editor, Codex, the user's shell, or shared MCP servers unless the
script proves they are safe orphaned targets.
