# Changelog

All notable changes to Afterparty are documented here. Versions follow semantic versioning.

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
