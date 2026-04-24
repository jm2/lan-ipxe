# Driver Scraper Go Implementation Design

## Overview

A modular, parallel Go implementation of the PowerShell `Get-*Drivers.ps1` scripts that scrape driver packages from the Microsoft Update Catalog. The result is a single binary (`driver-scrape`) that downloads and extracts Windows driver CAB packages for injection into Windows 11 netboot images.

## Architecture

### Directory Structure

```
driver-scrapers/
├── go.mod
├── design.md                    # This file
├── cmd/
│   └── driverscrape/
│       └── main.go              # Binary entry point (CLI + orchestrator + TUI/plain output)
├── core/
│   ├── catalog.go               # Microsoft Update Catalog HTTP client
│   ├── search.go                # Search orchestration + detail fetching
│   ├── selection.go             # Package selection logic
│   ├── downloader.go            # CAB download with progress
│   ├── extractor.go             # CAB extraction (expand.exe / bsdtar)
│   └── platform.go              # Platform/arch detection helpers
├── providers/
│   ├── interface.go             # DriverProvider interface + types
│   ├── intel/
│   │   ├── ethernet.go          # Intel Ethernet providers
│   │   └── wifi.go              # Intel WiFi providers
│   ├── marvell/
│   │   └── marvell.go           # Marvell/Aquantia providers
│   ├── realtek/
│   │   └── realtek.go           # Realtek Ethernet providers
│   ├── qualcomm/
│   │   └── qualcomm.go          # Qualcomm WiFi providers
│   └── mediatek/
│       └── mediatek.go          # MediaTek WiFi providers
└── tui/
    ├── model.go                 # Bubble Tea progress model (passive, no input)
    ├── styles.go                # Lipgloss terminal styling
    └── spinner.go               # Simple spinner for fallback
```

## Core Concepts

### Provider Interface

Each hardware vendor implements the `DriverProvider` interface:

```go
type DriverProvider interface {
    // Name returns the display name (e.g., "Intel Ethernet")
    Name() string

    // Devices returns the list of hardware targets to search
    Devices() []DeviceTarget

    // SelectionStrategy returns how to pick the best package per device+arch combo
    SelectionStrategy() SelectionStrategy
}

type DeviceTarget struct {
    Prefix       string   // e.g., "I225-V" - used for grouping results
    HWID         string   // e.g., "VEN_8086&DEV_15F3" - catalog search identifier
    FamilyName   string   // e.g., "I225" - folder naming
    Queries      []string // alternative search queries (Qualcomm/MediaTek style)
    PreferredBranches []string // version prefix preferences (e.g., ["3.1"])
}

type SelectionStrategy int

const (
    NewestByDate SelectionStrategy = iota   // Intel Ethernet/WiFi, Marvell, Realtek
    SemanticVersion                         // Qualcomm, MediaTek
    SemanticVersionWithBranch               // Qualcomm, MediaTek with branch preference
)
```

### Progress Events

The orchestrator broadcasts progress events via a buffered channel. Both the TUI and plain-text output read from the same channel:

```go
type EventType int

const (
    EventProviderStart EventType = iota
    EventDeviceSearchStart
    EventDeviceSearchDone
    EventPackageSelected
    EventDownloadStart
    EventDownloadProgress
    EventDownloadDone
    EventExtractStart
    EventExtractDone
    EventProviderDone
    EventProviderFailed
    EventDone
)

type ProgressEvent struct {
    Type       EventType
    Provider   string // provider name
    Device     string // device prefix or model name
    Arch       string // "AMD64" or "ARM64"
    Version    string // selected package version
    Progress   float64 // 0.0 - 1.0
    Status     string // human-readable status
    Message    string // additional details (filename, error, etc.)
    Err        error   // non-nil if EventProviderFailed
}
```

### Parallelization Strategy

Multi-level parallelization using `golang.org/x/sync/errgroup`:

```
Level 1: All providers run concurrently (errgroup, unlimited)
  └── Level 2: Per-provider, all devices search concurrently (errgroup, unlimited)
        └── Level 3: Per-device, catalog search (HTTP GET)
              └── Level 4: Per-search-result, detail page fetch (HTTP GET, global throttle=8)
        └── Level 5: Per-device, package selection (in-memory)
        └── Level 6: Per-selected, CAB download (global throttle=4)
              └── Level 7: Per-download, CAB extraction (sequential per provider)
```

**Global semaphores:**
- Detail page fetches: max 8 concurrent (mirrors PowerShell `-ThrottleLimit 8`)
- CAB downloads: max 4 concurrent (conservative to avoid throttling)

### HTTP Client

All scripts query the Microsoft Update Catalog:
- Base URL: `https://www.catalog.update.microsoft.com`
- Search: `https://www.catalog.update.microsoft.com/Search.aspx?q=<query>`
- Detail: `https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=<id>`
- Download POST: `https://www.catalog.update.microsoft.com/DownloadDialog.aspx`
- Download URL extracted from: `https://[^'\"<]+\.cab`

The HTTP client will:
- Use a shared `http.Client` with timeout (30s per request, 5min total download)
- Set appropriate User-Agent and Referer headers
- Handle redirects (up to 10)
- Retry failed requests (3 attempts with exponential backoff)

## CLI Design

```bash
driver-scrape [flags]

Flags:
  --arch x64|arm64|all          Target architecture (default: x64)
  --output <path>                Download output directory (default: ./drivers)
  --providers string...          Providers to run: comma-separated names (default: "all")
                                 Options: intel-eth, intel-wifi, marvell, realtek, qualcomm, mediatek
  --no-download                  Search only, skip download and extraction
  --no-extract                   Download but skip CAB extraction
  --no-tui                       Plain text output instead of TUI
  --workers int                  Max concurrent downloads (default: 4)
  --detail-throttle int          Max concurrent detail page fetches (default: 8)
  --timeout duration             Request timeout per operation (default: 5m0s)
  --verbose                      Enable debug logging
  --help                         Show help
```

### Provider Selection Logic

When `--providers` is not specified or is `all`, all providers run.
When specified, only matching providers run.
Unknown provider names cause a fatal error.

### Output Directory Structure

```
<output>/
├── Intel_Ethernet/
│   ├── I225/
│   │   └── AMD64/
│   │       ├── *.inf
│   │       ├── *.sys
│   │       └── ...
│   ├── I226/
│   │   └── AMD64/
│   └── ...
├── Intel_WiFi/
│   ├── BE200/
│   │   └── AMD64/
│   └── AX200/
│       └── AMD64/
├── Marvell_Ethernet/
│   ├── AQC107/
│   │   └── AMD64/
│   └── AQC113/
│       └── AMD64/
├── Realtek_Ethernet/
│   ├── RTL8125/
│   │   └── AMD64/
│   └── ...
├── Qualcomm_WiFi/
│   ├── QCA6390/
│   │   └── AMD64/
│   └── ...
└── MediaTek_WiFi/
    ├── MT7921_Filogic330/
    │   └── AMD64/
    └── ...
```

## Provider Details

### Intel Ethernet (`intel-eth`)
- **Selection**: Newest by date
- **Devices**: I225-V, I226-V, I219-V, I210, X540, X550, X710, E810, IAVF (9 devices)
- **Families**: 2.5G, 1G, 10G, 100G, AVF

### Intel WiFi (`intel-wifi`)
- **Selection**: Newest by date
- **Devices**: BE200, AX200 (2 devices)
- **Families**: WiFi 7, WiFi 6

### Marvell Ethernet (`marvell`)
- **Selection**: Newest by date
- **Devices**: AQC107, AQC113, AQC111U (3 HWIDs, 5 total search queries)
- **Families**: Aquantia PCIe, Aquantia USB

### Realtek Ethernet (`realtek`)
- **Selection**: Newest by date
- **Devices**: RTL8125, RTL8126, RTL8127, RTL8168, RTL8153, RTL8156, RTL8157, RTL8159 (8 devices)
- **Families**: PCIe, USB

### Qualcomm WiFi (`qualcomm`)
- **Selection**: Semantic version with branch preference
- **Devices**: QCA6390, WCN6855, WCN7850 (3 devices)
- **Preferred branches**: 3.0 (QCA6390, WCN6855), 3.1 (WCN7850)
- **Filter**: Exclude NDIS titles

### MediaTek WiFi (`mediatek`)
- **Selection**: Semantic version with branch preference
- **Devices**: MT7921, MT7921K, MT7922, MT7925, MT7927 (5 devices)
- **Preferred branches**: 3.5 (MT7921, MT7921K, MT7922), 25.30/5.7 (MT7925, MT7927)
- **Filter**: Exclude NDIS titles

## TUI Design

The TUI is a **passive progress display** - no user selection needed.

### Layout

```
┌────────────────────────────────────────────────────────────────────────┐
│ LAN-iPXE Driver Scraper                 Intel Ethernet [████████░░] 80% │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│ ─ Intel Ethernet (5/5 devices)                                         │
│   ├─ I225-V [AMD64]  [████████████████] 100%  v12.17.62  ✓ Done       │
│   ├─ I226-V [AMD64]  [████████████████] 100%  v12.17.62  ✓ Done       │
│   ├─ I219   [AMD64]  [████████████████] 100%  v12.17.62  ✓ Done       │
│   ├─ I210   [AMD64]  [████████████████] 100%  v12.17.62  ✓ Done       │
│   └─ X550   [AMD64]  [████░░░░░░░░░░]  40%  Downloading...            │
│                                                                        │
│ ─ Intel WiFi (2/2 devices)                                             │
│   ├─ BE200 [AMD64]  [████████████████] 100%  v23.32.1   ✓ Done       │
│   └─ AX200 [AMD64]  [████████████████] 100%  v23.32.1   ✓ Done       │
│                                                                        │
│ ─ Marvell Ethernet (0/2 devices)                                       │
│   ├─ AQC107 [AMD64]  [░░░░░░░░░░░░░░░░]   0%  Queued...               │
│   └─ AQC113 [AMD64]  [░░░░░░░░░░░░░░░░]   0%  Queued...               │
│                                                                        │
│ ─ Realtek Ethernet (0/8)  Qualcomm WiFi (0/3)  MediaTek WiFi (0/5)     │
│   ──░░░░░░░░░░░░░░░░   0%              ──░░░░░░░░░░░░░░░░   0%       ──░░░░░░░░░░░░░░░░   0%
│                                                                        │
│ Overall: 7/18 devices complete    Downloading: 3    Extracting: 1      │
└────────────────────────────────────────────────────────────────────────┘
```

### Status Indicators

| Symbol | Meaning |
|--------|---------|
| `✓` | Completed successfully |
| `✗` | Failed |
| `→` | In progress |
| `·` | Waiting / queued |
| `─` | Not yet started |

### Progress Bar

- Uses fixed-width block characters: `█` (full), `▓` (3/4), `▒` (1/2), `░` (1/4), ` ` (empty)
- 20-character wide progress bars per device
- Overall progress in header and per-provider summary

### Plain Text Output (`--no-tui`)

```
[2026-04-23 22:15:01] => Intel Ethernet
[2026-04-23 22:15:01]   [SEARCH] I225-V (VEN_8086&DEV_15F3)
[2026-04-23 22:15:02]   [FOUND] 12 packages for I225-V
[2026-04-23 22:15:03]   [SELECT] I225-V [AMD64] v12.17.62 (Update ID: abc-123)
[2026-04-23 22:15:03]   [DOWNLOAD] I225-V [AMD64] 45.2MB ████████████████░░░░ 78%
[2026-04-23 22:15:04]   [EXTRACT] I225-V [AMD64] 23 files
[2026-04-23 22:15:04]   [DONE] I225-V [AMD64] v12.17.62
[2026-04-23 22:15:05] => Intel Ethernet complete: 5/5 devices
```

## CAB Extraction

### Windows
- Use `expand.exe -F:* "<cab>" "<extract_dir>"` (native Windows utility)
- No external dependencies

### Linux
- Use `bsdtar -x -f "<cab>" -C "<extract_dir>"` (from `libarchive-tools`)
- Fallback: `7z x "<cab>" -o"<extract_dir>"` (from `p7zip-full`)

## Extensibility

Adding a new vendor requires:
1. Create `providers/<vendor>/<vendor>.go` implementing `DriverProvider`
2. Register in `cmd/driverscrape/main.go` provider map
3. That's it - the orchestrator handles everything else

## Dependencies

```go
github.com/charmbracelet/bubbletea  // TUI framework
github.com/charmbracelet/lipgloss   // Terminal styling
golang.org/x/sync                   // errgroup, semaphores
```

## Implementation Order

1. `core/` package (catalog, search, selection, download, extract, platform)
2. `providers/interface.go` (shared interface)
3. `providers/intel/` (two files - ethernet + wifi)
4. `providers/marvell/`
5. `providers/realtek/`
6. `providers/qualcomm/`
7. `providers/mediatek/`
8. `cmd/driverscrape/main.go` (CLI + orchestrator)
9. `tui/` (Bubble Tea model + styles)
10. Integration testing