# Progress

## What Works

### PXE Boot Infrastructure
- [x] iPXE boot menu with x86_64 and ARM64 support
- [x] Dynamic version scraping for Debian, Fedora, Rocky Linux
- [x] HTTP-based ISO booting for multiple distributions
- [x] Netboot.xyz integration for Clonezilla and network tools
- [x] Background image and console configuration
- [x] Configurable feature flags for menu items

### Arch Linux
- [x] Custom ISO builder with multiple desktop environments (GNOME, KDE, XFCE, Sway, Enlightenment)
- [x] Desktop selection via systemd generator
- [x] Autologin configuration for all desktops
- [x] Kernel/initrd extraction for PXE booting
- [x] airootfs.sfs for HTTP boot
- [x] Antigravity workstation profile with comprehensive package list

### Fedora Linux
- [x] Antigravity workstation profile with DNF-based package management
- [x] COPR repository integration (tributary)
- [x] RPM Fusion setup (free/nonfree)
- [x] Flatpak integration with pre-installed games
- [x] Repository configs for VSCodium, Google Chrome

### Windows 11
- [x] VHDX builder with UEFI partition layout
- [x] DISM-based image application
- [x] Driver injection from multiple vendors (Intel, Realtek, Marvell, MediaTek, Qualcomm)
- [x] Cumulative update injection with dependency resolution
- [x] iSCSI boot registry configuration
- [x] TPM/SecureBoot/RAM bypass via LabConfig
- [x] OOBE configuration (local account, privacy bypasses)
- [x] Unattend.xml for automated setup
- [x] Network power management scripts
- [x] Antigravity workstation profile with winget packages

### Helper Scripts
- [x] Driver scrapers for all major NIC vendors
- [x] Hyper-V enablement script for Windows 11 Home
- [x] OpenSSH enablement script for Windows 11
- [x] Mellanox firmware flash script

## What's Left to Build

### Potential Enhancements
- [ ] ARM64 Linux distro support is partially implemented (version scraping returns empty for many distros)
- [ ] Custom ArchISO menu (`ENABLE_CUSTOM_ARCHISO`) needs build_artifacts in PXE directory
- [ ] More desktop environments could be added to Arch ISO (i3, sway, enlightenment fully implemented)
- [ ] Windows 11 ARM64 netboot support
- [ ] Automated testing pipeline
- [ ] Documentation for end-user setup

### Known Issues
- Windows 11 Home requires workaround script for Hyper-V enablement
- Some AUR packages in Arch profile may require manual intervention during yay installation
- DISM cumulative update injection can fail with checkpoint dependency issues
- Net power management script runs on first boot only (scheduled task may conflict)

### Evolution of Project Decisions
- **2024**: Project started with basic iPXE menu for Arch Linux
- **Decision**: Switched from xz to zstd compression for faster ISO builds
- **Decision**: Use `snponly.efi` instead of stock `ipxe.efi` for better UEFI compatibility
- **Decision**: Adopted Antigravity over Ansible for simpler declarative configuration
- **Decision**: Purdue RCAC mirror chosen for consistent US-based download speeds
- **2025**: Windows 11 iSCSI boot added for lab environments
- **Decision**: Registry-based iSCSI driver promotion instead of injecting drivers into Windows image
- **2025-2026**: Expanded to support Fedora, Debian, Rocky Linux in PXE menu
- **Decision**: Version scraping from mirrors instead of hardcoded versions for automatic updates