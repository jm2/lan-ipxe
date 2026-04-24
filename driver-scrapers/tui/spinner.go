package tui

import (
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// spinner is a simple thread-safe spinner animation.
type spinner struct {
	mu      sync.Mutex
	frame   int
	running bool
	ticker  *time.Ticker
	done    chan struct{}
}

// frames defines the spinner animation frames.
var frames = []string{"⠋", "⠙", "⠸", "⠴", "⠦", "⠇", "⠋", "⠹"}

// String returns the current spinner frame.
func (s *spinner) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running && len(frames) > 0 {
		return frames[s.frame%len(frames)]
	}
	return " "
}

// Update advances the spinner frame.
func (s *spinner) Update() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running {
		s.frame++
	}
}

// tick returns a tea.Cmd that updates the spinner at a fixed interval.
func (s *spinner) tick() tea.Cmd {
	return func() tea.Msg {
		s.mu.Lock()
		s.running = true
		s.frame++
		s.mu.Unlock()
		time.Sleep(80 * time.Millisecond)
		return tickMsg(time.Now())
	}
}

// stop stops the spinner ticker.
func (s *spinner) stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.running = false
	if s.done != nil {
		close(s.done)
	}
	if s.ticker != nil {
		s.ticker.Stop()
	}
}
