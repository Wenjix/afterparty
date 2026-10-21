package main

import (
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture() viewState {
	cpu, idle := 0.2, int64(64800)
	s := viewState{Event: "state", Generation: 1, Scope: scope{Root: "/work/afterparty", Status: "complete", Observed: "2026-10-12T09:23:00Z"}, Step: "choose", Focus: "process:1", SaveEnabled: true, RevealFocus: true, Message: "Mark targets to include in the plan.", MessageKind: "info", Destination: "/tmp/reviewed-plan.md",
		Items: []item{
			{ID: "process:1", Type: "process-group", Target: "4821", DisplayLabel: "vite | PGID 4821", Scope: "/work/afterparty", Availability: "available", Consequence: "Stop every group member. Restart the service manually.", Reason: "eligible", ReasonSentence: "Recorded agent activity is old. Observed CPU use is below the limit.", Evidence: evidence{CPU: &cpu, Ports: []int{3000}, Members: []member{{PID: 4821, Command: "npm run dev --token [REDACTED]"}, {PID: 4822, Command: "node vite --host 127.0.0.1"}}, Activity: &activity{Idle: &idle, Sources: []string{"codex"}}}},
			{ID: "worktree:1", Type: "worktree", Target: "/work/afterparty-wt/auth", Scope: "/work/afterparty", Availability: "withheld", Consequence: "Remove the worktree and its files through Git.", Reason: "occupied", ReasonSentence: "A live process uses this worktree (PID 7304).", Evidence: evidence{Activity: &activity{Status: "unknown"}}},
			{ID: "artifact:1", Type: "artifact", Target: "/work/afterparty/.next", Scope: "/work/afterparty", Availability: "available", Consequence: "Delete build output. Run a build to recreate it.", Reason: "The filesystem checks are complete.", Evidence: evidence{Size: "840 MB"}},
			{ID: "artifact:2", Type: "artifact", Target: "/work/afterparty/playwright-report", Scope: "/work/afterparty", Availability: "available", Consequence: "Delete test reports. Run the tests to recreate them.", Reason: "The filesystem checks are complete.", Evidence: evidence{Size: "120 MB"}},
		}}
	for _, target := range s.Items {
		s.VisibleIDs = append(s.VisibleIDs, target.ID)
	}
	s.HelpKeys = []keyHint{{"Space", "Mark or unmark"}, {"Enter", "Review choices, then Save plan"}, {"Up/Down", "Move focus"}, {"i", "Inspect target"}, {"d", "Show or hide details"}, {"/", "Filter targets"}, {"r", "Refresh the scan"}, {"q", "Quit"}, {"Ctrl+Z", "Suspend; use fg to resume"}}
	return fixtureMode(s, "choose")
}
func fixtureMode(s viewState, step string) viewState {
	s.Step = step
	switch step {
	case "review":
		s.Legend = []keyHint{{"Enter", "Continue to Save plan"}, {"Space", "unmark"}, {"Up/Down", "focus"}, {"d", "details"}, {"Esc", "Choose"}, {"q", "quit"}, {"?", "help"}}
		s.Summary = []string{"1 process group · 2 members", "0 worktrees", "1 artifact"}
	case "save":
		s.Legend = []keyHint{{"Enter", "Save plan"}, {"Esc", "Review choices"}, {"q", "quit"}, {"?", "help"}}
	case "saved":
		s.Legend = []keyHint{{"Enter/q", "finish"}, {"d", "details"}, {"?", "help"}}
	case "help":
		s.Legend = []keyHint{{"q/Esc/?", "back"}, {"PgUp/PgDn", "scroll"}}
	case "evidence":
		s.Legend = []keyHint{{"Space", "mark/unmark"}, {"Enter", "Review choices"}, {"Up/Down", "focus"}, {"PgUp/PgDn", "scroll"}, {"q/Esc", "Choose"}, {"?", "help"}}
	default:
		s.Legend = []keyHint{{"Space", "mark/unmark"}, {"Enter", "Review choices"}, {"Up/Down", "focus"}, {"i", "inspect"}, {"d", "details"}, {"/", "filter"}, {"r", "refresh"}, {"q", "quit"}, {"?", "help"}}
	}
	return s
}
func fixtureModel(s viewState, w, h int) model {
	now, _ := time.Parse(time.RFC3339, "2026-10-12T09:25:05Z")
	return model{state: s, width: w, height: h, now: now, theme: loadTheme(), focusVisible: true}
}
func setTheme(t *testing.T, kind string) {
	t.Helper()
	t.Setenv("AFTERPARTY_REVIEW_ATTRIBUTES", "1")
	t.Setenv("AFTERPARTY_REVIEW_COLOR", "1")
	t.Setenv("AFTERPARTY_REVIEW_BRAND_COLOR", "5")
	t.Setenv("AFTERPARTY_REVIEW_HEADING_COLOR", "6")
	t.Setenv("AFTERPARTY_REVIEW_WARNING_COLOR", "3")
	t.Setenv("AFTERPARTY_REVIEW_SUCCESS_COLOR", "2")
	if kind == "mono" || kind == "ascii" {
		t.Setenv("AFTERPARTY_REVIEW_COLOR", "0")
	}

}
func TestResponsiveFrames(t *testing.T) {
	for _, size := range [][2]int{{60, 20}, {80, 24}, {120, 40}} {
		for _, kind := range []string{"dark", "light", "mono", "ascii"} {
			t.Run(fmt.Sprintf("%dx%d/%s", size[0], size[1], kind), func(t *testing.T) {
				setTheme(t, kind)
				for _, expanded := range []bool{false, true} {
					for _, step := range []string{"choose", "evidence", "review", "save", "saved", "help", "confirm_quit", "confirm_refresh"} {
						s := fixtureMode(fixture(), step)
						s.Expanded = expanded
						s.Marked = []string{"process:1", "artifact:1"}
						m := fixtureModel(s, size[0], size[1])
						m.ascii = kind == "ascii"
						frame := ansi.Strip(m.render())
						if len(strings.Split(frame, "\n")) > size[1] {
							t.Fatalf("%s too tall", step)
						}
						for _, line := range strings.Split(frame, "\n") {
							if ansi.StringWidth(line) >= size[0] {
								t.Fatalf("%s too wide: %q", step, line)
							}
						}
						for _, fact := range []string{"Scope:", "2 marked", "Scan: complete", "2m 5s ago"} {
							if !strings.Contains(frame, fact) {
								t.Fatalf("%s missing %q:\n%s", step, fact, frame)
							}
						}
						if strings.Contains(frame, "\t") {
							t.Fatalf("%s contains copy-hostile tabs", step)
						}
					}
				}
			})
		}
	}
}
func TestFrameGoldens(t *testing.T) {
	t.Setenv("TZ", "UTC")
	oldLocal := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = oldLocal })
	for _, size := range [][2]int{{60, 20}, {80, 24}} {
		for _, kind := range []string{"color", "mono"} {
			for _, step := range []string{"choose", "review", "help"} {
				t.Run(fmt.Sprintf("%s_%dx%d_%s", step, size[0], size[1], kind), func(t *testing.T) {
					setTheme(t, kind)
					s := fixtureMode(fixture(), step)
					s.Marked = []string{"process:1", "artifact:1"}
					s.Capabilities = []capability{{Name: "activity", Status: "complete", Reason: "Transcript index complete"}}
					m := fixtureModel(s, size[0], size[1])
					frame := m.render() + "\n"
					path := filepath.Join("testdata", fmt.Sprintf("%s_%dx%d_%s.ansi", step, size[0], size[1], kind))
					if os.Getenv("UPDATE_GOLDEN") == "1" {
						if err := os.MkdirAll("testdata", 0755); err != nil {
							t.Fatal(err)
						}
						if err := os.WriteFile(path, []byte(frame), 0644); err != nil {
							t.Fatal(err)
						}
					}
					want, err := os.ReadFile(path)
					if err != nil {
						t.Fatal(err)
					}
					if frame != string(want) {
						t.Fatalf("frame changed; inspect before UPDATE_GOLDEN=1:\n%s", ansi.Strip(frame))
					}
				})
			}
		}
	}
}
func TestCompactRowsAndBoundedFocusStrip(t *testing.T) {
	s := fixture()
	s.Items[0].Consequence = strings.Repeat("Restart all services manually after stopping the group. ", 50)
	m := fixtureModel(s, 60, 20)
	frame := ansi.Strip(m.render())
	for _, fact := range []string{"Process groups", "Worktrees", "Artifacts", "PGID 4821", "840 MB", "120 MB", "[i: full detail]"} {
		if !strings.Contains(frame, fact) {
			t.Fatalf("missing %q:\n%s", fact, frame)
		}
	}
	if len(m.focusStrip(57)) > 4 {
		t.Fatal("long consequence consumed the list viewport")
	}
	if strings.Contains(frame, "Member 4821:") {
		t.Fatal("compact Choose leaked member details")
	}
	m.state = fixtureMode(m.state, "evidence")
	m.state.RevealFocus = true
	details, _ := m.body(57)
	if !strings.Contains(ansi.Strip(strings.Join(details, "\n")), "Member 4821:") {
		t.Fatal("inspection omitted full process identity")
	}
}
func TestReviewIncludesEveryGroupMemberWithoutExpandedEvidence(t *testing.T) {
	s := fixtureMode(fixture(), "review")
	s.Marked = []string{"process:1"}
	s.Expanded = false
	m := fixtureModel(s, 120, 40)
	frame := ansi.Strip(m.render())
	for _, fact := range []string{"Member 4821: npm run dev --token [REDACTED]", "Member 4822: node vite --host 127.0.0.1", "Space unmark"} {
		if !strings.Contains(frame, fact) {
			t.Fatalf("missing %q:\n%s", fact, frame)
		}
	}
	if strings.Contains(frame, "Identity:") {
		t.Fatal("compact review displayed optional fingerprint evidence")
	}
}

func TestExpandedChooseRetainsFullIdentityAndConsequence(t *testing.T) {
	for _, width := range []int{57, 77, 116} {
		s := fixture()
		s.Expanded = true
		s.Items[2].Target = "/work/afterparty/a long generated output directory/with another segment/.next"
		s.Items[2].Consequence = strings.Repeat("Delete this generated output. Rebuild it before the next preview. ", 8)
		m := fixtureModel(s, width+3, 24)
		body, _ := m.body(width)
		text := strings.Join(strings.Fields(ansi.Strip(strings.Join(body, "\n"))), "")
		for _, fact := range []string{s.Items[2].Target, s.Items[2].Consequence, "PGID 4821", "Member 4821: npm run dev --token [REDACTED]"} {
			if !strings.Contains(text, strings.Join(strings.Fields(fact), "")) {
				t.Fatalf("expanded Choose at %d columns omitted %q", width, fact)
			}
		}
		if !strings.Contains(ansi.Strip(body[1]), "> [ ] PGID 4821") {
			t.Fatal("expanded Choose lost its focused target")
		}
	}
}
func TestShortenedLabelsStayDistinct(t *testing.T) {
	s := fixture()
	s.Items = s.Items[2:]
	s.Items[0].Target = "/work/afterparty/very-long-identical-shared-prefix/alpha/dist"
	s.Items[1].Target = "/work/afterparty/very-long-identical-shared-prefix/bravo/dist"
	m := fixtureModel(s, 60, 20)
	a, b := m.label(s.Items[0], 20), m.label(s.Items[1], 20)
	if a == b || !strings.HasPrefix(a, "[1]") || !strings.HasPrefix(b, "[2]") {
		t.Fatalf("shortened labels collided: %q %q", a, b)
	}
	for _, ascii := range []bool{false, true} {
		m.ascii = ascii
		if safeText("日本語", ascii) == safeText(`\u65e5\u672c\u8a9e`, ascii) {
			t.Fatal("literal escape and Unicode identity collided")
		}
	}
	if safeText("\U00010000", true) == safeText("\u10000", true) {
		t.Fatal("Unicode escapes are ambiguous")
	}
}
func TestFilteredPositionNamesFocusedTarget(t *testing.T) {
	s := fixture()
	s.VisibleIDs = []string{"artifact:1", "artifact:2"}
	s.Focus = "artifact:2"
	m := fixtureModel(s, 80, 24)
	frame := ansi.Strip(m.render())
	if !strings.Contains(frame, "Target 2 of 2: playwright-report") {
		t.Fatalf("unfiltered or unnamed position:\n%s", frame)
	}
}
func TestIncompleteEvidenceRemainsPinnedAndInspectable(t *testing.T) {
	s := fixture()
	s.Scope.Status = "incomplete"
	s.Capabilities = []capability{{Name: "activity", Status: "unavailable", Reason: "Unreadable fixture transcript"}}
	m := fixtureModel(s, 80, 24)
	m.scroll = 999
	m.state.RevealFocus = false
	frame := ansi.Strip(m.render())
	for _, fact := range []string{"Scan: incomplete", "Unavailable: activity"} {
		if !strings.Contains(frame, fact) {
			t.Fatalf("lost %q", fact)
		}
	}
	m.state = fixtureMode(m.state, "help")
	m.scroll = 999
	if !strings.Contains(ansi.Strip(m.render()), "Unreadable fixture transcript") {
		t.Fatal("scan reason not inspectable")
	}
}
func TestSavedViewAndSmallPaneRecovery(t *testing.T) {
	s := fixtureMode(fixture(), "saved")
	s.Marked = []string{"process:1"}
	s.SavedPath = `/tmp/quoted \ plan.md`
	m := fixtureModel(s, 80, 24)
	frame := ansi.Strip(m.render())
	if !strings.Contains(frame, "Finish the review to print the apply command.") || strings.Contains(frame, "afterparty apply") {
		t.Fatal("save screen must direct to unwrapped exit command")
	}
	m.width, m.height = 40, 10
	frame = ansi.Strip(m.render())
	words := strings.Join(strings.Fields(frame), " ")
	for _, fact := range []string{"Afterparty saved the plan.", "Press Enter or q to finish.", "prefix z"} {
		if !strings.Contains(words, fact) {
			t.Fatalf("small saved pane lost %q", fact)
		}
	}
	m.state = fixture()
	m.state.Marked = []string{"process:1"}
	frame = ansi.Strip(m.render())
	if !strings.Contains(frame, "1 marked") || !strings.Contains(frame, "prefix z") {
		t.Fatal("small pane lost recovery or marks")
	}
}
func TestMonochromeRetainsNeutralFocusAttributes(t *testing.T) {
	setTheme(t, "mono")
	m := fixtureModel(fixture(), 80, 24)
	focus := m.theme.roles["focus"].Render("focused")
	if !strings.Contains(focus, "\x1b[1;7m") {
		t.Fatalf("focus lost bold/reverse: %q", focus)
	}
	if strings.Contains(focus, "38;") || strings.Contains(focus, "36m") {
		t.Fatal("focus gained a hue")
	}
	for _, role := range []string{"", "dim"} {
		if strings.Contains(m.theme.roles[role].Render("scope or legend"), "38;") {
			t.Fatal("scope/legend has a hue")
		}
	}
}
func TestLiveClockAndCollectionElapsed(t *testing.T) {
	m := fixtureModel(fixture(), 80, 24)
	before := ansi.Strip(m.render())
	m.Update(tickMsg(m.now.Add(time.Minute)))
	after := ansi.Strip(m.render())
	if before == after || !strings.Contains(after, "3m 5s ago") {
		t.Fatal("snapshot age did not advance")
	}
	m.state = viewState{}
	m.scanStarted = m.now.Add(-7 * time.Second)
	frame := ansi.Strip(m.render())
	if !strings.Contains(frame, "Elapsed: 7s") {
		t.Fatal("collection elapsed time missing")
	}
}

func TestScanScreenExplainsIgnoredKeysAndExit(t *testing.T) {
	for _, generation := range []int{1, 2} {
		m := fixtureModel(viewState{Event: "scan", Collecting: true, Generation: generation}, 60, 20)
		m.scanStarted = m.now.Add(-7 * time.Second)
		frame := ansi.Strip(m.render())
		action := "Afterparty scans for cleanup targets."
		if generation > 1 {
			action = "Afterparty scans for cleanup targets again."
		}
		for _, message := range []string{action, "Afterparty ignores review keys during the scan.", "Press q or Ctrl+C to exit without cleanup.", "Elapsed: 7s"} {
			if !strings.Contains(frame, message) {
				t.Fatalf("scan screen missing %q:\n%s", message, frame)
			}
		}
		for _, line := range strings.Split(frame, "\n") {
			if ansi.StringWidth(line) >= 60 {
				t.Fatalf("scan screen is too wide: %q", line)
			}
		}
	}
}

func TestInspectShowsActualMarkState(t *testing.T) {
	s := fixtureMode(fixture(), "evidence")
	m := fixtureModel(s, 80, 24)
	frame := ansi.Strip(m.render())
	if !strings.Contains(frame, "[ ] PGID 4821") {
		t.Fatalf("unmarked inspect target looked approved:\n%s", frame)
	}
	s.Marked = []string{"process:1"}
	m.state = s
	if !strings.Contains(ansi.Strip(m.render()), "[x] PGID 4821") {
		t.Fatal("marked inspect target lost its choice")
	}
}

func TestRenderInspectionMatrix(t *testing.T) {
	dir := os.Getenv("RENDER_MATRIX_DIR")
	if dir == "" {
		t.Skip("set RENDER_MATRIX_DIR to export inspection frames")
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	for _, size := range [][2]int{{60, 20}, {80, 24}, {120, 40}, {40, 10}} {
		for _, kind := range []string{"dark", "light", "mono", "ascii"} {
			setTheme(t, kind)
			for _, step := range []string{"choose", "review", "help"} {
				s := fixtureMode(fixture(), step)
				s.Marked = []string{"process:1", "artifact:1"}
				s.Capabilities = []capability{{Name: "activity", Status: "complete", Reason: "Transcript index complete"}}
				m := fixtureModel(s, size[0], size[1])
				m.ascii = kind == "ascii"
				frame := m.render() + "\n"
				path := filepath.Join(dir, fmt.Sprintf("%dx%d_%s_%s", size[0], size[1], kind, step))
				if err := os.WriteFile(path+".ansi", []byte(frame), 0644); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path+".txt", []byte(ansi.Strip(frame)), 0644); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
}

func TestLongRefusalRemainsInspectableAfterFooterClipping(t *testing.T) {
	s := fixture()
	s.MessageKind = "refused"
	s.SaveEnabled = false
	s.Message = "Refresh failed: " + strings.Repeat("inspection detail ", 20) + "UNIQUE RECOVERY TAIL."
	m := fixtureModel(s, 60, 20)
	frame := ansi.Strip(m.render())
	if !strings.Contains(frame, "[? details]") {
		t.Fatalf("clipped refusal has no recovery hint:\n%s", frame)
	}
	m.state = fixtureMode(m.state, "help")
	body, _ := m.body(57)
	if !strings.Contains(strings.Join(strings.Fields(ansi.Strip(strings.Join(body, "\n"))), " "), "UNIQUE RECOVERY TAIL.") {
		t.Fatal("full failure cause cannot be read in Help")
	}
}

func TestActualRowsDisambiguateLabelsWithDifferentMeasurementWidths(t *testing.T) {
	s := fixture()
	s.Scope.Root = "/repo"
	prefix := strings.Repeat("a", 34)
	s.Items = []item{
		{ID: "a", Type: "artifact", Target: "/repo/[2] " + strings.Repeat("a", 30) + "...", Availability: "available", Evidence: evidence{Size: "1 B"}},
		{ID: "b", Type: "artifact", Target: "/repo/" + prefix + "BetaXYZ", Availability: "available"},
		{ID: "c", Type: "artifact", Target: "/repo/" + prefix + "CharliYZ", Availability: "available", Evidence: evidence{Size: "12 MB"}},
	}
	m := fixtureModel(s, 60, 20)
	// Prove the actual row budgets entered the mixed-width collision case.
	first := m.label(s.Items[0], 46)
	second := m.label(s.Items[1], 37)
	if first != second {
		t.Fatalf("fixture no longer reaches collision: %q %q", first, second)
	}
	labels := m.rowLabels(s.Items, 57)
	seen := map[string]bool{}
	for _, target := range s.Items {
		label := labels[target.ID]
		if seen[label] {
			t.Fatalf("actual rows still collide: %q", label)
		}
		seen[label] = true
	}
	if !strings.HasPrefix(labels["a"], "[1] ") || !strings.HasPrefix(labels["b"], "[2] ") {
		t.Fatal("collision was not visibly disambiguated")
	}
}
