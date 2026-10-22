# Architecture

Afterparty separates observations, cleanup approval, and execution. The terminal
interface presents evidence and saves choices. It does not execute cleanup.

The [README](../README.md) describes installation and commands. The contracts
for [plan snapshots](plan-snapshot.md), [apply receipts](apply-events.md), and
[build inventory](build-inventory.md) define their structured interfaces.

## Components and ownership

The root [CLI wrapper](../bin/afterparty) forwards to the self-contained
[skill bundle](../skills/afterparty/). Its bundled wrapper routes commands through
[`agent-hygiene.sh`](../skills/afterparty/lib/agent-hygiene.sh).
Installed commands do not depend on files outside that bundle.

| Component | Responsibility |
| --- | --- |
| [`plan.sh`](../skills/afterparty/lib/plan.sh), `plan-collect.sh`, `plan-capture.sh`, `plan-render.sh` | Collect proposals and their canonical Markdown from shared observations. Render captured output without independent discovery. |
| [`plan_data.py`](../skills/afterparty/lib/plan_data.py) | Serialize and validate snapshots, item identities, document mappings, completion records, and digests. |
| [`review.py`](../skills/afterparty/lib/review.py) | Collect snapshots and exchange private JSON messages with the terminal frontend. |
| [`review_data.py`](../skills/afterparty/lib/review_data.py) | Own target order, focus, filtering, marks, generation checks, contextual keys, and plan saving. |
| [`build_inventory.py`](../skills/afterparty/lib/build_inventory.py) | Discover generated output, measure it, compare private history, and supply read-only inventory state. |
| [`ui/`](../skills/afterparty/ui/) | Use Bubble Tea for input, rendering, resize, and terminal restoration. Apply layout and styling with Lip Gloss. |
| [`plan-format.sh`](../skills/afterparty/lib/plan-format.sh) | Parse checked Markdown entries before execution. |
| [`apply.sh`](../skills/afterparty/lib/apply.sh) | Recheck approved targets and execute the applicable cleanup path. Delegate process signals to the audit handler. |
| [`state.sh`](../skills/afterparty/lib/state.sh), [`journal.sh`](../skills/afterparty/lib/journal.sh) | Centralize private state, permissions, locking, and mutation receipts. |

Plugin hooks remain bounded and noninteractive. SessionStart reads saved
summaries. SessionEnd writes a separate session marker. Neither hook launches
the terminal interface or a build inventory.

## Evidence and approval

`plan` starts every item unchecked. Markdown and JSON describe the same captured
observations. Focus changes, filtering, detail toggles, and resizing do not
collect new evidence.

Keep these facts separate:

- **Magnitude:** observed CPU, process count, idle time, or estimated size.
- **Availability:** a target passed selection checks or is withheld with a reason.
- **Activity:** indexed agent transcript activity, its sources, or unknown activity.

Size and old modification times do not establish cleanup eligibility. Transcript
activity does not prove human presence or abandonment. Unknown activity never
authorizes a process proposal. Filesystem targets use their own checks.

Review follows Choose, Review choices, then Save plan. Each saved choice requires
an explicit mark. Focus, colors, filters, IDs, and fingerprints never approve
cleanup. Withheld targets remain inspectable without an override.

The writer checks the snapshot, marks, availability, and Markdown mappings. It
changes only the selected checkboxes, then parses and compares the resulting
checked targets. It publishes a private file without replacing an existing path.

A confirmed refresh clears all marks, even when familiar targets remain. Go
drops review actions during collection. Python rejects stale mark and advance
keys using a collection generation. A failed refresh disables saving until a
valid refresh succeeds.

Build inventory has no marks or save step. Enter opens a fresh artifact review
for the focused repository, with no inherited choices. The shared
[`artifact-kinds.tsv`](../skills/afterparty/lib/artifact-kinds.tsv) defines names
for inventory, artifact collection, and apply-time checks.

Cleanup requires a separate `afterparty apply PLAN` invocation. The checked
Markdown supplies approval. Snapshot hashes check consistency, not operating-system
ownership or authorization.

## Fresh checks and truthful results

Approval does not replace execution checks. Apply rechecks identity, activity
where required, protection, scope, occupancy, tracking, and nested repositories.
Unavailable required evidence refuses cleanup.

Process categories and eligibility use shared helpers. Ledger and audit cleanup
signal process groups with TERM, then KILL if needed. A protected member protects
the whole group. Devclean orphan cleanup signals individual PIDs because unrelated
processes can share their group. Both paths use the shared protection patterns.

Worktree identity includes the physical directory and Git administrative identity.
Filesystem checks use physical paths. Artifact checks reject symlinks, scope
escapes, tracked data, repository roots, and nested repositories. Worktree removal
rechecks cleanliness, ignored local data, and occupancy. Its nested-repository scan
excludes only the worktree's own Git metadata.

Occupancy means a process working directory at or inside the target. It does not
establish general file use.

Signal delivery and successful removal commands do not prove cleanup completed.
Confirm process absence or path disappearance. Native maintenance tools, such as
`pnpm store prune`, supply their own results. A journal failure preserves confirmed
effects but makes the overall result fail. Portable identity and occupancy checks
remain observations, not atomic ownership guarantees.

Documentation review is separate from artifact cleanup. Its collector records
deterministic evidence without editing project files or calling an LLM. Agent
judgment and unresolved reviews remain separate from new scans.

## Terminal presentation and fallbacks

[`style.sh`](../skills/afterparty/lib/style.sh) owns CLI styling and shared theme
policy. `s_review_theme` exports roles for Go's
[`theme.go`](../skills/afterparty/ui/theme.go). `NO_COLOR` removes hues while
retaining bold and reverse focus cues in the terminal interface.

Compact rows and bounded focus panels keep scope, status, choices, and keys
visible. Wide layouts place focused evidence beside the list. A phase indicator
tracks selection, review, and saving. Inspection and Review show full identities
and consequences. Shortened labels remain distinct. Display escaping never
supplies authoritative paths.

Inventory bars use the known allocated-byte total, including during filtering.
Unknown sizes retain their status. Repository subtotals include known estimates
and label incomplete evidence. Neither display establishes cleanup eligibility.
Collection pulses show activity beside elapsed time without claiming percentage
completion. Saved reviews use a static plan receipt.

The backend supplies primary hints, complete Help keys, and named commands.
Commands validate the scan generation, mode, focused identity, and current
availability before they use an existing handler. Separate Mark and Unmark
commands prevent a repeated request from toggling a target twice.
The Go command search never executes entered text. Apply remains separate.

Mode guidance stays separate from retained feedback. Routine acknowledgements
expire in the main footer after four seconds. Help retains their full text.
Refusals and save receipts remain persistent. Focused evidence uses structured
sections and exact hidden-line counts. Review retains every process-group member.

The optional helper supports macOS/Linux terminals. Small panes show a size notice
and preserve marks while blocking marking and saving. Unsupported review terminals
print an unchecked plan and return nonzero. Build inventory falls back to plain
output. Ordinary plain and JSON outputs retain their separate contracts.

## Verification

Focused suites cover snapshots and review in [`test-review.sh`](../tests/test-review.sh),
inventory in [`test-builds.sh`](../tests/test-builds.sh), and receipts in
[`test-apply-events.sh`](../tests/test-apply-events.sh). Go tests include whole-frame
snapshots at 60-by-20 and 80-by-24 in color and monochrome. Pseudo-terminal tests
cover interaction and terminal restoration.

Safety tests must prove that the intended guard ran, alongside its refusal.
Fixtures that enter apply paths must intercept machine tools and signals.
Run the full suite only in a disposable container, VM, or CI runner. The
[contributor guide](../CONTRIBUTING.md) gives setup and test commands.
