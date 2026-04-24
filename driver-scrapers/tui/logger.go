package tui

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

var globalLogger *Logger

// Logger provides file-based logging for the TUI.
// All TUI errors, panics, and diagnostic messages are written here
// instead of stdout/stderr since bubbletea owns those streams.
type Logger struct {
	mu      sync.Mutex
	file    *os.File
	prefix  string
	seq     int
	started time.Time
}

// GetLogger returns the global TUI logger instance.
// If not yet initialized, it returns nil until InitLogger is called.
func GetLogger() *Logger {
	return globalLogger
}

// InitLogger creates the global TUI logger and writes all Go logging
// output (if log package is ever used) to the same file.
//
// The log file is created at the given path. If the directory doesn't
// exist, it is created. The file is appended to if it already exists.
func InitLogger(path string) error {
	if dir := dirFor(path); dir != "" {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("tui: create log dir %q: %w", dir, err)
		}
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return fmt.Errorf("tui: open log file %q: %w", path, err)
	}

	globalLogger = &Logger{
		file:    f,
		started: time.Now(),
	}
	return nil
}

// dirFor returns the directory component of a path, or "" for relative
// paths without a directory component.
func dirFor(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i]
		}
	}
	return ""
}

// Close closes the log file.
func (l *Logger) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file != nil {
		l.file.Close()
		l.file = nil
	}
}

// logf writes a formatted message to the log file.
func (l *Logger) logf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return
	}
	elapsed := time.Since(l.started).Truncate(time.Millisecond)
	msg := fmt.Sprintf("[%-11s] %s%s\n", elapsed, l.prefix, fmt.Sprintf(format, args...))
	// Best-effort write; ignore errors since we can't surface them.
	l.file.WriteString(msg)
}

// Log writes a message at the given level.
func (l *Logger) Log(level, format string, args ...any) {
	l.logf("[%s] "+format, append([]any{level}, args...)...)
}

// Error logs an error message.
func (l *Logger) Error(format string, args ...any) {
	l.logf("[ERROR] "+format, args...)
}

// Warn logs a warning message.
func (l *Logger) Warn(format string, args ...any) {
	l.logf("[WARN]  "+format, args...)
}

// Info logs an informational message.
func (l *Logger) Info(format string, args ...any) {
	l.logf("[INFO]  "+format, args...)
}

// Debug logs a debug message (only useful during development).
func (l *Logger) Debug(format string, args ...any) {
	l.logf("[DEBUG] "+format, args...)
}

// Recover captures a panic and logs it, preventing the TUI from
// crashing silently.
func (l *Logger) Recover(recoverName string) {
	if r := recover(); r != nil {
		l.Error("PANIC in %s: %v", recoverName, r)
		// Re-panic so the program still crashes with the error visible
		// in the log file.
		panic(r)
	}
}

// Writer returns an io.Writer that writes to the log file.
// Useful for redirecting output streams.
func (l *Logger) Writer() io.Writer {
	return &logWriter{l: l}
}

// logWriter is an io.Writer that writes to the TUI logger.
type logWriter struct {
	l *Logger
}

func (w *logWriter) Write(p []byte) (int, error) {
	w.l.logf("[STDOUT] %s", string(p))
	return len(p), nil
}
