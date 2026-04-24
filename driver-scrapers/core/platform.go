package core

import (
	"fmt"
	"os"
	"runtime"
	"strings"
)

// Arch represents a target CPU architecture.
type Arch string

const (
	ArchX64   Arch = "x64"
	ArchARM64 Arch = "arm64"
	ArchAll   Arch = "all"
)

// StringToArch maps architecture strings to Arch constants.
var StringToArch = map[string]Arch{
	"x64":   ArchX64,
	"amd64": ArchX64,
	"64":    ArchX64,
	"arm64": ArchARM64,
	"arm":   ArchARM64,
	"all":   ArchAll,
}

// ArchToCatalog maps our Arch type to the architecture strings used in catalog pages.
func ArchToCatalog(a Arch) []string {
	switch a {
	case ArchX64:
		return []string{"AMD64"}
	case ArchARM64:
		return []string{"ARM64"}
	case ArchAll:
		return []string{"AMD64", "ARM64"}
	default:
		return []string{"AMD64"}
	}
}

// HostArch returns the host's native architecture string as used by the catalog.
func HostArch() string {
	switch runtime.GOARCH {
	case "amd64":
		return "AMD64"
	case "arm64":
		return "ARM64"
	default:
		return "x86"
	}
}

// HostOS returns the host operating system name.
func HostOS() string {
	return runtime.GOOS
}

// IsWindows returns true if running on Windows.
func IsWindows() bool {
	return runtime.GOOS == "windows"
}

// IsLinux returns true if running on Linux.
func IsLinux() bool {
	return runtime.GOOS == "linux"
}

// ExtractCommand returns the command and arguments for extracting a CAB file.
// Returns (command, args, error).
func ExtractCommand(cabPath, extractDir string) (string, []string, error) {
	switch runtime.GOOS {
	case "windows":
		// expand.exe is a native Windows utility
		// NOTE: Do NOT wrap paths in quotes - Go's exec.Command on Windows
		// passes arguments directly to CreateProcess(), which doesn't use
		// shell quoting. Quotes become literal characters in the path.
		return "expand.exe", []string{"-F:*", cabPath, extractDir}, nil
	case "linux", "darwin":
		// Try bsdtar first, then 7z
		if runtime.GOOS == "linux" {
			return "bsdtar", []string{"-x", "-f", cabPath, "-C", extractDir}, nil
		}
		// Fallback to 7z
		return "7z", []string{"x", cabPath, fmt.Sprintf("-o%s", extractDir), "-y"}, nil
	default:
		return "", nil, fmt.Errorf("unsupported OS: %s", runtime.GOOS)
	}
}

// ValidateArch validates that the architecture string is a known value.
func ValidateArch(s string) (Arch, error) {
	a, ok := StringToArch[strings.ToLower(s)]
	if !ok {
		return "", fmt.Errorf("unknown architecture: %s (valid: x64, arm64, all)", s)
	}
	return a, nil
}

// EnsureDir creates a directory if it doesn't exist.
func EnsureDir(path string) error {
	return os.MkdirAll(path, 0755)
}
