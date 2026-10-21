# Terminal UI implementation specification

Status: original implementation specification, written 2026-10-04 against
0.13.0. Commit `9210b5e` merged the first guided implementation on 2026-10-21.
The changelog lists 0.14.0 as Unreleased. The original phases below remain the
design record. [README](../../README.md), the [snapshot contract](../plan-snapshot.md),
and the [apply receipt contract](../apply-events.md) describe the implemented
command interfaces.

The merged implementation includes top-level help, responsive styled reports, a captured
plan snapshot, and the compact guided reviewer. The 2026-10-12 implementation
review selects **Bubble Tea 2.1.0 and Lip Gloss 2.0.0**. This replaces the
initial Python terminal loop. It supersedes unresolved adapter choices in the
original phase proposals below.

Collection captures canonical Markdown fragments and NUL-framed identity/evidence
records in `plan-capture.sh` and `plan-collect.sh`. `plan-render.sh` replays the
captured document. `plan_data.py` checks and serializes it. `review_data.py`
owns explicit choices and saves without overwriting existing files. `review.py`
provides a private JSON channel for state and keys to `ui/main.go`.

The build-output inventory uses the same helper and a separate read-only
`build_inventory.py` backend. It reports multiple explicit project roots
without changing the single-repository plan snapshot contract. Enter opens
a fresh artifact review for one repository. The
[inventory contract](../build-inventory.md) defines measurements and history.

Bubble Tea owns input, rendering, resize, and terminal restoration. Lip Gloss
lays out views in `ui/view.go` and `ui/sections.go`. Shared text and theme
helpers live in `ui/text.go` and `ui/theme.go`. Theme roles come from `style.sh`.
Shared CLI Unicode geometry lives in `terminal_text.py`. Noninteractive reports
use escaped ASCII when Python is absent.

The copied skill contains all these sources. Build its optional helper
explicitly with `bin/build-review` (Go 1.26+). At runtime, the helper requires
Python 3 but does not require Go. A copied built bundle works on the same
OS/architecture. Source installs without the helper retain the unchecked plan
fallback. See the [README build instructions](../../README.md#approving-cleanup-with-planapply).

The accepted keys are Space to mark, **Enter to advance**, `i` to inspect,
`d` to expand/compact, and Escape to go back. Enter opens Review choices,
then Save plan. A separate Enter in Save plan writes the plan. Enter on the
saved screen finishes. These bindings supersede the original Enter-to-inspect
proposal below and in the historical HTML mockup.

Review choices starts with a three-row summary, full identities and
consequences, and every process-group member. Space unmarks the focused choice.
`d` adds evidence checks. The backend emits the active key legend for each
mode. With zero available targets, Enter finishes without saving a plan.
Incomplete evidence still exits nonzero.

When targets are available, zero explicit marks cannot advance or save.

Styled workspace and process views stack below 80 columns. Wider layouts put
numbers before wrapped detail. Ledger fields, artifact paths, and cache labels
retain their full text. The output terminal's width takes precedence over
COLUMNS, with an 80-column fallback. Quoted commands and target IDs stay on
one logical line. Copying them does not insert shell syntax or split an ID.

Tests cover these layouts at 60, 80, and 120 columns. Ordinary plain reports
and JSON keep their existing contracts.

Choose uses one compact row per target. `review_data.py` groups and orders the
rows, so navigation follows the display. A fixed strip shows the focused
identity and consequence preview, or withholding reason, in at most four rows.
Overflow ends with an `i: full detail` hint. Inspection and Review show the
complete consequence.

If shortened labels collide, distinct ordinal prefixes separate them. Process
labels retain the full PGID. The position line names the focused target
within the filtered list. PageUp/PageDown scroll without moving target focus.
If paging hides the focus, Space reveals it first.

The saved screen names selected targets and directs the user to finish with
Enter or q. After terminal restoration, exit output repeats the choices and
saved path. It prints the exact apply command, with shell quoting, alone on
one logical line. If `afterparty` is absent from PATH, the command uses the
bundled CLI's absolute path. Display rows use spaces rather than hard tabs.

Exit output starts on a clean line even when GNU screen retains the last
frame. If the user finishes below the minimum size, review still reports the
saved plan and succeeds.

Terminal support is macOS/Linux. Supported terminals can launch below 60×20.
The reviewer shows the current and required dimensions. It keeps marks and
suggests tmux `prefix z`. Marking and saving resume when the pane can show
the choices. Unsupported terminals retain the unchecked plain-plan fallback.

Scope, scan status, unavailable capabilities, steps, count, and keys remain
fixed on screen. Scope and actionable keys use the terminal's default
foreground. Focus uses bold reverse with no hue. Monochrome keeps bold and
reverse attributes. Messages use info, done, and refused kinds. They put the
sentence first and diagnostic code last.

Help separates Keys from Scan status. Observation time uses the local clock
plus live snapshot age. Idle durations are readable.

Go whole-frame snapshots cover 60×20 and 80×24 in color and monochrome.
Layout and public-CLI pseudo-terminal (PTY) tests also cover these behaviors:

- both detail densities and Enter navigation;
- saving, finishing, and completion without available targets;
- input during loading and refresh;
- off-screen focus and discard confirmation;
- small panes, suspension, and terminal restoration.

Filesystem size context retains the existing human-readable artifact estimate.
The implementation does not add exact byte totals or worktree sizes.
The merged implementation also includes structured apply receipts (Phase 4).
The optional dashboard (Phase 5) remains a separate proposal that requires a
decision.

During the first scan and every refresh, Go drops review keys except q and
Ctrl+C. Each completed snapshot has a generation number. Python rejects
Space, Enter, and `s` from an older generation. It reports how many keys it
ignored. A generation identifies a collection, not a revision after each key.
Rapid navigation and marking over SSH remain usable.

A confirmed refresh clears marks. With marks set, q and r each ask once
before they discard marks. In help or inspection, q closes that view.
Ctrl+Z suspends and resumes the app without cancellation. The app handles
Alt chords from a fast Esc then key as those two keys. Collection shows
elapsed time.

The launcher refuses an existing `--output` path before collection. It
explains how to choose a new destination. The writer still checks for files
created during review and refuses to overwrite them.

The receipt adapter uses `apply-events.sh` and `apply_events.py`. `state.sh`
supplies its private run directory. Each checked target has one final result.
The parent checks delegated process evidence and independently checks absence.
Unavailable child evidence leaves `mutation_attempted` and `receipt_status`
null. False or not-attempted would invent knowledge.

The invocation fails even when the parent independently confirms target absence.

All remaining unimplemented commands, flags, and modules below are proposals.
The 0.14.0 reviewer does not imply those features. Cleanup requires a separate
explicit apply invocation. The [terminal UI design](terminal-ui-design.md)
describes the experience. The [references](terminal-ui-references.md) record the
adapter comparison.

## Decisions carried into implementation

- Preserve the Bash CLI and the copied, self-contained Agent Skill.
  Interactive dependencies are optional. Only explicitly invoked human
  commands use them.
- Start the human review command with the guided compact view.
  Choose → Review choices → Save plan is its primary workflow. Bare invocation,
  ordinary reports, agent commands, and plugin hooks keep their behavior.
- Let d toggle Expand details / Compact view for the same snapshot. Keep
  focus, explicit marks, the current step, search, and scope. Density changes
  affect presentation only.
- Use **available** and **withheld** for proposal availability. Keep activity,
  CPU, size, and outcome separate. Available does not mean safe.
- Start every proposal unchecked. Focus, highlighting, filtering, eligibility,
  an item ID, and a fingerprint never authorize cleanup.
- Collect each required observation once per collection stage. Render every
  representation from those captured observations. Moving focus or resizing
  the terminal does not run discovery.
- Review saves a plan and never invokes apply. Apply retains every existing
  identity, policy, protection, occupancy, delegation, and postcondition check.
- Clear all marks after confirmed refresh, even if item IDs or fingerprints
  stay unchanged. Ask before clearing a nonempty draft. Never restore marks
  automatically.
- Keep glance read-only. Keep devclean's target-ID model separate from
  repository process-group, worktree, and artifact plans.

## Current implementation boundaries

| Area | Current implementation | Consequence for the proposal |
| --- | --- | --- |
| Entry points | The [root wrapper](../../bin/afterparty) forwards into the [bundled wrapper](../../skills/afterparty/bin/afterparty), then [agent-hygiene.sh](../../skills/afterparty/lib/agent-hygiene.sh). | Add routing inside the bundle. Avoid dependencies on checkout-only files. |
| Styling | [style.sh](../../skills/afterparty/lib/style.sh) owns TTY and NO_COLOR behavior, colors, glyphs, severity cells, meters, cards, and composite counters. | Extend shared helpers. Keep palettes and thresholds out of callers. |
| Workspace evidence | [workspace.sh](../../skills/afterparty/lib/workspace.sh) and [workspace-index.py](../../skills/afterparty/lib/workspace-index.py) own attribution and transcript activity. | Display their evidence. Never infer activity from a running process alone. |
| Proposals | [plan.sh](../../skills/afterparty/lib/plan.sh) emits unchecked Markdown. [clean-artifacts.sh](../../skills/afterparty/lib/clean-artifacts.sh) supplies artifact proposals. | Extract collection from rendering before adding a structured plan view. |
| Approval parsing | [plan-format.sh](../../skills/afterparty/lib/plan-format.sh), through plan_read_checked, checks checked plan entries before mutation. | The saved Markdown remains the authority consumed by apply. |
| Execution | [apply.sh](../../skills/afterparty/lib/apply.sh) checks targets again. It delegates process stopping to [audit-processes.sh](../../skills/afterparty/lib/audit-processes.sh). | A selector or adapter never signals processes or removes cleanup targets itself. |
| JSON and receipts | [json.sh](../../skills/afterparty/lib/json.sh) supplies JSON Lines helpers. [journal.sh](../../skills/afterparty/lib/journal.sh) records mutation outcomes. | Add separate structured proposal and apply streams. Preserve existing JSON rows. |
| Private state | [state.sh](../../skills/afterparty/lib/state.sh) owns state locations, modes, and locks. | Add the snapshot helper here. Use the existing cache root. |
| Hooks | [hooks.json](../../hooks/hooks.json) runs bounded report reminders and a session marker. | Neither hook launches an interactive reviewer or dashboard. |

The current plan includes process-group members, purpose, workspace, listening
ports, and consequences. Use those facts in the evidence pane. Avoid a new
heuristic inspection in the interface.

## Phase 1 Polish the existing CLI and help

Ship this independently of an interactive adapter. Concentrate on clearer hierarchy,
consistent alignment, width handling, and next steps.

### Proposed changes

| File | Proposed functions or changes |
| --- | --- |
| style.sh | Add s_columns and shared layout helpers for column budgets, wrapped detail rows, and compact status summaries. Keep existing severity and size policy here. |
| glance.sh | Use shared layout helpers for a compact table at ordinary widths and stacked rows below 80 columns. Retain full workspace identity in detail output; unknown remains unknown. |
| audit-processes.sh and process-ledger.sh | Align identity and numeric columns consistently; wrap command detail rather than allowing it to shift neighboring columns. |
| clean-artifacts.sh and devclean.sh | Reuse shared size cells and summaries; retain streaming plain output and streaming destructive narration. |
| agent-hygiene.sh | Replace source-comment extraction for top-level help with a deliberate usage renderer grouped around observe, review, act, and history. Route command help to the relevant existing parser. |

Proposed display breakpoints are below 80, 80–119, and 120 or more columns.
Resolve width from the active terminal, then a valid COLUMNS value, then 80.
Measurement failure selects a simpler wrapped layout. Avoid byte truncation of
UTF-8 paths. A compact label must have a full, unambiguous identity available in
its detail view; the saved approval plan always contains the complete path.

Presentation changes are confined to styled human output. Existing data-bearing
plain output, JSON output, report bodies, eligibility, and exit statuses retain
their contracts. Top-level help is an intentional text change and needs help
regressions; it must not expose source code or start scans.

Do not add a second banner around every child script. Prefer one mode line, a
quiet table header, and a truthful summary. Green confirmation describes a
confirmed outcome; magnitude coloring follows existing style helpers.

### Acceptance

- Capture deterministic styled fixtures at 60, 80, and 120 columns, including
  long and multibyte paths, empty results, and incomplete scans.
- Keep piped automatic output byte-equal to the plain branch for the same
  observations. Existing JSON remains valid and ANSI-free under forced style.
- Exercise NO_COLOR, TERM=dumb, explicit style overrides, and stderr gating.
- Help names the available commands and flags, returns without discovery, and
  never implies blanket cleanup approval.
- Reuse test-style, test-style-helpers, test-proc-tables, and test-glance;
  introduce only focused layout/help cases appropriate to the changed surface.

## Phase 2 Introduce one structured plan snapshot

Add the proposed command:

~~~bash
# Proposed; not supported by 0.13.0.
afterparty plan --json --root /work/afterparty
~~~

Existing plan flags retain their scopes. Ordinary plan still prints the current
Markdown contract. JSON mode produces one JSON Lines snapshot, including the
canonical Markdown representation generated during that same invocation.

### Collection and rendering modules

| File | Proposed responsibility |
| --- | --- |
| New lib/plan-collect.sh | plan_collect, plan_collect_process_groups, and plan_collect_worktrees capture proposals using existing workspace, eligibility, category, protection, fingerprint, and veto helpers. |
| clean-artifacts.sh | Extract artifact_collect and artifact_emit_candidates so its report, Markdown proposal, and structured proposal share the same collector and final nested-repository guard. |
| New lib/plan-render.sh | plan_render_markdown builds the canonical Markdown from captured records in Bash, preserving ordinary plan behavior without requiring Python. |
| plan.sh | Parse scope once, invoke shared collection and the common Markdown renderer, then print Markdown or pass those exact bytes and records to the JSON serializer. Avoid discovery inside rendering callbacks. |
| New lib/plan-data.py | Validate and serialize the captured records and canonical Markdown; assign snapshot/item IDs, verify row mapping, and assemble the structured stream. It performs no process or filesystem policy discovery. |
| plan-format.sh | Preserve plan_read_checked and the accepted Markdown schema. Add a non-mutating validation entry point usable when checking a newly saved plan. |
| json.sh | Keep existing helper semantics unchanged. The new serializer uses lossless JSON encoding for identity fields. |

A capture boundary does not make observations atomic. Existing protection and
fingerprint calls remain policy-required observations, and strict occupancy
stages remain where their policy requires them. The requirement is that
Markdown and JSON do not run independent collectors and that UI interactions
do not trigger more scans. Apply still obtains fresh evidence later.

Internal TSV records retain the existing sentinel rule: no empty middle field.
The serializer must reject malformed or incomplete internal records. Never
silently turn unavailable evidence into an empty successful collection.

The JSON mode may require Python 3 for serialization. Missing Python refuses
that mode explicitly; it does not break ordinary Bash plan output or enable
proposals that depend on unavailable transcript evidence.

### Proposed JSON Lines records

Every record carries contract "afterparty.plan", schema_version 1, and the
same snapshot_id. Versioning this new contract does not change the existing
schema_version 1 audit/list/git streams.

| Section | Required data |
| --- | --- |
| plan_scope | snapshot_id, observed_at, physical root, process/worktree scope, artifact scope, flags, and collection_status. |
| plan_capability | name, target types affected, status, and explanatory reason. Include unavailable evidence even when there are no items. |
| plan_item | item_id, target type, exact target, relevant scope, fingerprint or null, availability, reason_code, reason, selected=false, evidence, consequence, and Markdown mapping. |
| plan_document | Canonical Markdown text and its full SHA-256 digest. Exactly one document per snapshot. |
| plan_complete | Snapshot digest, item counts, section completion, and collection_status. Exactly one terminal record. |

The reader requires the terminal record, matching IDs/digests, valid mapping,
and supported schema. A truncated stream is unusable and cannot be saved as a
reviewed plan. A successfully terminated but incomplete scan retains visible
withheld items and capability reasons. Independent available sections may
remain reviewable only when their own required evidence is complete; a global
index failure withholds every dependent process proposal.

The proposed JSON mode exits 0 for complete inspection, 1 for inspection gaps
or failed collection, and 2 for usage/unsupported-format errors. A reviewer can
inspect an exit-1 snapshot only when its terminal framing and integrity checks
pass; that status never promotes affected items to available. Ordinary plan
keeps its existing exit behavior.

JSON values use numbers for numeric observations and null for unknown values.
Ports are an array, not a whitespace-formatted string. Preserve exact identity
strings; terminal sanitization and display redaction never derive an identity.
The current json_escape helper deliberately flattens controls, so it must not
be reused for authoritative paths in the new contract. Persisted command
display fields use the existing plan redaction behavior; raw argv used for
classification or fingerprinting stays separate from displayed evidence.

### Item identity and Markdown mapping

Assign an item_id from the target type, normalized exact target, and applicable
scope using an unambiguous length-framed encoding and SHA-256. Use a
type-prefixed hexadecimal ID, stable across snapshots of the same named target
and scope. A process target is the PGID; filesystem targets are the full paths
used by the backend. A same-path replacement can retain its UI ID but must
carry a changed fingerprint.

Item IDs support lookup and rendering only. A snapshot ID identifies the
captured review context. Fingerprints compare observed object identity. The
checked Markdown checkbox is the approval supplied to apply.

For available items, map each ID to the one-based header line, checkbox column
4, and SHA-256 of the original header line excluding its trailing LF. The
original header begins "- [ ]". A withheld item has a header line for
inspection but no writable checkbox mapping. Also retain the full-document
digest. This permits a writer to change the checkbox character without
reconstructing a target from a rendered label.

The following shortened **specification example** describes the process fixture.
Digest values are placeholders and would fail real validation.

~~~json
{
  "contract": "afterparty.plan",
  "schema_version": 1,
  "section": "plan_item",
  "snapshot_id": "example-snapshot",
  "item_id": "process-group:example-sha256",
  "type": "process-group",
  "target": "4821",
  "scope": "/work/afterparty",
  "fingerprint": "example-fingerprint",
  "availability": "available",
  "reason_code": "eligible",
  "reason": "Recorded agent activity is old and observed CPU is below the threshold.",
  "selected": false,
  "evidence": {
    "workspace": "/work/afterparty",
    "category": "dev",
    "members": [{"pid": 4821, "command": "npm run dev"}, {"pid": 4822, "command": "vite"}],
    "cpu_max": 0.2,
    "ports": [3000],
    "activity": {"status": "known", "idle_seconds": 64800, "sources": ["codex-transcript"]},
    "recorded_purpose": null
  },
  "consequence": "Stop every member of group 4821; restart the service manually.",
  "markdown": {"header_line": 12, "checkbox_column": 4, "header_sha256": "example-row-digest"}
}
~~~

### Target-specific evidence

| Type | Availability inputs | Separate review context |
| --- | --- | --- |
| Process group | Existing two-signal eligibility, one resolved workspace, supported kill category, protection, and verifiable identity. | Agent transcript activity and provenance, maximum observed member CPU, members, ports, purpose, and group-wide effect. |
| Worktree | Existing clean/ignored-data policy, occupancy, nested-repository, structural, and creation-identity checks. | Branch, measured directory size when available, and agent activity; recent or unknown activity is not itself a removal veto. |
| Artifact | Existing allowlist, scope, tracking, nested-repository, complete scan, occupancy, and identity checks. | Measured size when available, kind, and rebuild consequence. |

Current worktree Markdown can display "in-use" or "unknown" as activity context
on an unchecked proposal. Preserve that legacy representation initially; the
structured reviewer shows availability and activity in distinct fields.
An unknown size displays unknown, never zero.

### Acceptance

- A fixture proves Markdown and JSON carry identical targets, scopes,
  fingerprints, withheld reasons, and consequences from one collection.
  A logging scanner proves the renderer did not perform a second collection.
- All available items start unselected; withheld items have no writable mapping.
- Stable IDs survive sorting/filtering; changed physical identity changes the
  fingerprint and never becomes approval.
- Path spaces, quotes, backslashes, Unicode, equal basenames, and supported
  control characters preserve exact JSON identity. Unsupported paths are
  withheld consistently with existing policy, never flattened into another path.
- Invalid records, duplicate IDs, bad mapping/digests, unknown schema, and
  incomplete framing produce explicit snapshot rejection. Failed evidence
  produces an explicit capability reason and withholds affected targets.
- Existing plan, plan-scope, worktree, artifact, fingerprint, veto, and copied
  skill fixtures still exercise the same public CLI behavior.

## Phase 3 Add an optional guided save-only reviewer

Add the proposed command:

~~~bash
# Proposed; review writes approval choices but does not perform cleanup.
afterparty review --root /work/afterparty --output ./cleanup-plan.md

# Existing explicit execution remains a separate invocation.
afterparty apply ./cleanup-plan.md
~~~

The preferred first interactive delivery is the compact guided view combined
with the polished detailed presentation from Phase 1. It begins with the
target choices and keeps the essential consequence and any withholding reason
visible. The visible d action expands that same captured proposal into the
detailed presentation and returns to compact view without changing choices.

[Gum's choose/filter/pager utilities](https://github.com/charmbracelet/gum#commands)
are a candidate for the guided adapter. Audit its actual custom-key and
state-restoration behavior before committing to the tool. The required d
interaction is not established merely by having a multiselect and a pager.
An optional [fzf adapter](https://github.com/junegunn/fzf#usage) remains an
alternative searchable list/preview presentation; it is not the default design
or a required dependency of guided review.

### Proposed files and functions

| File | Responsibility |
| --- | --- |
| agent-hygiene.sh | Route review without changing the default command or any hook. |
| New lib/review.sh | Parse scope/output, choose an available presentation before collection, capture one snapshot, and own the guided workflow, compact/details toggle, refresh/cancel/save, and saved-path result. |
| New lib/review-data.py | Load/validate snapshots, maintain explicit review state, supply compact/detailed rows and focused evidence, and implement review_save against the exact captured document. |
| New lib/review-preview.sh | Fixed helper for evidence rendering; accept only validated opaque IDs and a bound private snapshot location. Source style.sh for shell presentation. |
| Possible lib/review-keys.py | If toolkit composition cannot preserve the required hotkeys/state, a bounded native key loop may own input and terminal restoration using the existing Python dependency. This is a feasibility question, not a committed new module or framework. |
| state.sh | Add state_review_dir for workspace-keyed, private reviewer snapshots. |
| style.sh | Supply reviewer shell styling and an explicit theme export for a future adapter; no independent palette or magnitude thresholds. |

Both the shell controller and the save helper treat snapshot and selector output
as untrusted input. A selector's displayed label is never parsed into a path,
command, PGID, or category.

### Interaction and state

The guided steps are Choose, Review choices, and Save plan. The controller's
operational states are collecting, reviewing, refreshing, saving, saved,
cancelled, and failed. Density is a separate compact/expanded value, not a
workflow transition. There is no applying state.

Arrow keys or j/k move focus; Space toggles an available item; slash filters;
Enter opens focused target evidence; s opens Review choices; d toggles the
visible Expand details / Compact view action. The labelled Save plan action
is available only after reviewing the explicitly marked set. r requests a new
snapshot; q cancels; Escape backs out of evidence or the summary without
clearing choices. There is no bulk-select binding in the first version.
Filtering does not change the selection set, and the header reports total
marks including those currently hidden by the filter.

The review state holds snapshot_id, exact scope, guided step, density,
focused_item_id, explicit marked IDs, search query, and the return location for
evidence/summary views. d changes only density. It does not recollect evidence,
reset the step, rewrite the plan, imply a mark, save, or invoke apply. Opening
and closing evidence is also independent of the mark set.
Density preference persists through Choose, focused evidence, Review choices,
Save plan, and the saved result within the session. A new explicit review
session starts compact. Toggle labels remain visible as "d Expand details" or
"d Compact view", including in the saved result.

Compact means less secondary context, not less essential review information.
Show identity, availability, a short consequence, and each withheld reason.
Expanded output adds the captured evidence and full target paths through the
shared styled helpers. It does not run audit or plan again to obtain detail.
Keep the active step, scope, completeness, mark count, and next action visible
in both densities. Use words and ASCII labels in monochrome/no-glyph terminals.
The guided reviewer remains a single-column sequence in both densities, with
expanded evidence in stacked text rows. Review choices always shows every
selected target's full identity and full consequence before Save plan,
regardless of density.

At less than 60 columns, use wrapped sequential rows and a full-width evidence
view, or offer the read-only fallback below if the adapter cannot support the
terminal. Density remains a content choice: expanded need not mean side-by-side
panes. Navigation bindings must not consume query characters while searching;
test the actual adapter keymap rather than assuming its default behavior.

The guided view keeps withheld findings visible and inspectable without a
writable checkbox. A toolkit with no disabled-row guarantee uses a separate
read-only withheld reader; the compact step still shows the withholding reasons.
The fzf alternative uses an available-only selectable list plus that reader.

Refresh clears all marks before replacing the snapshot and announces the reset.
If refresh fails, browsing may continue against the old visibly dated snapshot,
but marks remain cleared and saving is disabled until a valid snapshot is
obtained. Resizing and focus changes use captured data only.

**Explicit marks require their own evidence.** The
[fzf manual](https://github.com/junegunn/fzf/blob/master/man/man1/fzf.1)
documents that selected-item placeholders can fall back to the current item
when nothing is selected. Default Enter output therefore cannot prove approval.
The Save path must convey a positive explicit mark count and the marked opaque
IDs separately from focus. Bind Enter to evidence inspection rather than the
selector's default acceptance action. For the optional fzf adapter, unavailable
selection-count/binding capability enters the read-only fallback. Do not
silently select the focused row.

Save with zero explicit marks produces no checked plan and no output-file
write; it returns to Choose or allows cancellation. A future deliberate
"save an empty plan" action would need its own explicit interaction.

### Adapter feasibility and terminal lifecycle

Before selecting Gum for the default adapter, prototype d in Choose, in target
evidence, and in Review choices with a marked item and a nonempty search.
Demonstrate that reopening or reconfiguring a toolkit subprocess restores the
focused ID, marks, current step, scope, and query. Do not assume a shell
wrapper can intercept d while another process owns raw terminal input.

If toolkit composition cannot satisfy the state contract, evaluate a small
wrapper-owned key loop that renders through style.sh and uses only already
required core/runtime tools. It must own termios/raw-mode entry and restoration,
cursor visibility, SIGINT/TERM, resize, subprocess ownership, and normal terminal
exit. Do not have the wrapper and toolkit race to consume input. If this would
require a larger maintained TUI, stop that adapter experiment and use the plain
fallback rather than changing approval behavior to fit a library.

Gum remains a candidate, and fzf remains an optional alternative. The first
implementation milestone chooses the smallest adapter that proves compact
guided review and the d contract on supported terminals; framework/version
selection is not settled by this specification.

### Concrete read-only fallback

The fallback adds no UI dependencies to the existing core. With no usable
interactive terminal, toolkit, or custom-key support, the reviewer reports
that no plan was saved and prints the existing unchecked Bash plan once using
the same scope flags. When a snapshot was already captured, render its canonical
Markdown rather than collecting again. When unsupported capability is known
before collection, select the existing Bash renderer before collecting once.

For the illustrative scope, the user can invoke:

~~~bash
# Existing Bash proposal; no optional UI dependencies.
afterparty plan --root /work/afterparty
~~~

Keep automatic fallback stdout plain and direct its capability explanation to
stderr; return a nonzero review result to make the absence of a saved plan
explicit. Fallback never writes the requested output file or approves a
checkbox. The user may use the existing plan/redirection/editor/apply workflow
deliberately afterward. Core evidence requirements still apply; missing Python
means unavailable activity and withheld dependent process proposals, not a
mandatory new UI package.

### Saving the reviewed plan

The writer verifies the bound snapshot ID, complete stream, document digest,
unique marked IDs, explicit mark count, availability, and checkbox mappings.
It rejects the entire save if any marked ID is absent, withheld, duplicated, or
from another snapshot.

For each mark, require the expected untouched header row and change only the
space inside "- [ ]" to "x". Preserve all other canonical Markdown bytes.
The first version leaves the existing Why section for manual editing afterward.
Validate the resulting checked metadata through plan_read_checked before
publishing the file. That validation is not a substitute for apply-time checks.

Write through a private temporary file and publish without overwriting an
existing unrelated output file. An explicit output path is the user's chosen
destination; without it, save under state_review_dir and print the exact path.
Directories use 0700 and files 0600 where supported. Never auto-create a
cleanup-plan.md in the repository just because review was opened.

The saved summary names each marked target and its consequence and prints the
properly shell-quoted command for a separate apply invocation. It reports
"plan saved", never "cleaned" or "applied".

Preview bindings invoke a fixed, quoted installed helper with validated opaque
IDs. They never evaluate target text or command displays. Clear inherited fzf
option/default-command inputs, including an option-file setting where supported,
for this invocation so user-global bindings cannot become an implicit cleanup
action. Avoid dependence on newly introduced fzf styling flags until a supported
release is selected and tested.

### Acceptance

- Open, filter, move focus, inspect withheld targets, refresh, resize, and cancel
  without invoking apply, audit --kill, signals, or target deletion.
- Start explicit human review in compact Choose, showing the essential
  consequence and withheld reasons. Ordinary commands and bare invocation
  retain their existing entry points.
- Mark two items, focus a different item, enter evidence or Review choices, and
  toggle d both ways. Assert the same snapshot ID, scope, focused ID, guided
  step/return location, search, and mark set; logging scanners must record no
  new collection and mutation/save interceptors must record no action.
- Carry expanded density forward/back across guided steps and toggle it in the
  saved result. Preserve the density preference and saved plan bytes; Review
  choices exposes full identities/consequences even when compact.
- Toggle density while a marked row is hidden by filtering and in an incomplete
  snapshot. Preserve hidden marks and truthful scan status; do not hide the
  only consequence or withholding reason.
- Escape from evidence and summary retains choices. r clears choices even when
  refreshed identity is unchanged. Prove both distinct event paths were entered.
- Marking a row saves exactly that checkbox; hidden marks remain visible in the
  count; focus-only Enter saves nothing.
- Refresh clears marks for unchanged IDs and fingerprints as well as changed
  items. Failed refresh cannot save stale marks.
- Invalid selector output or stale mappings rejects the whole save. A withheld
  ID injected directly into the output is refused by the writer.
- Output publication is atomic, preserves unrelated files, and yields a plan
  accepted by the existing parser. Paths with spaces round-trip correctly.
- Missing optional tools, unsupported d/state-restoration capabilities, and
  non-TTY input/output enter the read-only fallback with preserved scope and no
  saved file. Missing Python does not introduce a dependency into ordinary Bash
  reporting. No package installation or interactive launch occurs automatically.
- Exercise compact/expanded views at 60/80/120 columns and ASCII/monochrome
  output; restoring the terminal after cancellation/interruption is observable
  and must not clear existing reviewed choices merely on returning from detail.
- A copied skills/afterparty bundle can review in a disposable repository
  without accessing checkout-only modules.

## Phase 4 Add machine-readable apply outcomes

This is a separate backend deliverable needed before any maintained dashboard
can display execution receipts reliably. Add the proposed command:

~~~bash
# Proposed JSON Lines output; the existing non-JSON form remains available.
afterparty apply --json ./cleanup-plan.md
~~~

Add proposed apply_emit_target and apply_emit_summary helpers, backed by a new
lib/apply-events.sh and lossless JSON serialization. Keep mutation policy in
apply.sh and the existing delegated handlers. JSON mode does not run the plain
apply command and infer outcomes by parsing its prose.
Validate required serialization support and initialize the private event
channel before any mutation. If that setup is unavailable, refuse JSON apply
with an explicit error; never discover a missing serializer after cleanup.

For delegated process actions, add an optional private event channel from
audit-processes.sh to apply.sh. The child reports its per-group decision,
attempted/confirmed effect, and journal result using apply-events.sh; its human
narration goes to diagnostic stderr during JSON apply. Bind channel records to
the apply run_id and reviewed group ID. Do not reuse the styling tally, parse
the child's text, or read the journal afterward to guess receipt success.
The parent validates the channel and still checks its own group postconditions.
Missing or malformed child outcome evidence is unavailable and makes the
overall result nonzero. Event write failure remains separate from confirmed
effects. Ordinary audit and its report-only --json mode keep their contracts.

Emit an apply_start record with a unique run_id and the checked plan's digest.
For every checked target, emit one terminal apply_target outcome after its
revalidation/action finishes. Structured outcomes include applied, gone, held,
vetoed, drift, survived, and failed, plus stable reason_code and explanatory
detail. A validation error emits apply_rejection before any target mutation.

Every target result separately exposes whether mutation was attempted,
whether its postcondition was confirmed, and receipt_status
("recorded", "failed", or "not-attempted"). This allows a confirmed deletion
with a journal failure to remain applied while still failing the overall run.
Pre-mutation refusals that currently have only prose become structured stream
events with receipt_status "not-attempted"; do not invent historical journal
records or claim that a refusal was persisted.

An apply_summary exposes final target counts, existing aggregate counters,
journal failure counts, invocation errors, and exit status. Use a final
apply_complete record to distinguish a complete event stream from a
disconnected or crashed writer. Missing completion means result unavailable,
not a successful empty receipt. Event-output failure cannot turn a confirmed
mutation into an unperformed one or a failed run into success.

Preserve existing semantics: malformed input exits 2 before mutation; held,
drifted, vetoed, surviving, failed, or unrecorded results return nonzero;
confirmed absence and deliberate no-op remain distinguishable from failure.
A later refusal does not undo an earlier completed action.

If delegated audit fails, retain that invocation failure alongside the observed
group postcondition. Do not claim that signal delivery, a successful child
exit, or an optimistic prepared-target count proves cleanup completed.

Do not add --json to audit --kill as a shortcut: its current JSON mode is
explicitly report-only. The apply event adapter owns its output while audit
continues to own the single process-group kill discipline.

### Acceptance

- Compare structured and plain apply under intercepted fixtures for gone,
  drift, held, veto, survived, confirmed success, and mutation failure.
- Exercise malformed metadata, duplicate targets, and display/metadata
  disagreement; assert validation rejection and zero delegated mutations.
- Inject journal failure after a confirmed effect. The target remains
  postcondition-confirmed, receipt_status is failed, and overall exit is nonzero.
- Exercise early non-journaled refusals and confirm they appear in the stream
  without claiming a persisted receipt.
- Make serialization support and the private child channel unavailable before
  execution; assert an explicit setup refusal and no delegated mutations.
- Assert no ANSI or human chatter on JSON stdout under forced styling.
  Diagnostic stderr does not substitute for required structured outcomes.
- Verify truncated streams, failed event writes, and interrupted runs cannot
  render a completed-success card.

## Phase 5 Consider an optional full-screen adapter

Proceed only after the save-only prototype demonstrates value and the
structured contracts have compatibility tests. The proposed invocation is
afterparty ui, routed to a separately installed afterparty-ui companion.
No default command, Agent Skill invocation, or plugin hook enters full-screen
mode.

Use existing glance JSON for the workspace overview, the proposed plan snapshot
for target review, docs JSON for evidence/review state, and actions JSON for
history. Navigation into review remains explicit; the overview has no mutation
binding. A refresh shows an observation timestamp and uses the same mark-reset
policy as guided review. The later adapter preserves the compact/details
presentation contract and does not replace the first guided delivery.

[Bubble Tea](https://github.com/charmbracelet/bubbletea#tutorial) and
[Lip Gloss](https://github.com/charmbracelet/lipgloss) are a proposed adapter
stack, not a required core dependency. Pin a tested release and verify its Go
toolchain and distribution requirements at implementation time. See the
references document for the Python alternative and comparison.

The adapter consumes shared theme roles exported from style.sh; it may implement
focus/layout rendering but must not duplicate magnitude thresholds or cleanup
eligibility. Negotiation rejects unsupported backend schemas explicitly.

Package binaries for the supported macOS/Linux architectures with reproducible
build instructions and a clear backend-version relationship. The copied skill
still contains all core scripts and works without the companion. Review adapters
do not install dependencies, download binaries, or register hooks on startup.
TTY restoration, resize, interruption, keyboard access, NO_COLOR, TERM=dumb,
and plain-mode fallback are release requirements for the adapter.

The first full-screen adapter also saves plans only. If an execution control is
ever added, it is a separately specified action over a saved checked plan using
the existing apply entry point and its structured receipts.

## Devclean remains a separate model

Do not convert devclean IDs into repository plan items. Its existing model
binds reviewed IDs to selected modes and scope and includes orphan PIDs,
simulators, persistent settings, launch agents, named caches, history, and
native-tool maintenance. Those effects need their own consequences and, for
persistent changes, restoration context.

A later proposed devclean preview JSON contract should expose the exact
target_id from target_gate, modes, normalized scope, availability/reason,
identity evidence, consequence, and restoration information. Apply continues
to use devclean --apply --target for those exact IDs. History age gates,
HOME boundaries, archived-session exclusion, and pnpm store prune remain in
their existing backend. Repository roaming findings remain report-only.

If a future interface can browse both models, separate their review sessions
and saved selections. A repository plan checkbox cannot approve a devclean
setting change, cache action, or history deletion.

## Backward compatibility and verification

The old Markdown plan schema remains readable and authoritative. Add no new
required metadata to checked legacy rows. Ordinary plan output, existing
JSON Lines schemas, report formats, shell defaults, and command exit meanings
retain their contracts except for deliberately reviewed help/presentation
changes. Keep glance's rejection of --kill and --apply pinned.

New private state belongs in state.sh. Do not duplicate protection patterns,
kill categories, process eligibility, identity logic, filesystem vetoes,
journal semantics, terminal palette, or size thresholds. UI IDs and snapshot
digests do not weaken checks for tracked paths, symlink/scope escapes,
repository roots, nested repositories, occupancy, or incomplete inspection.

Any apply-path fixture uses disposable repositories/state plus logging
interceptors for kill, pgrep, launchctl, and pnpm before production code is
entered. HOME alone is insufficient isolation. The full live-kill suite runs
only in a disposable Linux VM/container or CI runner. File-age fixtures retain
the GNU-then-BSD touch fallback.

Add meaningful regression cases through the public CLI and reviewer helper
boundaries. For new approval guards, prove that the code path was entered and
that the refused item or flag is named, then remove that guard in a scratch
copy and demonstrate the intended test goes red:

| Guard | Positive entry evidence and refusal | Scratch mutation |
| --- | --- | --- |
| Focus is not a mark | Fake selector reports focus plus mark_count=0; save validation is entered and reports explicit-marks-required; no checked file appears. | Treat focused ID as a mark and confirm the assertion fails. |
| Withheld items stay unselectable | Inject a known withheld ID; writer reaches availability validation and names that ID as refused. | Remove availability validation and confirm a checked plan would be written. |
| Refresh invalidates marks | Mark an item, refresh an unchanged identity, and enter save; reviewer reports marks-cleared and no checked output. | Retain the old mark set and confirm the test fails. |
| Density preserves review state | Mark a known item, focus another, enter a known step/query, toggle d, and assert a rendered density change plus unchanged snapshot/scope/step/focus/marks and zero new scans. | Clear marks, reset the step, or rescan on d in separate scratch mutations; each must fail its intended state assertion. |
| Mapping binds the visible row | Change the captured header or document digest; writer reaches digest/mapping validation and refuses the affected row. | Skip the integrity check and confirm the test observes the invalid save. |
| Incomplete streams are unusable | Supply valid item/document records without plan_complete; snapshot validation explicitly reports stream-incomplete. | Accept end-of-file as completion and confirm the test fails. |
| Journal failure is separate from effect | Intercept a successful mutation, then fail journaling; observe the confirmed target result plus receipt failure and nonzero status. | Suppress receipt-failure propagation and confirm the result/status test fails. |

Run syntax and blocking lint for touched scripts, focused public-CLI suites,
JSON/schema and guided-adapter fixtures, copied-bundle tests, and the isolated full
suite when production changes are made. Validate marketplace, plugin manifest,
skills, commands, and hooks explicitly. Check LF endings and review
documentation evidence before shipping a changed user-facing contract.

This specification does not implement the features, change release metadata,
or authorize committing, pushing, deploying, or releasing them.

## Delivery order and remaining choices

1. Ship shared layout/help polish.
2. Extract shared proposal collection and add the structured snapshot, keeping
   Markdown behavior pinned.
3. Prototype compact guided review with d expansion; audit Gum composition or
   a bounded wrapper key loop before committing to an adapter. Validate
   explicit marks, density-state preservation, refresh resets, withheld
   inspection, back-navigation, and cancellation. Keep fzf as an alternative.
4. Add structured apply receipts without changing execution policy.
5. Decide whether the prototype warrants a separately distributed full-screen
   companion. Specify devclean interaction independently if it is needed.

The selected first-pass behavior is compact guided save-only review, a visible
d toggle to polished details over the same snapshot, no bulk-select shortcut,
complete mark reset on refresh, and explicit apply afterward. Gum is a candidate
pending custom-key/state/lifecycle feasibility; fzf is an optional alternative.
Before implementation, select and test the adapter and supported capability set,
resolve whether a wrapper-owned native key loop is needed, and confirm snapshot
field names against collector fixtures. Companion framework/version, binary
distribution channel, and any devclean UI remain deferred decisions.
