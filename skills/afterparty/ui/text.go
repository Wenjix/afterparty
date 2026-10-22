package main

import (
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
)

func safeText(text string, ascii bool) string {
	var b strings.Builder
	for _, r := range text {
		switch {
		case r == '\\':
			b.WriteString("\\\\")
		case unicode.IsControl(r) || unicode.In(r, unicode.Cf, unicode.Co, unicode.Cs, unicode.Zl, unicode.Zp) || (ascii && r > 127):
			if r <= 255 {
				fmt.Fprintf(&b, "\\x%02x", r)
			} else if r <= 65535 {
				fmt.Fprintf(&b, "\\u%04x", r)
			} else {
				fmt.Fprintf(&b, "\\U%08x", r)
			}
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func has(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func (s viewState) visible() []item {
	var result []item
	ids := make(map[string]bool, len(s.VisibleIDs))
	for _, id := range s.VisibleIDs {
		ids[id] = true
	}
	for _, target := range s.Items {
		if ids[target.ID] {
			result = append(result, target)
		}
	}
	return result
}

func (s viewState) available() int {
	count := 0
	for _, target := range s.Items {
		if target.Availability == "available" {
			count++
		}
	}
	return count
}

func (s viewState) hiddenMarks() int {
	visible := make(map[string]bool, len(s.VisibleIDs))
	for _, id := range s.VisibleIDs {
		visible[id] = true
	}
	count := 0
	for _, id := range s.Marked {
		if !visible[id] {
			count++
		}
	}
	return count
}

func measurement(target item) string {
	if target.Type == "process-group" {
		if target.Evidence.CPU == nil {
			return "CPU unknown"
		}
		return "CPU " + strconv.FormatFloat(*target.Evidence.CPU, 'f', -1, 64) + "%"
	}
	if target.Evidence.Size == "" {
		return "Size unknown"
	}
	return target.Evidence.Size
}

func durationText(seconds int64) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	if seconds < 3600 {
		return fmt.Sprintf("%dm %ds", seconds/60, seconds%60)
	}
	if seconds < 86400 {
		return fmt.Sprintf("%dh %dm", seconds/3600, seconds%3600/60)
	}
	return fmt.Sprintf("%dd %dh", seconds/86400, seconds%86400/3600)
}
func activityText(a *activity) string {
	if a == nil {
		return ""
	}
	if a.Idle == nil {
		return "Recorded activity unknown"
	}
	return "Recorded activity " + durationText(*a.Idle) + " ago"
}
func (m *model) rawLabel(target item) string {
	if target.DisplayLabel != "" {
		return m.plain(target.DisplayLabel)
	}
	if target.Type == "process-group" {
		command := target.Evidence.Purpose
		if command == "" && len(target.Evidence.Members) > 0 {
			command = target.Evidence.Members[0].Command
		}
		if command == "" {
			command = "Command unavailable"
		}
		return m.plain(command + " | PGID " + target.Target)
	}
	name := target.Target
	if name == m.state.Scope.Root {
		name = filepath.Base(name) + " (repository root)"
	} else {
		name = strings.TrimPrefix(name, strings.TrimSuffix(m.state.Scope.Root, "/")+"/")
	}
	return m.plain(name)
}
func (m *model) shortLabel(target item, limit int) string {
	raw := m.rawLabel(target)
	if target.Type == "process-group" {
		suffix := " | PGID " + target.Target
		raw = strings.TrimSuffix(raw, suffix)
		return ansi.Truncate(raw, max(1, limit-ansi.StringWidth(suffix)), "...") + suffix
	}
	return ansi.Truncate(raw, limit, "...")
}
func (m *model) label(target item, width int) string {
	return m.labels(width)[target.ID]
}

func (m *model) labels(width int) map[string]string {
	width = max(8, width)

	labels := make(map[string]string, len(m.state.Items))
	seen := map[string]bool{}
	collision := false
	for _, other := range m.state.Items {
		label := m.shortLabel(other, width)
		labels[other.ID] = label
		if seen[label] {
			collision = true
		}
		seen[label] = true
	}
	if collision {
		// A short ordinal is used only when shortening would erase a distinction.
		// Every row then carries its own prefix, including literal lookalike paths.
		for index, other := range m.state.Items {
			prefix := fmt.Sprintf("[%d] ", index+1)
			labels[other.ID] = prefix + m.shortLabel(other, max(1, width-len(prefix)))
		}
	}
	return labels
}

type detailSection struct {
	Title string
	Lines []string
}

// Sections contain raw evidence. Rendering escapes and wraps each value once.
func evidenceSections(target item) []detailSection {
	ev := target.Evidence
	measurements := []string{}
	identity := []string{"Scope: " + target.Scope}
	if target.Type == "process-group" {
		ports := []string{}
		for _, port := range ev.Ports {
			ports = append(ports, strconv.Itoa(port))
		}
		portText := strings.Join(ports, ", ")
		if portText == "" {
			portText = ev.PortsStatus
		}
		category := ev.Category
		if category == "" {
			category = "none"
		}
		measurements = append(measurements, measurement(target), "Ports: "+portText)
		identity = append(identity, "Category: "+category)
	} else {
		measurements = append(measurements, "Size: "+measurement(target))
		if ev.Branch != "" {
			identity = append(identity, "Branch: "+ev.Branch)
		}
	}
	if a := activityText(ev.Activity); a != "" {
		measurements = append(measurements, a)
	}
	if ev.Activity != nil && len(ev.Activity.Sources) > 0 {
		identity = append(identity, "Providers: "+strings.Join(ev.Activity.Sources, ", "))
	}
	if target.Fingerprint != "" {
		identity = append(identity, "Identity: "+target.Fingerprint)
	}
	sections := []detailSection{{"Measurements", measurements}, {"Identity", identity}}
	if target.Type == "process-group" && len(ev.Members) > 0 {
		members := make([]string, 0, len(ev.Members))
		for _, member := range ev.Members {
			members = append(members, fmt.Sprintf("Member %d: %s", member.PID, member.Command))
		}
		sections = append(sections, detailSection{"Process members", members})
	}
	return sections
}
