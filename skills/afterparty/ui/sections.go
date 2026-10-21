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
		labels := m.rowLabels(s.visible(), w)
		for _, target := range s.visible() {
			if target.Type != previous {
				lines = append(lines, m.paint("heading", sectionName(target.Type)))
				previous = target.Type
			}
			start := len(lines)
			if s.Expanded {
				lines = append(lines, m.targetDetails(target, w, true)...)
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
		add("Keys", "bold")
		for _, hint := range s.HelpKeys {
			add(fmt.Sprintf("%-10s %s", hint.Key, hint.Label), "")
		}

		add("", "")
		add("Scan status", "bold")
		if s.MessageKind == "refused" || !s.SaveEnabled {
			message := s.Message
			if !s.SaveEnabled {
				message = "Refresh before you save the plan. " + message
			}
			add(message, "warning")
			add("", "")
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
		add("Target types", "bold")
		add("A process group contains processes with one process group ID (PGID).", "")
		add("A worktree is a separate checkout of a Git repository.", "")
		add("An artifact is a directory with generated files.", "")
	case "confirm_quit":
		question := fmt.Sprintf("Unmark %d targets and quit?", len(s.Marked))
		if len(s.Marked) == 1 {
			question = "Unmark 1 target and quit?"
		}
		add(question, "bold")
		add("Press Enter or q to quit. Press Esc to keep your marks.", "")
	case "confirm_refresh":
		question := fmt.Sprintf("Unmark %d targets and refresh?", len(s.Marked))
		if len(s.Marked) == 1 {
			question = "Unmark 1 target and refresh?"
		}
		add(question, "bold")
		add("Press Enter or r for a new scan. Press Esc to keep these results.", "")
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
	add("If applied: "+target.Consequence, "")
	if target.Availability != "available" {
		add("Withheld: "+m.reason(target), "warning")
	}
	// A process approval covers the whole group, so Review always names every member.
	if target.Type == "process-group" {
		for _, member := range target.Evidence.Members {
			add(fmt.Sprintf("Member %d: %s", member.PID, member.Command), "")
		}
	}
	if evidence {
		for _, line := range evidenceLines(target) {
			add(line, "dim")
		}
	}
	return lines
}
func (m *model) focusStrip(w int) []string {
	target, ok := m.focused()
	if !ok {
		return nil
	}
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
	identity := m.label(target, max(8, w-ansi.StringWidth(badge)-3))
	title := identity + strings.Repeat(" ", max(1, w-ansi.StringWidth(identity)-ansi.StringWidth(badge))) + badge
	lines := []string{m.line(title, "bold", w)}
	text, role := "If applied: "+target.Consequence, ""
	if target.Availability != "available" {
		text = "Withheld: " + m.reason(target)
		role = "warning"
	}
	detail := m.wrapped(m.plain(text), role, w)
	// Keep a useful list viewport even for multi-page consequences.
	limit := 3
	if len(detail) > limit {
		detail = detail[:limit]
		detail[limit-1] = m.line(ansi.Strip(detail[limit-1]), role, max(1, w-17)) + m.paint("bold", " [i: full detail]")
	}
	lines = append(lines, detail...)
	return lines
}
func (m *model) footer(w int) []string {
	s := m.state
	lines := []string{}
	if s.Searching || s.Query != "" {
		query := "/ " + s.Query
		if s.Searching {
			query += "_"
		}
		lines = append(lines, m.line(m.plain(query), "", w))
	}
	message := s.Message
	role := ""
	symbol := ""
	switch s.MessageKind {
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
		if ansi.StringWidth(message) > w && (s.MessageKind == "refused" || (!s.SaveEnabled && !m.inventory)) {
			lines = append(lines, m.line(message, role, max(1, w-12))+" [? details]")
		} else {
			lines = append(lines, m.line(message, role, w))
		}
	}
	hints := []string{}
	for _, hint := range s.Legend {
		hints = append(hints, hint.Key+" "+hint.Label)
	}
	if len(hints) == 0 {
		hints = []string{"Enter continue", "Space mark", "i inspect", "d details", "? help", "q quit"}
		if m.inventory {
			hints = []string{"Enter review", "Up/Down focus", "i inspect", "/ filter", "r refresh", "? help", "q exit"}
		}
	}
	// Pack the backend's mode-specific actions into readable default-color rows.
	row := ""
	for _, hint := range hints {
		next := hint
		if row != "" {
			next = row + " | " + hint
		}
		if ansi.StringWidth(next) > w && row != "" {
			lines = append(lines, m.line(m.plain(row), "", w))
			row = hint
		} else {
			row = next
		}
	}
	if row != "" {
		lines = append(lines, m.line(m.plain(row), "", w))
	}
	return lines
}
