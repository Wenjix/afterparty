package main

import (
	"fmt"
	"math"
	"path/filepath"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

func inventorySize(size int64) string {
	units := []string{"B", "KB", "MB", "GB", "TB", "PB", "EB"}
	value := float64(size)
	unit := 0
	for value >= 1000 && unit < len(units)-1 {
		value /= 1000
		unit++
	}
	if unit == 0 {
		return fmt.Sprintf("%d B", size)
	}
	return fmt.Sprintf("%.1f %s", value, units[unit])
}

func inventoryItemSize(target inventoryItem) string {
	if target.SizeBytes == nil {
		return "unknown"
	}
	return inventorySize(*target.SizeBytes)
}

func inventoryDelta(delta *int64) string {
	if delta == nil {
		return "unknown"
	}
	if *delta < 0 {
		return "-" + inventorySize(-*delta)
	}
	if *delta > 0 {
		return "+" + inventorySize(*delta)
	}
	return "0 B"
}

func inventoryTime(stamp string) string {
	if when, err := time.Parse(time.RFC3339, stamp); err == nil {
		return when.Local().Format("2006-01-02 15:04 MST")
	}
	return "unknown"
}

func inventoryMeter(size *int64, total int64, ascii bool) string {
	const width = 8
	if size == nil {
		return fmt.Sprintf("%-*s", width, "unknown")
	}
	filled := 0
	if total > 0 {
		filled = max(0, min(width, int(math.Round(float64(*size)/float64(total)*width))))
	}
	full, empty := "█", "░"
	if ascii {
		full, empty = "#", "."
	}
	return strings.Repeat(full, filled) + strings.Repeat(empty, width-filled)
}

func inventoryShare(size *int64, total int64) string {
	if size == nil || total <= 0 {
		return "Share: unknown"
	}
	return fmt.Sprintf("Share: %.1f%% of known bytes", 100*float64(*size)/float64(total))
}

func (m *model) inventoryVisible() []inventoryItem {
	var result []inventoryItem
	ids := map[string]bool{}
	for _, id := range m.state.VisibleIDs {
		ids[id] = true
	}
	for _, target := range m.state.Inventory.Items {
		if ids[target.ID] {
			result = append(result, target)
		}
	}
	return result
}

func (m *model) inventoryFocused() (inventoryItem, bool) {
	for _, target := range m.inventoryVisible() {
		if target.ID == m.state.Focus {
			return target, true
		}
	}
	return inventoryItem{}, false
}

func (m *model) inventoryRawLabel(target inventoryItem) string {
	repository := filepath.Base(target.Repository)
	for _, repo := range m.state.Inventory.Repositories {
		if repo.Root == target.Repository && repo.Label != "" {
			repository = repo.Label
			break
		}
	}
	path := target.RelativePath
	if path == "" {
		path = filepath.Base(target.Path)
	}
	return m.plain(repository + "/" + path)
}

func (m *model) inventoryLabels(items []inventoryItem, width int) map[string]string {
	labels := map[string]string{}
	seen := map[string]bool{}
	collision := false
	for _, target := range items {
		label := ansi.Truncate(m.inventoryRawLabel(target), width, "...")
		labels[target.ID] = label
		if seen[label] {
			collision = true
		}
		seen[label] = true
	}
	if collision {
		for index, target := range items {
			prefix := fmt.Sprintf("[%d] ", index+1)
			labels[target.ID] = prefix + ansi.Truncate(m.inventoryRawLabel(target), max(1, width-len(prefix)), "...")
		}
	}
	return labels
}

func (m *model) inventoryGrowth() string {
	r := m.state.Inventory
	if r.HistoryStatus == "first" {
		return "Growth: first scan; no comparison"
	}
	if r.HistoryStatus != "compared" || r.DeltaBytes == nil {
		return "Growth: unknown (? details)"
	}
	return "Growth: " + inventoryDelta(r.DeltaBytes) + " since previous complete scan"
}

func (m *model) inventoryBody(w int) ([]string, map[string][2]int) {
	lines := []string{}
	anchors := map[string][2]int{}
	add := func(text, role string) { lines = append(lines, m.wrapped(m.plain(text), role, w)...) }
	r, s := m.state.Inventory, m.state
	switch s.Step {
	case "inventory_help":
		lines = append(lines, m.sectionRule("Keys", "bold", w))
		for _, hint := range s.HelpKeys {
			add(fmt.Sprintf("%-10s %s", hint.Key, hint.Label), "")
		}
		add("", "")
		lines = append(lines, m.sectionRule("Scan status", "bold", w))
		add("Collection: "+r.CollectionStatus, "")
		add(fmt.Sprintf("Repository depth: %d", r.MaxDepth), "")
		add("Scanned: "+m.observation(), "")
		add("Known total: "+inventorySize(r.TotalBytes)+" (estimated)", "")
		if r.CollectionStatus != "complete" {
			add("The total includes only sizes that the scan could read.", "warning")
		}
		add(m.inventoryGrowth(), "")
		if r.PreviousObservedAt != "" {
			add("Previous complete scan: "+inventoryTime(r.PreviousObservedAt), "")
		}
		if r.HistoryStatus == "unavailable" {
			add("The previous scan is unavailable. Growth is unknown.", "warning")
		}
		add("File modification times do not prove last use.", "")
		add("The inventory does not check cleanup eligibility.", "")
		add("Enter opens cleanup review for the focused repository.", "")
		add("", "")
		lines = append(lines, m.sectionRule("Roots", "bold", w))
		for _, root := range r.Roots {
			add(root, "")
		}
		add("", "")
		lines = append(lines, m.sectionRule("Repositories", "bold", w))
		for _, repo := range r.Repositories {
			add(repo.Root+" - "+repo.Status, "")
		}
		add("", "")
		lines = append(lines, m.sectionRule("Scan issues", "bold", w))
		if len(r.Issues) == 0 {
			add("None.", "dim")
		}
		for _, issue := range r.Issues {
			add(issue.Path+": "+issue.Message, "warning")
		}
		if s.Message != "" {
			add("", "")
			lines = append(lines, m.sectionRule("Latest message", "bold", w))
			role := ""
			if s.MessageKind == "refused" {
				role = "warning"
			}
			add(s.Message, role)
		}
	case "inventory_inspect":
		if target, ok := m.inventoryFocused(); ok {
			lines = append(lines, m.wrapped(m.inventoryRawLabel(target), "bold", w)...)
			lines = append(lines, m.inventoryDetails(target, w)...)
		} else {
			add("No target has focus. Return to the list to choose a target.", "")
		}
	default:
		items := m.inventoryVisible()
		labelWidth := max(8, w-24)
		meters := m.width >= 80
		if meters {
			labelWidth = max(8, w-34)
		}
		labels := m.inventoryLabels(items, labelWidth)
		heading := fmt.Sprintf("  %-*s %10s %10s", labelWidth, "Repository / path", "Allocated", "Growth")
		if meters {
			heading += "  Share"
		}
		add(heading, "dim")
		for _, target := range items {
			cursor, role := "  ", ""
			if target.ID == s.Focus {
				cursor, role = "> ", "focus"
			}
			start := len(lines)
			label := labels[target.ID]
			row := cursor + label + strings.Repeat(" ", max(0, labelWidth-ansi.StringWidth(label)))
			row += fmt.Sprintf(" %10s %10s", inventoryItemSize(target), inventoryDelta(target.DeltaBytes))
			if meters {
				row += "  " + inventoryMeter(target.SizeBytes, r.TotalBytes, m.ascii)
			}
			lines = append(lines, m.line(row, role, w))
			anchors[target.ID] = [2]int{start, start + 1}
			if s.Expanded && target.ID == s.Focus {
				lines = append(lines, m.inlineRail(m.inventoryDetails(target, w-2), w)...)
			}
		}
		if len(items) == 0 {
			message := "The scan found no build output in this scope."
			if s.Query != "" {
				message = "No paths match the filter. Press / to change it."
			} else if r.CollectionStatus != "complete" {
				message = "The scan is incomplete. Press ? for the unavailable paths."
			}
			add(message, "")
		}
	}
	return lines, anchors
}

func (m *model) inventoryStrip(w int) []string {
	target, ok := m.inventoryFocused()
	if !ok {
		return nil
	}
	labels := m.inventoryLabels(m.inventoryVisible(), w-5)
	lines := m.wrapped(m.plain("Kind: "+target.Kind+" | "+inventoryShare(target.SizeBytes, m.state.Inventory.TotalBytes)), "", w-4)
	lines = append(lines, m.line("Enter opens review. No cleanup runs here.", "", w-4))
	return m.evidencePanel(labels[target.ID], lines, w, 4)
}

func (m *model) inventoryRepositoryTotal(root string) (int64, bool) {
	var total int64
	partial := true
	for _, repository := range m.state.Inventory.Repositories {
		if repository.Root == root {
			partial = repository.Status != "complete"
			break
		}
	}
	for _, target := range m.state.Inventory.Items {
		if target.Repository != root {
			continue
		}
		if target.SizeBytes == nil {
			partial = true
		} else {
			total += *target.SizeBytes
		}
	}
	return total, partial
}

func (m *model) inventoryPanel(width, height int) []string {
	lines := []string{}
	add := func(text, role string) {
		lines = append(lines, m.wrapped(m.plain(text), role, width-4)...)
	}
	if target, ok := m.inventoryFocused(); ok {
		labels := m.inventoryLabels(m.inventoryVisible(), width-4)
		lines = append(lines, m.line(labels[target.ID], "bold", width-4))
		lines = append(lines, m.inventoryDetails(target, width-4)...)
	} else {
		add("No output has focus.", "")
		add("Choose a path to inspect its measurements.", "dim")
	}
	return m.evidencePanel("Focused output", lines, width, height)
}

func (m *model) inventoryDetails(target inventoryItem, width int) []string {
	total, partial := m.inventoryRepositoryTotal(target.Repository)
	qualifier := " (estimated)"
	if partial {
		qualifier = " (estimated, partial)"
	}
	sections := []detailSection{
		{"Decision", []string{"No cleanup runs here.", "Enter opens repository review."}},
		{"Measurements", []string{"Allocated: " + inventoryItemSize(target), "Growth: " + inventoryDelta(target.DeltaBytes), inventoryShare(target.SizeBytes, m.state.Inventory.TotalBytes), "Repo known: " + inventorySize(total) + qualifier, "Modified: " + inventoryTime(target.ModifiedAt) + " (file time)", "File modification time does not prove last use."}},
		{"Identity", []string{"Path: " + target.Path, "Repository: " + target.Repository, "Kind: " + target.Kind + " | Scan: " + target.Status, "This inventory does not check cleanup eligibility."}},
	}
	lines := []string{}
	for _, section := range sections {
		lines = append(lines, m.sectionRule(section.Title, "bold", width))
		for _, line := range section.Lines {
			lines = append(lines, m.wrapped(m.plain(line), "", width)...)
		}
	}
	return lines
}

func (m *model) renderInventory() string {
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
		lines := []string{
			m.paint("brand", "afterparty / BUILD OUTPUT"), "",
			m.paint("bold", m.collectionPulse()+" Afterparty scans build output."),
			fmt.Sprintf("Elapsed: %s", durationText(elapsed)), "",
			"This scan does not delete files.",
			"Afterparty ignores keys during the scan.",
			"Press q or Ctrl+C to exit.",
		}
		return lipgloss.NewStyle().PaddingLeft(1).Render(strings.Join(lines, "\n"))
	}
	s, r := m.state, m.state.Inventory
	left := m.paint("brand", "afterparty") + " / " + m.paint("bold", "BUILD OUTPUT")
	right := m.plain(m.observation())
	header := []string{left + strings.Repeat(" ", max(2, w-ansi.StringWidth(left)-ansi.StringWidth(right))) + m.paint("dim", right)}
	header = append(header, m.line(m.plain(fmt.Sprintf("Roots (%d): %s", len(r.Roots), strings.Join(r.Roots, " | "))), "", w))
	coverage := fmt.Sprintf("Scan: %s | %d repos | depth %d", r.CollectionStatus, len(r.Repositories), r.MaxDepth)
	role := ""
	if r.CollectionStatus != "complete" {
		role = "warning"
	}
	header = append(header, m.line(coverage, role, w))
	total := "Known total: " + inventorySize(r.TotalBytes) + " (estimated)"
	if r.CollectionStatus != "complete" {
		total = "Known total: " + inventorySize(r.TotalBytes) + " (estimated, partial)"
	}
	header = append(header, m.line(total, role, w), m.line(m.inventoryGrowth(), "", w))
	if len(r.Issues) > 0 {
		label := "scan issues"
		if len(r.Issues) == 1 {
			label = "scan issue"
		}
		header = append(header, m.line(fmt.Sprintf("%d %s (? details)", len(r.Issues), label), "warning", w))
	}
	if s.Step == "inventory" && m.width >= 80 {
		header = append(header, m.line("Share of known bytes", "", w))
	}
	wide := s.Step == "inventory" && m.width >= 100 && m.height >= 24
	bodyWidth := w
	const panelWidth = 34
	if wide {
		bodyWidth -= panelWidth + 2
	}
	body, anchors := m.inventoryBody(bodyWidth)
	footer := m.footer(w)
	strip := []string{}
	if s.Step == "inventory" && !wide {
		strip = m.inventoryStrip(w)
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
		if s.Step == "inventory_inspect" {
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
	if wide {
		shown = m.joinColumns(shown, m.inventoryPanel(panelWidth, room), bodyWidth)
	}
	position := fmt.Sprintf("%d paths", len(m.inventoryVisible()))
	if s.Step == "inventory" {
		for index, target := range m.inventoryVisible() {
			if target.ID == s.Focus {
				position = fmt.Sprintf("Path %d of %d: %s", index+1, len(m.inventoryVisible()), m.inventoryRawLabel(target))
				break
			}
		}
	} else {
		position = fmt.Sprintf("Lines %d-%d of %d", min(m.scroll+1, len(body)), min(m.scroll+room, len(body)), len(body))
	}
	if s.Step == "inventory" && !m.focusVisible {
		position += " (off-screen)"
	}
	lines := append(header, shown...)
	lines = append(lines, m.line(position, "dim", w))
	lines = append(lines, strip...)
	lines = append(lines, footer...)
	return lipgloss.NewStyle().PaddingLeft(1).Render(strings.Join(lines, "\n"))
}
