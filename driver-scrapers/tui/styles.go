package tui

import (
	"github.com/charmbracelet/lipgloss"
)

var (
	styleGuide = lipgloss.NewStyle().Padding(0, 0, 0, 1)

	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("252")).
			MarginTop(1)

	providerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("14"))

	deviceStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("252"))

	statusStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241"))

	doneStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("42"))

	failStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("196"))

	progressBarStyle = lipgloss.NewStyle().
				Bold(true)

	overallStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("205")).
			MarginTop(1)

	spinnerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("135"))

	versionStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("39"))

	separatorStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("237")).
			Padding(0, 1)
)

// progressBar renders a fixed-width progress bar with the given percentage.
func progressBar(fraction float64, width int) string {
	if fraction < 0 {
		fraction = 0
	}
	if fraction > 1 {
		fraction = 1
	}

	filled := int(fraction * float64(width))
	if filled > width {
		filled = width
	}

	var sb string
	for i := 0; i < width; i++ {
		if i < filled {
			sb += "█"
		} else {
			sb += "░"
		}
	}
	return sb
}

// progressBarWithColor renders a progress bar with color based on fraction.
func progressBarWithColor(fraction float64, width int) string {
	if fraction < 0 {
		fraction = 0
	}
	if fraction > 1 {
		fraction = 1
	}

	filled := int(fraction * float64(width))
	if filled > width {
		filled = width
	}

	var sb string
	for i := 0; i < width; i++ {
		if i < filled {
			if fraction >= 1.0 {
				sb += lipgloss.NewStyle().SetString("█").String()
			} else if fraction >= 0.5 {
				sb += lipgloss.NewStyle().Foreground(lipgloss.Color("34")).SetString("█").String()
			} else {
				sb += lipgloss.NewStyle().Foreground(lipgloss.Color("220")).SetString("█").String()
			}
		} else {
			sb += lipgloss.NewStyle().Foreground(lipgloss.Color("235")).SetString("░").String()
		}
	}
	return sb
}
