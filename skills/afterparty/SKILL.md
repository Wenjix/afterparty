---
name: afterparty
description: Use before starting another localhost server, before ending a turn that spawned long-running processes, when CPU or memory is high, when disk is low, or when the user says "what is running", "devclean", "orphaned MCP", "cleanup terminals", "localhosts out of control", "free disk space", "stale worktrees", or "leftover branches".
---

# Afterparty

This skill is the memory hook. It exists so agents remember to run the script.
The deterministic cleanup behavior lives in this skill's bundled
`bin/afterparty` and `lib/*.sh`. `$CLAUDE_SKILL_DIR` below is this skill's
directory (Claude Code sets it; in other harnesses substitute the skill's base
path).

Requirements: macOS/Linux (on Windows use Git Bash or WSL) and `ripgrep`;
`lsof` is optional (localhost report).

Run a dry-run audit first (processes, localhost ports, git leftovers —
worktrees, agent branches, conflict litter):

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" audit
```

Add `--json` for JSON Lines. `audit --report` saves the report for the next
session: `report.md` if the repo gitignores it, else
`~/.cache/agent-processes/report.md`.

Record long-running commands you start:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" add --pid <PID> --kind dev --port <PORT> --purpose "<why>" -- <command>
```

Before ending the turn:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" audit
```

Only act after reviewing the dry run:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" stop --kill            # stop process groups recorded in the ledger
"$CLAUDE_SKILL_DIR/bin/afterparty" audit --kill tests,dev # kill stray processes by category pattern
"$CLAUDE_SKILL_DIR/bin/afterparty" git --clean            # prune stale worktrees, merged agent branches
"$CLAUDE_SKILL_DIR/bin/afterparty" artifacts --clean
"$CLAUDE_SKILL_DIR/bin/afterparty" devclean --apply
```

Never kill the editor, Codex, the user's shell, or shared MCP servers unless the
script proves they are safe orphaned targets.
