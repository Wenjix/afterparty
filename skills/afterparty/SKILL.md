---
name: afterparty
description: Use before starting another localhost server, before ending a turn that spawned long-running processes, when CPU or memory is high, when disk is low, or when the user says "what is running", "what did I leave running", "welcome back", "approve cleanup", "devclean", "orphaned MCP", "cleanup terminals", "localhosts out of control", "free disk space", "stale worktrees", or "leftover branches".
license: ./LICENSE
compatibility: Requires Bash 3.2+, Git, and standard Unix process tools. macOS/Linux terminals and WSL are supported; Git Bash provides Git/filesystem commands with degraded process audits.
metadata:
  author: Wenjix
  version: "0.10.0"
---

# Afterparty

`$CLAUDE_SKILL_DIR` is this self-contained skill's directory. Use its bundled CLI.

On return, report what workspaces still hold:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" glance
```

Save a checklist, have the user review its boxes, then apply:

```bash
"$CLAUDE_SKILL_DIR/bin/afterparty" plan > cleanup-plan.md
"$CLAUDE_SKILL_DIR/bin/afterparty" apply cleanup-plan.md
```

Worktrees start unchecked;
unavailable scans, nested repositories, and changed identity block removal.

Audit before starting services and ending sessions:

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
"$CLAUDE_SKILL_DIR/bin/afterparty" artifacts --clean
"$CLAUDE_SKILL_DIR/bin/afterparty" devclean --apply
```

`git` reports leftovers; approve worktree removal through `plan`/`apply`.

`--json` emits JSON Lines. `audit --report` persists a report; `report-path`
locates it. `actions` shows mutation history.

Never kill the editor, Codex, the user's shell, or shared MCP servers unless the
script proves they are safe orphaned targets.
