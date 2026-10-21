package main

import (
	"bytes"
	"errors"
	"io"
	"testing"
)

type shortSink struct {
	bytes.Buffer
	limit   int
	failAt  int
	failure error
}

func (s *shortSink) Write(input []byte) (int, error) {
	n := min(s.limit, len(input))
	if s.failAt >= 0 {
		n = min(n, s.failAt-s.Len())
		if n <= 0 {
			return 0, s.failure
		}
	}
	s.Buffer.Write(input[:n])
	if s.failAt >= 0 && s.Len() == s.failAt {
		return n, s.failure
	}
	return n, nil
}
func TestTerminalOutputUsesCursorMovementWithoutHardTabs(t *testing.T) {
	sink := &shortSink{limit: 2, failAt: -1}
	writer := terminalWriter{sink: sink}
	input := []byte("name\tvalue\n\tend\t")
	n, err := writer.Write(input)
	if err != nil || n != len(input) {
		t.Fatalf("short writes failed: %d %v", n, err)
	}
	if got, want := sink.String(), "name\x1b[Ivalue\n\x1b[Iend\x1b[I"; got != want {
		t.Fatalf("terminal motion changed: %q", got)
	}
	if bytes.ContainsRune(sink.Bytes(), '\t') {
		t.Fatal("raw output retained a hard tab")
	}
}
func TestTerminalWriterReportsOriginalByteCountOnFailure(t *testing.T) {
	failure := errors.New("fixture output failure")
	for _, test := range []struct{ stop, count int }{{1, 1}, {2, 1}, {3, 1}, {4, 2}, {5, 3}} {
		sink := &shortSink{limit: 2, failAt: test.stop, failure: failure}
		n, err := (terminalWriter{sink: sink}).Write([]byte("a\tb"))
		if n != test.count || !errors.Is(err, failure) {
			t.Fatalf("write through byte%d: count=%d err=%v", test.stop, n, err)
		}
	}
	sink := &shortSink{limit: 0, failAt: -1}
	if n, err := (terminalWriter{sink: sink}).Write([]byte("a")); n != 0 || !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("zero write count=%d err=%v", n, err)
	}
}
