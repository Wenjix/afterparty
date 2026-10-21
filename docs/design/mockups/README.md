# Terminal mockup gallery

These are proposed Afterparty layouts with illustrative data. They are not
screenshots of released Afterparty commands or working framework integrations.
The current CLI contract is in the [project README](../../../README.md).

These HTML/PNG layouts retain the original October 4–5 interaction labels.
The October 12 implementation now uses Bubble Tea and Lip Gloss: **Enter
advances and `i` inspects**. Use these mockups for layout comparison; use the
README for the current build requirements and keys. The optional dashboard
remains a separate, deferred proposal.

Open [terminal-ui-comparison.html](terminal-ui-comparison.html) locally. The
preferred C+A guided view opens compact by default. Press `d` or use the visible
Expand details control to reveal polished stacked evidence. Press `d` again to
return; focus, explicit marks, scope, snapshot and current step stay the same.

The comparison controls also offer:

- A: polished scrolling CLI proposals.
- B: compact fzf-inspired selector with evidence.
- C+A: Choose → Review choices → Save plan, with optional detail expansion.
- D: full review TUI inspired by lazygit and dua.

Use the controls to switch light, dark, and monochrome terminal presentations;
60, 80, and 120-column layouts; and complete, incomplete, or empty fixtures.
ASCII mode replaces terminal symbols. The page requires no server, downloads,
package installation, network connection, or access to the host system.

Focus a review terminal or click a row. Arrow keys move focus, Space marks an
available target, Enter opens evidence, and `s` previews the explicit choices.
Escape returns from details or a summary; `q` cancels and clears the mock draft.
Refresh (`r`) clears marks. Withheld rows remain inspectable and cannot be marked.
In C+A, `?` shows contextual help; inspecting evidence is optional and does not
add a mandatory step. Compact rows retain short consequences and withheld
reasons. Review choices always retains full identities and consequences.
Only the target/evidence content scrolls; scope, step, detail control, mark count
and keys remain visible. `PageUp`/`PageDown` scroll content without moving target
focus; arrows navigate to another target and reveal it. A target/position line
reports the focused identity independently of its checkbox.
Any saved-state preview is labeled a simulation; no actual file is saved and no
executable plan is generated. Apply remains separate in the proposed product.

## Images

| Image | What it shows |
| --- | --- |
| [Guided compact](guided-compact.png) | Preferred C+A initial view with explicit choices and a visible d shortcut |
| [Guided expanded](guided-expanded.png) | The same Choose step expanded into polished stacked evidence |
| [Guided narrow](guided-narrow.png) | Preferred guided compact view at 60 columns in a light terminal |
| [Guided incomplete](guided-incomplete.png) | Expanded guided view with failed transcript inspection and process proposals withheld |
| [Concept board](concept-board.png) | Earlier AI-generated four-option composition study, predating the C+A preference; simplified five-target fixture |
| [Dark comparison](comparison-dark.png) | Precise HTML rendering of all four approaches with the six-target fixture |
| [Light comparison](comparison-light.png) | The same layouts in a light terminal presentation |
| [Narrow selector](selector-narrow.png) | The compact reviewer at 60 columns |
| [Incomplete TUI](tui-incomplete.png) | Failed transcript inspection with dependent process proposals withheld |
| [Monochrome and ASCII](monochrome-ascii.png) | Guided narrow view with meaning preserved without color or Unicode terminal symbols |
| [Selected actions](selected-review.png) | Explicitly marked process, worktree and artifact choices with separate totals |
| [Saved state preview](saved-plan-preview.png) | Simulated plan destination and a separate apply command; no actual file write |
| [Partial apply receipt](apply-receipt.png) | Confirmed stop, identity refusal, incomplete deletion, and a separate receipt error |

[apply-receipt.html](apply-receipt.html) is the source of the static receipt
example. [concept-board-prompts.md](concept-board-prompts.md) records the exact
built-in image-generation and correction prompts, also embedded in the PNG.
The precise HTML prototype and design spec govern semantics when the generated
concept board simplifies a detail.

## Reproducing a view

The comparison accepts query parameters when opened in a browser:

```text
terminal-ui-comparison.html?view=guided&theme=light&width=80&details=expanded
```

Supported values:

| Parameter | Values |
| --- | --- |
| `view` | `all`, `cli`, `selector`, `guided`, `tui` |
| `theme` | `dark`, `light`, `mono` |
| `width` | `60`, `80`, `120` |
| `scenario` | `complete`, `incomplete`, `empty` |
| `ascii` | `1` for ASCII terminal symbols |
| `details` | `expanded` to start C+A with details open; default is compact |

Screenshots were exported from the local HTML using headless Chromium. They are
visual mockups of terminal layouts, not a terminal emulator or evidence of
macOS/Linux/Git Bash framework compatibility. Real ANSI palette rendering,
cell width, input bindings, and terminal restoration require the implementation
tests described in the [technical specification](../terminal-ui-implementation.md).
