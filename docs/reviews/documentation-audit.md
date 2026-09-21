# Documentation accuracy audit

Date: 2026-09-06. Baseline: `e0d3bf1`. Corrections ship in 0.11.1.

Reviewed README, CLAUDE.md, the bundled skill, plugin command and hooks,
manifests, release metadata, CLI help and inline contracts, historical plans,
and the terminal illustration. Command claims were traced through the router
to the implementing scripts. Historical changelog entries retain their release
context; the [README](../../README.md) describes current behavior.

## Documentation corrections

| Surface | Finding and correction |
| --- | --- |
| Git/artifact help | Help still promised direct deletion. Both legacy `--clean` flags report and refuse; repository removal uses checked plan/apply targets. |
| Command effects | Replaced “every command reports first” with explicit behavior for immediate checked apply, ledger bookkeeping, and report writes. |
| Process ownership | `add` registers an existing PID; its trailing command is a display label. Workspace/cwd attribution comes from the caller. Group signals do not necessarily stop descendants that changed groups. |
| Protection | Documented the bundled command patterns and their limited coverage, including devclean's use of the shared list. Removed the old orphan exception and “usually safe to kill” wording. |
| Plans | Process groups require transcript/CPU eligibility; worktrees and artifacts use filesystem, occupancy and identity checks without a transcript-age requirement. Clarified `--all` discovery and fixed artifact scope. |
| Activity | Activity is observed Claude transcript-file mtime, not human presence or all-agent history. Removed the unused stale-hours setting from advertised controls. |
| Audit coverage | Clarified loopback/wildcard development-listener filtering, the protection-pattern legend, strict capability errors, and the limited sections covered by `doctor` and saved reports. |
| Persistence | Only `audit --report` saves audit snapshots. Documented ledger overrides, cached session archives, non-journaled early refusals, retained archives, and the fields covered by best-effort redaction. |
| Devclean | Documented target identity versus recursive contents, the 1024 KiB directory threshold, exact Codex/Gemini history scopes, and whole-directory modification-time retention. |
| Native tools | The configured pnpm store may be outside HOME. pnpm maintenance uses pnpm's exit status; launch-agent confirmation uses launchctl probes. Python is needed for simulator inspection as well as JSONC edits. |
| Installation | Added the parent-directory creation needed for a correct fresh skill copy and explicit Codex instructions. Distinguished local shell access, hosted execution, and terminal PATH installation. |
| Plugin entry points | The skill and command previously shared the same name. The general skill remains `/afterparty:afterparty`; the explicit audit command is `/afterparty:audit`. Plain copied skills have no plugin hooks. |
| Validation | Marketplace validation does not inspect all component contents. Documented explicit skill/command validation and isolated full-suite execution. Version metadata requires manual synchronization. |
| Help and examples | Fixed stale help boundaries, including source-code leakage from `glance --help`. Removed the terminal illustration that recommended obsolete Git deletion commands. |
| Historical plans | Marked implementation plans as historical records and made upgrade advice conditional. This owner's prior state was test data; there is no migration task. |

## Implementation gaps found while checking claims

- Devclean could complete an action, fail to write its receipt, and still exit
  successfully. Receipt failures now have a separate count and nonzero status;
  confirmed action counts remain intact. Regressions cover settings, cache
  deletion and an intercepted pnpm prune.
- Failed orphan discovery through the no-pgrep fallback could report spotless.
  Both backends now distinguish complete no-match results from unavailable,
  diagnostic or malformed evidence. Regressions prove scanner entry and verify
  successful-empty and failure cases without signalling any process.
- Invalid idle/CPU environment values set before sourcing became their own
  fallback values. Literal defaults remain 4 hours and 20 percent CPU; startup
  and per-call overrides are validated. Regressions cover both sides of each
  threshold and valid leading-zero/fractional inputs.
- `git --clean` outside a repository returned success, and artifact
  `--plan --clean` could return a successful proposal. These combinations now
  refuse consistently; ordinary non-repository Git reporting still succeeds.
- The plugin's duplicate command/skill name made the documented audit entry
  ambiguous. Distinct names are checked by the copied-bundle lifecycle fixture.

## Validation and practical limits

Verification uses disposable state and tool/signal interceptors. The outer
signal guard permits only the concurrency fixture's identified child process
to receive its intentional TERM; it preserves the tests' own exported signal
mocks. The Linux live-stop suite belongs in an isolated CI runner and skips
on this Mac because `setsid` is unavailable.

Checked shell syntax, blocking ShellCheck, all documented validator commands,
11 help entry points, relative documentation links, synchronized version and
license copies, and the 249-word skill. Focused regressions include failing
before/fixed-after checks and mutations of receipt, discovery and threshold
guards. All 29 suites passed in the isolated macOS checkout (294 `ok:` checks);
the live-stop suite explicitly skipped. Outer interceptors recorded no blocked
signals and one allowed TERM to the concurrency fixture's own child. Native
Linux/Windows CI outcomes are reported with the delivery.

Remaining limits are documented rather than presented as guarantees:
protection patterns are heuristic; portable identity/cwd scans are not atomic;
redaction does not cover every field or secret format; pnpm determines its own
pruning result; and a failed launchctl registration probe is treated as absence.
This review does not establish a general proof that arbitrary cleanup is safe.

External platform claims were checked against the official
[Claude skill guide](https://code.claude.com/docs/en/skills#where-skills-live),
[hook command fields](https://code.claude.com/docs/en/hooks#command-hook-fields),
[component validation scope](https://code.claude.com/docs/en/plugin-marketplaces#validate-a-plugin-or-a-directory-without-a-manifest),
[hosted skill scripting](https://support.claude.com/en/articles/12512198-how-to-create-custom-skills#add-scripts),
[Codex local skill discovery](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills),
and the [Agent Skills specification](https://agentskills.io/specification).
