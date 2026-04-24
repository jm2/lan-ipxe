package core

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// extractPackage extracts a downloaded CAB file.
func (o *Orchestrator) extractPackage(pkg *DriverPackage) error {
	o.buildOutputPaths(pkg)

	// Verify CAB file exists
	if _, err := os.Stat(pkg.CabPath); os.IsNotExist(err) {
		return fmt.Errorf("cab file not found: %s", pkg.CabPath)
	}

	o.progress.Send(ProgressEvent{
		Type:     EventExtractStart,
		Provider: o.provider.Name(),
		Device:   pkg.DevicePrefix,
		Arch:     pkg.Arch,
		Status:   "Extracting...",
		Message:  filepath.Base(pkg.CabPath),
	})

	// Ensure output directory exists
	if err := EnsureDir(pkg.ExtractPath); err != nil {
		return fmt.Errorf("create extract dir: %w", err)
	}

	// Extract the CAB file
	files, err := extractCAB(pkg.CabPath, pkg.ExtractPath)
	if err != nil {
		return fmt.Errorf("extract: %w", err)
	}

	o.progress.Send(ProgressEvent{
		Type:     EventExtractDone,
		Provider: o.provider.Name(),
		Device:   pkg.DevicePrefix,
		Arch:     pkg.Arch,
		Version:  pkg.Version,
		Progress: 1.0,
		Status:   "Extract complete",
		Message:  fmt.Sprintf("%d files", len(files)),
	})

	return nil
}

// extractCAB extracts a CAB file using the appropriate tool for the platform.
func extractCAB(cabPath, extractDir string) ([]string, error) {
	cmd, args, err := ExtractCommand(cabPath, extractDir)
	if err != nil {
		return nil, err
	}

	var stdout, stderr bytes.Buffer
	command := exec.Command(cmd, args...)
	command.Stdout = &stdout
	command.Stderr = &stderr

	err = command.Run()
	if err != nil {
		// Try fallback on Linux
		if IsLinux() {
			return extractCABFallback(cabPath, extractDir)
		}
		return nil, fmt.Errorf("command %s %v: %w (stdout: %s, stderr: %s)",
			cmd, args, err, stdout.String(), stderr.String())
	}

	// List extracted files
	files, err := listFiles(extractDir)
	if err != nil {
		return nil, err
	}

	return files, nil
}

// extractCABFallback tries alternative extraction methods on Linux.
func extractCABFallback(cabPath, extractDir string) ([]string, error) {
	// Try 7z as fallback
	command := exec.Command("7z", "x", cabPath, fmt.Sprintf("-o%s", extractDir), "-y")
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	err := command.Run()
	if err != nil {
		return nil, fmt.Errorf("7z extraction failed: %w (stderr: %s)", err, stderr.String())
	}

	files, err := listFiles(extractDir)
	if err != nil {
		return nil, err
	}

	return files, nil
}

// listFiles returns all files in a directory recursively.
func listFiles(dir string) ([]string, error) {
	var files []string
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			files = append(files, path)
		}
		return nil
	})
	return files, err
}

// extractVersionFromTitle extracts a version string from a catalog item title.
func extractVersionFromTitle(title string) string {
	// Match version patterns like "12.17.62.0001" or "v12.17.62"
	re := regexp.MustCompile(`(?:v|V)?(\d+(?:\.\d+){2,4})`)
	matches := re.FindStringSubmatch(title)
	if len(matches) >= 2 {
		return matches[1]
	}
	return ""
}

// extractDateFromTitle extracts a date string from a catalog item title.
func extractDateFromTitle(title string) string {
	// Match date patterns like "10/15/2024" or "2024-10-15"
	re := regexp.MustCompile(`(\d{1,2}[/-]\d{1,2}[/-]\d{4}|\d{4}[/-]\d{1,2}[/-]\d{1,2})`)
	matches := re.FindStringSubmatch(title)
	if len(matches) >= 2 {
		return matches[1]
	}
	return ""
}

// isDriverPackage checks if a catalog item title looks like a driver package.
func isDriverPackage(title string) bool {
	lower := strings.ToLower(title)
	// Common driver package indicators
	driverIndicators := []string{
		"driver", "inf", "sys", "catalog", "wdf",
		"network", "ethernet", "wifi", "usb", "pci",
		"intel", "realtek", "marvell", "qualcomm",
		"atheros", "kaby", "coffee", "comet",
	}
	for _, indicator := range driverIndicators {
		if strings.Contains(lower, indicator) {
			return true
		}
	}
	return false
}

// extractArchFromTitle extracts architecture info from a catalog item title.
func extractArchFromTitle(title string) string {
	lower := strings.ToLower(title)
	if strings.Contains(lower, "arm64") || strings.Contains(lower, "arm") {
		return "ARM64"
	}
	if strings.Contains(lower, "amd64") || strings.Contains(lower, "x64") || strings.Contains(lower, "x86_64") {
		return "AMD64"
	}
	if strings.Contains(lower, "x86") || strings.Contains(lower, "32") {
		return "x86"
	}
	return ""
}
