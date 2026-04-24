package core

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// selectPackages selects the best package for each device+arch combination.
func (o *Orchestrator) selectPackages(searchResults map[string][]*SearchResult) []*DriverPackage {
	var packages []*DriverPackage

	for prefix, results := range searchResults {
		if len(results) == 0 {
			continue
		}

		// Group by architecture
		byArch := make(map[string][]*SearchResult)
		for _, r := range results {
			byArch[r.Arch] = append(byArch[r.Arch], r)
		}

		for _, archResults := range byArch {
			pkg := o.selectSingle(prefix, archResults)
			if pkg != nil {
				packages = append(packages, pkg)
			}
		}
	}

	return packages
}

// selectSingle selects the best package from a list of search results for a single device+arch.
func (o *Orchestrator) selectSingle(prefix string, results []*SearchResult) *DriverPackage {
	if len(results) == 0 {
		return nil
	}

	strategy := o.provider.SelectionStrategy()
	best := results[0]

	for i := 1; i < len(results); i++ {
		if o.isBetter(results[i], best, strategy) {
			best = results[i]
		}
	}

	// Build the driver package
	pkg := &DriverPackage{
		ProviderName: o.provider.Name(),
		DevicePrefix: best.DevicePrefix,
		FamilyName:   best.FamilyName,
		Arch:         best.Arch,
		Version:      best.Detail.Version,
		UpdateID:     best.Detail.UpdateID,
	}

	o.progress.Send(ProgressEvent{
		Type:     EventPackageSelected,
		Provider: o.provider.Name(),
		Device:   pkg.DevicePrefix,
		Arch:     pkg.Arch,
		Version:  pkg.Version,
		Status:   fmt.Sprintf("Selected v%s", pkg.Version),
	})

	return pkg
}

// isBetter returns true if candidate is better than current based on selection strategy.
func (o *Orchestrator) isBetter(candidate, current *SearchResult, strategy SelectionStrategy) bool {
	switch strategy {
	case NewestByDate:
		return isBetterByDate(candidate, current)
	case SemanticVersion:
		return isBetterByVersion(candidate, current)
	case SemanticVersionWithBranch:
		return isBetterByVersionWithBranch(candidate, current, o.provider.Devices())
	default:
		return isBetterByDate(candidate, current)
	}
}

// isBetterByDate returns true if candidate has a newer date.
func isBetterByDate(candidate, current *SearchResult) bool {
	return candidate.Detail.Date.After(current.Detail.Date)
}

// isBetterByVersion returns true if candidate has a higher semantic version.
func isBetterByVersion(candidate, current *SearchResult) bool {
	candVer := parseVersion(candidate.Detail.Version)
	curVer := parseVersion(current.Detail.Version)
	return versionsGreater(candVer, curVer)
}

// isBetterByVersionWithBranch returns true if candidate is better considering branch preferences.
func isBetterByVersionWithBranch(candidate, current *SearchResult, devices []DeviceTarget) bool {
	// First check if either matches a preferred branch
	candBranch := extractBranch(candidate.Detail.Version, devices)
	curBranch := extractBranch(current.Detail.Version, devices)

	// If one has a preferred branch and the other doesn't, prefer the one with branch
	if candBranch != "" && curBranch == "" {
		return true
	}
	if candBranch == "" && curBranch != "" {
		return false
	}

	// If both have branches or neither has a branch, compare versions
	candVer := parseVersion(candidate.Detail.Version)
	curVer := parseVersion(current.Detail.Version)
	return versionsGreater(candVer, curVer)
}

// extractBranch extracts the version branch prefix if it matches any preferred branches.
func extractBranch(version string, devices []DeviceTarget) string {
	// Find the device prefix from the version string
	parts := strings.Split(version, ".")
	if len(parts) < 2 {
		return ""
	}

	branch := parts[0] + "." + parts[1]

	for _, dev := range devices {
		for _, pref := range dev.PreferredBranches {
			if strings.HasPrefix(branch, pref) {
				return pref
			}
		}
	}

	return ""
}

// versionParts holds parsed version components.
type versionParts struct {
	major int
	minor int
	patch int
	build int
	has4  bool
}

// parseVersion parses a version string like "12.17.62.0001" into components.
func parseVersion(v string) versionParts {
	v = strings.TrimSpace(v)
	// Remove any leading "v" or "V"
	v = strings.TrimLeft(v, "vV")

	re := regexp.MustCompile(`^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?`)
	matches := re.FindStringSubmatch(v)
	if len(matches) < 3 {
		return versionParts{major: 0}
	}

	major, _ := strconv.Atoi(matches[1])
	minor, _ := strconv.Atoi(getMatch(matches, 2))
	patch, _ := strconv.Atoi(getMatch(matches, 3))
	build, _ := strconv.Atoi(getMatch(matches, 4))
	has4 := len(matches) >= 6 && matches[5] != ""

	return versionParts{
		major: major,
		minor: minor,
		patch: patch,
		build: build,
		has4:  has4,
	}
}

func getMatch(matches []string, idx int) string {
	if idx < len(matches) {
		return matches[idx]
	}
	return "0"
}

// versionsGreater returns true if a > b.
func versionsGreater(a, b versionParts) bool {
	if a.major != b.major {
		return a.major > b.major
	}
	if a.minor != b.minor {
		return a.minor > b.minor
	}
	if a.patch != b.patch {
		return a.patch > b.patch
	}
	if a.has4 && !b.has4 {
		return true
	}
	if !a.has4 && b.has4 {
		return false
	}
	return a.build > b.build
}

// buildOutputPaths sets the CabPath and ExtractPath for a driver package.
func (o *Orchestrator) buildOutputPaths(pkg *DriverPackage) {
	// Provider folder / Device folder / Arch folder
	providerFolder := sanitizeFilename(pkg.ProviderName)
	deviceFolder := sanitizeFilename(pkg.DevicePrefix)
	archFolder := pkg.Arch

	pkg.CabPath = filepath.Join(o.cfg.OutputDir, providerFolder, deviceFolder+".cab")
	pkg.ExtractPath = filepath.Join(o.cfg.OutputDir, providerFolder, deviceFolder, archFolder)

	// Convert to absolute path so expand.exe can find the file regardless of working directory
	if !filepath.IsAbs(pkg.CabPath) {
		abs, err := filepath.Abs(pkg.CabPath)
		if err == nil {
			pkg.CabPath = abs
		}
	}
	if !filepath.IsAbs(pkg.ExtractPath) {
		abs, err := filepath.Abs(pkg.ExtractPath)
		if err == nil {
			pkg.ExtractPath = abs
		}
	}
}

// sanitizeFilename replaces characters not safe for filepaths with underscores.
func sanitizeFilename(s string) string {
	var result []rune
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
			result = append(result, r)
		} else {
			result = append(result, '_')
		}
	}
	return string(result)
}
