# Terminal UI references and implementation choices

Research checked 2026-10-04. This is a design decision reference, not a shipped
command contract. Capabilities below come from primary documentation; choices
and tradeoffs for Afterparty are our recommendations. Moving branch documentation
does not establish availability in an installed release. No tools were installed for that research.

Current decision (2026-10-12): guided review uses **Bubble Tea 2.1.0 and Lip
Gloss 2.0.0**. Bubble Tea owns terminal input, resize, rendering and lifecycle;
Lip Gloss supplies layout/styles from Afterparty's shared theme. The existing
Python backend retains snapshot validation, explicit marks and no-clobber saving.
This is the C+A reviewer, not the optional Phase 5 dashboard. Enter advances;
`i` inspects. The module pins the dependencies and an explicit build creates
the optional helper; ordinary commands do not install anything.
[Bubble Tea v2 API](https://pkg.go.dev/charm.land/bubbletea/v2@v2.1.0),
[Lip Gloss v2 API](https://pkg.go.dev/charm.land/lipgloss/v2@v2.0.0),
[build and runtime instructions](../../README.md#approving-cleanup-with-planapply).

Superseded decision (2026-10-11): the first guided reviewer used a bounded
Python standard-library input loop, with shared shell theme roles. Gum's current
source keymap and options were rechecked before this choice; its stock chooser
does not expose the required live `d` transition. PTY fixtures exercise the owned
key loop. User review identified both the framework mismatch and the awkward
Enter-to-inspect flow. The 2026-10-12 correction above replaces that adapter.

The remaining comparison records the original 2026-10-04 research and proposals;
its candidate rankings and original key bindings are historical.

## Preferred direction: compact guided review with detailed CLI output

The user selected C+A: compact guided review by default, with `d` expanding the
same snapshot into polished detailed output. Density changes must preserve
focused identity and explicit marks without rescanning. This is the preferred
interaction; Gum is one possible source of widgets, not a promise that its
standalone `choose` command implements the proposed hotkeys. Keep the present
CLI and an accessible linear review available. An optional fzf evidence selector
remains an alternative for comparison.

| Option | Documented building blocks | Afterparty recommendation and tradeoff |
| --- | --- | --- |
| **Gum** | `choose` and `filter` support multiple choices; `pager` displays long evidence; `confirm` reports affirmative/negative through its exit code. Commands print results for a shell script to consume. [Commands](https://github.com/charmbracelet/gum#commands) | Preferred guided visual direction: choose, inspect, explicitly mark, review. One optional binary for stock widgets, but a wrapper/helper must own persistent state and the proposed density toggle. See the source limitations below. |
| **fzf** | Reads candidates from stdin and returns selections on stdout; supports multiselect, partial-height display and a command-driven preview. Its man page documents field delimiters, presentation transforms, NUL-delimited input/output and preview layout controls. [README](https://github.com/junegunn/fzf#usage), [man page](https://github.com/junegunn/fzf/blob/master/man/man1/fzf.1) | Alternative prototype: searchable list plus evidence preview, with an opaque target ID behind every row. One optional binary. A wrapper must own approval semantics, disabled targets, cancellation and snapshot validation. |
| **Bubble Tea + Lip Gloss** | Bubble Tea's model has `Init`, `Update` and `View`; events update state and views can request alternate-screen and mouse behavior. Lip Gloss provides terminal styling/layout and color-profile downsampling. [Bubble Tea tutorial](https://github.com/charmbracelet/bubbletea#tutorial), [Lip Gloss](https://github.com/charmbracelet/lipgloss#colors) | Later full-screen option: workspace list, typed-target tabs, evidence pane and receipts. More control over focus and disabled rows, with a new Go application to maintain and distribute. |
| **Textual** | Python framework with table cursor/highlight/selection events and horizontal, vertical and grid layouts. [DataTable](https://textual.textualize.io/widgets/data_table/#cursors), [Layout](https://textual.textualize.io/guide/layout/) | Python alternative for the same full-screen review. Existing Python collectors may make development familiar, but users would need an additional package environment beyond a Python interpreter. |

### Dependencies and support boundaries

- **fzf:** its README offers a standalone binary and installation paths for
  macOS, Linux and Windows. Shell keybindings/completion are separate integrations
  and are unnecessary for a subprocess selector. [Distribution and usage](https://github.com/junegunn/fzf#installation)
- **Gum:** its README lists binaries for Linux, macOS, Windows and several BSDs;
  shell scripts can use its utilities without writing Go.
  [Installation](https://github.com/charmbracelet/gum#installation)
- **Bubble Tea/Lip Gloss:** current main documentation uses
  `charm.land/bubbletea/v2` and `charm.land/lipgloss/v2`. At this check their main
  module files declare Go 1.26.0 and 1.26.7 respectively. These are observations
  about moving source branches, not a proposed release pin. Verify the chosen
  versions and build toolchain before implementation.
  [Bubble Tea module](https://github.com/charmbracelet/bubbletea/blob/main/go.mod),
  [Lip Gloss module](https://github.com/charmbracelet/lipgloss/blob/main/go.mod)
- **Textual:** official setup docs require Python 3.9+ and describe Linux, macOS
  and Windows support. The package also depends on libraries including Rich and
  markdown-it-py. Python's presence alone does not satisfy that dependency set.
  [Requirements](https://textual.textualize.io/getting_started/#requirements),
  [Package metadata](https://github.com/Textualize/textual/blob/main/pyproject.toml)

These projects' platform support does not supply missing Afterparty process,
occupancy or filesystem evidence. Unsupported inspection must still withhold
affected actions. For the prototype, check the installed selector's capabilities
and fall back explicitly. Do not assume the latest README matches a packaged
binary or introduce a minimum version without exercising its required features.

### Gum feasibility: proposed hotkeys require owned state

Current main source fixes `choose` bindings: arrows/Vim keys navigate;
Space/Tab/x toggle in multiselect; Enter/Ctrl+Q submit; Esc quits; Ctrl+C aborts.
Neither `d` nor Ctrl+D has a density action, and the exposed options do not
include custom bindings or an event callback. `--selected` seeds initial
selection; label/value delimiters can separate displayed labels from returned
IDs. [Keymap and update loop](https://github.com/charmbracelet/gum/blob/main/choose/choose.go),
[Options](https://github.com/charmbracelet/gum/blob/main/choose/options.go)

The command prints selected values only after submission. Esc yields an error
without exporting its current marks. Single-select submission implicitly picks
the focused item; `--no-limit` enables explicit marks, including a possible empty
submission. Rendering goes to stderr and selection results to stdout.
[Command implementation](https://github.com/charmbracelet/gum/blob/main/choose/command.go)

Our implementation recommendation is an Afterparty-owned input/state loop for
`d`: snapshot + focused opaque ID + checked ID set + density. Render compact or
detailed text from that state; `d` changes density only. A small shell/helper can
do this, using Gum for optional separate prompts. A shell waiting outside a
running `gum choose` cannot use an unbound key to retrieve its live marks.
Reopening with `--selected` can preserve already-submitted choices, but does not
provide an in-widget toggle without losing unsubmitted changes. A custom
Bubble Tea helper is another option; a complete dashboard is unnecessary.

Default Enter submission also differs from the proposal's Enter-to-inspect.
Treat a single-select result as navigation only, followed by a separate explicit
mark action. Keep withheld inspection out of any stock multiselect list that
could treat those rows as approvals. Stock Gum bindings and proposed Afterparty
bindings must be labeled separately in implementation notes.

No screen-reader compatibility guarantee was established from these sources.
Because the widget redraws a terminal view, a stable linear text path should be
verified independently: numbered choices, full evidence, explicit mark prompts,
and compact/detailed as named options. This is our accessibility recommendation,
not a Gum capability claim. Monochrome or configurable ASCII prefixes alone do
not establish screen-reader accessibility. No TTY or missing optional tooling
should retain the ordinary read-only CLI output and manual plan workflow.

### fzf details that affect approval

The preview command executes when focus changes; field placeholders are quoted
by default. The selected-items placeholder falls back to the focused item if
nothing is marked. The man page also documents `FZF_SELECT_COUNT` and configurable
actions. [Preview and bindings](https://github.com/junegunn/fzf/blob/master/man/man1/fzf.1)

For Afterparty, these imply concrete adapter requirements:

1. Feed a completed, validated snapshot into the selector. A fixed preview helper
   reads evidence by validated opaque ID; changing focus does not trigger another
   machine scan or execute displayed process commands.
2. Require explicit marks before saving approval. Default acceptance of a focused
   row must not become a checked item. Verify the selector's marked-count guard
   and cancellation behavior; zero marks saves no approval.
3. Keep withheld findings available for inspection. Generic multiselect does not
   enforce Afterparty eligibility: a mark on a withheld row must be rejected with
   its reason, or selection and inspection must use separate lists/screens.
4. Decode selected IDs against the same snapshot; reject unknown/duplicate IDs
   and changed evidence. Sanitize display text and preserve original identity
   separately. If rows use TSV, emit sentinels for empty middle fields.
5. Save choices only. Applying them remains an explicit invocation of the existing
   apply machinery, with its fresh checks, delegated process cleanup and receipts.

Prototype scope: compact guided review, detailed output from the same snapshot,
evidence browsing, explicit marks, a selected-target summary and save/cancel.
Progress animation, continuous monitoring, theme collections and direct
mutations do not help answer the first design question.

## Open-source interaction references

| Project | Verified pattern | Borrow for Afterparty | Boundary |
| --- | --- | --- | --- |
| **dua-cli** | Its current main README documents a `dua clean` hub that groups disposable candidates by parent, supports browsing/sorting/searching, and clears marks on refresh. Interactive exploration/deletion uses multiple stages. [Cleanup mode](https://github.com/Byron/dua-cli#cleanup-mode), [Interactive mode](https://github.com/Byron/dua-cli#interactive-mode) | Workspace grouping, individually marked targets, a selected total and explicit review. | Release availability of the documented cleanup hub was not established here. Its policy does not replace Afterparty's occupancy, identity and nested-repository checks. |
| **lazygit** | Configuration documents focus borders, selected-row highlighting, contextual bottom help, a command log, list position and responsive portrait layout. Official bindings cover filtering, help, refresh and cancellation. [Configuration](https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md), [Keybindings](https://github.com/jesseduffield/lazygit/blob/master/docs/keybindings/Keybindings_en.md) | A compact list/detail view, evident focus, context-specific footer and receipt pane. | Limit hotkeys. Its undo uses Git reflog and excludes working-tree/stash changes; Afterparty must not imply generic undo. [Undo](https://github.com/jesseduffield/lazygit#undo) |
| **btop** | Documents selected-process details, filtering/sorting, process trees, pausing/following and selectable graph characters, plus lower-color and TTY modes. [Features](https://github.com/aristocratos/btop#features), [Prerequisites](https://github.com/aristocratos/btop#prerequisites) | Stable selection during review; compact magnitude indicators; sensible terminal fallbacks. | Arbitrary signals would bypass Afterparty's authority boundaries. Sparklines need sampled history, and a dense hardware dashboard would dilute the cleanup decision. |
| **Mole** | Documents a terminal disk explorer with filtering, multiselection and confirmed Trash moves; text examples show category summaries, size bars and skipped operations. It labels partial/unavailable scan evidence and provides cleanup history. [Features and scan semantics](https://github.com/tw93/Mole#features-in-detail), [Safety](https://github.com/tw93/Mole#safety) | Consistent spacing, clear skips, visible completeness and a concise outcome receipt. | Broad system maintenance, a global health score and Trash semantics are not Afterparty's model. Magnitude, eligibility and evidence completeness need separate labels. |

The selected design uses guided steps and readable CLI evidence, borrowing dua's
deliberate selection, lazygit's focus clarity, restrained magnitude indicators
from btop and clear completion states from Mole. Focus colors should not imply
eligibility. Unknown activity should be written as unknown, and filesystem
removal must retain its own proof requirements independently of transcript age.

Existing styled output continues through `lib/style.sh`; plain and JSON contracts
remain stable. Any optional adapter must honor the project's styling controls,
work without Nerd Fonts, and preserve readable labels in monochrome and narrow
terminals. A framework's renderer is an implementation option, not authorization
to scatter a second styling policy through the current shell commands.
