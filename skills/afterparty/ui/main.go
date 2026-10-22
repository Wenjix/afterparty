//go:build darwin || linux

package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
)

type backend struct {
	command   *exec.Cmd
	input     io.WriteCloser
	output    io.ReadCloser
	decoder   *json.Decoder
	keys      chan keyRequest
	stop      chan struct{}
	inventory bool
}

func backendCommand(executable string, args []string, inventory bool) *exec.Cmd {
	script := "review.py"
	var flags []string
	if inventory {
		script = "build_inventory.py"
		flags = append(flags, "--serve")
	}
	commandArgs := append([]string{filepath.Join(filepath.Dir(executable), "../lib", script)}, flags...)
	return exec.Command("python3", append(commandArgs, args...)...)
}

func startBackend(args []string, inventory bool) (*backend, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	command := backendCommand(executable, args, inventory)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Stderr = os.Stderr
	input, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := command.StdoutPipe()
	if err != nil {
		input.Close()
		return nil, err
	}
	if err = command.Start(); err != nil {
		input.Close()
		output.Close()
		return nil, err
	}
	b := &backend{command: command, input: input, output: output, decoder: json.NewDecoder(output),
		keys: make(chan keyRequest, 256), stop: make(chan struct{}), inventory: inventory}
	go func() {
		encoder := json.NewEncoder(input)
		for {
			select {
			case key := <-b.keys:
				if err := encoder.Encode(key); err != nil {
					input.Close()
					return
				}
			case <-b.stop:
				return
			}
		}
	}()
	return b, nil
}

func (b *backend) next() tea.Msg {
	var event viewState
	if err := b.decoder.Decode(&event); err != nil {
		if errors.Is(err, io.EOF) {
			if b.inventory {
				return backendError{errors.New("The build output scan ended without a result. Run afterparty builds again.")}
			}
			return backendError{errors.New("The review ended without a result. Run afterparty review again.")}
		}
		return backendError{err}
	}
	return event
}

func (b *backend) close(interrupt bool) {
	close(b.stop)
	if interrupt {
		// The helper creates this group for the backend and its descendants.
		_ = syscall.Kill(-b.command.Process.Pid, syscall.SIGTERM)
	}
	b.input.Close()
	done := make(chan error, 1)
	go func() { done <- b.command.Wait() }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		// This is the backend's own group, created by this invocation.
		_ = syscall.Kill(-b.command.Process.Pid, syscall.SIGKILL)
		<-done
	}
	b.output.Close()
}

type backendError struct{ err error }
type interruptMsg struct{}
type tickMsg time.Time
type keyRequest struct {
	Key          string `json:"key"`
	Generation   int    `json:"generation"`
	FocusVisible bool   `json:"focus_visible"`
	IgnoredKeys  int    `json:"ignored_keys,omitempty"`
	Action       string `json:"action,omitempty"`
	Step         string `json:"step,omitempty"`
	Focus        string `json:"focus"`
}

func tick(collecting bool) tea.Cmd {
	interval := time.Second
	if collecting {
		interval = 200 * time.Millisecond
	}
	return tea.Tick(interval, func(when time.Time) tea.Msg { return tickMsg(when) })
}

type model struct {
	backend               *backend
	state                 viewState
	width, height, scroll int
	ascii                 bool
	theme                 theme
	final                 []string
	status                int
	finished              bool
	roomTooSmall          bool
	interrupts            <-chan os.Signal
	closed                chan struct{}
	now                   time.Time
	scanStarted           time.Time
	dropped               int
	focusVisible          bool
	inventory             bool
	reviewRoot            string
	commands              commandSheet
	feedbackID            int
	feedbackGeneration    int
	feedbackAt            time.Time
}

func (m *model) Init() tea.Cmd {
	return tea.Batch(m.backend.next, tick(m.collecting()), func() tea.Msg {
		select {
		case <-m.interrupts:
			return interruptMsg{}
		case <-m.closed:
			return nil
		}
	})
}

func (m *model) send(key string) {
	select {
	case m.backend.keys <- keyRequest{Key: key, Generation: m.state.Generation, FocusVisible: m.focusVisible}:
	default:
		m.state.Message = "Afterparty cannot accept more keys. Wait for this step to finish."
		m.state.MessageKind, m.state.MessageTransient = "refused", false
	}
}

func (m *model) reportIgnored() {
	if m.dropped == 0 || m.backend == nil || m.collecting() {
		return
	}
	select {
	case m.backend.keys <- keyRequest{Key: "IGNORED", Generation: m.state.Generation, FocusVisible: true, IgnoredKeys: m.dropped}:
		m.dropped = 0
	default:
	}
}
func (m *model) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := message.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.state.RevealFocus = true
		if msg.Width < 60 || msg.Height < 20 {
			m.commands = commandSheet{}
		}
	case tickMsg:
		if m.finished {
			return m, nil
		}
		m.now = time.Time(msg)
		m.reportIgnored()
		return m, tick(m.collecting())
	case tea.ResumeMsg:
		m.now = time.Now()
	case viewState:
		if msg.Event == "scan" {
			m.commands = commandSheet{}
			m.state.Collecting = true
			m.state.Generation = msg.Generation
			m.scanStarted = m.nowTime()
			return m, m.backend.next
		}
		if msg.Event == "done" || msg.Event == "error" {
			m.commands = commandSheet{}
			m.final, m.status, m.finished = msg.Lines, msg.ExitCode, msg.Event == "done"
			if m.inventory && m.finished {
				m.reviewRoot = msg.ReviewRoot
			}
			return m, tea.Quit
		}
		if msg.Event != "state" {
			return m, func() tea.Msg {
				return backendError{errors.New("The review received an unknown event. Run afterparty review again.")}
			}
		}
		if msg.Step != m.state.Step {
			m.scroll = 0
		}
		wasCollecting := m.collecting()
		if m.commands.open && (msg.Generation != m.commands.generation || msg.Step != m.commands.step || msg.Focus != m.commands.focus || msg.Collecting || msg.Searching ||
			!slices.Equal(msg.Actions, m.state.Actions) || msg.Scope.Root != m.state.Scope.Root || msg.Mode != m.state.Mode || !slices.Equal(msg.Inventory.Roots, m.state.Inventory.Roots)) {
			m.commands = commandSheet{}
		}
		if msg.MessageID != m.feedbackID || msg.Generation != m.feedbackGeneration {
			m.feedbackID, m.feedbackGeneration = msg.MessageID, msg.Generation
			m.feedbackAt = m.nowTime()
		}
		m.state = msg
		if msg.Collecting && !wasCollecting {
			m.scanStarted = m.nowTime()
		}
		m.reportIgnored()
		return m, m.backend.next
	case backendError:
		prefix := "review: "
		if m.inventory {
			prefix = "builds: "
		}
		m.final, m.status = []string{prefix + safeText(msg.err.Error(), m.ascii)}, 1
		return m, tea.Quit
	case interruptMsg:
		m.final, m.status = []string{"The review stopped. Afterparty did not run cleanup."}, 130
		if m.inventory {
			m.final = []string{"The build output scan stopped. Afterparty did not run cleanup."}
		}
		if m.state.SavedPath != "" {
			m.final = append(m.final, "Plan saved: "+safeText(m.state.SavedPath, m.ascii))
		}
		return m, tea.Quit
	case tea.PasteMsg:
		if m.collecting() {
			m.dropped++
			return m, nil
		}
		if m.commands.open {
			return m, nil
		}
		m.send("PASTE")
	case tea.KeyPressMsg:
		key := msg.String()
		if m.collecting() {
			if key == "q" {
				m.final = []string{"You canceled the review. Afterparty did not save a plan."}
				if m.inventory {
					m.final = []string{"You canceled the build output scan. Afterparty did not run cleanup."}
				}
				m.status = 1
				return m, tea.Quit
			}
			if key == "ctrl+c" {
				return m.Update(interruptMsg{})
			}
			m.dropped++
			return m, nil
		}
		if key == "ctrl+z" {
			return m, tea.Suspend
		}
		// Legacy terminals encode Esc followed quickly by a key as Alt+key.
		// Commands consumes the whole chord; elsewhere preserve both actions.
		if msg.Mod.Contains(tea.ModAlt) {
			if m.commands.open {
				m.commands = commandSheet{}
				return m, nil
			}
			m.send("ESC")
			msg.Mod &^= tea.ModAlt
			key = msg.String()
		}
		if key == "ctrl+c" || key == "ctrl+\\" {
			return m.Update(interruptMsg{})
		}
		if m.width < 60 || m.height < 20 || m.roomTooSmall {
			if m.inventory {
				if key == "q" {
					if m.state.Searching {
						m.send("ESC")
					}
					m.send("q")
				}
				if key == "esc" {
					m.send("ESC")
				}
				return m, nil
			}
			if m.state.SavedPath != "" && (key == "q" || key == "enter" || key == "esc") {
				m.send("CANCEL")
			}
			if m.state.SavedPath == "" {
				if key == "q" {
					if m.state.Searching {
						m.send("ESC")
					}
					if m.state.Step == "confirm_refresh" {
						m.send("ESC")
					}
					m.send("q")
				}
				if key == "esc" {
					m.send("ESC")
				}
				if m.state.Step == "confirm_quit" {
					if key == "enter" {
						m.send("ENTER")
					}
				}
			}
			return m, nil
		}
		if m.commands.open {
			m.commandKey(key)
			return m, nil
		}
		if key == "ctrl+p" {
			m.openCommands()
			return m, nil
		}
		if key == "pgup" || key == "pgdown" {
			amount := max(3, m.height/2)
			if key == "pgup" {
				amount = -amount
			}
			m.scroll += amount
			m.state.RevealFocus = false
			m.focusVisible = false
			return m, nil
		}
		mapping := map[string]string{"enter": "ENTER", "esc": "ESC", "up": "UP", "down": "DOWN", "backspace": "BACKSPACE", "space": " "}
		if mapped, ok := mapping[key]; ok {
			key = mapped
		} else if len([]rune(key)) != 1 {
			return m, nil
		}
		m.send(key)
	}
	return m, nil
}

func (m *model) View() tea.View {
	content := ""
	if m.commands.open && m.width >= 60 && m.height >= 20 && !m.collecting() {
		content = m.renderCommands()
	} else {
		content = m.render()
	}
	view := tea.NewView(content)
	view.AltScreen = true
	return view
}

func run() int {
	stateDir := flag.String("state-dir", "", "private directory for review state")
	output := flag.String("output", "", "path for the saved plan")
	ascii := flag.Int("ascii", 0, "ASCII display")
	inventory := flag.Bool("inventory", false, "show the read-only build output inventory")
	flag.Parse()
	name := "review"
	if *inventory {
		name = "builds"
	}
	if *stateDir == "" {
		fmt.Fprintf(os.Stderr, "%s: --state-dir requires a directory. Run afterparty %s to set it automatically.\n", name, name)
		return 2
	}
	args := append([]string{"--state-dir", *stateDir, "--output", *output, "--"}, flag.Args()...)
	b, err := startBackend(args, *inventory)
	if err != nil {
		fmt.Fprintln(os.Stderr, name+":", err)
		return 1
	}
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	defer signal.Stop(interrupts)
	m := &model{backend: b, width: 80, height: 24, ascii: *ascii != 0, theme: loadTheme(), now: time.Now(), scanStarted: time.Now(), focusVisible: true, interrupts: interrupts, closed: make(chan struct{}), inventory: *inventory}
	profile := colorprofile.ANSI
	if !m.theme.enabled && !m.theme.attributes {
		profile = colorprofile.NoTTY
	}
	program := tea.NewProgram(m, tea.WithoutSignalHandler(), tea.WithColorProfile(profile), tea.WithOutput(terminalWriter{File: os.Stdout}))
	_, err = program.Run()
	close(m.closed)
	b.close(!m.finished)
	if err != nil {
		fmt.Fprintln(os.Stderr, name+":", err)
		return 1
	}
	// Start the receipt at column one after leaving the alternate screen,
	// including terminals that preserve the previous cursor column.
	fmt.Print("\r\n")
	for _, line := range m.final {
		fmt.Println(line)
	}
	if m.inventory && m.finished && m.reviewRoot != "" {
		executable, err := os.Executable()
		if err != nil {
			fmt.Fprintln(os.Stderr, "builds:", err)
			return 1
		}
		child := inventoryReviewCommand(executable, m.reviewRoot, m.ascii)
		child.Stdin, child.Stdout, child.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := child.Run(); err != nil {
			var exitError *exec.ExitError
			if errors.As(err, &exitError) {
				if exitError.ExitCode() >= 0 {
					return exitError.ExitCode()
				}
				if status, ok := exitError.Sys().(syscall.WaitStatus); ok && status.Signaled() {
					return 128 + int(status.Signal())
				}
			}
			fmt.Fprintln(os.Stderr, "builds:", err)
			return 1
		}
		return 0
	}
	return m.status
}

func inventoryReviewCommand(executable, root string, ascii bool) *exec.Cmd {
	args := []string{"--artifacts-only", "--root", root}
	if ascii {
		args = append(args, "--ascii")
	}
	return exec.Command(filepath.Join(filepath.Dir(executable), "../lib/review.sh"), args...)
}

func main() { os.Exit(run()) }
