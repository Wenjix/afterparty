# STE 100 language review

Date: 2026-10-19.

This review applies the installed `writing-simplified-technical-english` skill to Afterparty's operational text.
It covers CLI output, the terminal reviewer, command instructions, and current user guides.
The changes follow STE 100 principles. They do not certify compliance with the official STE dictionary.

## Review rules

- Use one term for each action or object.
- Use active voice and simple tenses.
- Give each sentence one main idea.
- Use at most 20 words for an instruction and 25 words for a description.
- Keep every safety condition, limit, and uncertainty.
- Explain a failure and the next action when the cause is known.
- Keep technical names when a simpler word would change the meaning.

Short labels, key legends, counters, commands, and structured fields use the exceptions below.

## Terms

| Term | Meaning |
| --- | --- |
| scan | Gather current information. |
| check | Test a condition. |
| target | A process group, worktree, or artifact that Afterparty reports or considers for cleanup. |
| process group | Processes that share a process-group ID, or PGID. A group action affects every member. |
| worktree | A Git working directory. |
| artifact | Generated output, such as a build directory or test report. |
| mark / unmark | Add or remove a cleanup choice in the terminal reviewer. |
| plan | A Markdown checklist with target identities and cleanup choices. |
| save plan | Write reviewed choices to a plan file. |
| apply | Execute the checked choices after the required safety checks pass again. |
| stop | End a process or process group. Signal names and `--kill` remain exact technical syntax. |
| delete | Remove filesystem content. Git worktree removal still uses Git. |
| unknown | The required information is unavailable. Unknown information does not authorize cleanup. |

The README defines the terms that readers need before they use the workflow.

## Coverage

The review inspected human text across all 36 library files and all seven production Go files.
It also inspected the launch scripts, plugin hooks, installed skill, and current workflow documents.
Files without operational prose required no text change.

| Surface | Files or scope | Result |
| --- | --- | --- |
| CLI help and status | `agent-hygiene.sh`, `audit-processes.sh`, `audit-git.sh`, `clean-artifacts.sh`, `devclean.sh`, `process-ledger.sh`, `glance.sh`, `apply.sh` | Replaced unclear metaphors. Split instructions. Kept supported commands and safety conditions. |
| Terminal reviewer | `review.sh`, `review.py`, `review_data.py`, `ui/main.go`, `ui/view.go`, `ui/sections.go` | Explained loading, ignored keys, choices, refusals, refresh, and saving. Added technical definitions to Help. |
| Plan text | `plan.sh`, `plan-collect.sh`, `plan-capture.sh` | Simplified reasons and consequences. Kept checkbox, metadata, and identity syntax. |
| Documentation output | `docs.py`, `docs.sh` | Simplified help, evidence reports, review reports, and recovery instructions. |
| Session reminders | `report.sh`, `hooks/hooks.json` | Explained the audit reminder and the session-end marker. Hook behavior did not change. |
| Receipt and settings errors | `apply-events.sh`, `devclean-settings.py`, `journal.sh` | Replaced unclear status and recovery text. Kept machine fields and result codes. |
| Shared helpers | Remaining library files; `ui/state.go`, `ui/text.go`, `ui/theme.go`, `ui/terminal.go` | Retained clear labels, technical diagnostics, schemas, and display helpers. |
| Launch scripts | Root and bundled `bin/afterparty`; `bin/build-review` | Reviewed command forwarding and build instructions. |
| Installed skill | `skills/afterparty/SKILL.md` | Simplified the body. Kept the trigger description, quoted search phrases, metadata, commands, and size limit. |
| Current user guides | `README.md`, `CONTRIBUTING.md`, `RELEASING.md` | Defined terms and split procedures into separate steps. Kept examples and policy conditions. |
| Agent workflows | `commands/audit.md`, `commands/docs.md`, `skills/afterparty/docs-review.md` | Simplified instructions. Kept review scope, approval, evidence, and completion requirements. |
| Structured interfaces | `docs/plan-snapshot.md`, `docs/apply-events.md` | Simplified prose. Kept schema tables and examples. |
| Current design guidance | `docs/design/terminal-ui-design.md`, `docs/design/terminal-ui-implementation.md` | Simplified current guidance. Retained original phases, mockups, and dated comparisons as historical records. |

## Examples

| Before | After |
| --- | --- |
| Keys are paused while evidence is collected. | Afterparty scans for cleanup targets. Afterparty ignores review keys during the scan. |
| 1 process group shown the door | 1 process group stopped |
| Snapshot refreshed; mark targets again. | The scan finished. Mark targets again. |
| Saving disabled until a valid refresh. | Refresh before you save the plan. |
| fingerprint moved | fingerprint changed |
| unrelated backup already owns the restore path | another backup file exists at the restore path |

## Safety accuracy

The review also checked whether shorter text preserved the actual evidence and policy.

- CPU use exactly at the configured limit remains eligible. Text says "at or below" for eligibility and "exceeds" for refusal.
- Mixed workspace attribution can include missing working-directory data. Text does not assume that every group spans several known workspaces.
- A dirty verdict can mean uncommitted changes or a failed Git check. Text preserves that uncertainty.
- Protection can cover editors, shells, agents, and other matching processes. Text refers to protection patterns.
- Occupancy describes a process working directory at or inside a target. It does not prove general file use.
- An incomplete scan can have several causes. Text does not invent a specific failed check.
- A tracked artifact can be a file. Text covers the target and files inside a directory.
- A missing target does not establish when it disappeared. Text avoids that timing claim.

These changes alter explanations. They do not alter cleanup eligibility or removal checks.

## Retained interfaces and records

| Exception | Reason |
| --- | --- |
| JSON keys, enum values, reason codes, target IDs, fingerprints, and TSV columns | Programs use these fields. They are identifiers, not English sentences. |
| Plan checkbox lines, section names, metadata, and canonical headers | Existing parsers and saved approvals require this syntax. |
| Plain table headings and fixed status markers | Scripts use these output fields. Clear prose can surround them without changing their format. |
| Command syntax, flags, paths, environment variables, and signal names | A rewrite would change the action or identifier. |
| Short key legends, labels, and counters | They identify controls or data. Full sentences would reduce the space for targets and explanations. |
| Raw tool diagnostics and quoted text | Afterparty must preserve the reported details. |
| Skill trigger metadata and quoted search phrases | The installed skill uses these words to route requests. |
| Marketing taglines and plugin descriptions | These express product identity rather than operational instructions. |
| License text, policy records, repository agent rules, historical plans, prior reviews, and dated mockups | These retain legal meaning, supplied rules, or historical evidence. This review does not recast them as current dialogue. |

Readable status text changed where necessary. Regression tests retain positive checks for the affected code paths.

## Validation

Validation covers CLI output, structured formats, terminal frames, installed-bundle instructions, and safety refusals.
The full Linux test inventory runs in a disposable container with an init process to reap exited children.
The terminal tests cover 60x20, 80x24, and 120x40 layouts, including color, monochrome, and ASCII output.
Additional checks cover shell syntax, Python syntax, blocking ShellCheck errors, plugin validation, local links, and LF line endings.
The repository's documentation workflow records the final evidence review separately in private state.

The remaining exceptions are intentional interfaces or records. They are not claims of full STE dictionary compliance.
