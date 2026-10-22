package main

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

func TestPanelsKeepInspectionReachableWithinTheirBudget(t *testing.T) {
	for _, ascii := range []bool{false, true} {
		m := fixtureModel(fixture(), 60, 20)
		m.ascii = ascii
		lines := []string{"An important consequence", "The consequence continues", "More evidence", "Full identity"}
		panel := m.evidencePanel("Focused target", lines, 57, 4)
		if len(panel) != 4 || !strings.Contains(ansi.Strip(strings.Join(panel, "\n")), "3 more lines") || !strings.Contains(ansi.Strip(strings.Join(panel, "\n")), "i inspect") {
			t.Fatalf("clipped panel lost its inspection path: %q", panel)
		}
		for _, line := range panel {
			if ansi.StringWidth(line) != 57 {
				t.Fatalf("panel exceeded or lost its width budget: %q", line)
			}
			if ascii {
				for _, char := range ansi.Strip(line) {
					if char > 127 {
						t.Fatalf("ASCII panel contains %q", char)
					}
				}
			}
		}
	}
}

func TestEvidenceDisclosureCountsWholeHiddenRenderedLines(t *testing.T) {
	m := fixtureModel(fixture(), 60, 20)
	for count := 0; count < 8; count++ {
		lines := []string{}
		for index := 0; index < count; index++ {
			lines = append(lines, fmt.Sprintf("UNIQUE line %d", index))
		}
		panel := ansi.Strip(strings.Join(m.evidencePanel("Evidence", lines, 57, 4), "\n"))
		if count <= 2 {
			if strings.Contains(panel, "more lines") {
				t.Fatalf("unclipped panel invented hidden content: %s", panel)
			}
			continue
		}
		if !strings.Contains(panel, "UNIQUE line 0") || strings.Contains(panel, "UNIQUE line 1") || !strings.Contains(panel, fmt.Sprintf("%d more lines", count-1)) {
			t.Fatalf("hidden count included partial or visible lines: %s", panel)
		}
	}
	plain := ansi.Strip(strings.Join(m.boundedPanel("Commands", []string{"First action", "Second action", "Third action"}, 57, 4), "\n"))
	if !strings.Contains(plain, "First action") || strings.Contains(plain, "i inspect") {
		t.Fatalf("generic panel inherited an invalid evidence shortcut: %s", plain)
	}
}

func TestJoinedPanelsPreserveNeutralFocusAndColumnAlignment(t *testing.T) {
	setTheme(t, "mono")
	m := fixtureModel(fixture(), 120, 40)
	left := []string{m.paint("focus", "> [x] target"), "second target"}
	right := m.boundedPanel("Focus", []string{"Consequence"}, 42, 4)
	joined := m.joinColumns(left, right, 72)
	if len(joined) != 4 || !strings.Contains(joined[0], "\x1b[1;7m") {
		t.Fatal("composition lost height or focus")
	}
	for _, line := range joined {
		if ansi.StringWidth(line) != 116 || strings.Contains(line, "\t") {
			t.Fatalf("misaligned composition: %q", line)
		}
	}
}

func TestCollectionPulseMovesWithoutInventingProgress(t *testing.T) {
	m := fixtureModel(viewState{Event: "scan", Collecting: true}, 80, 24)
	m.scanStarted = m.now
	first := m.collectionPulse()
	m.now = m.now.Add(200 * time.Millisecond)
	if first == m.collectionPulse() {
		t.Fatal("collection indicator did not advance")
	}
	m.ascii = true
	if !strings.Contains("|/-\\", m.collectionPulse()) {
		t.Fatal("ASCII collection indicator is not ASCII")
	}
	m.finished = true
	if _, command := m.Update(tickMsg(m.now)); command != nil {
		t.Fatal("finished review scheduled another clock update")
	}
}
