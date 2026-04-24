# System Patterns

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      PXE Boot Server                             │
│  (Linux host with /srv/http/pxe and /srv/tftp)                   │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │  HTTP Server  │  │   TFTP Server │  │   DHCP Server        │   │
│  │  /srv/http/pxe│  │  /srv/tftp   │  │   (pxe.ipxe entry)   │   │
│  │              │  │              │  │                      │   │
│  │  bg.png      │  │  ipxe.efi    │  │  → chain http://.../ │   │
│  │  default.ipxe│  │  undionly.kpxe│ │    /pxe/default.ipxe │   │
│  │  vmlinuz-*   │  │  ipxe-arm64  │  │                      │   │
│  │  initramfs*  │  │              │  │                      │   │
│  │  arch/       │  │              │  │                      │   │
│  │  win11/      │  │              │  │                      │   │
│  │  archiso/    │  │              │  │                      │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                            │
                            │ Network Boot
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Client Machine                              │
│                                                                  │
│  1. DHCP → gets IP + TFTP server info                            │
│  2. TFTP → downloads ipxe.efi / undionly.kpxe                   │
│  3. iPXE → downloads default.ipxe via HTTP                       │
│  4. User selects from menu                                       │
│  5. Boot selected OS (live ISO, iSCSI, etc.)                    │
└─────────────────────────────────────────────────────────────────┘
```

## Key Technical Decisions

### iPXE as Boot Protocol
- iPXE supports HTTP, iSCSI, and chain loading -- far more capable than traditional PXE
- Uses `snponly.efi` for UEFI systems for better hardware compatibility (SVMPI/NVM driver)
- Separate binaries for x86_64 (`ipxe.efi`), legacy (`undionly.kpxe`), and ARM64 (`ipxe-arm64.efi`)

### HTTP-Based ISO Booting
- Linux distros boot from ISO files on HTTP server (no need to download ISOs locally)
- Fedora/Rocky use `root=live:http://...` kernel parameter
- Debian uses netboot.xyz squashfs approach with `fetch=` parameter
- Arch Linux uses extracted kernel/initrd with `archiso_http_srv=` parameter

### iSCSI Boot for Windows 11
- Windows 11 runs from a VHDX file served over iSCSI
- Uses iSCSI Boot from Firmware (iBFT) support
- Registry modifications promote iSCSI and NIC drivers to boot start (Start=0)
- SAN Policy 4 brings iSCSI disk online while keeping others offline

### Antigravity for Configuration
- Declarative YAML profiles apply consistent configuration post-install
- Supports package installation, file copying, and service management
- Provider-specific packages (yay for Arch, winget for Windows)
- Conditional actions with `where:` clauses

### Mirror Strategy
- Purdue RCAC (plug-mirror.rcac.purdue.edu) as primary mirror for all distros
- Consistent download speeds and reliability for US academic networks
- Fedora uses RIT mirror for version detection

## Component Relationships

```
update-pxe-images.sh
├── Downloads iPXE binaries (if ENABLE_TFTP_BOOTSTRAP)
├── Downloads bg.png for console
├── Copies local Arch kernel/initrd (if ENABLE_LOCAL_ARCH)
├── Scrapes versions from mirrors
│   ├── Debian: parses cd image listing
│   ├── Fedora: checks Workstation/Spins directories
│   └── Rocky: checks Live directory
└── Generates default.ipxe with dynamic menu items

build_archiso.sh
├── Creates profile from /usr/share/archiso/configs/releng
├── Adds custom packages to packages.x86_64
├── Configures pacman mirror (RCAC Purdue)
├── Injects desktop selection systemd generator
├── Builds ISO with mkarchiso
└── Extracts kernel/initrd/airootfs.sfs to PXE directory

build_win11pxe.ps1
├── Creates dynamically expanding VHDX
├── Applies Windows image from ISO via DISM
├── Optionally injects drivers (Get-*Drivers.ps1 scripts)
├── Optionally injects cumulative updates
├── Writes UEFI boot files with bcdboot
├── Modifies offline registry for iSCSI boot
├── Configures OOBE (local account, privacy bypasses)
└── Creates unattend.xml for automated setup
```

## Critical Implementation Paths

### Adding a New Linux Distro to PXE Menu
1. Add version scraping function in `update-pxe-images.sh`
2. Add x86_64 and ARM64 menu items in the generated `default.ipxe`
3. Add boot labels with kernel/initrd parameters
4. Set appropriate `ENABLE_*` flag if needed

### Adding Drivers to Windows 11 Netboot
1. Create `Get-<Vendor>Drivers.ps1` script
2. Script downloads driver packages and extracts INF files
3. `build_win11pxe.ps1` runs all `Get-*Drivers.ps1` scripts when `-Drivers` flag is set
4. Drivers injected via `dism.exe /Add-Driver`

### Adding a Desktop Environment to Arch ISO
1. Add DE packages to `packages.x86_64` in `build_archiso.sh`
2. Add DM service to `archiso-desktop-generator`
3. Add autologin config to `configure-desktop.sh`
4. Add menu item to `update-pxe-images.sh`