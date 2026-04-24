# Active Context

## Current Work (2026-04-23)
The Go implementation of the driver scraper tool is now complete. All core components have been implemented:

### Core Package (`driver-scrapers/core/`)
- `platform.go` - Platform detection (Windows/Linux), extraction command builders
- `catalog.go` - Windows Driver Catalog API client with search and download URL resolution
- `search.go` - Driver package search with device matching, version/date filtering
- `types.go` - Shared types: `Orchestrator`, `DriverPackage`, `ProgressEvent`, `ProgressChan`, `OrchestratorConfig`
- `selection.go` - Package selection strategies (newest-by-date, semantic version with branch)
- `downloader.go` - CAB package downloader with progress reporting
- `extractor.go` - CAB extraction using `makecab` on Windows, `7z` fallback on Linux

### Providers Package (`driver-scrapers/providers/`)
- `interface.go` - All vendor provider implementations:
  - Intel Ethernet (I225, I226, I219, I210, X540, X550, X710, E810, IAVF)
  - Intel WiFi (BE200, AX200)
  - Marvell Ethernet (AQC107, AQC113, AQC111U)
  - Realtek Ethernet (RTL8125, RTL8126, RTL8127, RTL8168, RTL8153, RTL8156, RTL8157, RTL8159)
  - Qualcomm WiFi (QCA6390, WCN6855, WCN7850)
  - MediaTek WiFi (MT7921, MT7922, MT7925, MT7927)

### TUI Package (`driver-scrapers/tui/`)
- `model.go` - Bubble Tea TUI model with progress tracking
- `styles.go` - Lipgloss styling and progress bar rendering
- `spinner.go` - Thread-safe spinner animation

### CLI Entry Point (`driver-scrapers/cmd/driverscrape/main.go`)
- Full CLI with flags for architecture, output directory, provider selection
- Concurrent provider execution with signal handling
- TUI and plain text output modes
- Progress channel integration

### Dependencies
- `github.com/charmbracelet/bubbletea` - TUI framework
- `github.com/charmbracelet/lipgloss` - Terminal styling
- `golang.org/x/sync` - Concurrent execution utilities

### Architecture
```
cmd/driverscrape/main.go          ← CLI entry point
    │
    ├── core/                       ← Core orchestration logic
    │   ├── platform.go             ← Platform detection
    │   ├── catalog.go              ← Catalog API client
    │   ├── search.go               ← Driver search
    │   ├── types.go                ← Shared types
    │   ├── selection.go            ← Package selection
    │   ├── downloader.go           ← Download logic
    │   └── extractor.go            ← CAB extraction
    │
    ├── providers/                  ← Vendor-specific providers
    │   └── interface.go            ← All provider implementations
    │
    └── tui/                        ← Terminal UI
        ├── model.go                ← TUI model
        ├── styles.go               ← Styling
        └── spinner.go              ← Spinner animation
```

### Parallelism Model
- Providers run concurrently (one goroutine each)
- Within each provider, device searches run concurrently
- Downloads are rate-limited by `MaxDownloads` config
- Detail page fetches are rate-limited by `DetailThrottle` config
- Progress events flow through a shared channel to the TUI

### Key Design Decisions
1. **Provider Interface** - Each vendor is a separate implementation of `DriverProvider` interface
2. **Orchestrator Pattern** - Single orchestrator per provider handles the full pipeline
3. **Progress Channel** - Shared buffered channel for all progress events
4. **Selection Strategies** - Pluggable strategies for package selection
5. **Platform Abstraction** - Extraction uses platform-appropriate tools

## Next Steps
1. Build and test the complete project
2. Add unit tests for core logic
3. Add more device targets as needed
4. Consider adding CSV/JSON output for results
5. Add retry logic for failed downloads
6. Implement driver package signing verification
7. Add support for .inf-based driver extraction
8. Consider adding a `--dry-run` mode for testing
9. Add support for custom catalog URLs
10. Implement caching for catalog search results
11. Add support for driver package repackaging
12. Consider adding a GUI mode using a different TUI library
13. Add support for driver package validation
14. Implement driver package compression
15. Add support for driver package signing
16. Consider adding a web-based dashboard
17. Add support for driver package deduplication
18. Implement driver package verification
19. Add support for driver package documentation
20. Consider adding a driver package manager

## Recent Changes
- Fixed TUI progress event integration by adding `ProgressEvent` type alias
- Fixed spinner tick() return type to match tea.Cmd signature
- Fixed providerState struct to include message field
- Added support for both `core.ProgressEvent` and `tui.ProgressEvent` in TUI model
- Added plain text output mode as alternative to TUI
- Added signal handling for graceful shutdown
- Added concurrent provider execution with WaitGroup
- Added provider selection via command-line flags
- Added architecture validation and filtering
- Added timeout configuration
- Added verbose/debug logging support
- Added version flag
- Added worker count configuration
- Added detail throttle configuration
- Added no-download and no-extract flags

## Current Focus
Porting PowerShell driver scraping scripts to Go with a Bubble Tea/TUI frontend. Starting with Marvell/Aquantia Ethernet drivers.

## Recent Changes
- Memory bank initialization (current task)
- Created `driver-scrapers/` Go module with Bubble Tea TUI
  - `types.go` -- Shared TUI types (Architecture, DriverPackage, DriverStatus, DownloadTask)
  - `model.go` -- Bubble Tea Model with Init/Update/View methods
  - `styles.go` -- Lipgloss UI styling
  - `main.go` -- Application entry point, scraper orchestration, TUI rendering
  - `marvell/types.go` -- Vendor-specific types (Device, TargetGroup, CandidatePackage, ResultPackage)
  - `marvell/interface.go` -- Marvell/Aquantia scraper implementation with catalog search, download, and extraction

## Next Steps
- Review and validate memory-bank contents with project documentation
- Port remaining Get-*Drivers.ps1 scripts (Intel, Realtek, Qualcom, Mediatek, WiFi)
- Add CAB extraction using expand.exe equivalent or Go library (e.g., arc)
- Add CLI flags for architecture selection and install mode
- Consider adding progress bars with bubbletea.Progress

## Important Patterns and Preferences

### Directory Structure Conventions
- `files/` -- Shared configuration files deployed to target systems
- `files/etc/` -- System config files (pacman.conf, locale.conf, yum.repos.d/, etc.)
- `files/config/` -- Application configs (e.g., Antigravity User settings)
- `*.yaml` -- Antigravity workstation profiles
- `build_*.sh` / `build_*.ps1` -- Build scripts for generating boot images
- `update_*.sh` -- Maintenance/update scripts

### Build Script Patterns
- Scripts check for writable directories and fallback to local test dirs
- Root privilege checks where needed (`$EUID -ne 0`)
- Output directories prefer `/srv/http/pxe` when writable
- Temporary work directories cleaned up after builds

### iPXE Menu Generation
- Dynamic menu items based on scraped versions
- Feature flags control what appears (`ENABLE_CUSTOM_ARCHISO`, `ENABLE_WIN11_PXE`, etc.)
- ARM64 and x86_64 menus generated separately
- Netboot.xyz used for Clonezilla and generic network tools

### Antigravity Profile Pattern
- `where:` clause filters by OS name
- `actions:` list includes package installs, file copies, service enables, and command runs
- Privileged actions use `privileged: true`
- File copies use template variables like `{{ env.HOME }}`

## Learnings and Project Insights
- Arch ISO build requires `mkarchiso` tool from the `archiso` package
- Windows 11 iSCSI boot requires loading and modifying the offline SYSTEM registry hive
- DISM operations need adequate scratch space for cumulative updates
- iPXE `snponly.efi` resolves UEFI keyboard/GOP issues on more hardware than stock `ipxe.efi`
- The project uses Purdue RCAC (plug-mirror.rcac.purdue.edu) as the primary mirror