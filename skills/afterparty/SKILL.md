---
name: afterparty
description: Use before starting another localhost server, before coding handoff, when CPU/memory is high, when disk is low, or for "review documentation", "stale docs", "what is running", "what did I leave running", "welcome back", "approve cleanup", "devclean", "orphaned MCP", "cleanup terminals", "localhosts out of control", "free disk space", "stale worktrees", or "leftover branches".
license: ./LICENSE
compatibility: Bash 3.2+, Git, Unix tools; Python 3 for activity/docs/review. macOS/Linux/WSL; Git Bash has degraded process audits.
metadata:
  author: Wenjix
  version: "0.14.0"
---

Claude sets `${CLAUDE_SKILL_DIR}`. Other agents must use this skill's absolute directory.

On return, run:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" glance
```

Create a plan. Check targets the user approves. Apply the plan:

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" plan > cleanup-plan.md
"${CLAUDE_SKILL_DIR}/bin/afterparty" apply cleanup-plan.md
```

Targets start unchecked. Incomplete scans, nested repositories, and
changed identities block removal.

Before handoff, follow [documentation review](docs-review.md):

```bash
"${CLAUDE_SKILL_DIR}/bin/afterparty" docs --report --json
```

Before you start services or end a session, run:

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

`git` and `artifacts` report targets. Approve removal through `plan` and `apply`.
Devclean requires reviewed `--target` IDs.

`--json` emits JSON Lines except for `builds`. `audit --report` saves a report.
`report-path` shows its path. `actions` shows history.
Plugin hooks show reminders at session start. They record session end.
Plain skills have no hooks.

Scripts keep processes that match protection patterns.
