package main

import (
	"charm.land/lipgloss/v2"
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"time"
)

func (m *model) paint(role, text string) string { return m.theme.roles[role].Render(text) }
func (m *model) line(text, role string, width int) string {
	return m.paint(role, ansi.Truncate(text, width, "..."))
}
func (m *model) wrapped(text, role string, width int) []string {
	return strings.Split(m.theme.roles[role].Width(width).Render(text), "\n")
}
func (m *model) plain(text string) string { return safeText(text, m.ascii) }
func (m *model) nowTime() time.Time {
	if !m.now.IsZero() {
		return m.now
	}
	return time.Now()
}
func (m *model) collecting() bool { return m.state.Event == "" || m.state.Collecting }
func (m *model) observation() string {
	stamp := m.state.CapturedAt
	if stamp == "" && m.inventory {
		stamp = m.state.Inventory.ObservedAt
	}
	if stamp == "" {
		stamp = m.state.Scope.Observed
	}
	if when, err := time.Parse(time.RFC3339, stamp); err == nil {
		age := m.nowTime().Sub(when)
		if age < 0 {
			age = 0
		}
		separator := " · "
		if m.ascii {
			separator = " | "
		}
		return when.Local().Format("15:04 MST") + separator + durationText(int64(age.Seconds())) + " ago"
	}
	return "time unavailable"
}
func (m *model) title(width int) string {
	name := "Choose"
	switch m.state.Step {
	case "review":
		name = "Review choices"
	case "save":
		name = "Save plan"
	case "saved":
		name = "Plan saved"
	case "help":
		name = "Help"
	case "evidence":
		name = "Inspect"
	case "confirm_quit":
		name = "Confirm cancel"
	case "confirm_refresh":
		name = "Confirm refresh"
	}
	left := m.paint("brand", "afterparty") + " " + m.paint("bold", "REVIEW / "+name)
	right := m.plain(m.observation())
	gap := width - ansi.StringWidth(left) - ansi.StringWidth(right)
	if gap < 2 {
		return m.line(ansi.Strip(left), "brand", max(1, width-len(right)-2)) + "  " + right
	}
	return left + strings.Repeat(" ", gap) + m.paint("dim", right)
}
func (m *model) tooSmall() string {
	w := max(1, m.width-2)
	if m.inventory {
		label := fmt.Sprintf("Build output needs 60×20. This pane is %d×%d.", m.width, m.height)
		if m.ascii {
			label = fmt.Sprintf("Build output needs 60x20. This pane is %dx%d.", m.width, m.height)
		}
		lines := m.wrapped(label, "bold", w)
		lines = append(lines, m.wrapped("Resize to continue. Press q to exit.", "", w)...)
		lines = append(lines, m.wrapped("In tmux, press prefix z to zoom the pane.", "", w)...)
		return lipgloss.NewStyle().PaddingLeft(1).Render(strings.Join(lines[:min(len(lines), max(1, m.height))], "\n"))
	}
	label := fmt.Sprintf("Review needs 60×20. This pane is %d×%d.", m.width, m.height)
	if m.ascii {
		label = fmt.Sprintf("Review needs 60x20. This pane is %dx%d.", m.width, m.height)
	}
	lines := m.wrapped(label, "bold", w)
	if m.state.SavedPath != "" {
		lines = append(lines, m.wrapped("Afterparty saved the plan. Press Enter or q to finish.", "", w)...)
	} else {
		lines = append(lines, m.wrapped(fmt.Sprintf("%d marked. Resize to continue. Press q to quit.", len(m.state.Marked)), "", w)...)
	}
	if m.state.Step == "confirm_quit" {
		lines = append(lines, m.wrapped("Unmark all targets? Press q to quit. Press Esc to return.", "bold", w)...)
	}
	lines = append(lines, m.wrapped("In tmux, press prefix z to zoom the pane.", "", w)...)
	return lipgloss.NewStyle().PaddingLeft(1).Render(strings.Join(lines[:min(len(lines), max(1, m.height))], "\n"))
}
func (m *model) render() string {
	m.roomTooSmall = false
	if m.inventory {
		return m.renderInventory()
	}
	if m.width < 60 || m.height < 20 {
		m.roomTooSmall = true
		return m.tooSmall()
	}
	w := min(m.width-3, 116)
	if m.collecting() {
		elapsed := int64(m.nowTime().Sub(m.scanStarted).Seconds())
		if m.scanStarted.IsZero() || elapsed < 0 {
			elapsed = 0
		}
		action := "Afterparty scans for cleanup targets."
		if m.state.Generation > 1 {
			action = "Afterparty scans for cleanup targets again."
		}
		lines := []string{m.paint("brand", "afterparty REVIEW"), "", m.paint("bold", action), fmt.Sprintf("Elapsed: %s", durationText(elapsed)), "", "Afterparty ignores review keys during the scan.", "Press q or Ctrl+C to exit without cleanup."}
		return lipgloss.NewStyle().PaddingLeft(1).Render(strings.Join(lines, "\n"))
	}
	s := m.state
	header := []string{m.title(w)}
	counts := fmt.Sprintf("Scan: %s | %d available | %d withheld", s.Scope.Status, s.available(), len(s.Items)-s.available())
	// Scope is one stable row; the full path remains in Help and target evidence.
	header = append(header, m.line(m.plain("Scope: "+s.Scope.Root), "", w))
	role := ""
	if s.Scope.Status != "complete" {
		role = "warning"
	}
	header = append(header, m.line(counts, role, w))
	if s.Scope.Flags["all"] {
		header = append(header, m.line("Process groups/worktrees: all; artifacts: this scope", "", w))
	}
	var unavailable []string
	for _, cap := range s.Capabilities {
		if cap.Status != "complete" {
			unavailable = append(unavailable, cap.Name)
		}
	}
	if len(unavailable) > 0 {
		header = append(header, m.line("Unavailable: "+m.plain(strings.Join(unavailable, ", "))+" (? details)", "warning", w))
	}
	body, anchors := m.body(w)
	footer := m.footer(w)
	strip := []string{}
	if s.Step == "choose" {
		strip = m.focusStrip(w)
	}
	room := m.height - len(header) - len(footer) - len(strip) - 1
	if room < 3 {
		m.roomTooSmall = true
		return m.tooSmall()
	}
	if s.RevealFocus {
		if bounds, ok := anchors[s.Focus]; ok && (bounds[0] < m.scroll || bounds[1] > m.scroll+room) {
			m.scroll = bounds[0]
		}
		if s.Step == "evidence" {
			m.scroll = 0
		}
		m.state.RevealFocus = false
	}
	m.scroll = max(0, min(m.scroll, max(0, len(body)-room)))
	m.focusVisible = true
	if bounds, ok := anchors[s.Focus]; ok {
		m.focusVisible = bounds[0] >= m.scroll && bounds[0] < m.scroll+room
	}
	shown := append([]string{}, body[m.scroll:min(len(body), m.scroll+room)]...)
	for len(shown) < room {
		shown = append(shown, "")
	}
	pos := fmt.Sprintf("%d marked", len(s.Marked))
	if s.Step == "choose" {
		for i, t := range s.visible() {
			if t.ID == s.Focus {
				pos += fmt.Sprintf(" | Target %d of %d: %s", i+1, len(s.visible()), m.label(t, max(8, w/2)))
				break
			}
		}
	} else {
		pos += fmt.Sprintf(" | Lines %d-%d of %d", min(m.scroll+1, len(body)), min(m.scroll+room, len(body)), len(body))
	}
	if s.Step == "choose" && !m.focusVisible {
		pos += " (off-screen)"
	}
	lines := append(header, shown...)
	lines = append(lines, m.line(pos, "dim", w))
	lines = append(lines, strip...)
	lines = append(lines, footer...)
	return lipgloss.NewStyle().PaddingLeft(1).Render(strings.Join(lines, "\n"))
}
