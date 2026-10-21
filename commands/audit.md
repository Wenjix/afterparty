---
description: Audit leftovers and apply cleanup only within the user's approved scope
allowed-tools: Bash(bash:*)
---

## Context

- Dry-run audit of this machine and repo:
!`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit 2>&1; rc=$?; if [ "$rc" -ne 0 ]; then printf "\nAFTERPARTY AUDIT INCOMPLETE (exit %s)\n" "$rc"; fi`

## Your task

Summarize the reported leftovers in one or two sentences. Include processes,
localhost listeners, ledger entries, and Git leftovers. Git leftovers include
worktrees, agent branches, index.lock, conflict files, and stashes. Explain any
unavailable section or incomplete audit. Claim a clean result only when the
relevant scans completed.

If `$ARGUMENTS` requests JSON, run
`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit --json`.
Return its JSON Lines. Explain any nonzero status or unavailable capability.
Valid JSON alone does not prove success.

If the user requests cleanup, identify the matching targets. Preserve the
requested category and scope. Reuse approval already given for specific
targets. Otherwise, present the targets for approval before cleanup. Approval
for one group does not cover other ledger groups or a machine-wide category.

- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" stop` previews this repository's recorded groups. Add `--kill` only when the user approves that set.
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit --kill <tests|dev|browser> --pgid <reviewed-pgid>` stops reviewed groups within a category.
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" plan > cleanup-plan.md` proposes unchecked process, worktree, and artifact targets. Apply only approved checkboxes.

Without a cleanup request, summarize the audit and offer the relevant next step.
Never signal protected processes. `git --clean` and `artifacts --clean` only
report targets. Afterparty does not support branch or stash deletion. Report
nonzero cleanup status and partial results accurately.

Find the prior session report with
`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" report-path`.
