package main

type scope struct {
	Root     string          `json:"root"`
	Status   string          `json:"collection_status"`
	Observed string          `json:"observed_at"`
	Flags    map[string]bool `json:"flags"`
}
type capability struct{ Name, Status, Reason string }
type member struct {
	PID     int    `json:"pid"`
	Command string `json:"command"`
}
type activity struct {
	Status  string
	Idle    *int64 `json:"idle_seconds"`
	Sources []string
}
type evidence struct {
	CPU              *float64 `json:"cpu_max"`
	Ports            []int
	PortsStatus      string `json:"ports_status"`
	Purpose          string `json:"recorded_purpose"`
	Category, Branch string
	Size             string `json:"size_display"`
	Members          []member
	Activity         *activity
}
type item struct {
	ID                                                                  string `json:"item_id"`
	Type, Target, Scope, Availability, Reason, Consequence, Fingerprint string
	Evidence                                                            evidence
	DisplayLabel                                                        string `json:"display_label"`
	ReasonSentence                                                      string `json:"reason_sentence"`
}
type keyHint struct{ Key, Label string }
type inventoryRepository struct {
	Root, Label, Status string
}
type inventoryItem struct {
	ID           string `json:"item_id"`
	Repository   string
	Path         string
	RelativePath string `json:"relative_path"`
	Kind         string
	SizeBytes    *int64 `json:"size_bytes"`
	DeltaBytes   *int64 `json:"delta_bytes"`
	ModifiedAt   string `json:"modified_at"`
	Status       string
}
type inventoryIssue struct{ Path, Message string }
type inventoryReport struct {
	SchemaVersion      int    `json:"schema_version"`
	ObservedAt         string `json:"observed_at"`
	Roots              []string
	MaxDepth           int    `json:"max_depth"`
	CollectionStatus   string `json:"collection_status"`
	HistoryStatus      string `json:"history_status"`
	PreviousObservedAt string `json:"previous_observed_at"`
	Repositories       []inventoryRepository
	Items              []inventoryItem
	Issues             []inventoryIssue
	TotalBytes         int64  `json:"total_bytes"`
	DeltaBytes         *int64 `json:"delta_bytes"`
}
type viewState struct {
	Event                             string
	Mode                              string
	Inventory                         inventoryReport
	Scope                             scope
	Capabilities                      []capability
	Items                             []item
	Focus                             string
	Marked                            []string
	VisibleIDs                        []string `json:"visible_ids"`
	Query, Step, Message, Destination string
	Searching, Expanded               bool
	SaveEnabled                       bool   `json:"save_enabled"`
	SavedPath                         string `json:"saved_path"`
	RevealFocus                       bool   `json:"reveal_focus"`
	ExitCode                          int    `json:"exit_code"`
	Lines                             []string
	Generation                        int
	Collecting                        bool
	IgnoredKeys                       int    `json:"ignored_keys"`
	MessageKind                       string `json:"message_kind"`
	PositionLabel                     string `json:"position_label"`
	Summary                           []string
	Legend                            []keyHint
	HelpKeys                          []keyHint `json:"help_keys"`
	CapturedAt                        string    `json:"captured_at"`
	ReviewRoot                        string    `json:"review_root"`
}
