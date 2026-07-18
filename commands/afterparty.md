---
description: Run the afterparty audit and clean up what the session left behind
allowed-tools: Bash(bash:*)
---

## Context

- Dry-run audit of this machine and repo:
!`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit 2>&1`

## Your task

Summarize the leftovers above for the user in a sentence or two — stray
processes, localhost listeners, ledger entries, git leftovers (worktrees,
agent branches, index.lock, conflict litter, stashes). If everything is
clean, say so and stop.

If `$ARGUMENTS` asks to clean, kill, or apply (e.g. "clean", "kill tests"),
run the matching gated command(s) with the Bash tool and report what
happened:

- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" stop --kill` — stop ledger-recorded groups
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit --kill <tests|dev|browser>` — kill stray processes by category
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" git --clean` — apply the safe git subset

Otherwise just offer those commands. Never signal protected processes (the
scripts refuse anyway); unmerged branches, dirty worktrees, and stashes are
report-only. The last session's report, if any, is at `report.md` (repo
root, when gitignored) or `~/.cache/agent-processes/report.md`.
