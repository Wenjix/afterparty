---
description: Run the afterparty audit and clean up what the session left behind
allowed-tools: Bash(bash:*)
---

## Context

- Dry-run audit of this machine and repo:
!`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit 2>&1; rc=$?; if [ "$rc" -ne 0 ]; then printf "\nAFTERPARTY AUDIT INCOMPLETE (exit %s)\n" "$rc"; fi`

## Your task

Summarize the leftovers above for the user in a sentence or two — stray
processes, localhost listeners, ledger entries, git leftovers (worktrees,
agent branches, index.lock, conflict litter, stashes). If any section is unavailable or the audit is incomplete, explain the gap.
Only claim a clean result when the relevant scans completed.

If `$ARGUMENTS` asks to clean, kill, or apply (e.g. "clean", "kill tests"),
run the matching gated command(s) with the Bash tool and report what
happened:

- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" stop --kill` — stop ledger-recorded groups
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit --kill <tests|dev|browser> --pgid <reviewed-pgid>` — kill reviewed stray groups in a category
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" git` — report git leftovers (`--clean` is report-only; removal goes through `plan`/`apply`)

Otherwise just offer those commands. Never signal protected processes (the
scripts refuse anyway); unmerged branches, dirty worktrees, and stashes are
report-only. Treat a nonzero cleanup status as a partial failure and report it
instead of claiming success. Find the prior session report with
`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" report-path`.
