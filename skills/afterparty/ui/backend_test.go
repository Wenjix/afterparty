//go:build darwin || linux

package main

import (
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestBackendOwnedGroupProcess(t *testing.T) {
	role := os.Getenv("AFTERPARTY_TEST_GROUP_ROLE")
	if role == "" {
		return
	}
	dir := os.Getenv("AFTERPARTY_TEST_GROUP_DIR")
	terminated := make(chan os.Signal, 1)
	signal.Notify(terminated, syscall.SIGTERM)
	if role == "descendant" {
		if err := os.WriteFile(filepath.Join(dir, "descendant-ready"), []byte("ready"), 0600); err != nil {
			os.Exit(2)
		}
		<-terminated
		if err := os.WriteFile(filepath.Join(dir, "descendant-term"), []byte("SIGTERM"), 0600); err != nil {
			os.Exit(3)
		}
		os.Exit(0)
	}
	child := exec.Command(os.Args[0], "-test.run=^TestBackendOwnedGroupProcess$")
	child.Env = append(os.Environ(), "AFTERPARTY_TEST_GROUP_ROLE=descendant")
	if err := child.Start(); err != nil {
		os.Exit(4)
	}
	if err := os.WriteFile(filepath.Join(dir, "leader-ready"), []byte("ready"), 0600); err != nil {
		os.Exit(5)
	}
	<-terminated
	// The child remains in the backend's group. A PID-only TERM never reaches it.
	if err := child.Wait(); err != nil {
		os.Exit(6)
	}
	os.Exit(0)
}

func TestBackendShutdownSignalsItsOwnedDescendants(t *testing.T) {
	dir := t.TempDir()
	command := exec.Command(os.Args[0], "-test.run=^TestBackendOwnedGroupProcess$")
	command.Env = append(os.Environ(), "AFTERPARTY_TEST_GROUP_ROLE=leader", "AFTERPARTY_TEST_GROUP_DIR="+dir)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if command.ProcessState == nil {
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
			_ = command.Wait()
		}
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, leaderErr := os.Stat(filepath.Join(dir, "leader-ready"))
		_, descendantErr := os.Stat(filepath.Join(dir, "descendant-ready"))
		if leaderErr == nil && descendantErr == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the controlled leader and descendant did not become ready")
		}
		time.Sleep(10 * time.Millisecond)
	}
	input, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	b := &backend{command: command, input: input, output: io.NopCloser(strings.NewReader("")), stop: make(chan struct{})}
	b.close(true)
	receipt, err := os.ReadFile(filepath.Join(dir, "descendant-term"))
	if err != nil || string(receipt) != "SIGTERM" {
		t.Fatalf("the owned descendant did not receive graceful termination: %q %v", receipt, err)
	}
	if command.ProcessState == nil || !command.ProcessState.Success() {
		t.Fatal("the backend did not reap its terminated descendant")
	}
}
