package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func inventoryNumber(value int64) *int64 { return &value }

func inventoryFixture() viewState {
	report := inventoryReport{
		SchemaVersion: 1, ObservedAt: "2026-10-12T09:23:00Z", Roots: []string{"/work", "/side-projects"}, MaxDepth: 3,
		CollectionStatus: "complete", HistoryStatus: "compared", PreviousObservedAt: "2026-10-11T09:23:00Z",
		Repositories: []inventoryRepository{{Root: "/work/afterparty", Label: "afterparty", Status: "complete"}, {Root: "/side-projects/notes", Label: "notes", Status: "complete"}},
		TotalBytes:   1164000000, DeltaBytes: inventoryNumber(124000000),
		Items: []inventoryItem{
			{ID: "cache:one", Repository: "/work/afterparty", Path: "/work/afterparty/.next", RelativePath: ".next", Kind: "build", SizeBytes: inventoryNumber(840000000), DeltaBytes: inventoryNumber(120000000), ModifiedAt: "2026-10-12T08:15:00Z", Status: "complete"},
			{ID: "cache:two", Repository: "/side-projects/notes", Path: "/side-projects/notes/node_modules/.cache", RelativePath: "node_modules/.cache", Kind: "cache", SizeBytes: inventoryNumber(204000000), DeltaBytes: inventoryNumber(-16000000), ModifiedAt: "2026-10-11T18:15:00Z", Status: "complete"},
			{ID: "test:one", Repository: "/work/afterparty", Path: "/work/afterparty/playwright-report", RelativePath: "playwright-report", Kind: "test", SizeBytes: inventoryNumber(120000000), DeltaBytes: inventoryNumber(20000000), ModifiedAt: "2026-10-12T08:05:00Z", Status: "complete"},
		},
	}
	s := viewState{Event: "state", Mode: "builds", Inventory: report, Generation: 1, Step: "inventory", Focus: "cache:one", RevealFocus: true, CapturedAt: report.ObservedAt, Message: "Size and file time do not prove that output is unused.", MessageKind: "info"}
	for _, target := range report.Items {
		s.VisibleIDs = append(s.VisibleIDs, target.ID)
	}
	s.HelpKeys = []keyHint{{"Enter", "Review this repository"}, {"Up/Down", "Move focus (j/k)"}, {"/", "Filter paths"}, {"i", "Inspect the path"}, {"d", "Show or hide details"}, {"r", "Refresh the scan"}, {"q", "Finish"}, {"Ctrl+Z", "Suspend; use fg to resume"}}
	return inventoryFixtureMode(s, "inventory")
}

func inventoryFixtureMode(s viewState, step string) viewState {
	s.Step = step
	switch step {
	case "inventory_help":
		s.Legend = []keyHint{{"q/Esc/?", "back"}, {"PgUp/PgDn", "scroll"}}
	case "inventory_inspect":
		s.Legend = []keyHint{{"Enter", "review repository"}, {"q/Esc", "back"}, {"?", "help"}, {"PgUp/PgDn", "scroll"}}
	default:
		s.Legend = []keyHint{{"Enter", "review"}, {"Up/Down", "focus (j/k)"}, {"/", "filter"}, {"i", "inspect"}, {"d", "details"}, {"?", "help"}, {"r", "refresh"}, {"q", "finish"}}
	}
	return s
}

func inventoryModel(s viewState, width, height int) model {
	m := fixtureModel(s, width, height)
	m.inventory = true
	return m
}

func inventoryVariant(variant string) viewState {
	s := inventoryFixture()
	switch variant {
	case "first":
		s.Inventory.HistoryStatus = "first"
		s.Inventory.PreviousObservedAt = ""
		s.Inventory.DeltaBytes = nil
		for index := range s.Inventory.Items {
			s.Inventory.Items[index].DeltaBytes = nil
		}
	case "incomplete":
		s.Inventory.CollectionStatus = "incomplete"
		s.Inventory.HistoryStatus = "unavailable"
		s.Inventory.DeltaBytes = nil
		s.Inventory.Issues = []inventoryIssue{{Path: "/side-projects/notes/node_modules/.cache", Message: "Afterparty could not read this directory. Check its access permissions."}}
		s.Inventory.Items[1].Status = "unavailable"
		s.Inventory.Items[1].SizeBytes = nil
		s.Inventory.Items[1].DeltaBytes = nil
		s.Inventory.TotalBytes = 960000000
	case "filter":
		s.Query = "playwright"
		s.VisibleIDs = []string{"test:one"}
		s.Focus = "test:one"
	case "expanded":
		s.Expanded = true
	case "inventory_help", "inventory_inspect":
		s = inventoryFixtureMode(s, variant)
	}
	return s
}

func TestInventoryFramesFitAndPreserveReadOnlyFacts(t *testing.T) {
	for _, size := range [][2]int{{60, 20}, {80, 24}, {120, 40}} {
		for _, kind := range []string{"dark", "light", "mono", "ascii"} {
			setTheme(t, kind)
			for _, variant := range []string{"inventory", "inventory_help", "inventory_inspect", "first", "incomplete", "filter", "expanded"} {
				m := inventoryModel(inventoryVariant(variant), size[0], size[1])
				m.ascii = kind == "ascii"
				frame := ansi.Strip(m.render())
				if m.roomTooSmall {
					t.Fatalf("%s does not fit %dx%d", variant, size[0], size[1])
				}
				if len(strings.Split(frame, "\n")) > size[1] {
					t.Fatalf("%s frame is too tall", variant)
				}
				for _, line := range strings.Split(frame, "\n") {
					if ansi.StringWidth(line) >= size[0] {
						t.Fatalf("%s frame is too wide: %q", variant, line)
					}
				}
				for _, fact := range []string{"BUILD OUTPUT", "Roots (2):", "Scan:", "Known total:", "estimated", "Growth:", "2m 5s ago"} {
					if !strings.Contains(frame, fact) {
						t.Fatalf("%s missing %q:\n%s", variant, fact, frame)
					}
				}
				for _, forbidden := range []string{"[ ]", "[x]", "marked", "Save plan", "reclaimable", "\t"} {
					if strings.Contains(frame, forbidden) {
						t.Fatalf("%s included %q:\n%s", variant, forbidden, frame)
					}
				}
			}
		}
	}
}

func TestInventoryFrameGoldens(t *testing.T) {
	oldLocal := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = oldLocal })
	for _, size := range [][2]int{{60, 20}, {80, 24}} {
		for _, kind := range []string{"color", "mono"} {
			setTheme(t, kind)
			for _, variant := range []string{"inventory", "inventory_help", "inventory_inspect", "first", "incomplete", "filter", "expanded"} {
				m := inventoryModel(inventoryVariant(variant), size[0], size[1])
				frame := m.render() + "\n"
				path := filepath.Join("testdata", fmt.Sprintf("builds_%s_%dx%d_%s.ansi", variant, size[0], size[1], kind))
				if os.Getenv("UPDATE_GOLDEN") == "1" {
					if err := os.WriteFile(path, []byte(frame), 0644); err != nil {
						t.Fatal(err)
					}
				}
				want, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				if frame != string(want) {
					t.Fatalf("inventory frame changed; inspect before UPDATE_GOLDEN=1: %s\n%s", path, ansi.Strip(frame))
				}
			}
		}
	}
}

func TestInventoryPreservesOrderFilterAndDistinctLabels(t *testing.T) {
	s := inventoryFixture()
	m := inventoryModel(s, 60, 20)
	frame := ansi.Strip(m.render())
	if !(strings.Index(frame, "afterparty/.next") < strings.Index(frame, "notes/node_modules/.cache") && strings.Index(frame, "notes/node_modules/.cache") < strings.Index(frame, "afterparty/playwright-report")) {
		t.Fatalf("inventory order changed:\n%s", frame)
	}
	m.state = inventoryVariant("filter")
	frame = ansi.Strip(m.render())
	if !strings.Contains(frame, "Path 1 of 1: afterparty/playwright-report") || !strings.Contains(frame, "120.0 MB") || strings.Contains(frame, "notes/node_modules") {
		t.Fatalf("filter lost the selected path or retained another path:\n%s", frame)
	}
	items := []inventoryItem{{ID: "one", Repository: "/one/project", RelativePath: strings.Repeat("a", 40) + "-one"}, {ID: "two", Repository: "/two/project", RelativePath: strings.Repeat("a", 40) + "-two"}}
	labels := m.inventoryLabels(items, 25)
	if labels["one"] == labels["two"] || !strings.HasPrefix(labels["one"], "[1] ") || !strings.HasPrefix(labels["two"], "[2] ") {
		t.Fatalf("shortened paths collide: %v", labels)
	}
}

func TestInventoryInspectionUsesFullIdentityAndFileTime(t *testing.T) {
	s := inventoryFixtureMode(inventoryFixture(), "inventory_inspect")
	s.Inventory.Items[0].Path = "/work/afterparty/a very long directory/日本語 'quoted' $(no-command)/.next"
	m := inventoryModel(s, 60, 20)
	body, _ := m.inventoryBody(57)
	text := strings.Join(strings.Fields(ansi.Strip(strings.Join(body, "\n"))), " ")
	for _, fact := range []string{s.Inventory.Items[0].Path, "Repository: /work/afterparty", "Kind: build", "(file time)", "File modification time does not prove last use.", "Enter opens this repository's cleanup review."} {
		if !strings.Contains(text, fact) {
			t.Fatalf("inspection lost %q:\n%s", fact, text)
		}
	}
	if !strings.Contains(text, inventoryTime(s.Inventory.Items[0].ModifiedAt)) {
		t.Fatal("inspection replaced file time with scan time")
	}
}

func TestInventoryExpandedDetailsPreserveOrderAndFocus(t *testing.T) {
	s := inventoryFixture()
	m := inventoryModel(s, 60, 20)
	compact, compactAnchors := m.inventoryBody(57)
	m.state.Expanded = true
	expanded, expandedAnchors := m.inventoryBody(57)
	if len(expanded) <= len(compact) || m.state.Focus != s.Focus {
		t.Fatal("details did not expand or changed the focused path")
	}
	last := -1
	for _, target := range s.Inventory.Items {
		anchor := expandedAnchors[target.ID]
		if anchor[0] <= last || anchor[1] != anchor[0]+1 || compactAnchors[target.ID][1] != compactAnchors[target.ID][0]+1 {
			t.Fatalf("details changed order or the row anchor for %s", target.ID)
		}
		last = anchor[0]
	}
	text := strings.Join(strings.Fields(ansi.Strip(strings.Join(expanded, "\n"))), " ")
	for _, fact := range []string{"Repository: /work/afterparty", "Path: /work/afterparty/.next", "Kind: build | Scan: complete", "(file time)"} {
		if !strings.Contains(text, fact) {
			t.Fatalf("expanded details lost %q:\n%s", fact, text)
		}
	}
	m.state.Focus = "test:one"
	m.state.RevealFocus = true
	frame := ansi.Strip(m.render())
	if !strings.Contains(frame, "> afterparty/playwright-report") || !m.focusVisible {
		t.Fatalf("expanded navigation did not reveal the focused row:\n%s", frame)
	}
}

func TestInventoryIncompleteStatusAndAllScopesRemainAccessible(t *testing.T) {
	s := inventoryVariant("incomplete")
	m := inventoryModel(s, 60, 20)
	m.scroll = 999
	frame := ansi.Strip(m.render())
	for _, fact := range []string{"Scan: incomplete", "(estimated, partial)", "Growth: unknown", "1 scan issue (? details)"} {
		if !strings.Contains(frame, fact) {
			t.Fatalf("incomplete scan lost %q:\n%s", fact, frame)
		}
	}
	m.state = inventoryFixtureMode(s, "inventory_help")
	body, _ := m.inventoryBody(57)
	text := strings.Join(strings.Fields(ansi.Strip(strings.Join(body, "\n"))), " ")
	for _, fact := range []string{"/work", "/side-projects", "The previous scan is unavailable. Growth is unknown.", s.Inventory.Issues[0].Path, s.Inventory.Issues[0].Message} {
		if !strings.Contains(text, fact) {
			t.Fatalf("help lost %q:\n%s", fact, text)
		}
	}
}

func TestInventoryFirstScanDoesNotInventGrowth(t *testing.T) {
	m := inventoryModel(inventoryVariant("first"), 60, 20)
	frame := ansi.Strip(m.render())
	if !strings.Contains(frame, "Growth: first scan; no comparison") || !strings.Contains(frame, "unknown") || strings.Contains(frame, "+120.0 MB") {
		t.Fatalf("first scan implies a comparison:\n%s", frame)
	}
}

func TestInventoryLoadingAndSmallPaneRemainReadOnly(t *testing.T) {
	m := inventoryModel(viewState{Event: "scan", Collecting: true, Generation: 1}, 60, 20)
	m.scanStarted = m.now.Add(-5 * time.Second)
	frame := ansi.Strip(m.render())
	for _, fact := range []string{"BUILD OUTPUT", "Afterparty scans build output.", "This scan does not delete files.", "Elapsed: 5s", "Press q or Ctrl+C to exit."} {
		if !strings.Contains(frame, fact) {
			t.Fatalf("loading lost %q:\n%s", fact, frame)
		}
	}
	m.width, m.height = 40, 10
	frame = strings.Join(strings.Fields(ansi.Strip(m.render())), " ")
	if !strings.Contains(frame, "Build output needs 60×20.") || !strings.Contains(frame, "Press q to exit.") || !strings.Contains(frame, "prefix z") || strings.Contains(frame, "marked") {
		t.Fatalf("small inventory pane lost recovery or included marks: %s", frame)
	}
}

func TestInventoryBackendAndHandoffUseFixedCommands(t *testing.T) {
	args := []string{"--state-dir", "/private/state", "--output", "", "--", "--projects-root", "/work/$(no-command)"}
	command := backendCommand("/bundle/bin/afterparty-review", args, true)
	want := append([]string{"python3", "/bundle/lib/build_inventory.py", "--serve"}, args...)
	if !reflect.DeepEqual(command.Args, want) {
		t.Fatalf("inventory command changed or lost arguments: %q", command.Args)
	}
	command = backendCommand("/bundle/bin/afterparty-review", args, false)
	want = append([]string{"python3", "/bundle/lib/review.py"}, args...)
	if !reflect.DeepEqual(command.Args, want) {
		t.Fatalf("normal review command changed: %q", command.Args)
	}
	root := "/work/quoted '$(no-command)' repository"
	command = inventoryReviewCommand("/bundle/bin/afterparty-review", root)
	if !reflect.DeepEqual(command.Args, []string{"/bundle/lib/review.sh", "--artifacts-only", "--root", root}) {
		t.Fatalf("handoff lost literal identity or used a shell command: %q", command.Args)
	}
}

func TestOnlyInventoryDoneEventsCanRequestReviewHandoff(t *testing.T) {
	for _, inventory := range []bool{false, true} {
		for _, event := range []string{"done", "error"} {
			for _, status := range []int{0, 1} {
				m := keyedModel(inventoryFixture())
				m.inventory = inventory
				m.Update(viewState{Event: event, ExitCode: status, ReviewRoot: "/work/afterparty"})
				want := ""
				if inventory && event == "done" {
					want = "/work/afterparty"
				}
				if m.reviewRoot != want {
					t.Fatalf("inventory=%t event=%s exit=%d handoff=%q", inventory, event, status, m.reviewRoot)
				}
			}
		}
	}
}

func TestInventoryCollectionDropsKeysAndSmallPaneAllowsExit(t *testing.T) {
	m := keyedModel(viewState{Event: "scan", Collecting: true, Generation: 2})
	m.inventory = true
	for _, key := range []rune{' ', 's', tea.KeyEnter, 'r', tea.KeyDown} {
		press(&m, key)
	}
	if len(m.backend.keys) != 0 || m.dropped != 5 {
		t.Fatal("inventory replayed keys during collection")
	}
	m.Update(inventoryFixture())
	receipt := <-m.backend.keys
	if receipt.Key != "IGNORED" || receipt.IgnoredKeys != 5 {
		t.Fatalf("inventory lost the ignored keys: %+v", receipt)
	}
	m.width, m.height = 40, 10
	m.render()
	press(&m, ' ')
	press(&m, tea.KeyEnter)
	if len(m.backend.keys) != 0 {
		t.Fatal("small pane accepted an action before the user could read it")
	}
	press(&m, 'q')
	if request := <-m.backend.keys; request.Key != "q" {
		t.Fatalf("small pane blocked exit: %+v", request)
	}
}

func TestInventoryProtocolDecodesNullableValues(t *testing.T) {
	var state viewState
	data := `{"event":"state","mode":"builds","step":"inventory","inventory":{"schema_version":1,"observed_at":"2026-10-12T09:23:00Z","roots":["/work"],"max_depth":3,"collection_status":"incomplete","history_status":"first","previous_observed_at":null,"repositories":[{"root":"/work/repo","label":"repo","status":"complete"}],"items":[{"item_id":"one","repository":"/work/repo","path":"/work/repo/dist","relative_path":"dist","kind":"build","size_bytes":null,"delta_bytes":null,"modified_at":null,"status":"unavailable"}],"issues":[],"total_bytes":0,"delta_bytes":null},"focus":"one","visible_ids":["one"]}`
	if err := json.Unmarshal([]byte(data), &state); err != nil {
		t.Fatal(err)
	}
	if state.Mode != "builds" || state.Inventory.Items[0].SizeBytes != nil || state.Inventory.Items[0].ModifiedAt != "" || state.Inventory.DeltaBytes != nil {
		t.Fatalf("nullable inventory values lost their unknown state: %+v", state)
	}
	if state.Inventory.Items[0].RelativePath != "dist" || state.Inventory.CollectionStatus != "incomplete" {
		t.Fatal("inventory identity or completeness was lost")
	}
}
