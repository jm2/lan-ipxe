package tui

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/gitgerby/lan-ipxe/driver-scrapers/core"
)

// Model is the Bubble Tea TUI model for displaying driver scrape progress.
type Model struct {
	width  int
	height int
	events []core.ProgressEvent
	// Per-provider state
	providerStates map[string]*providerState
	// Overall state
	totalDevices int
	doneDevices  int
	// Spinner
	spinner  spinner
	done     bool
	quitting bool
	// Timers
	lastTick  time.Time
	tickCount int
}

type providerState struct {
	name     string
	devices  map[string]*deviceState
	total    int
	done     int
	failed   int
	status   string
	progress float64
	message  string
}

type deviceState struct {
	prefix   string
	arch     string
	version  string
	status   string
	progress float64
	message  string
	done     bool
	failed   bool
}

// NewModel creates a new TUI model.
func NewModel() *Model {
	return &Model{
		width:          80,
		height:         24,
		providerStates: make(map[string]*providerState),
	}
}

// Init returns the initial TUI message.
func (m *Model) Init() tea.Cmd {
	return tea.Batch(
		m.spinner.tick(),
		tea.WindowSize(),
		tea.Tick(100*time.Millisecond, func(t time.Time) tea.Msg {
			return tickMsg(t)
		}),
	)
}

// Update handles TUI messages.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// Recover from panics and log them.
	defer func() {
		if r := recover(); r != nil {
			if log := GetLogger(); log != nil {
				log.Error("PANIC in Model.Update: %v", r)
			}
		}
	}()

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			m.quitting = true
			if log := GetLogger(); log != nil {
				log.Info("User pressed %s, quitting TUI", msg.String())
			}
			return m, tea.Quit
		}
		return m, nil

	case tickMsg:
		m.tickCount++
		m.spinner.Update()
		return m, m.spinner.tick()

	case core.ProgressEvent:
		m.handleProgress(msg)
		return m, nil
	}

	return m, nil
}

// View renders the TUI.
func (m *Model) View() string {
	if m.quitting {
		return ""
	}

	var b strings.Builder

	// Always render a visible header, even before window size is known.
	b.WriteString("=== LAN-iPXE Driver Scraper ===\n")

	// Separator
	width := m.width
	if width < 5 {
		width = 40
	}
	b.WriteString(strings.Repeat("-", width) + "\n")
	b.WriteString("\n")

	// Provider sections
	b.WriteString(m.renderProviders())

	// Overall progress
	b.WriteString(m.renderOverall())

	// Fill remaining space so the screen isn't blank
	remaining := m.height - m.estimateHeight()
	if remaining < 0 {
		remaining = 0
	}
	if remaining > 3 {
		remaining = 3
	}
	for i := 0; i < remaining; i++ {
		b.WriteString("\n")
	}

	// Footer — always visible
	b.WriteString("\n")
	b.WriteString(fmt.Sprintf(" [%s] Press q to quit\n", m.spinner.String()))

	return b.String()
}

func (m *Model) renderProviders() string {
	var b strings.Builder

	// Get provider names in insertion order
	names := make([]string, 0, len(m.providerStates))
	seen := make(map[string]bool)
	for _, ev := range m.events {
		if ev.Provider != "" && !seen[ev.Provider] {
			names = append(names, ev.Provider)
			seen[ev.Provider] = true
		}
	}

	// Render each provider
	for i, name := range names {
		ps := m.providerStates[name]
		if ps == nil {
			continue
		}

		// Provider header
		b.WriteString(fmt.Sprintf(" [%s] (%d/%d devices)\n", ps.name, ps.done, ps.total))

		// Provider progress bar
		if ps.total > 0 {
			b.WriteString(fmt.Sprintf("     [%s]\n", progressBarWithColor(float64(ps.done)/float64(ps.total), 20)))
		}

		// Device lines
		for _, ds := range ps.devices {
			line := m.renderDeviceLine(ds)
			b.WriteString(line + "\n")
		}

		// Separator between providers (not after last)
		if i < len(names)-1 {
			b.WriteString("\n")
		}
	}

	return b.String()
}

func (m *Model) renderDeviceLine(ds *deviceState) string {
	// Progress bar
	bar := ""
	if ds.done {
		bar = "████████████████"
	} else if ds.failed {
		bar = "████░░░░░░░░░░░░"
	} else {
		bar = progressBarWithColor(ds.progress, 16)
	}

	// Status symbol
	status := " · "
	if ds.done {
		status = " ✓ "
	} else if ds.failed {
		status = " ✗ "
	} else if ds.progress > 0 {
		status = " → "
	}

	// Version
	version := ""
	if ds.version != "" {
		version = fmt.Sprintf(" v%s", ds.version)
	}

	return fmt.Sprintf("  %s[%s] %s%s%s %s%s",
		ds.prefix, ds.arch, bar, version, status, ds.status, ds.message)
}

func (m *Model) renderOverall() string {
	var downloading, extracting int
	for _, ev := range m.events[len(m.events)-min(20, len(m.events)):] {
		switch ev.Type {
		case core.EventDownloadStart:
			downloading++
		case core.EventDownloadProgress:
			downloading++
		case core.EventExtractStart:
			extracting++
		}
	}

	text := fmt.Sprintf("Overall: %d/%d devices complete", m.doneDevices, m.totalDevices)
	if downloading > 0 {
		text += fmt.Sprintf("    Downloading: %d", downloading)
	}
	if extracting > 0 {
		text += fmt.Sprintf("    Extracting: %d", extracting)
	}

	return "\n" + text
}

func (m *Model) handleProgress(ev core.ProgressEvent) {
	// Recover from panics and log them.
	defer func() {
		if r := recover(); r != nil {
			if log := GetLogger(); log != nil {
				log.Error("PANIC in handleProgress: event=%s provider=%s device=%s arch=%s error=%v",
					ev.Type, ev.Provider, ev.Device, ev.Arch, r)
			}
		}
	}()

	m.events = append(m.events, ev)

	ps, ok := m.providerStates[ev.Provider]
	if !ok {
		ps = &providerState{
			name:    ev.Provider,
			devices: make(map[string]*deviceState),
		}
		m.providerStates[ev.Provider] = ps
	}

	log := GetLogger()

	switch ev.Type {
	case core.EventProviderStart:
		if log != nil {
			log.Info("Provider started: %s", ev.Provider)
		}
		ps.status = "Starting..."

	case core.EventDeviceSearchStart:
		key := deviceKey(ev.Device, ev.Arch)
		ds, ok := ps.devices[key]
		if !ok {
			ds = &deviceState{prefix: ev.Device, arch: ev.Arch}
			ps.devices[key] = ds
			ps.total++
			m.totalDevices++
			if log != nil {
				log.Debug("New device: %s %s", ev.Device, ev.Arch)
			}
		}
		ds.status = ev.Status
		ds.message = ev.Message

	case core.EventDeviceSearchDone:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.status = "Search complete"
		}

	case core.EventPackageSelected:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.version = ev.Version
			ds.status = ev.Status
			ds.message = ev.Message
			if log != nil {
				log.Info("Package selected: %s %s v%s", ev.Device, ev.Arch, ev.Version)
			}
		}

	case core.EventDownloadStart:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.status = "Downloading..."
			ds.progress = 0
			if log != nil {
				log.Info("Download started: %s %s", ev.Device, ev.Arch)
			}
		}

	case core.EventDownloadProgress:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.progress = ev.Progress
			ds.status = ev.Status
			ds.message = ev.Message
		}

	case core.EventDownloadDone:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.progress = 1.0
			ds.status = "Download complete"
			ds.message = ev.Message
			if log != nil {
				log.Info("Download complete: %s %s", ev.Device, ev.Arch)
			}
		}

	case core.EventExtractStart:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.status = "Extracting..."
			if log != nil {
				log.Info("Extract started: %s %s", ev.Device, ev.Arch)
			}
		}

	case core.EventExtractDone:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.status = "Extract complete"
			ds.message = ev.Message
			if log != nil {
				log.Info("Extract complete: %s %s", ev.Device, ev.Arch)
			}
		}

	case core.EventProviderDone:
		key := deviceKey(ev.Device, ev.Arch)
		if ds, ok := ps.devices[key]; ok {
			ds.done = true
			ds.status = ev.Status
			m.doneDevices++
			ps.done++
		}
		ps.status = "Complete"
		ps.message = ev.Message
		if log != nil {
			log.Info("Provider done: %s - %s", ev.Provider, ev.Message)
		}

	case core.EventProviderFailed:
		ps.failed++
		ps.status = "Failed"
		ps.message = ev.Message
		if log != nil {
			log.Error("Provider failed: %s - %s", ev.Provider, ev.Message)
		}
	}
}

func (m *Model) estimateHeight() int {
	lines := 4 // header + separator + overall + footer
	for _, ps := range m.providerStates {
		lines += 1 // provider header
		lines += len(ps.devices)
		lines += 1 // blank line between providers
	}
	return lines
}

func deviceKey(device, arch string) string {
	if arch != "" {
		return fmt.Sprintf("%s-%s", device, arch)
	}
	return device
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

type tickMsg time.Time

// ProgressEvent is a type alias for core.ProgressEvent used as a Bubble Tea message.
type ProgressEvent core.ProgressEvent
