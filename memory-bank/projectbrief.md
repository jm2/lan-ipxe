# LAN iPXE Project Brief

## Project Overview
A comprehensive network booting and workstation provisioning system that enables:
- PXE/network booting of multiple Linux distributions (Arch Linux, Fedora, Debian, Rocky Linux)
- Windows 11 network boot via iSCSI (Win2Go)
- Automated workstation configuration using [Antigravity](https://github.com/antigravity/antigravity) YAML profiles
- Driver scraping and injection for Windows 11 netboot images

## Core Goals
1. Provide a centralized PXE boot menu for lab/workstation provisioning
2. Automate operating system installation and configuration across platforms
3. Support both x86_64 and ARM64 architectures
4. Enable network-bootable Windows 11 for lab environments
5. Streamline workstation setup with declarative configuration profiles

## Key Components
- **PXE Boot Infrastructure**: iPXE-based boot menu with HTTP and TFTP support
- **Arch ISO Builder**: Custom Arch Linux ISO with multiple desktop environments
- **Windows 11 PXE Builder**: Creates iSCSI-bootable VHDX from Windows 11 ISO
- **Workstation Profiles**: Antigravity YAML files for post-install configuration
- **Driver Scrapers**: PowerShell scripts to download Intel, Realtek, Marvell, MediaTek, Qualcomm drivers

## Technology Stack
- iPXE for network booting
- archiso for custom Arch Linux ISO building
- DISM/bcdboot for Windows image manipulation
- Antigravity for declarative system configuration
- PowerShell and Bash for automation scripts

## Output Artifacts
- iPXE boot menu (`default.ipxe`)
- Custom Arch Linux ISO with kernel/initrd
- Windows 11 netboot VHDX
- Configured workstation installations