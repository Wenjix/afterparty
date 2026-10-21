# Concept board generation prompts

This board was generated with the built-in `image_gen.imagegen` tool and one
correction pass. It is a visual exploration, not a released-interface screenshot.
The exact prototype and fixture are defined in `terminal-ui-comparison.html` and
`../terminal-ui-design.md`.

## Original generation prompt

```text
Use case: ui-mockup. Create a polished landscape design comparison board for Afterparty, a terminal-native cleanup tool for coding-agent leftovers. This is an illustrative design exploration, not a screenshot of released software.
Show four equally prominent readable terminal windows in a clean 2 by 2 comparison composition on a warm off-white presentation background. Each window is an authentic text-only terminal: monospaced text, aligned columns, minimal box drawing, a dark charcoal background, restrained cyan focus, magenta branding, amber warnings, no gradients, no glass, no web buttons, no mouse-first controls, no dashboard gauges, no illustrations, no giant ASCII logo, no Nerd Font icons. Use very crisp legible typography and generous spacing. The terminal content should be visually plausible and implementable with ANSI text.
Outside each terminal put its exact variant title:
"A  Polished CLI"
"B  Selector + evidence"
"C  Guided review"
"D  Full review TUI"
A uses scrollback output with a summary at the top, three ordinary section headings, a resource-size bar, and a concrete next command. This is READ ONLY.
B uses a compact fzf-inspired list with checkboxes on the left and a read-only evidence preview to the right, a search input, and keyboard footer. This is REVIEW.
C uses a Gum-inspired sequential terminal review with a typed candidate list and a short expanded consequence below it; choice is save reviewed plan, not delete. This is REVIEW.
D uses a lazygit/dua-inspired full-screen terminal with a small workspace list, a target list, an evidence pane, and context help footer. This is REVIEW.
Use the same sample data in all four: repository "/work/afterparty", artifact ".next" size "840 MB", artifact "playwright-report" size "120 MB", process "vite · group 4821" CPU "0.2%", worktree "docs-pass" activity "unknown", worktree "auth" status "withheld: occupied".
Important exact short labels to render accurately wherever they appear: "afterparty", "Scan complete", "0 selected", "available", "withheld: occupied", "Save reviewed plan", "No changes made". All visible checkboxes start empty [ ]. Availability and agent activity must appear as separate facts; unknown activity is not zero and does not imply stale. Color distinguishes focus and resource magnitude, not safety. Never show 'safe to delete', a large delete button, preselected cleanup, an undo promise, a composite health score, or simulated animation. Selected row highlight is not a checked checkbox.
Every terminal shows "afterparty" and "/work/afterparty", a compact "Scan complete" line, and a quiet keyboard/next-action footer. B, C and D say "0 selected". Leave enough space between windows that titles and evidence can be compared without tiny overcrowded text. Add one small board footer: "Proposed interfaces · illustrative data · existing plan/apply checks remain authoritative".
```

## Correction prompt

```text
Edit the supplied Afterparty four-terminal comparison board, preserving its composition, typography, dark terminal surfaces, warm background, titles, colors and all four variant identities.
Correct its product semantics:
1. In B, C and D, the auth worktree row MUST have a dash "—" instead of "[ ]", because "withheld: occupied" is not selectable. Keep it visible and keep that reason readable.
2. All keyboard footers MUST say "space select" and "enter details"; Enter NEVER toggles selection. Change "Enter: toggle" accordingly. Focus highlight stays distinct from empty checkboxes.
3. Replace the filled cyan web-like Save button in C with a plain terminal text hotkey line "s  Save reviewed plan". All selection counts remain "0 selected".
4. In details in B/C/D replace the arbitrary "Modified 2024..." and sample nested-directory listing with evidence relevant to this proposed tool: "Tracked files: none", "Occupancy: complete; no process observed", "Nested repos: none", "Identity: recorded", and "Consequence: delete generated output; rebuild as needed".
5. Give the docs-pass worktree a separate visible "Activity: unknown" fact while keeping proposal availability "available". Never call unknown idle.
6. The prototype Next line in A is "Next: afterparty plan > cleanup-plan.md" and A says READ ONLY. Review variants only save a plan; do not show direct apply or delete buttons.
7. Add a subtle "CONCEPT ONLY" at board footer before the existing illustrative-data wording.
Keep all visible checkboxes unchecked. Preserve all other layout and no new decoration. Crisp readable monospaced text.
```
