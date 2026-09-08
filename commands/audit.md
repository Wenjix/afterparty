---
description: Audit leftovers and apply cleanup only within the user's approved scope
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

If `$ARGUMENTS` requests JSON, run
`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit --json`.
Return its JSON Lines and explain any nonzero status or unavailable capability;
do not infer success from valid JSON alone.

If cleanup is requested, identify the matching targets and preserve the user's
category and scope. Reuse approval already given for specific targets; otherwise
present them for approval before mutation. A request for one group does not
approve other ledger groups or a machine-wide category kill.

- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" stop` — preview this repository's recorded groups; add `--kill` only when that set is approved
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" audit --kill <tests|dev|browser> --pgid <reviewed-pgid>` — kill reviewed stray groups in a category
- `bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" plan > cleanup-plan.md` — propose unchecked process/worktree/artifact targets; apply only approved boxes

Without a cleanup request, summarize the audit and offer the relevant next step.
Never signal protected processes. `git --clean` and `artifacts --clean` are
report-only; branch and stash deletion are not supported. Report a nonzero
cleanup status and any partial outcome instead of claiming success.
Find the prior session report with
`bash "${CLAUDE_PLUGIN_ROOT}/skills/afterparty/bin/afterparty" report-path`.
