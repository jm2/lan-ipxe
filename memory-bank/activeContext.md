# Active Context

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