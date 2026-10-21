# Changelog

All notable changes to Afterparty are documented here. Versions follow semantic versioning.

## [0.14.0] - Unreleased

### Added

- Explicit source/plugin and Agent Skill release archives, with copied-bundle
  checks for required files, metadata, licenses, and read-only CLI operation.
- Release archives are published only after both are fully written; interruptions leave no partial archives.
- `afterparty builds`: a read-only terminal inventory of known generated output
  across explicit project roots. Rows show repository paths, allocated-size
  estimates, and growth against the previous complete matching-scope scan.
  Inspection and filtering retain full paths and scan errors. Enter opens a
  fresh artifact review for one repository. Plain and versioned JSON reports
  also work without the optional terminal helper.
- Shared artifact-name definitions keep inventory discovery, existing artifact
  proposals, and apply-time name checks consistent.
- `afterparty review`: compact guided target selection, optional detail with
  `d`, focused inspection with `i`, filtering, explicit marks, and Enter to
  advance through separate review/save/finish
  steps. Confirmed refresh clears marks; a failed refresh disables saving.
  Review writes a checked Markdown plan and never invokes cleanup.
- `afterparty plan --json`: one versioned snapshot of target identities,
  evidence capabilities, availability, canonical Markdown and integrity data.
  The reviewer and Markdown use the same collected observations.
- `afterparty apply --json`: versioned per-target outcomes and a completion
  digest, with confirmed effects, journal failures and delegated invocation
  failures reported separately. Process results use a private channel from the
  existing audit handler and an independent parent postcondition check.
- No-clobber plan publication with private permissions, explicit mark validation,
  snapshot/row checks and validation through the existing approval parser.
- A Bubble Tea 2.1.0 and Lip Gloss 2.0.0 terminal frontend over the Python
  evidence/save backend. An explicit `bin/build-review` inside the skill bundle
  builds its optional helper with Go 1.26+. Monochrome/ASCII display, fixed scope
  and controls surround scrolling evidence; a missing helper or unsupported
  terminal/runtime uses the read-only plain-plan fallback.

### Changed

- Replaced historical design experiments, task plans, and review reports in the
  public documentation tree with a concise current architecture guide.
  Public interface contracts remain available. Local critique output stays ignored.
- Reorganized the README around installation, review, and cleanup workflows.
  Removed repeated guidance and corrected scope/output examples. Added DevClean
  by ImL1s to the credits alongside Wenjie Fu and Kevin Liu's Agent-Broom.
- Expanded Wenjie Fu's project credit and acknowledged Bubble Tea and Lip Gloss
  for the terminal interface.
- Checked README instructions against the implementation and corrected the
  Python minimum, terminal-helper description, host documentation link, and plan overwrite guidance.
  Updated agent architecture rules, security reporting instructions, and privacy guidance.
- Invalid-option and missing-value errors name the command, the option, and a
  recovery step. Documentation distinguishes plan validation, fresh target
  checks, attempted actions, and confirmed outcomes.
- CLI and terminal-review text use short sentences, literal status messages, and
  consistent terms based on STE 100 principles. Help defines required technical
  terms. Refusals retain uncertainty when a safety check cannot finish.
- Current user guides and agent instructions use separate procedural steps.
  Historical records, legal text, parser fields, and command syntax retain their
  existing purpose and format.
- Guided review uses one-line targets and a bounded focus strip, backend row
  ordering, contextual keys and readable withholding reasons. Review choices
  starts with a three-row summary, retains every process-group member, supports
  unmarking, and shows evidence on `d`.
- Review focus uses bold reverse with terminal-default colors; monochrome keeps
  text attributes, and messages distinguish information, completion and refusal.
  Observation times use the local clock with live snapshot age.
- Top-level help groups commands by inspection, review, actions and history and
  uses the public `afterparty` command name. Bare invocation still prints help.
- Styled workspace, process, ledger, artifact and cache reports adapt to terminal
  width. Numeric facts stay aligned; complete commands and paths wrap into
  detail rows without cutting Unicode characters or losing significant spaces.
- Shared text geometry uses Python when available and escaped ASCII otherwise.
  Copyable next-step commands retain their shell quoting and one logical line.
  Plain tables, JSON fields, and plan metadata retain their existing formats.

### Fixed

- Codex history retention treats leading zeros as decimal. Zero-padded zero
  values and overflowing age limits are refused. Oversized process idle
  intervals withhold cleanup instead of wrapping to a shorter interval.
- Process plans and apply-time checks withhold groups when any member has
  missing, malformed, or nonfinite CPU evidence. Reports retain unknown CPU
  values instead of converting them to zero.
- Process-plan CPU capability reflects only groups included in the selected scope.
- Process eligibility and snapshots retain raw group CPU maxima while displays
  remain rounded to one decimal place.
- History cleanup excludes physical aliases of archived Codex sessions and
  directories that contain those archives.
- Ledger pruning preserves the original file when a replacement-row write
  fails, reports failure, and releases its private lock.
- Small terminal panes allow users to leave refresh confirmation and request
  quit confirmation while preserving marks. Large review lists compute labels
  in shared passes instead of scanning all targets for every row.
- Keys typed during collection or refresh cannot mark unseen targets or advance
  an older snapshot. Space after paging first reveals an off-screen focus.
  Cancelling or refreshing with marks requires confirmation; q closes help and
  inspection, and Ctrl+Z suspends without losing the draft.
- Existing `review --output` destinations are refused before collection with a
  recovery action. Small panes open a readable size notice with a tmux zoom hint,
  and Esc followed by another key is preserved.
- Saved-review exit output lists the choices and prints the apply command alone,
  using an absolute CLI path when needed. Copied rows contain no hard tabs and
  exit output starts cleanly under GNU screen.
- Review preserves Unicode separators in target paths and process commands
  when collecting evidence and validating saved choices.
- Focus navigation scrolls to reveal the target's essential facts, including
  its consequence and any withholding reason.
- Compact rows lead with meaningful target names and aligned measurements;
  full commands and evidence remain available in inspection and expanded views.
  Missing evidence stays pinned above the list. Enter finishes without saving
  when no targets are available, retaining a nonzero result for incomplete scans.
- Finishing a saved review prints a copyable apply command after restoring the
  terminal, preserving long paths and backslashes. Shrinking the terminal after
  saving still allows a successful finish.
- Worktree removal now treats a dangling symlink left at the target path as a
  surviving target, with a nonzero result and no confirmed-removal receipt.

## [0.13.0] - 2026-09-20

### Added

- `/afterparty:docs` documentation review with evidence-backed recommendations
  to update, mark historical, consolidate, archive, delete, flag or keep documents.
  The active agent prepares concrete previews and applies selected treatments.
- `afterparty docs` collects changed paths, related documentation, purpose hints
  and unresolved local Markdown links. `--since REF`, `--full` and `--root DIR`
  make scope explicit; default scope is HEAD versus the working tree, including
  staged and untracked files. The collector never modifies project documents.
- Versioned JSON Lines evidence, private snapshots, validated agent review records
  and separate review revisions. `--show`, `--report-path`, `--template` and
  `--save-review` support handoff; new scans preserve previous review findings.
- `docs --check` detects changes to reviewed evidence before agent edits. Partial
  collection cannot become a complete review. Saved review outcomes are explicitly
  agent-reported, with evidence freshness recorded separately.
- SessionStart reminders include documentation evidence/review summaries and
  unresolved counts. SessionEnd remains a bounded marker without a review scan.

### Fixed

- Browser classification recognizes system `google-chrome`,
  `google-chrome-stable` and `chromium-browser` processes with automation flags.
  Normalize the known macOS/bare `Google Chrome` executable before splitting
  process text, so headless-only launches are recognized too. Match complete
  automation flag names; lookalike prefixes and unrelated argv remain excluded.

## [0.12.0] - 2026-09-07

### Added

- Codex workspace activity from existing `sessions` and `archived_sessions`
  transcripts, alongside all immediate-project Claude JSONL files. Glance
  identifies the contributing providers, and process eligibility uses their
  shared activity index.
- `AFTERPARTY_CODEX_ROOT` selects the Codex history root for indexing, defaulting
  to `${CODEX_HOME:-$HOME/.codex}`. Existing Claude root configuration is unchanged.
  Discovery is read-only and requires no migration, registration, or new hook.

### Changed

- Activity indexing requires Python 3 and uses the latest transcript-file mtime
  per normalized workspace across both providers. Codex session and turn records
  contribute cwd paths; resumed file activity conservatively refreshes every
  workspace recorded in that file. Activity remains an observation of files,
  not human presence or a precise per-workspace visit time.
- Indexed ancestor activity also contributes to descendant workspaces, so fresh
  activity in a repository cannot be hidden by an older subdirectory transcript.
- Corrupt, unreadable, or incompletely scanned history makes the entire activity
  index unavailable. Missing optional history directories remain valid empty
  sources; records larger than 32 MiB and missing Python withhold
  activity-dependent cleanup. Other capabilities keep their own checks, and
  history deletion scope is unchanged.
- File consistency checks account for Windows pathname/handle timestamp
  differences while retaining identity and change detection. Transcript TSV uses
  UTF-8 and LF line endings on every platform. Windows CI checks
  transcript compatibility before running the full suite.

## [0.11.1] - 2026-09-06

### Fixed

- Devclean reports lost receipts separately from completed actions and returns
  nonzero. Failed orphan discovery cannot produce a successful spotless result.
- Process-plan eligibility uses the documented defaults for invalid startup
  idle/CPU settings instead of accepting fresh processes or failing arithmetic.
- `git --clean` also refuses outside a repository; conflicting artifact
  `--plan --clean` flags return a usage error instead of a successful proposal.
- The explicit plugin audit command is `/afterparty:audit`, distinct from the
  `/afterparty:afterparty` skill, avoiding same-name command precedence.

### Documentation

- Audited README, agent instructions, help, inline contracts, packaging, and
  historical plans against source. Clarified target-specific eligibility,
  heuristic protection, caller-based ledger attribution, report scope, history
  targets, native-tool limitations, and optional migration advice.
- Corrected fresh-install skill copies, hosted-runtime claims, component
  validation commands, and isolated test instructions. Removed the obsolete
  terminal illustration that recommended direct Git deletion.

## [0.11.0] - 2026-09-06

### Changed

- All plan actions start unchecked; scope defaults to the current repository.
  `--root`, `--all`, `--artifacts-only` and `--caches-only` make review scope explicit.
- Artifacts use typed plan/apply approvals. `artifacts --clean` is report-only
  and exits 2. Malformed checked plans are rejected before any action.
- Devclean mutation requires individual preview target IDs. Disk, history,
  orphan, deep and optimize modes have separate consequences; disk mode does
  not stop processes. History retention requires stale observed activity.
- SessionEnd records a bounded session marker without scanning. Explicit audits
  retain session archives, complete/incomplete status and failed sections.

### Fixed

- Artifact cleanup protects nested history and refuses failed Git inspection.
  Worktree cleanup preserves ignored local data added after approval.
- Ledger ownership includes process-member identity; reused IDs, unavailable
  inspection and unverifiable legacy rows cannot authorize stopping processes.
  Original workers can be cleaned after launcher exit without accepting a
  replacement group. Category selection checks executable/subcommand evidence.
- Missing process/listener evidence stays unavailable; glance retains
  unattributed processes. JSON numbers and cleanup exit semantics are consistent.
- Journal failures return nonzero independently of confirmed mutation results.
  Persisted display text redacts common credentials; actions gains workspace/date
  filters and opt-in retention.
- Claude skill path substitution, slash failure handling and installed bundle
  lifecycle coverage are corrected. Optimize edits effective JSONC settings with
  backup and restoration instructions.

If you have saved cleanup plans, regenerate them for the new defaults. Existing
ledger rows without member identity cannot authorize cleanup; register a known
running process again if you need to manage it. Fresh setups need no migration.

## [0.10.0] - 2026-09-06

### Added

- Linked worktrees in the plan/apply checklist, always unchecked by default.
  The current repository is discovered without requiring Claude transcripts;
  missing transcript history is shown as unknown staleness.
- Worktree removal checks fresh occupancy, nested repositories (including
  ignored paths), and directory and Git administrative identity. Incomplete
  scans and unavailable identity refuse removal, even for a checked item.

### Fixed

- A replaced worktree cannot inherit an approval from another directory or
  clone at the same path. Regenerate worktree plans created before 0.10.0.
- Artifact fingerprints retain available timestamp precision to distinguish
  rapid replacement when an inode is reused.
- KG5's signalling-loop assertion now executes. Symlink fixtures verify native
  support, and report-only tests isolate devclean's machine-level commands.
- Documentation directs Git cleanup through the worktree checklist;
  `git --clean` remains report-only and exits 2.

## [0.9.0] - 2026-08-19

### Changed

- **`git --clean` is now report-only** and exits 2. It discovered targets and
  destroyed them in one step from heuristics that could not carry the weight: a
  worktree's staleness came from HEAD's committer date and a top-directory
  mtime that does not move when files inside it are edited, so a worktree in
  active use read as idle indefinitely and removal took it along with every
  gitignored file in it. A gitignored `.env` is not cleanup debris.
- **devclean's roaming project scan is now report-only** under `--apply`. It
  walked `$DOCUMENTS_ROOT` for a directory NAME with no liveness check, no
  git-tracked veto and no age gate, and deleted from projects the user never
  named. Exact allowlisted cache paths such as `~/.gradle/caches` still clean
  normally — the cut is roaming-vs-named, not apply-vs-report.

### Fixed

- Category kills revalidate identity at the signal boundary. `--expect` gave
  plan-driven kills that gate while `audit --kill dev` had none, so a pgid
  freed and recycled mid-run was signalled on an authority never granted.
- Process groups 0 and 1 are refused at the point of signalling. `-1` means
  every process the user owns.
- An empty `--pgid` is an error rather than a silent widening to the whole
  category.
- Every `rg` invocation passes `--no-config`, so a user's ripgrep config can no
  longer disable the protect list.
- The `tests` and `browser` categories are anchored to command position. An
  unanchored `ava ` matched inside `java `, so `audit --kill tests` classified
  every JVM — a JetBrains IDE, a Gradle daemon — as a test runner.

Removal is moving behind `plan`/`apply` as typed targets. Approval will not
replace safety checks: tracked targets, symlink and scope escapes, repository
roots, nested repositories and incomplete scans remain hard vetoes.

## [0.8.0] - 2026-08-19

### Added

- `afterparty plan` — an editable checklist of what could be cleaned, one box
  per process group. Only items passing the two-signal eligibility gate arrive
  checked; `in-use`, `working`, `unknown`, and `no-rule` items are listed
  unchecked with the reason stated.
- `afterparty apply <plan>` — executes only the checked boxes, and only when
  the item is still what was reviewed. A moved fingerprint is refused rather
  than re-targeted, so a recycled process group cannot be killed by an approval
  that was never given for it. apply delegates every kill to `audit --kill`
  rather than signalling, so one kill discipline governs everything.
- `lib/fingerprint.sh`, `lib/eligible.sh`, `lib/categories.sh`.

### Changed

- Kill category patterns moved to `lib/categories.sh`, shared by
  `audit-processes.sh` and `plan.sh`. Patterns are unchanged.

## [0.7.0] - 2026-08-18

### Added

- `afterparty glance` — machine-wide, grouped by workspace, sorted by how long
  each has been left alone. Answers "what did I leave running?" on returning to
  the machine. `--oneline` for a status line, `--json` for JSON Lines.
- `lib/workspace.sh` — workspace attribution and staleness. Identity comes from
  the working directory an agent transcript records, so no directory-name
  decoding is involved; a workspace with no transcript reports no last-touched
  time rather than being assumed idle. Thresholds via `AFTERPARTY_IDLE_HOURS`
  (default 4) and `AFTERPARTY_STALE_HOURS` (default 24).

### Fixed

- `--help` no longer truncates its last line when a command is added. `usage()`
  renders a fixed line range that the header had already grown to fill.

## [0.6.1] - 2026-08-13

### Fixed

- Dev-server detection no longer matches prose inside a long command line.
  Agent runtimes carry their whole prompt in `argv`, so unanchored patterns
  such as `bun.*dev` spanned unrelated text ("bundle" ... "/dev") and offered
  live agent sessions to `audit --kill dev`. The bounded gap still admits
  flags and subcommands, so `bun --watch run dev` and Turborepo 2.x's
  `turbo watch dev` are recognized, but it never spans a bare prose word.
- Running agent sessions (Claude Code, Codex) are protected from ledger and
  audit group kills. The entry is anchored on the executable, so the shells an
  agent spawns — which carry an agent path in their arguments — stay killable.
  Devclean's orphan cleanup is unaffected and still targets orphaned agent and
  MCP processes.

### Changed

- The test suite no longer reaches past its fixtures onto the host: `--apply`
  cases now shim `launchctl` and `pgrep`, which address the real login session
  and process table regardless of `HOME`. This also removes an intermittent
  failure whose outcome depended on what other suites had left running.
- Age-gated Git fixtures use a portable `touch` fallback, so the suite passes
  on BSD/macOS as well as GNU/Linux.

## [0.6.0] - 2026-07-31

### Added

- Asynchronous `SessionEnd` reporting and a lightweight `SessionStart` reminder.
- Repository-scoped fallback reports, `report-path`, and `actions` discovery commands.
- A private, versioned JSON Lines action journal for confirmed mutation outcomes.
- Strict capability checks with `afterparty doctor --strict`.
- Exact `--pgid` narrowing for reviewed process-group cleanup.
- Portable ledger locking for concurrent `add` and `prune` operations.
- Standalone skill version and license metadata.

### Changed

- Mutation receipts now count only confirmed deletions and process exits.
- Process and protection inspection failures now fail closed.
- Artifact, global-cache, and optimize cleanup reject broad or symlink-escaped scopes.
- Every artifact collector now respects nested-repository boundaries.
- Persisted reports never overwrite an unrelated ignored `report.md`.
- JSON Lines output now includes `schema_version: 1`.

### Fixed

- Concurrent ledger pruning can no longer overwrite a newly added process entry.
- Degraded process scans can no longer produce a misleading spotless result.
- Failed Git, cache, configuration, PID, and PGID cleanup now returns a nonzero status.
- Crash-dump cleanup no longer treats a failed verification scan as success.
