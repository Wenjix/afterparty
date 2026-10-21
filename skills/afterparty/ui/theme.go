package main

import (
	"charm.land/lipgloss/v2"
	"os"
)

type theme struct {
	enabled    bool
	attributes bool
	roles      map[string]lipgloss.Style
}

func loadTheme() theme {
	color := os.Getenv("AFTERPARTY_REVIEW_COLOR") == "1"
	attrs := color || os.Getenv("AFTERPARTY_REVIEW_ATTRIBUTES") == "1"
	t := theme{enabled: color, attributes: attrs, roles: map[string]lipgloss.Style{}}
	if attrs {
		t.roles["brand"] = lipgloss.NewStyle().Bold(true)
		t.roles["bold"] = lipgloss.NewStyle().Bold(true)
		t.roles["focus"] = lipgloss.NewStyle().Bold(true).Reverse(true)
		t.roles["dim"] = lipgloss.NewStyle().Faint(true)
	}
	if color {
		t.roles["brand"] = t.roles["brand"].Foreground(lipgloss.Color(os.Getenv("AFTERPARTY_REVIEW_BRAND_COLOR")))
		t.roles["heading"] = lipgloss.NewStyle().Foreground(lipgloss.Color(os.Getenv("AFTERPARTY_REVIEW_HEADING_COLOR")))
		t.roles["warning"] = lipgloss.NewStyle().Foreground(lipgloss.Color(os.Getenv("AFTERPARTY_REVIEW_WARNING_COLOR")))
		t.roles["done"] = lipgloss.NewStyle().Foreground(lipgloss.Color(os.Getenv("AFTERPARTY_REVIEW_SUCCESS_COLOR")))
	}
	return t
}
