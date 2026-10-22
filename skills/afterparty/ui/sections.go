package main

import (
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"strings"
)

func sectionName(kind string) string {
	switch kind {
	case "process-group":
		return "Process groups"
	case "worktree":
		return "Worktrees"
	default:
		return "Artifacts"
	}
}
func (m *model) focused() (item, bool) {
	for _, target := range m.state.Items {
		if target.ID == m.state.Focus {
			return target, true
		}
	}
	return item{}, false
}
func (m *model) reason(target item) string {
	if target.ReasonSentence != "" {
		return target.ReasonSentence
	}
	return target.Reason
}
func (m *model) rowRight(target item, w int) string {
	if target.Availability != "available" {
		return ansi.Truncate(m.plain(m.reason(target)), min(30, w/2), "...")
	}
	return m.plain(measurement(target))
}
func (m *model) rowLabels(items []item, w int) map[string]string {
	labels, widths := map[string]string{}, map[string]int{}
	byWidth := map[int]map[string]string{}
	seen := map[string]bool{}
	collision := false
	for _, target := range items {
		widths[target.ID] = max(8, w-8-ansi.StringWidth(m.rowRight(target, w)))
		width := widths[target.ID]
		if byWidth[width] == nil {
			byWidth[width] = m.labels(width)
		}
		label := byWidth[width][target.ID]
		labels[target.ID] = label
		if seen[label] {
			collision = true
		}
		seen[label] = true
	}
	if collision {
		for index, target := range items {
			prefix := fmt.Sprintf("[%d] ", index+1)
			labels[target.ID] = prefix + m.shortLabel(target, max(1, widths[target.ID]-len(prefix)))
		}
	}
	return labels
}
func (m *model) body(w int) ([]string, map[string][2]int) {
	s := m.state
	lines := []string{}
	anchors := map[string][2]int{}
	add := func(text, role string) { lines = append(lines, m.wrapped(m.plain(text), role, w)...) }
	switch s.Step {
	case "choose":
		previous := ""
		visible := s.visible()
		labels := m.rowLabels(visible, w)
		counts := map[string]int{}
		for _, target := range visible {
			counts[target.Type]++
		}
		for _, target := range visible {
			if target.Type != previous {
				lines = append(lines, m.sectionRule(fmt.Sprintf("%s %d", sectionName(target.Type), counts[target.Type]), "heading", w))
				previous = target.Type
			}
			start := len(lines)
			if s.Expanded && target.ID == s.Focus {
				lines = append(lines, m.inlineRail(m.targetDetails(target, w-2, true), w)...)
				add("", "")
				anchors[target.ID] = [2]int{start, start + 1}
				continue
			}
			cursor, box := " ", "[ ]"
			if target.ID == s.Focus {
				cursor = ">"
			}
			if has(s.Marked, target.ID) {
				box = "[x]"
			}
			right := m.rowRight(target, w)
			if target.Availability != "available" {
				box = " ⊘ "

				if m.ascii {
					box = "[-]"
				}
			}
			prefix := cursor + " " + box + " "
			label := labels[target.ID]
			gap := max(1, w-ansi.StringWidth(prefix+label)-ansi.StringWidth(right))
			row := prefix + label + strings.Repeat(" ", gap) + right
			role := ""
			if cursor == ">" {
				role = "focus"
			} else if has(s.Marked, target.ID) {
				role = "bold"
			}
			lines = append(lines, m.line(row, role, w))
			anchors[target.ID] = [2]int{start, start + 1}
		}
		if len(s.visible()) == 0 {
			message := "The scan found no targets in this scope."
			if len(s.Items) > 0 {
				message = "No targets match the filter. Press / to edit it. Use Backspace to erase it. Press Enter when done."
			} else if s.Scope.Status != "complete" {
				message = "The scan is incomplete. No targets are available. Press r to retry the scan."
			}
			add(message, "")
		}
	case "evidence":
		if target, ok := m.focused(); ok {
			lines = m.targetDetails(target, w, true)
		} else {
			add("No target is focused.", "")
		}
	case "review", "save", "saved":
		if s.Step == "review" {
			summary := s.Summary
			if len(summary) == 0 {
				summary = []string{fmt.Sprintf("%d marked targets. Afterparty did not run cleanup.", len(s.Marked)), "Apply checks each target again.", "Press Space to unmark the target. Press d for details."}
			}
			for _, line := range summary {
				if m.ascii {
					line = strings.ReplaceAll(line, " · ", " | ")
				}
				add(line, "bold")
			}
			add("", "")
		}
		if s.Step == "save" || s.Step == "saved" {
			if s.Step == "saved" {
				heading := "✓ Plan saved"
				if m.ascii {
					heading = "DONE Plan saved"
				}
				add(heading, "done")
				add("No cleanup ran.", "")
			}
			label, path := "Destination: ", s.Destination
			if s.SavedPath != "" {
				label, path = "Saved: ", s.SavedPath
			}
			add(label+path, "bold")
			add("Finish the review to print the apply command.", "")
			add("The plan records your choices. Apply checks each target again.", "dim")
			add("", "")
		}
		for _, target := range s.Items {
			if has(s.Marked, target.ID) {
				start := len(lines)
				lines = append(lines, m.targetDetails(target, w, s.Expanded)...)
				anchors[target.ID] = [2]int{start, start + 1}
				add("", "")
			}
		}
	case "help":
		lines = append(lines, m.sectionRule("Keys", "bold", w))
		for _, hint := range s.HelpKeys {
			add(fmt.Sprintf("%-10s %s", hint.Key, hint.Label), "")
		}

		add("", "")
		if s.Message != "" {
			lines = append(lines, m.sectionRule("Latest message", "bold", w))
			role := ""
			if s.MessageKind == "refused" {
				role = "warning"
			}
			add(s.Message, role)
			add("", "")
		}
		lines = append(lines, m.sectionRule("Scan status", "bold", w))
		if !s.SaveEnabled {
			add("Refresh before you save the plan.", "warning")
		}
		add("Scope: "+s.Scope.Root, "")
		add("Observed: "+m.observation(), "")
		add("Recorded file activity does not prove human presence.", "dim")
		for _, cap := range s.Capabilities {
			role := ""
			if cap.Status != "complete" {
				role = "warning"
			}
			add(cap.Name+": "+cap.Status+" - "+cap.Reason, role)
		}
		add("", "")
		lines = append(lines, m.sectionRule("Target types", "bold", w))
		add("A process group contains processes with one process group ID (PGID).", "")
		add("A worktree is a separate checkout of a Git repository.", "")
		add("An artifact is a directory with generated files.", "")
	case "confirm_quit", "confirm_refresh":
		lines = m.confirmationPanel(w)
	}
	return lines, anchors
}
func (m *model) targetDetails(target item, w int, evidence bool) []string {
	lines := []string{}
	add := func(value, role string) { lines = append(lines, m.wrapped(m.plain(value), role, w)...) }
	prefix := "[ ] "
	if has(m.state.Marked, target.ID) {
		prefix = "[x] "
	}
	role := "bold"
	if target.Availability != "available" {
		prefix = "⊘ "
		if m.ascii {
			prefix = "WITHHELD "
		}
	}
	if target.ID == m.state.Focus && (m.state.Step == "review" || m.state.Step == "choose") {
		prefix = "> " + prefix
		role = "focus"
	}
	identity := target.Target
	if target.Type == "process-group" {
		identity = "PGID " + target.Target
	}
	add(prefix+identity, role)
	return append(lines, m.targetEvidence(target, w, evidence)...)
}
func (m *model) targetEvidence(target item, w int, expanded bool) []string {
	lines := []string{}
	add := func(text, role string) { lines = append(lines, m.wrapped(m.plain(text), role, w)...) }
	if expanded {
		lines = append(lines, m.sectionRule("Decision", "bold", w))
		add(m.focusBadge(target), "")
	}
	add("If applied: "+target.Consequence, "")
	if target.Availability != "available" {
		add("Withheld: "+m.reason(target), "warning")
	} else if expanded && m.reason(target) != "" {
		add("Checks: "+m.reason(target), "")
	}
	for _, section := range evidenceSections(target) {
		// A process approval covers every member, even with optional evidence hidden.
		if !expanded && section.Title != "Process members" {
			continue
		}
		lines = append(lines, m.sectionRule(section.Title, "bold", w))
		for _, line := range section.Lines {
			add(line, "")
		}
	}
	return lines
}
func (m *model) confirmationPanel(w int) []string {
	count := fmt.Sprintf("%d targets marked.", len(m.state.Marked))
	if len(m.state.Marked) == 1 {
		count = "1 target marked."
	}
	content := m.wrapped(count, "bold", w-4)
	result, key, action := "Quit without saving these marks.", "q/Enter", "Discard marks and quit"
	if m.state.Step == "confirm_refresh" {
		result, key, action = "Start a new scan. All marks are cleared.", "r/Enter", "Discard marks and refresh"
	}
	content = append(content, m.wrapped(result, "", w-4)...)
	content = append(content, "")
	content = append(content, m.keyHints([]keyHint{{"Esc", "Keep reviewing"}, {key, action}}, w-4)...)
	return m.boundedPanel("Discard marks?", content, w, len(content)+2)
}
func (m *model) focusStrip(w int) []string {
	target, ok := m.focused()
	if !ok {
		return nil
	}
	badge := m.focusBadge(target)
	identity := m.label(target, max(8, w-ansi.StringWidth(badge)-8))
	title := identity + " | " + m.plain(badge)
	text, role := "If applied: "+target.Consequence, ""
	if target.Availability != "available" {
		text = "Withheld: " + m.reason(target)
		role = "warning"
	}
	return m.evidencePanel(title, m.wrapped(m.plain(text), role, w-4), w, 4)
}
func (m *model) focusBadge(target item) string {
	badge := "[ ] available"
	if has(m.state.Marked, target.ID) {
		badge = "[x] marked"
	}
	if target.Availability != "available" {
		badge = "⊘ withheld"
		if m.ascii {
			badge = "WITHHELD"
		}
	}
	return badge
}
func (m *model) focusPane(w, height int) []string {
	target, ok := m.focused()
	if !ok {
		return m.boundedPanel("Focused target", m.wrapped("No target has focus.", "", w-4), w, height)
	}
	lines := []string{}
	add := func(text, role string) { lines = append(lines, m.wrapped(m.plain(text), role, w-4)...) }
	identity := target.Target
	if target.Type == "process-group" {
		identity = "PGID " + identity
	}
	add(identity, "bold")
	if target.Type == "process-group" && target.DisplayLabel != "" {
		add(target.DisplayLabel, "")
	}
	lines = append(lines, m.targetEvidence(target, w-4, true)...)
	return m.evidencePanel("Focused target", lines, w, height)
}
func (m *model) footer(w int) []string {
	s := m.state
	if s.Step == "confirm_quit" || s.Step == "confirm_refresh" {
		return nil
	}
	lines := []string{}
	if s.Searching || s.Query != "" {
		query := "/ " + s.Query
		if s.Searching {
			query += "_"
		}
		if hidden := s.hiddenMarks(); hidden > 0 {
			query = fmt.Sprintf("%d marked outside filter | %s", hidden, query)
		}
		lines = append(lines, m.line(m.plain(query), "", w))
	}
	message := m.feedbackMessage()
	kind := s.MessageKind
	if message != s.Message {
		kind = "info"
	}
	role := ""
	symbol := ""
	switch kind {
	case "done":
		role = "done"
		symbol = "✓ "
		if m.ascii {
			symbol = "DONE "
		}
	case "refused":
		role = "warning"
		symbol = "⊘ "
		if m.ascii {
			symbol = "REFUSED "
		}
	}
	if !s.SaveEnabled && !m.inventory {
		message = "Refresh before you save the plan. " + message
		role = "warning"
	}
	if message != "" {
		message = symbol + m.plain(message)
		if ansi.StringWidth(message) > w && (kind == "refused" || (!s.SaveEnabled && !m.inventory)) {
			lines = append(lines, m.line(message, role, max(1, w-12))+" [? details]")
		} else {
			lines = append(lines, m.line(message, role, w))
		}
	}
	return append(lines, m.keyHints(s.Legend, w)...)
}
