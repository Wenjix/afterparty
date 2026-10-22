package main

import (
	"fmt"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// Panel dimensions include the border. Callers wrap safe content before framing.
func (m *model) boundedPanel(title string, lines []string, width, height int) []string {
	return m.panel(title, lines, width, height, false)
}

func (m *model) evidencePanel(title string, lines []string, width, height int) []string {
	return m.panel(title, lines, width, height, true)
}

func (m *model) panel(title string, lines []string, width, height int, inspect bool) []string {
	if width < 6 || height < 3 {
		return nil
	}
	border := lipgloss.NormalBorder()
	if m.ascii {
		border = lipgloss.Border{Top: "-", Bottom: "-", Left: "|", Right: "|", TopLeft: "+", TopRight: "+", BottomLeft: "+", BottomRight: "+"}
	}
	contentWidth := width - 4
	title = ansi.Truncate(title, width-5, "...")
	label := " " + m.paint("bold", title) + " "
	top := border.TopLeft + border.Top + label + strings.Repeat(border.Top, max(0, width-3-ansi.StringWidth(label))) + border.TopRight
	result := []string{top}
	room := height - 2
	for index := 0; index < room; index++ {
		line := ""
		if index < len(lines) {
			line = ansi.Truncate(lines[index], contentWidth, "...")
		}
		if inspect && index == room-1 && len(lines) > room {
			separator := " · "
			if m.ascii {
				separator = " | "
			}
			line = m.line(fmt.Sprintf("%d more lines%si inspect", len(lines)-(room-1), separator), "bold", contentWidth)
		}
		padding := strings.Repeat(" ", max(0, contentWidth-ansi.StringWidth(line)))
		result = append(result, border.Left+" "+line+padding+" "+border.Right)
	}
	return append(result, border.BottomLeft+strings.Repeat(border.Bottom, width-2)+border.BottomRight)
}

func (m *model) sectionRule(title, role string, width int) string {
	label := m.line(title, role, width)
	rule := "─"
	if m.ascii {
		rule = "-"
	}
	if remaining := width - ansi.StringWidth(label) - 1; remaining > 0 {
		label += " " + strings.Repeat(rule, remaining)
	}
	return label
}

// Content is already wrapped at width-2, leaving a neutral rail and one space.
func (m *model) inlineRail(lines []string, width int) []string {
	rail := "│ "
	if m.ascii {
		rail = "| "
	}
	result := make([]string, 0, len(lines))
	for _, line := range lines {
		result = append(result, rail+ansi.Truncate(line, max(1, width-2), "..."))
	}
	return result
}

func (m *model) joinColumns(left, right []string, leftWidth int) []string {
	first := strings.Join(left, "\n")
	first = lipgloss.NewStyle().Width(leftWidth).Render(first)
	joined := lipgloss.JoinHorizontal(lipgloss.Top, first, "  ", strings.Join(right, "\n"))
	return strings.Split(joined, "\n")
}

func (m *model) collectionPulse() string {
	frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	if m.ascii {
		frames = []string{"|", "/", "-", "\\"}
	}
	elapsed := m.nowTime().Sub(m.scanStarted)
	if m.scanStarted.IsZero() || elapsed < 0 {
		elapsed = 0
	}
	return frames[int(elapsed/(200*time.Millisecond))%len(frames)]
}
