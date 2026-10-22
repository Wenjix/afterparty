package main

import (
	"fmt"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestReviewProgressRail(t *testing.T) {
	setTheme(t, "mono")
	for _, step := range []string{"choose", "review", "save", "saved"} {
		t.Run(step, func(t *testing.T) {
			m := fixtureModel(fixtureMode(fixture(), step), 80, 24)
			m.ascii = true
			rail := m.progressRail(77)
			want := "Choose > Review choices > Save plan"
			current := map[string]string{"choose": "Choose", "review": "Review choices", "save": "Save plan", "saved": "Plan saved"}[step]
			if step == "saved" {
				want = "Choose > Review choices > Plan saved"
			}
			if ansi.Strip(rail) != want || !strings.Contains(rail, m.paint("bold", current)) {
				t.Fatalf("phase is not clear: %q", rail)
			}
		})
	}
}

func TestReviewProgressRailHasTextCueWithoutStyling(t *testing.T) {
	t.Setenv("AFTERPARTY_REVIEW_ATTRIBUTES", "0")
	t.Setenv("AFTERPARTY_REVIEW_COLOR", "0")
	m := fixtureModel(fixtureMode(fixture(), "review"), 80, 24)
	m.ascii = true
	if rail := m.progressRail(77); rail != "Choose > [Review choices] > Save plan" {
		t.Fatalf("unstyled phase lost its current-state cue: %q", rail)
	}
}

func TestReviewSectionCountsFollowVisibleTargets(t *testing.T) {
	setTheme(t, "mono")
	s := fixture()
	s.VisibleIDs = []string{"process:1", "artifact:2"}
	m := fixtureModel(s, 80, 24)
	lines, _ := m.body(77)
	counts := map[string]bool{}
	for _, line := range lines {
		plain := strings.TrimSpace(ansi.Strip(line))
		for _, label := range []string{"Process groups 1", "Artifacts 1", "Artifacts 2", "Worktrees 1"} {
			if strings.HasPrefix(plain, label+" ") {
				counts[label] = true
			}
		}
	}
	if !counts["Process groups 1"] || !counts["Artifacts 1"] {
		t.Fatalf("group counts did not use the filtered list: %v", lines)
	}
	if counts["Artifacts 2"] || counts["Worktrees 1"] {
		t.Fatalf("hidden targets contributed to group counts: %v", lines)
	}
}

func TestWideReviewEvidenceKeepsHumanAndExactIdentity(t *testing.T) {
	setTheme(t, "mono")
	m := fixtureModel(fixture(), 120, 40)
	lines := m.focusPane(45, 30)
	pane := ansi.Strip(strings.Join(lines, "\n"))
	for _, fact := range []string{"PGID 4821", "vite | PGID 4821", "Decision", "Measurements", "Identity", "Process members", "CPU 0.2%", "Recorded activity 18h 0m ago"} {
		if !strings.Contains(pane, fact) {
			t.Fatalf("evidence pane lost %q:\n%s", fact, pane)
		}
	}
}

func TestReviewFocusPanelIsBoundedAndInspectionIsComplete(t *testing.T) {
	setTheme(t, "mono")
	s := fixture()
	s.Items[0].Consequence = strings.Repeat("Restart this service manually after stopping the group. ", 30)
	m := fixtureModel(s, 60, 20)
	m.ascii = true
	strip := m.focusStrip(57)
	if len(strip) != 4 || !strings.Contains(ansi.Strip(strings.Join(strip, "\n")), "more lines | i inspect") {
		t.Fatalf("bounded panel lost inspection hint: %v", strip)
	}
	if !strings.HasPrefix(ansi.Strip(strip[0]), "+") || !strings.HasPrefix(ansi.Strip(strip[3]), "+") {
		t.Fatal("ASCII panel has no visible boundaries")
	}
	m.state.Step = "evidence"
	lines, _ := m.body(57)
	full := strings.Join(strings.Fields(ansi.Strip(strings.Join(lines, "\n"))), "")
	if !strings.Contains(full, strings.Join(strings.Fields(s.Items[0].Consequence), "")) {
		t.Fatal("inspection lost the complete consequence")
	}
}

func TestWideReviewKeepsFocusAndFilteredPosition(t *testing.T) {
	setTheme(t, "mono")
	s := fixture()
	s.Items, s.VisibleIDs = nil, nil
	for index := 0; index < 48; index++ {
		id := fmt.Sprintf("artifact:%d", index)
		s.Items = append(s.Items, item{ID: id, Type: "artifact", Scope: s.Scope.Root, Target: fmt.Sprintf("/work/afterparty/output-%d/.next", index), Availability: "available", Consequence: "Delete build output. Run a build to recreate it.", Evidence: evidence{Size: "120 MB"}})
		if index%2 == 1 {
			s.VisibleIDs = append(s.VisibleIDs, id)
		}
	}
	s.Focus = s.Items[47].ID
	s.Marked = []string{s.Focus}
	m := fixtureModel(s, 120, 24)
	frame := ansi.Strip(m.render())
	if !m.focusVisible || m.scroll == 0 {
		t.Fatalf("wide list did not reveal focused target: scroll=%d\n%s", m.scroll, frame)
	}
	for _, fact := range []string{"Focused target", "Target 24 of 24", "output-47/.next", "If applied:", "120 MB"} {
		if !strings.Contains(frame, fact) {
			t.Fatalf("wide frame lost %q:\n%s", fact, frame)
		}
	}
	for _, line := range strings.Split(frame, "\n") {
		if ansi.StringWidth(line) >= m.width {
			t.Fatalf("wide pane overflowed: %q", line)
		}
	}
	for _, size := range [][2]int{{120, 40}, {80, 24}, {60, 20}, {100, 24}} {
		m.Update(tea.WindowSizeMsg{Width: size[0], Height: size[1]})
		frame = ansi.Strip(m.render())
		if !m.focusVisible || m.roomTooSmall || m.state.Focus != s.Focus || !has(m.state.Marked, s.Focus) {
			t.Fatalf("resize to %dx%d lost the focused choice:\n%s", size[0], size[1], frame)
		}
		if !strings.Contains(frame, "Target 24 of 24") {
			t.Fatal("resize changed the filtered target position")
		}
	}
}

func TestSavedReviewHasStaticCompletionReceipt(t *testing.T) {
	setTheme(t, "mono")
	s := fixtureMode(fixture(), "saved")
	s.SavedPath = "/tmp/reviewed-plan.md"
	m := fixtureModel(s, 60, 20)
	m.ascii = true
	frame := ansi.Strip(m.render())
	for _, fact := range []string{"DONE Plan saved", "Saved: /tmp/reviewed-plan.md", "Apply checks each target again.", "No cleanup ran."} {
		if !strings.Contains(strings.Join(strings.Fields(frame), " "), fact) {
			t.Fatalf("saved frame lost %q:\n%s", fact, frame)
		}
	}
}

func TestSavedReceiptSurvivesAutomaticFocusReveal(t *testing.T) {
	s := fixtureMode(fixture(), "saved")
	s.SavedPath = "/tmp/reviewed-plan.md"
	s.Marked = []string{"process:1", "artifact:1", "artifact:2"}
	s.Focus = "artifact:2"
	m := fixtureModel(s, 60, 20)
	for _, expanded := range []bool{false, true} {
		m.state.Expanded = expanded
		m.state.RevealFocus = true
		frame := ansi.Strip(m.render())
		if m.scroll != 0 || !strings.Contains(frame, "Saved: /tmp/reviewed-plan.md") || !strings.Contains(frame, "No cleanup ran.") {
			t.Fatalf("automatic focus reveal hid the saved receipt:\n%s", frame)
		}
	}
}

func TestConfirmationsShowExplicitChoicesWithoutRepeatedFooter(t *testing.T) {
	setTheme(t, "mono")
	for _, step := range []string{"confirm_quit", "confirm_refresh"} {
		for _, ascii := range []bool{false, true} {
			s := fixtureMode(fixture(), step)
			s.Marked = []string{"process:1", "artifact:1"}
			m := fixtureModel(s, 60, 20)
			m.ascii = ascii
			body, _ := m.body(57)
			text := strings.Join(strings.Fields(ansi.Strip(strings.Join(body, "\n"))), " ")
			for _, fact := range []string{"Discard marks?", "2 targets marked.", "Esc Keep reviewing"} {
				if !strings.Contains(text, fact) {
					t.Fatalf("%s omitted %q: %s", step, fact, text)
				}
			}
			confirm := "q/Enter Discard marks and quit"
			if step == "confirm_refresh" {
				confirm = "r/Enter Discard marks and refresh"
			}
			if !strings.Contains(text, confirm) || len(m.footer(57)) != 0 || len(body) > 10 {
				t.Fatalf("%s obscured its explicit choices: %s", step, text)
			}
			if strings.Contains(strings.Join(body, "\n"), "\x1b[1;7m") || m.state.Focus != s.Focus || len(m.state.Marked) != 2 {
				t.Fatal("confirmation selected a destructive choice or changed the draft")
			}
		}
	}
}

func TestHiddenMarksRemainVisibleWithoutChangingFilterOrSelection(t *testing.T) {
	s := fixture()
	s.Query = "playwright"
	s.VisibleIDs = []string{"artifact:2"}
	s.Focus = "artifact:2"
	s.Marked = []string{"artifact:1", "artifact:2"}
	m := fixtureModel(s, 60, 20)
	footer := ansi.Strip(strings.Join(m.footer(57), "\n"))
	if s.hiddenMarks() != 1 || !strings.Contains(footer, "1 marked outside filter | / playwright") {
		t.Fatalf("filter hid a reviewed mark without notice: %s", footer)
	}
	if m.state.Focus != s.Focus || m.state.Query != s.Query || strings.Join(m.state.Marked, ",") != "artifact:1,artifact:2" {
		t.Fatal("hidden-mark reporting changed the draft")
	}
	m.state.Marked = []string{"artifact:2"}
	if footer = ansi.Strip(strings.Join(m.footer(57), "\n")); strings.Contains(footer, "outside filter") || !strings.Contains(footer, "/ playwright") {
		t.Fatalf("hidden-mark status outlived the hidden mark: %s", footer)
	}
}

func TestExpiredFeedbackUsesNeutralGuidanceAndRemainsInHelp(t *testing.T) {
	setTheme(t, "mono")
	s := fixture()
	s.Message, s.MessageKind, s.MessageTransient = "You marked vite. 1 marked.", "done", true
	s.Guidance = "Mark targets to include in the plan."
	m := fixtureModel(s, 80, 24)
	m.feedbackAt = m.now.Add(-5 * time.Second)
	footer := ansi.Strip(strings.Join(m.footer(77), "\n"))
	if !strings.Contains(footer, s.Guidance) || strings.Contains(footer, s.Message) || strings.Contains(footer, "✓") {
		t.Fatalf("expired feedback kept a success cue or lost guidance: %s", footer)
	}
	m.state.Step = "help"
	body, _ := m.body(77)
	help := ansi.Strip(strings.Join(body, "\n"))
	if !strings.Contains(help, "Latest message") || !strings.Contains(help, s.Message) {
		t.Fatalf("Help discarded the latest full acknowledgement: %s", help)
	}
}

func TestStructuredInspectionPreservesMembersAndEscapesRawIdentityOnce(t *testing.T) {
	setTheme(t, "mono")
	s := fixtureMode(fixture(), "evidence")
	s.Items[0].Evidence.CPU = nil
	s.Items[0].Evidence.Members = nil
	for index := 0; index < 25; index++ {
		s.Items[0].Evidence.Members = append(s.Items[0].Evidence.Members, member{PID: 5000 + index, Command: fmt.Sprintf("worker --instance %d", index)})
	}
	m := fixtureModel(s, 60, 20)
	body, _ := m.body(57)
	text := strings.Join(strings.Fields(ansi.Strip(strings.Join(body, "\n"))), " ")
	for _, fact := range []string{"Decision", "Measurements", "Identity", "Process members", "CPU unknown", s.Items[0].Consequence} {
		if !strings.Contains(text, fact) {
			t.Fatalf("structured inspection omitted %q", fact)
		}
	}
	for _, member := range s.Items[0].Evidence.Members {
		if !strings.Contains(text, fmt.Sprintf("Member %d: %s", member.PID, member.Command)) {
			t.Fatalf("structured inspection omitted captured member %d", member.PID)
		}
	}
	raw := "/work/afterparty/cache\\files\t日本\x1b[31m"
	artifact := s.Items[2]
	artifact.Target = raw
	m.ascii = true
	lines := m.targetDetails(artifact, 57, true)
	escaped := strings.Join(strings.Fields(ansi.Strip(strings.Join(lines, "\n"))), "")
	want := strings.Join(strings.Fields(m.plain(raw)), "")
	twice := strings.Join(strings.Fields(m.plain(m.plain(raw))), "")
	if !strings.Contains(escaped, want) || strings.Contains(escaped, twice) {
		t.Fatalf("raw identity was lost or escaped twice: %s", escaped)
	}
}

func TestCompactChooseHintsPreserveSmallPaneBudget(t *testing.T) {
	m := fixtureModel(fixture(), 60, 20)
	hints := m.keyHints(m.state.Legend, 57)
	if len(hints) > 2 {
		t.Fatalf("Choose hints used %d rows: %v", len(hints), hints)
	}
	for _, key := range []string{"Space", "Enter", "Up/Down", "q", "Ctrl+P", "?"} {
		if !strings.Contains(ansi.Strip(strings.Join(hints, "\n")), key+" ") {
			t.Fatalf("compact hints omitted %q", key)
		}
	}
	m.state.Scope.Flags = map[string]bool{"all": true}
	m.state.Capabilities = []capability{{Name: "activity", Status: "unavailable", Reason: "Test evidence unavailable."}}
	m.state.Query, m.state.Marked = "vite", []string{"artifact:1"}
	m.state.VisibleIDs = []string{"process:1"}
	frame := ansi.Strip(m.render())
	if m.roomTooSmall || !strings.Contains(frame, "1 marked outside filter") || !strings.Contains(frame, "PGID 4821") {
		t.Fatalf("persistent context displaced the target list: %s", frame)
	}
}
