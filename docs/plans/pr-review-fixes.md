# PR review fixes

This plan addresses the review of PR #10 (`d2beff1`) and PR #11 (`0824511`).
The KG5 test correction belongs to #10. The remaining fixes belong to #11,
which inherits the correction through its stacked base.

## PR #10: make KG5's assertion execute

- Restore KG2b's multiline `printf` and move the reachability assertion after
  KG5 captures the ledger output.
- Verify the normal test passes, then mutate discovery in a disposable copy so
  the row is withheld before signalling. The repaired assertion must fail for
  that specific reason.

## PR #11: require evidence before removing a worktree

1. Preserve cwd-scan failures rather than representing them as an empty,
   successful scan. Missing, failed, malformed, or incomplete discovery must
   withhold worktree removal with a visible reason and nonzero apply result.
   Refresh occupancy at the removal boundary, after any process cleanup.
2. Check linked worktrees for nested repositories, including repositories under
   ignored directories. Exclude the worktree's own root `.git` metadata. A
   failed filesystem scan must also veto removal. Test that unique nested
   history survives and that an ordinary clean worktree remains removable.
3. Bind worktree fingerprints to the physical directory and Git administrative
   identity as well as HEAD, branch, and cleanliness. A replacement at the same
   path, including one owned by another clone, must invalidate an old approval.
   Repeated fingerprints of an unchanged worktree must remain stable.
4. Discover the current repository independently of Claude transcripts, then
   include transcript-indexed repositories without duplicates. A worktree with
   no transcript is visible, unchecked, and marked with unknown staleness.

## CI and verification

- Make artifact identity distinguish rapid replacement using the available
  filesystem identity and timestamp precision. Separate a deterministic
  distinct-inode fixture from a controlled inode-reuse regression; document
  the limits of portable filesystem fingerprints.
- Make symlink fixtures confirm that real symlinks were created. Explicitly
  skip unsupported symlink cases on Git Bash rather than testing copied paths.
- Isolate report-only tests that invoke devclean's apply path with logging
  `pgrep`, `launchctl`, and `pnpm` shims and disposable working directories.
- For each behavior, run the failing reproduction, implement its fix, and run
  the corresponding test again. Mutate each new destructive guard in a scratch
  copy to prove the regression test observes that guard.
- Run Bash syntax checks, blocking shellcheck when available, and the full
  suite in an isolated snapshot. Record unavailable platform coverage instead
  of claiming Linux/Windows CI passed locally.
- Update user-facing documentation and release metadata for the resulting
  behavior. Existing worktree plans must be regenerated after identity changes.

## Completion record

Implemented across `fix/dead-tests` and `feat/typed-targets`, with package
metadata synchronized at 0.10.0. The KG5 correction is committed separately
on the base branch and inherited by the worktree feature branch.

- **PR #10:** KG5's assertion executes after its output capture. A discovery
  mutation passes the old test and fails the repaired assertion. The correction
  is isolated in `tests/test-kill-guards.sh` on #10.
- **Occupancy:** strict discovery rejects missing tools, failed/empty/partial
  output, stderr warnings, malformed records, and Linux inline cwd errors.
  Apply refreshes the scan after process cleanup for each worktree; plan uses
  the same strict evidence. A real macOS lsof scan also passed the parser.
- **Nested repositories:** ignored ordinary and bare repositories retain their
  unique committed history. Incomplete scans veto deletion; only the worktree's
  own `.git` metadata is excluded.
- **Identity:** the physical directory and Git administrative creation identities
  invalidate same-path replacements from the same or another clone. A final
  fingerprint check catches replacement during safety scans. Unavailable
  creation identity is an explicit refusal, and unchanged worktrees stay stable
  across status refreshes and ignored build output.
- **Discovery:** current-repository worktrees are visible without Claude history,
  and repositories found through multiple paths are listed once.
- **CI fixtures:** artifact identity retains GNU/BSD fractional timestamps;
  controlled same-inode replacement tests cover both formats. Native symlink
  support is checked before symlink assertions. Unsupported birth-time behavior
  is verified independently of the fingerprint implementation.
- **Test isolation:** report-only apply tests intercept machine-level commands
  and use disposable working directories. Outer sentinels saw four calls from
  the old test and none from the corrected test.

Validation on macOS:

- `bash tests/run.sh` in an isolated checkout: exit 0, 24 suites invoked, 267
  `ok:` checks, no failures. The live-kill suite skipped because `setsid` is
  unavailable. Outer machine-tool shims remained active for the full run.
- All shell scripts pass `bash -n`; production scripts pass ShellCheck 0.11.0
  at `--severity=error`; `git diff --check` passes.
- Eighteen targeted scratch mutations fail their intended assertions: ten
  safety guards, five identity checks, two plan checks, and KG5 reachability.
- Marketplace validation passes with `--strict`. Plugin-manifest validation
  passes normally; its strict mode retains the existing warning that root
  `CLAUDE.md` is developer context, not context loaded by an installed plugin.
  The shipped skill contains the agent instructions and remains under 250 words.

Native Linux and Windows runtimes were unavailable for local validation. Their
reported failures have regression coverage and fixture fixes; native CI results
are separate from the local results above. Portable filesystem identity remains
bounded by the timestamps and metadata the filesystem exposes; unsupported
worktree creation identity is refused rather than guessed.
