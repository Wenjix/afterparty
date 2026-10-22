package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestCommandsOpenWithoutChangingTheReview(t *testing.T) {
	m := keyedModel(fixture())
	m.state.Actions = []commandAction{{ID: "review.mark_target", Label: "Mark target", Key: "Space", Enabled: true}}
	m.scroll = 3
	before := m.state.Focus
	m.Update(tea.KeyPressMsg{Code: 'p', Mod: tea.ModCtrl})
	frame := ansi.Strip(m.View().Content)
	if !strings.Contains(frame, "Commands") {
		t.Fatalf("Ctrl+P did not open command discovery:\n%s", frame)
	}
	if m.state.Focus != before || m.scroll != 3 || len(m.backend.keys) != 0 {
		t.Fatal("opening Commands changed review context or sent a backend action")
	}
}

func commandFixture() viewState {
	s := fixture()
	s.Actions = []commandAction{
		{ID: "review.mark_target", Label: "Mark target", Description: "Include this target in the plan.", Key: "Space", Enabled: true},
		{ID: "review.inspect_target", Label: "Inspect target", Description: "Show the full identity and evidence.", Key: "i", Enabled: true},
		{ID: "review.review_choices", Label: "Review choices", Description: "Review the marked targets.", Key: "Enter", Reason: "Mark a target first."},
		{ID: "review.show_details", Label: "Show details", Description: "Show evidence for the focused target.", Key: "d", Enabled: true},
		{ID: "review.filter_targets", Label: "Filter targets", Description: "Find targets by name.", Key: "/", Enabled: true},
		{ID: "review.refresh", Label: "Refresh scan", Description: "Collect current evidence.", Key: "r", Enabled: true},
		{ID: "review.help", Label: "Help", Description: "Show all keys and scan status.", Key: "?", Enabled: true},
		{ID: "review.quit", Label: "Quit review", Description: "Exit this review.", Key: "q", Enabled: true},
	}
	return s
}

func openCommandModel() model {
	m := keyedModel(commandFixture())
	m.openCommands()
	return m
}

func TestCommandSearchSendsOnlyNamedActionAndCapturedContext(t *testing.T) {
	m := openCommandModel()
	m.focusVisible = false
	for _, char := range "inspect" {
		press(&m, char)
	}
	if !strings.Contains(ansi.Strip(m.View().Content), "Inspect target") || len(m.matchingCommands()) != 1 {
		t.Fatal("search did not find the named inspect action")
	}
	press(&m, tea.KeyEnter)
	request := <-m.backend.keys
	if request.Key != "ACTION" || request.Action != "review.inspect_target" || request.Step != "choose" || request.Generation != 1 || request.Focus != "process:1" || request.FocusVisible {
		t.Fatalf("action lost its captured context: %+v", request)
	}
	if m.commands.open {
		t.Fatal("command sheet remained open after successful dispatch")
	}
}

func TestCommandSearchConsumesLettersPasteAndEscapeLocally(t *testing.T) {
	m := openCommandModel()
	m.state.Query = "vite"
	m.state.Marked = []string{"artifact:1"}
	m.scroll = 8
	for _, char := range "qjk" {
		press(&m, char)
	}
	m.Update(tea.PasteMsg{Content: "mark\n"})
	if m.commands.query != "qjk" || !strings.Contains(ansi.Strip(m.View().Content), "No matching commands") {
		t.Fatal("letters or paste activated a review key instead of remaining local")
	}
	press(&m, tea.KeyEscape)
	if m.commands.open || m.state.Query != "vite" || m.state.Focus != "process:1" || !has(m.state.Marked, "artifact:1") || m.scroll != 8 || len(m.backend.keys) != 0 {
		t.Fatal("closing Commands changed the filter, focus, marks, scroll, or backend")
	}
}

func TestDisabledCommandHasReasonAndCannotDispatch(t *testing.T) {
	m := openCommandModel()
	for _, char := range "review" {
		press(&m, char)
	}
	frame := ansi.Strip(m.View().Content)
	if !strings.Contains(frame, "Unavailable: Mark a target first.") {
		t.Fatalf("disabled action has no recovery reason:\n%s", frame)
	}
	press(&m, tea.KeyEnter)
	if !m.commands.open || len(m.backend.keys) != 0 {
		t.Fatal("disabled command dispatched")
	}
	// A fresh enabled command must still cross the same dispatch path.
	m.Update(tea.KeyPressMsg{Code: 'u', Mod: tea.ModCtrl})
	press(&m, tea.KeyEnter)
	if request := <-m.backend.keys; request.Action != "review.mark_target" {
		t.Fatalf("enabled command did not dispatch: %+v", request)
	}
}

func TestCommandsCloseWhenPresentedContextChanges(t *testing.T) {
	for _, change := range []string{"generation", "step", "focus", "collecting", "searching", "action_id", "availability", "scope", "roots", "mode"} {
		t.Run(change, func(t *testing.T) {
			m := openCommandModel()
			s := commandFixture()
			switch change {
			case "generation":
				s.Generation++
			case "step":
				s.Step = "review"
			case "focus":
				s.Focus = "artifact:1"
			case "collecting":
				s.Collecting = true
			case "searching":
				s.Searching = true
			case "action_id":
				s.Actions[0].ID = "review.unmark_target"
			case "availability":
				s.Actions[0].Enabled = false
			case "scope":
				s.Scope.Root = "/another/repository"
			case "roots":
				s.Inventory.Roots = []string{"/another/root"}
			case "mode":
				s.Mode = "builds"
			}
			m.Update(s)
			if m.commands.open {
				t.Fatal("command sheet retained stale context")
			}
		})
	}
}

func TestCommandsRetainTheActionWhenTheInputQueueIsFull(t *testing.T) {
	m := openCommandModel()
	m.width, m.height = 60, 20
	for len(m.backend.keys) < cap(m.backend.keys) {
		m.backend.keys <- keyRequest{Key: "j"}
	}
	press(&m, tea.KeyEnter)
	frame := ansi.Strip(m.View().Content)
	if !m.commands.open || !strings.Contains(frame, "Press Enter again to retry") {
		t.Fatalf("queue failure lost the action or recovery:\n%s", frame)
	}
	if len(strings.Split(frame, "\n")) > 20 {
		t.Fatal("queue recovery overflowed the small pane")
	}
	<-m.backend.keys
	press(&m, tea.KeyEnter)
	if m.commands.open {
		t.Fatal("retried action did not cross the available queue")
	}
}

func TestLongCommandReasonRemainsReadableWithoutChangingSelection(t *testing.T) {
	m := openCommandModel()
	m.width, m.height = 60, 20
	m.state.Actions = []commandAction{{ID: "review.mark_target", Label: "Mark target", Reason: strings.Repeat("Unavailable evidence. ", 90) + "Refresh to try again. (scan-incomplete)", Enabled: false}}
	frame := ansi.Strip(m.View().Content)
	if !strings.Contains(frame, "Details 1-") || !strings.Contains(frame, "PgUp/PgDn read details") {
		t.Fatalf("long reason was silently clipped:\n%s", frame)
	}
	for i := 0; i < 100; i++ {
		press(&m, tea.KeyPgDown)
	}
	frame = ansi.Strip(m.View().Content)
	if !strings.Contains(frame, "(scan-incomplete)") || len(strings.Split(frame, "\n")) > 20 || m.commands.selected != 0 || len(m.backend.keys) != 0 {
		t.Fatalf("reason tail was unreachable or reading changed the action:\n%s", frame)
	}
	press(&m, tea.KeyEnter)
	if len(m.backend.keys) != 0 {
		t.Fatal("reading disabled details enabled the command")
	}
}

func TestCommandFramesFitAndRetainContext(t *testing.T) {
	for _, size := range [][2]int{{60, 20}, {80, 24}, {100, 24}, {120, 40}} {
		for _, kind := range []string{"color", "mono", "ascii"} {
			t.Run(fmt.Sprintf("%dx%d/%s", size[0], size[1], kind), func(t *testing.T) {
				setTheme(t, kind)
				m := openCommandModel()
				m.width, m.height, m.ascii = size[0], size[1], kind == "ascii"
				for _, query := range []string{"", "review", "no match", "日本語"} {
					m.commands.query = query
					frame := ansi.Strip(m.View().Content)
					if len(strings.Split(frame, "\n")) > size[1] {
						t.Fatalf("Commands exceeds height:\n%s", frame)
					}
					for _, line := range strings.Split(frame, "\n") {
						if ansi.StringWidth(line) >= size[0] {
							t.Fatalf("Commands exceeds width: %q", line)
						}
						if m.ascii {
							for _, char := range line {
								if char > 127 {
									t.Fatalf("ASCII contains %q", char)
								}
							}
						}
					}
					for _, fact := range []string{"Commands", "Scope:", "0 marked", "PGID 4821", "Find:", "Esc back"} {
						if !strings.Contains(frame, fact) {
							t.Fatalf("Commands lost %q:\n%s", fact, frame)
						}
					}
				}
			})
		}
	}
}

func TestTransientFeedbackExpiresWithoutNavigationRestart(t *testing.T) {
	m := keyedModel(fixture())
	s := fixture()
	s.Message, s.MessageID, s.MessageTransient, s.Guidance = "You marked PGID 4821.", 2, true, "Press Enter to review choices."
	m.Update(s)
	if m.feedbackMessage() != s.Message {
		t.Fatal("fresh acknowledgement is missing")
	}
	m.now = m.now.Add(3 * time.Second)
	s.Focus = "artifact:1"
	m.Update(s)
	m.now = m.now.Add(2 * time.Second)
	if m.feedbackMessage() != s.Guidance || m.state.Message != s.Message {
		t.Fatal("expiry restarted or erased retained feedback")
	}
	s.Message, s.MessageID, s.MessageTransient = "The target is withheld. Refresh to try again.", 3, false
	m.Update(s)
	m.now = m.now.Add(time.Minute)
	if m.feedbackMessage() != s.Message {
		t.Fatal("a refusal expired")
	}
	s.Message, s.MessageID, s.MessageTransient = "You unmarked PGID 4821.", 4, true
	m.Update(s)
	if m.feedbackMessage() != s.Message {
		t.Fatal("new feedback inherited prior expiry")
	}
}

func TestQueueFailureCannotInheritExpiredAcknowledgement(t *testing.T) {
	m := keyedModel(fixture())
	s := fixture()
	s.Message, s.MessageID, s.MessageTransient, s.MessageKind, s.Guidance = "You marked PGID 4821.", 2, true, "done", "Review the marked targets."
	m.Update(s)
	m.now = m.now.Add(5 * time.Second)
	if m.feedbackMessage() != s.Guidance {
		t.Fatal("fixture did not reach expired acknowledgement")
	}
	for len(m.backend.keys) < cap(m.backend.keys) {
		m.backend.keys <- keyRequest{Key: "j"}
	}
	m.send("j")
	frame := ansi.Strip(m.render())
	if m.state.MessageTransient || m.state.MessageKind != "refused" || !strings.Contains(frame, "Afterparty cannot accept more keys") {
		t.Fatalf("queue warning inherited expired or successful state:\n%s", frame)
	}
	<-m.backend.keys
	m.send("k")
	if len(m.backend.keys) != cap(m.backend.keys) {
		t.Fatal("available queue no longer accepts input")
	}
}

func TestCommandFrameGoldens(t *testing.T) {
	for _, size := range [][2]int{{60, 20}, {80, 24}, {120, 40}} {
		for _, kind := range []string{"color", "mono", "ascii"} {
			t.Run(fmt.Sprintf("%dx%d/%s", size[0], size[1], kind), func(t *testing.T) {
				setTheme(t, kind)
				m := openCommandModel()
				m.width, m.height, m.ascii = size[0], size[1], kind == "ascii"
				frame := m.View().Content + "\n"
				path := filepath.Join("testdata", fmt.Sprintf("commands_%dx%d_%s.ansi", size[0], size[1], kind))
				if os.Getenv("UPDATE_GOLDEN") == "1" {
					if err := os.WriteFile(path, []byte(frame), 0644); err != nil {
						t.Fatal(err)
					}
				}
				want, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				if string(want) != frame {
					t.Fatalf("Commands changed; review before updating:\n%s", ansi.Strip(frame))
				}
			})
		}
	}
}
