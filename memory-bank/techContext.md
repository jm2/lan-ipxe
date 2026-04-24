# Tech Context

## Technologies Used

### Operating Systems
- **Arch Linux**: Rolling release, primary development platform
- **Fedora Linux**: Workstation distribution for PXE menu
- **Debian Linux**: Stable distribution for PXE menu
- **Rocky Linux**: RHEL-compatible distribution for PXE menu
- **Windows 11**: Network-bootable via iSCSI (Win2Go)

### Boot Technologies
- **iPXE**: Network boot protocol with HTTP, iSCSI, and chain loading support
- **DHCP**: Provides IP and next-server/TFTP boot file info
- **TFTP**: Transports iPXE binaries to clients
- **HTTP**: Serves boot assets (ISOs, kernels, initrd, iPXE menu)
- **iSCSI**: Serves Windows VHDX over network

### Build Tools
- **archiso**: Custom Arch Linux ISO building (`mkarchiso`)
- **DISM**: Windows Image deployment (`dism.exe /Apply-Image`, `/Add-Driver`, `/Add-Package`)
- **bcdboot**: Windows boot file generation
- **bcdedit**: Windows Boot Configuration Data modification
- **New-VHD / Mount-VHD**: PowerShell VHDX management

### Configuration Management
- **Antigravity**: Declarative YAML-based system configuration
  - Actions: `package.install`, `command.run`, `file.copy`
  - Providers: `pacman`, `yay`, `dnf`, `winget`
  - Conditional: `where:` clauses for OS/arch filtering

### Scripting Languages
- **Bash**: Build scripts, update scripts, ISO customization
- **PowerShell**: Windows driver scraping, VHDX building, system configuration
- **iPXE Script**: Boot menu configuration and network boot commands

## Development Setup

### Prerequisites (Linux Host)
- `archiso` package (for `mkarchiso`)
- HTTP server (nginx, Apache, or python http.server)
- TFTP server (tftp-hpa, dracot, or built-in iPXE HTTP/TFTP)
- DHCP server with iPXE support
- Root access for ISO building

### Prerequisites (Windows Host)
- Windows 10/11 or Windows Server
- PowerShell 5.1+ with DISM and Storage modules
- Administrator privileges
- Windows 11 ISO for VHDX creation

### Required Directory Structure
```
/srv/http/pxe/           # HTTP root for PXE assets
/srv/tftp/               # TFTP root for iPXE binaries
/srv/arch/               # Mounted Arch Linux install media (optional)
```

## Key Dependencies

### Package Dependencies (Arch)
- `archiso` -- ISO building tools
- `pacman` -- Package management
- `systemd` -- Service management

### Package Dependencies (Windows)
- `DISM` -- Windows Image deployment
- `bcdboot/bcdedit` -- Boot configuration
- `Storage` PowerShell module -- VHDX management
- `Mount-DiskImage` -- ISO mounting

### External Dependencies
- **Netboot.xyz**: Clonezilla and generic network tools
- **Purdue RCAC Mirror**: Primary package mirror
- **RPM Fusion**: NVIDIA and Steam repos for Fedora
- **AUR**: Arch User Repository (via yay) for additional packages

## Technical Constraints

### Network Requirements
- Gigabit Ethernet recommended for smooth ISO booting
- iSCSI boot requires stable network connection
- DHCP must support next-server (PXE relay) configuration

### Hardware Requirements
- UEFI firmware recommended (legacy BIOS supported via `undionly.kpxe`)
- TPM 2.0 bypassed for Windows 11 netboot
- Secure Boot not explicitly handled (may need disabled)
- Minimum 8GB RAM recommended for Windows 11 netboot

### File System Constraints
- VHDX dynamically expands to configured size (default 128GB)
- DISM scratch space must be adequate for cumulative updates
- ISO files served over HTTP can be several GB each

## Tool Usage Patterns

### Version Scraping Pattern
```bash
# Scrape latest version from mirror
get_<distro>_version() {
    curl -sL "<mirror-url>" | grep -oP 'href="\K[\d\.]+(?=/")' | sort -rV | head -n 1
}
```

### Driver Injection Pattern
```powershell
# Download, extract, inject drivers
& $script.FullName -DownloadPath $driverTempPath -Architecture x64
dism.exe /Image:$winDrivePath /Add-Driver /Driver:$driverTempPath /Recurse
```

### Registry Modification Pattern
```powershell
# Load offline hive, modify, unload
reg load "HKLM\$tempHiveName" "$sysHivePath"
Set-ItemProperty -Path "HKLM:\$tempHiveName\$cs\Services\$service" -Name "Start" -Value 0
reg unload "HKLM\$tempHiveName"