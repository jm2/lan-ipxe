# Product Context

## Why This Project Exists
Setting up development/workstation machines in a lab or office environment is tedious. Each machine requires manual OS installation, driver configuration, software installation, and system tuning. This project automates and centralizes that entire workflow through network booting and declarative configuration.

## Problems It Solves
1. **Manual OS Installation**: No need to burn USBs or configure boot media -- boot directly over the network
2. **Driver Management**: Windows driver scraping automatically fetches the latest NIC drivers for reliable network booting
3. **Post-Install Configuration**: Antigravity profiles apply consistent configuration across all workstations
4. **Multi-OS Support**: Single PXE menu for Arch, Fedora, Debian, Rocky, and Windows 11
5. **ARM64 Support**: PXE menu includes ARM64 options for Apple Silicon and ARM servers

## How It Works
1. **PXE Boot**: Client boots via DHCP/TFTP to iPXE, which presents a menu
2. **OS Selection**: User selects an OS from the menu
3. **Live/Install**: Linux distros boot live and install; Windows 11 boots as a network iSCSI session
4. **Configuration**: After installation, Antigravity YAML profiles apply workstation configuration
5. **Image Updates**: `update-pxe-images.sh` scrapes mirrors for latest versions and regenerates the iPXE menu

## User Experience Goals
- **Zero-Touch Booting**: Boot from network, select from menu, no USB media needed
- **Auto-Configuration**: Post-install configuration applied automatically via Antigravity
- **Multi-Desktop Support**: Arch ISO supports GNOME, KDE, XFCE, Sway, and Enlightenment
- **Verbose Diagnostics**: Windows builds enable SOS mode and boot logging for troubleshooting
- **Local Account Setup**: Windows OOBE configured for local account, no Microsoft account required

## Key Design Decisions
- Uses Purdue RCAC mirror for all package downloads (US academic institution)
- iPXE binaries use `snponly.efi` for better UEFI keyboard/GOP compatibility
- Windows VHDX uses iSCSI boot with SAN Policy 4 (OfflineInternal) for lab flexibility
- zstd compression for Arch ISO builds (faster than xz)
- Rootless zswap disabled (`zswap.enabled=0`) for consistent performance