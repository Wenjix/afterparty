# Changelog

All notable changes to Afterparty are documented here. Versions follow semantic versioning.

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
