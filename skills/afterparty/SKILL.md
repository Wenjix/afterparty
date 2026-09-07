---
name: afterparty
description: Use before starting another localhost server, before ending a turn that spawned long-running processes, when CPU or memory is high, when disk is low, or when the user says "what is running", "what did I leave running", "welcome back", "approve cleanup", "devclean", "orphaned MCP", "cleanup terminals", "localhosts out of control", "free disk space", "stale worktrees", or "leftover branches".
license: ./LICENSE
compatibility: Requires Bash 3.2+, Git, and standard Unix process tools. macOS/Linux terminals and WSL are supported; Git Bash provides Git/filesystem commands with degraded process audits.
metadata:
  author: Wenjix
  version: "0.11.1"
---

# Afterparty

Claude substitutes `${CLAUDE_SKILL_DIR}`. Other agents: use this SKILL.md’s
absolute directory.

On return:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" glance
```

Save a checklist; apply only targets the user has approved:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" plan > cleanup-plan.md
"${CLAUDE_SKILL_DIR}/bin/afterparty" apply cleanup-plan.md
```

All boxes start unchecked. Unknown scans, nested repositories, and changed
identity block removal.

Before services and session end:

```bash
AFTERPARTY_SESSION_ID="${CLAUDE_SESSION_ID}" "${CLAUDE_SKILL_DIR}/bin/afterparty" audit --report
```

Record services:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" add --pid <PID> --kind dev --port <PORT> --purpose "<why>" -- <command>
```

Only act after reviewing the dry run:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" stop --kill
"${CLAUDE_SKILL_DIR}/bin/afterparty" audit --kill dev --pgid <reviewed-pgid>
"${CLAUDE_SKILL_DIR}/bin/afterparty" artifacts
"${CLAUDE_SKILL_DIR}/bin/afterparty" devclean
```

`git`/`artifacts` report; approve removal through `plan`/`apply`.
Devclean requires reviewed `--target` IDs.

Supported `--json` commands emit JSON Lines. `audit --report` saves a snapshot;
`report-path` locates it. Plugin hooks remind on start and record end markers;
Plain skill installs include no hooks. `actions` shows workspace history.

Scripts always withhold protected editors, agents, shells, and shared MCP servers.
