---
name: afterparty
description: Use before starting another localhost server, before coding handoff, when CPU/memory is high, when disk is low, or for "review documentation", "stale docs", "what is running", "what did I leave running", "welcome back", "approve cleanup", "devclean", "orphaned MCP", "cleanup terminals", "localhosts out of control", "free disk space", "stale worktrees", or "leftover branches".
license: ./LICENSE
compatibility: Bash 3.2+, Git, Unix tools; Python 3 for activity/docs. macOS/Linux/WSL; Git Bash has degraded process audits.
metadata:
  author: Wenjix
  version: "0.13.0"
---

# Afterparty

Claude substitutes `${CLAUDE_SKILL_DIR}`. Other agents: use this SKILL.md’s
absolute directory.

On return:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" glance
```

Apply only approved targets:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" plan > cleanup-plan.md
"${CLAUDE_SKILL_DIR}/bin/afterparty" apply cleanup-plan.md
```

Unchecked defaults; unknown scans, nested repositories and changed identity block removal.

Before handoff, follow [documentation review](docs-review.md):

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" docs --report --json
```

Before services and session end:

```bash
AFTERPARTY_SESSION_ID="${CLAUDE_SESSION_ID}" "${CLAUDE_SKILL_DIR}/bin/afterparty" audit --report
```

Record services:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" add --pid <PID> --kind dev --port <PORT> --purpose "<why>" -- <command>
```

Review before acting:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" stop --kill
"${CLAUDE_SKILL_DIR}/bin/afterparty" audit --kill dev --pgid <reviewed-pgid>
"${CLAUDE_SKILL_DIR}/bin/afterparty" artifacts
"${CLAUDE_SKILL_DIR}/bin/afterparty" devclean
```

`git`/`artifacts` report; approve removal through `plan`/`apply`.
Devclean requires reviewed `--target` IDs.

Supported `--json` commands emit JSON Lines. `audit --report` saves a snapshot;
`report-path` locates it. `actions` shows history.
Plugin hooks remind on start and mark session end. Plain skills have no hooks.

Scripts withhold protected editors, agents, shells and shared MCP servers.
