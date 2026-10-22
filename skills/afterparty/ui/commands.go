package main

import (
	"fmt"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

type commandSheet struct {
	open         bool
	query        string
	selected     int
	generation   int
	step, focus  string
	notice       string
	detailOffset int
}

func (m *model) openCommands() {
	if m.state.Searching || m.collecting() || len(m.state.Actions) == 0 {
		return
	}
	m.commands = commandSheet{open: true, generation: m.state.Generation, step: m.state.Step, focus: m.state.Focus}
}

func (m *model) matchingCommands() []commandAction {
	words := strings.Fields(strings.ToLower(m.commands.query))
	var result []commandAction
	for _, action := range m.state.Actions {
		text := strings.ToLower(action.Label + " " + action.Description)
		matches := true
		for _, word := range words {
			if !strings.Contains(text, word) {
				matches = false
				break
			}
		}
		if matches {
			result = append(result, action)
		}
	}
	return result
}

func (m *model) commandKey(key string) {
	actions := m.matchingCommands()
	switch key {
	case "esc", "ctrl+p":
		m.commands = commandSheet{}
	case "up":
		m.commands.selected = max(0, m.commands.selected-1)
		m.commands.detailOffset = 0
	case "down":
		m.commands.selected = min(max(0, len(actions)-1), m.commands.selected+1)
		m.commands.detailOffset = 0
	case "pgup":
		m.commands.detailOffset = max(0, m.commands.detailOffset-3)
	case "pgdown":
		m.commands.detailOffset += 3
	case "backspace":
		query := []rune(m.commands.query)
		if len(query) > 0 {
			m.commands.query = string(query[:len(query)-1])
		}
		m.commands.selected = 0
		m.commands.detailOffset = 0
	case "ctrl+u":
		m.commands.query, m.commands.selected = "", 0
		m.commands.detailOffset = 0
	case "enter":
		if len(actions) == 0 {
			return
		}
		m.commands.selected = min(m.commands.selected, len(actions)-1)
		action := actions[m.commands.selected]
		if !action.Enabled {
			return
		}
		request := keyRequest{Key: "ACTION", Action: action.ID, Generation: m.commands.generation,
			Step: m.commands.step, Focus: m.commands.focus, FocusVisible: m.focusVisible}
		select {
		case m.backend.keys <- request:
			m.commands = commandSheet{}
		default:
			// Retain the sheet and selection so the same action can be retried.
			m.commands.notice = "Wait for pending keys. Press Enter again to retry."
		}
	default:
		if key == "space" {
			key = " "
		}
		if len([]rune(key)) == 1 && len([]rune(m.commands.query)) < 128 {
			m.commands.query += key
			m.commands.selected = 0
			m.commands.detailOffset = 0
		}
	}
}

func (m *model) renderCommands() string {
	w := min(m.width-3, 80)
	inner := w - 4
	context := m.state.Scope.Root
	if m.inventory {
		context = strings.Join(m.state.Inventory.Roots, ", ")
	}
	lines := []string{m.paint("brand", "afterparty") + " / " + m.paint("bold", "COMMANDS"), m.line("Scope: "+m.plain(context), "", w)}
	if !m.inventory {
		phase := map[string]string{"choose": "Choose", "review": "Review choices", "save": "Save plan", "saved": "Plan saved", "evidence": "Inspect"}[m.state.Step]
		lines = append(lines, m.line(fmt.Sprintf("%d marked | %s", len(m.state.Marked), phase), "", w))
		if target, ok := m.focused(); ok {
			lines = append(lines, m.line("Target: "+m.label(target, w-8), "", w))
		}
	} else if target, ok := m.inventoryFocused(); ok {
		lines = append(lines, m.line("Target: "+m.inventoryRawLabel(target), "", w))
	}
	lines = append(lines, "")
	content := []string{m.line("Find: "+m.plain(m.commands.query)+"_", "", inner), ""}
	actions := m.matchingCommands()
	m.commands.selected = max(0, min(m.commands.selected, max(0, len(actions)-1)))
	var detail []string
	if len(actions) > 0 {
		action := actions[m.commands.selected]
		description := action.Description
		if !action.Enabled {
			description = "Unavailable: " + action.Reason
		}
		detail = m.wrapped(m.plain(description), "", inner)
	}
	hints := []keyHint{{"Up/Down", "choose"}, {"Enter", "run command"}, {"Esc", "back"}, {"Ctrl+U", "clear"}}
	keyLines := m.keyHints(hints, inner)
	noticeRows := 0
	if m.commands.notice != "" {
		noticeRows = 1
	}
	// Reserve framing, search, separators, command position, and one spare row.
	budget := m.height - len(lines) - 2 - len(content) - 3 - len(keyLines) - noticeRows - 1
	detailRows := min(len(detail), max(1, budget-1))
	if len(detail) > detailRows {
		hints = append(hints, keyHint{"PgUp/PgDn", "read details"})
		keyLines = m.keyHints(hints, inner)
		budget = m.height - len(lines) - 2 - len(content) - 3 - len(keyLines) - noticeRows - 1
		detailRows = min(len(detail), max(2, budget-1))
	}
	room := max(1, budget-detailRows)
	start := max(0, m.commands.selected-room+1)
	for index := start; index < min(len(actions), start+room); index++ {
		action := actions[index]
		prefix, role := "  ", ""
		if !action.Enabled {
			prefix = "⊘ "
			if m.ascii {
				prefix = "- "
			}
		}
		if index == m.commands.selected {
			prefix, role = "> ", "focus"
		}
		shortcut := m.plain(action.Key)
		label := ansi.Truncate(m.plain(action.Label), max(1, inner-len(prefix)-ansi.StringWidth(shortcut)-2), "...")
		gap := max(1, inner-ansi.StringWidth(prefix+label+shortcut))
		content = append(content, m.line(prefix+label+strings.Repeat(" ", gap)+shortcut, role, inner))
	}
	if len(actions) == 0 {
		content = append(content, "No matching commands. Use Backspace or Ctrl+U.")
	}
	content = append(content, "")
	if len(actions) > 0 {
		if len(detail) > detailRows {
			visible := max(1, detailRows-1)
			m.commands.detailOffset = max(0, min(m.commands.detailOffset, len(detail)-visible))
			end := min(len(detail), m.commands.detailOffset+visible)
			content = append(content, detail[m.commands.detailOffset:end]...)
			content = append(content, m.line(fmt.Sprintf("Details %d-%d of %d", m.commands.detailOffset+1, end, len(detail)), "", inner))
		} else {
			m.commands.detailOffset = 0
			content = append(content, detail...)
		}
		content = append(content, m.line(fmt.Sprintf("Command %d of %d", m.commands.selected+1, len(actions)), "", inner))
	}
	content = append(content, "")
	if m.commands.notice != "" {
		content = append(content, m.line(m.commands.notice, "", inner))
	}
	content = append(content, keyLines...)
	panel := m.boundedPanel("Commands", content, w, len(content)+2)
	lines = append(lines, panel...)
	return lipgloss.NewStyle().PaddingLeft(max(1, (m.width-w)/2)).PaddingTop(max(0, (m.height-len(lines))/2)).Render(strings.Join(lines, "\n"))
}

func (m *model) keyHints(hints []keyHint, width int) []string {
	var lines []string
	line := ""
	for _, hint := range hints {
		pair := m.paint("bold", m.plain(hint.Key)) + " " + m.plain(hint.Label)
		separator := " | "
		if line == "" {
			separator = ""
		}
		if line != "" && ansi.StringWidth(line+separator+pair) > width {
			lines = append(lines, line)
			line, separator = "", ""
		}
		line += separator + ansi.Truncate(pair, width, "...")
	}
	if line != "" {
		lines = append(lines, line)
	}
	return lines
}

func (m *model) feedbackMessage() string {
	if m.state.MessageTransient && !m.feedbackAt.IsZero() && m.nowTime().Sub(m.feedbackAt) >= 4*time.Second {
		return m.state.Guidance
	}
	if m.state.Message != "" {
		return m.state.Message
	}
	return m.state.Guidance
}
