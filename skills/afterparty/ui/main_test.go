package main

import (
	tea "charm.land/bubbletea/v2"
	"testing"
	"time"
)

func keyedModel(s viewState) model {
	m := fixtureModel(s, 80, 24)
	m.backend = &backend{keys: make(chan keyRequest, 256)}
	return m
}
func press(m *model, code rune) tea.Cmd { _, cmd := m.Update(tea.KeyPressMsg{Code: code}); return cmd }
func TestCollectionDropsInputAndReportsCountForCurrentGeneration(t *testing.T) {
	for _, refresh := range []bool{false, true} {
		s := viewState{}
		if refresh {
			s = fixture()
			s.Generation = 2
			s.Collecting = true
		}
		m := keyedModel(s)
		for _, code := range []rune{' ', tea.KeyEnter, 's', tea.KeyDown, 'j'} {
			press(&m, code)
		}
		m.Update(tea.KeyPressMsg{Code: 'z', Mod: tea.ModCtrl})
		if len(m.backend.keys) != 0 || m.dropped != 6 {
			t.Fatalf("collection replayed input: queued=%d dropped=%d", len(m.backend.keys), m.dropped)
		}
		done := fixture()
		if refresh {
			done.Generation = 2
		}
		m.Update(done)
		report := <-m.backend.keys
		if report.Key != "IGNORED" || report.IgnoredKeys != 6 || report.Generation != done.Generation {
			t.Fatalf("bad loading receipt: %+v", report)
		}
	}
}
func TestIgnoredReportNeverBlocksAFullInputQueue(t *testing.T) {
	m := keyedModel(fixture())
	for i := 0; i < cap(m.backend.keys); i++ {
		m.backend.keys <- keyRequest{Key: "j"}
	}
	m.dropped = 3
	m.Update(fixture())
	if m.dropped != 3 {
		t.Fatal("count lost while report queue full")
	}
	<-m.backend.keys
	m.Update(tickMsg(time.Now()))
	if m.dropped != 0 {
		t.Fatal("pending report not retried")
	}
}
func TestPagedSpaceRequestsRevealBeforeMarking(t *testing.T) {
	m := keyedModel(fixture())
	m.render()
	press(&m, tea.KeyPgDown)
	press(&m, ' ')
	request := <-m.backend.keys
	if request.Key != " " || request.FocusVisible || request.Generation != 1 {
		t.Fatalf("paged Space did not request reveal: %+v", request)
	}
	// The backend refuses the mark and reveals focus; a subsequent Space can mark.
	s := fixture()
	s.RevealFocus = true
	s.Message = "The target is visible. Press Space to mark or unmark it."
	m.Update(s)
	m.render()
	press(&m, ' ')
	if request = <-m.backend.keys; !request.FocusVisible {
		t.Fatal("revealed focused row stayed inaccessible")
	}
}
func TestQuitWithMarksStaysWithBackendConfirmation(t *testing.T) {
	s := fixture()
	s.Marked = []string{"process:1"}
	m := keyedModel(s)
	cmd := press(&m, 'q')
	if cmd != nil || m.finished || len(m.state.Marked) != 1 {
		t.Fatal("q discarded choices locally")
	}
	if request := <-m.backend.keys; request.Key != "q" {
		t.Fatalf("q bypassed confirmation: %+v", request)
	}
}
func TestEscFollowedByPrintableKeyPreservesBothActions(t *testing.T) {
	m := keyedModel(fixture())
	m.Update(tea.KeyPressMsg{Code: ' ', Mod: tea.ModAlt})
	first, second := <-m.backend.keys, <-m.backend.keys
	if first.Key != "ESC" || second.Key != " " {
		t.Fatalf("Esc swallowed next key: %+v %+v", first, second)
	}
}
func TestCtrlZSendsSuspendWithoutEndingReview(t *testing.T) {
	s := fixture()
	s.Marked = []string{"process:1"}
	m := keyedModel(s)
	_, cmd := m.Update(tea.KeyPressMsg{Code: 'z', Mod: tea.ModCtrl})
	if cmd == nil {
		t.Fatal("Ctrl+Z did not suspend")
	}
	if _, ok := cmd().(tea.SuspendMsg); !ok {
		t.Fatal("Ctrl+Z exited instead of suspending")
	}
	if m.finished || len(m.state.Marked) != 1 || len(m.backend.keys) != 0 {
		t.Fatal("suspend changed the review draft")
	}
}
func TestSmallPaneConfirmationRemainsUsable(t *testing.T) {
	s := fixture()
	s.Step = "confirm_quit"
	s.Marked = []string{"process:1"}
	m := keyedModel(s)
	m.width, m.height = 40, 10
	m.render()
	press(&m, tea.KeyEscape)
	if request := <-m.backend.keys; request.Key != "ESC" {
		t.Fatal("small pane swallowed cancel confirmation")
	}
	press(&m, tea.KeyEnter)
	if request := <-m.backend.keys; request.Key != "ENTER" {
		t.Fatal("small pane swallowed confirmed exit")
	}
}
