# Changelog

All notable changes to Afterparty are documented here. Versions follow semantic versioning.

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
