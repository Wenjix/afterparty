package main

import (
	"bytes"
	"io"
	"os"
)

// Bubble Tea may use hard tabs for cursor movement when termios permits them.
// CHT moves to the same tab stop without leaving tabs in copied screen rows.
// Embedding the terminal file preserves its descriptor and lifecycle handling.
type terminalWriter struct {
	*os.File
	sink io.Writer
}

func (w terminalWriter) Write(input []byte) (int, error) {
	output := bytes.ReplaceAll(input, []byte{'\t'}, []byte("\x1b[I"))
	sink := w.sink
	if sink == nil {
		sink = w.File
	}
	written := 0
	for written < len(output) {
		count, err := sink.Write(output[written:])
		if count < 0 || count > len(output)-written {
			return sourceCount(input, written), io.ErrShortWrite
		}
		written += count
		if err != nil {
			return sourceCount(input, written), err
		}
		if count == 0 {
			return sourceCount(input, written), io.ErrShortWrite
		}
	}
	return len(input), nil
}
func sourceCount(input []byte, written int) int {
	used := 0
	for index, value := range input {
		size := 1
		if value == '\t' {
			size = 3
		}
		if used+size > written {
			return index
		}
		used += size
	}
	return len(input)
}
