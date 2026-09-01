# lan-ipxe

A personal homelab network-boot environment: iPXE menu generation for live-booting
Linux distros over the LAN, a custom Arch Linux live image, a Windows 11 iSCSI-boot
image builder, idempotent workstation setup scripts, and Mellanox NIC firmware tooling.

## Architecture

Three roles, three sets of scripts:

| Host | Role | Runs |
|---|---|---|
| PXE server (Fedora Linux, `192.168.1.11`) | TFTP (`/srv/tftp`), HTTP on `:81` (`/srv/http/pxe`), iSCSI target (LIO/targetcli) | `update-pxe-images.sh`, `build_archiso.sh` |
| Windows build machine | Builds the Win11 iSCSI boot image | `build_win11pxe.ps1` + the `Get-*.ps1` scrapers |
| Clients | UEFI/BIOS PXE boot into the generated menu | — |

Boot flow: DHCP → TFTP (`ipxe.efi` / `undionly.kpxe`) → `default.ipxe` menu →
live boot from public mirrors / netboot.xyz assets / local HTTP artifacts /
Windows 11 via iSCSI `sanboot`.

## Components

### PXE menu generator — `update-pxe-images.sh`

Scrapes the Purdue PLUG mirror for the current Debian, Fedora, Rocky, and Ubuntu LTS
live ISOs (x86_64 and ARM64), resolves matching netboot.xyz kernel/initrd release
assets via the GitHub API, and generates `/srv/tftp/default.ipxe` with per-distro
menu entries plus Clonezilla, netboot.xyz, and an iPXE shell. Finishes with a
HEAD-check pass over the embedded URLs.

Feature toggles (edit the variables at the top of the script):

- `ENABLE_TFTP_BOOTSTRAP` — download iPXE binaries (`snponly.efi` saved as
  `ipxe.efi`, `undionly.kpxe`, ARM64 EFI) into the TFTP dir.
- `ENABLE_LOCAL_ARCH` — copy a local Arch kernel/initramfs from `/srv/arch` and add
  an NBD-root boot entry.
- `ENABLE_CUSTOM_ARCHISO` — add menu entries for the custom archiso image (below).
- `ENABLE_WIN11_PXE` — add the Windows 11 iSCSI `sanboot` entry.

If `/srv/http/pxe` or `/srv/tftp` is not writable (e.g. run without root), the script
falls back to `./pxe_test/` — useful as a dry run.

### Windows 11 iSCSI boot ("Win2Go") — `build_win11pxe.ps1`

Run as Administrator with PowerShell 7 on a Windows machine:

```powershell
.\build_win11pxe.ps1 -IsoPath .\Win11_25H2_English_x64.iso -OutPath .\win11_netboot.vhdx -ImageIndex 6 [-Drivers] [-Updates]
```

Creates a dynamic VHDX (GPT: ESP / MSR / NTFS), applies the Windows image with DISM,
writes boot files with `bcdboot`, then edits the offline SYSTEM/SOFTWARE hives:
promotes iSCSI/NIC/storage services to boot-start, sets the SAN policy, disables
BitLocker auto-encryption, injects LabConfig hardware-check bypasses and `BypassNRO`,
and drops an `unattend.xml` (local `lan` admin account with autologon) plus a
`SetupComplete.cmd` that disables NIC power management.

- `-Drivers` runs every NIC/Wi-Fi `Get-*Drivers.ps1` scraper in parallel (the
  `Get-*GraphicsDrivers.ps1` shims are excluded — see `-GraphicsDrivers`) and injects
  the results with `DISM /Add-Driver`.
- `-GraphicsDrivers Intel|AMD|NVIDIA|All` additionally injects GPU display drivers
  (also catalog-sourced) into the same image. GPU CABs are large (~0.6–1.2 GB each),
  so it is opt-in and separate from `-Drivers`; `All` injects the ~3–5 GB union of all
  three vendors, so prefer a single vendor matching the target machine. GPU drivers are
  post-boot-only (a GPU never serves iSCSI boot), so they get plain `DISM /Add-Driver`
  with **no** boot-start promotion. A bare INF install yields a fully accelerated driver
  (incl. the OpenGL/Vulkan/OpenCL/D3D and CUDA/NVENC runtimes); the vendor control-panel
  apps (NVIDIA App, AMD Adrenalin, Intel Graphics Software — all Microsoft Store) are not
  installed, and Radeon Pro cards get the base WHQL driver, not the ISV-certified PRO
  Edition. x64 only (discrete GPUs have no ARM64 Windows driver; Qualcomm Adreno is not
  on the catalog). The same shims run standalone on a live system (`-Install` → `pnputil`).
- `-Updates` runs `Get-Win11CumulativeUpdates.ps1` and injects the latest cumulative
  update (with checkpoint prerequisites) via folder-based `DISM /Add-Package`.

**Serving the image:** convert the VHDX to a raw image first
(`qemu-img convert -f vhdx -O raw win11_netboot.vhdx win11.img`) and expose it as an
LIO/targetcli backstore behind `iqn.2026-02.lan.pxe:win11`. LIO serves file bytes
raw — it does not parse the VHDX container. The targetcli configuration itself is
not versioned in this repo.

**Boot NIC (`-BootAdapterGuid`):** a DISM-applied image has never run PnP, so its
boot NIC exists only as a Services key and the kernel cannot bind it at boot —
the classic `0x7B INACCESSIBLE_BOOT_DEVICE` over iSCSI. The script fixes this with
the offline `DISM /Add-NetAdapter` verb (the same one Windows Setup runs when it
detects an iBFT), which needs the boot NIC's adapter GUID:

```powershell
# on a machine / WinPE where that NIC is live:
wmic nic get GUID,Name,ServiceName
# then:
.\build_win11pxe.ps1 -IsoPath ... -Drivers -Updates -BootAdapterGuid '{GUID}'
```

Without `-BootAdapterGuid` the script warns and the image will almost certainly
`0x7B`. **Deferred:** auto-detecting/validating the correct adapter from hardware
IDs is not yet implemented — the GUID is supplied by hand for now. If
`/Add-NetAdapter` is unavailable on your DISM build, install Windows by booting
Setup over the `sanhook`'d LUN instead (see the notes block at the end of
`build_win11pxe.ps1`).

Driver/update scrapers (Microsoft Update Catalog):

| Script | Covers |
|---|---|
| `Get-IntelEthernetDrivers.ps1` | Intel I210/I219/I225/I226, X540/X550, X710, E810, AVF |
| `Get-RealtekEthernetDrivers.ps1` | RTL8125/8126/8127/8168 PCIe, RTL8153/8156/8157 USB |
| `Get-MarvellEthernetDrivers.ps1` | Aquantia/Marvell AQC107/AQC113 PCIe, AQC111U USB |
| `Get-IntelWiFiDrivers.ps1` | Intel Wi-Fi 6/6E/7 (post-boot convenience) |
| `Get-MediatekWiFiDrivers.ps1` | MediaTek MT79xx Wi-Fi (post-boot convenience) |
| `Get-QualcommWiFiDrivers.ps1` | Qualcomm WCN/FastConnect Wi-Fi (post-boot convenience) |
| `Get-IntelGraphicsDrivers.ps1` | Intel Arc / Iris Xe / UHD GPU (post-boot convenience) |
| `Get-NvidiaGraphicsDrivers.ps1` | NVIDIA GeForce + RTX/Quadro GPU (post-boot convenience) |
| `Get-AmdGraphicsDrivers.ps1` | AMD Radeon RX + Radeon Pro GPU (post-boot convenience) |
| `Get-Win11CumulativeUpdates.ps1` | Latest monthly CU + checkpoint chain + SSU per Windows version |

**Status:** the `0x7B INACCESSIBLE_BOOT_DEVICE` failure (DISM apply + service-key
edits load the NIC driver but never PnP-*install* it) is addressed by the
`-BootAdapterGuid` / `DISM /Add-NetAdapter` step described above. Supplying the boot
NIC's adapter GUID is currently a manual step (auto-detection deferred); if the
verb is unavailable on your DISM build, fall back to installing via Setup over the
iBFT-attached LUN.

### Custom Arch live image — `build_archiso.sh`

Run as root on an Arch system with `archiso` installed. Clones the releng profile,
applies customizations (local pacman.conf, zstd squashfs, `archlinux-custom` ISO
name, a large multi-desktop package set), and injects a systemd generator +
`configure-desktop.sh` that enable exactly one desktop environment per boot based on
the `desktop=` kernel argument (gnome, kde, xfce, sway, enlightenment — selected by
the corresponding iPXE menu entry). Outputs the ISO plus extracted
`vmlinuz-linux` / `initramfs-linux.img` / `airootfs.sfs` into `/srv/http/pxe/archiso`
(or `./archiso` when not on the server) for HTTP PXE boot.

### Workstation provisioning — `setup-*-workstation.*`

One convergent script per platform, safe to re-run at any time. Package-manager
refreshes and updates still run where the platform requires them (notably Arch's full
`pacman -Syu` and AUR update). They replaced the earlier comtrya manifests; comtrya is
unmaintained upstream. Run from any directory: the Linux scripts resolve their config
payloads (`files/`) relative to their own location.

- `setup-arch-workstation.sh` — run as your normal user; sudo is used for the
  privileged steps (AUR builds refuse to run as root). Requires an existing GRUB
  installation, safely enables `[multilib]`, runs `pacman -Syu`, installs the official
  package set and detected Intel/AMD microcode, installs dotfiles/system config and
  zram policy from `files/`, explicitly generates and validates every dracut image
  before removing mkinitcpio, then enables services and GDM settings. AUR work is last:
  a self-bootstrapped `yay` interactively presents PKGBUILD diffs, updates installed
  AUR packages, and installs the requested set. Arch's signed repositories provide
  Code OSS, OpenCode, Codex CLI, and Zed; the AUR supplies Claude Code and the native
  Antigravity 2.x desktop/CLI. The script removes VSCodium, Antigravity IDE, and an
  installed Antigravity 1.x package before installing their replacements. The package
  selection intentionally includes Intel/AMD graphics support and NVIDIA open modules
  for both `linux` and `linux-lts`.
- `setup-fedora-workstation.sh` — run as your normal user; Fedora 41+ (dnf5). Adds the
  signed third-party repos (`files/etc/yum.repos.d/`, the tributary copr, RPM Fusion,
  Microsoft VS Code/PowerShell, Claude Code, sing-box; Chrome/NVIDIA/Steam repos on
  x86_64), installs the dnf and flatpak sets (plus the x86_64-only 32-bit/Steam/Chrome
  extras), and installs Zed plus native AI tools. Antigravity 2.x and its CLI,
  OpenCode, and Zed use immutable checksum-pinned native artifacts; Codex uses OpenAI's
  checksum-verifying standalone installer; Claude Code uses Anthropic's signed RPM
  repository. The abandoned unsigned Antigravity 1.x RPM/repository, its exact
  script-managed IDE settings, and VSCodium are removed, while customized settings or
  repo files are preserved (and retired repos disabled). The script also installs a
  checksum-pinned Ookla speedtest CLI and the r8152 USB NIC driver from a pinned
  upstream revision via DKMS, then applies dotfiles, zram policy, services, and GDM
  settings. Secure Boot hosts are warned when the DKMS MOK still needs enrollment.
- `setup-win11-workstation.ps1` — run from an elevated PowerShell (5.1 is enough):
  `powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1`. Sets up
  OpenSSH Server via `enable-openssh-win11.ps1`, then installs the winget package set.
  Antigravity 2.x/CLI, Claude Code, Codex, OpenCode, and Zed are checked for upgrades
  on every run; Antigravity IDE and VSCodium are removed, with Microsoft VS Code kept
  as the supported Windows editor. One `winget export` snapshot decides the remaining
  state; "already installed" / "reboot required" results count as success, any other
  failure is reported at the end (exit code 1) without stopping the run. `-HyperV`
  additionally enables the supported Windows optional feature on Pro, Enterprise, or
  Education; Windows 11 Home is rejected.

Missing package-set entries are installed and existing Arch/AUR packages are updated.
Config files are rewritten only when their content, type, mode, or ownership differs;
follow-ups (`grub-mkconfig`, `sysctl`, `dconf update`, DKMS/dracut builds) run only when
their inputs or validation require them. Workstation zram uses zstd, priority 100, and
`min(RAM, 8 GiB)`. Linux systemd services are enabled, not started, and come up on the
next boot. The Windows OpenSSH helper starts `sshd` immediately and opens Microsoft's
standard inbound TCP/22 firewall rule on all profiles; narrow that rule separately if
the workstation's policy requires it.

Windows helpers (called by `setup-win11-workstation.ps1`, also usable standalone):

- `enable-openssh-win11.ps1` — installs the OpenSSH Server capability, starts/enables
  `sshd`, ensures the firewall rule, sets PowerShell as the default SSH shell.
- `enable-hyperv-win11.ps1` — enables Hyper-V through the supported optional-feature
  API on eligible Windows editions and refuses the unsupported Windows 11 Home hack.

### `files/` — config payloads

Dotfiles and system config consumed by the workstation setup scripts: `bashrc`,
`vimrc`, `grub` defaults, `etc/locale.conf`, `etc/sysctl.d/99-inotify.conf`,
`etc/systemd/zram-generator.conf`,
`etc/cron.daily/pacman-update` (unattended Arch updates + reboot scheduling),
`etc/dconf/db/gdm.d/10-font-settings`, Fedora repo definitions under
`etc/yum.repos.d/`, and the Fedora Antigravity desktop entry under
`usr/share/applications/`. `etc/pacman.conf` is kept for reference only — the Arch
script deliberately does not install it.

### Mellanox firmware tool — `mlnx-fw-flash-update.sh`

Interactive detector/cross-flasher for ConnectX-3 through ConnectX-7 NICs. Queries
devices with `mstflint`, downloads stock NVIDIA firmware, flashes (including
OEM→stock cross-flash with `-allow_psid_change` after explicit confirmation), and
configures UEFI/legacy boot ROM options via `mstconfig`. Requires root, `mstflint`,
and `pciutils`. **Firmware flashing is inherently risky — read every prompt.**

## Typical run order

1. One-time: point DHCP at the TFTP server (`ipxe.efi` for UEFI, `undionly.kpxe` for
   BIOS); set `ENABLE_TFTP_BOOTSTRAP=true` for the first run to fetch the binaries.
2. Periodically (cron or manual): `./update-pxe-images.sh` on the server to refresh
   distro versions and regenerate the menu.
3. Optional: `sudo ./build_archiso.sh` to rebuild the custom Arch image; enable
   `ENABLE_CUSTOM_ARCHISO`.
4. Optional: build the Win11 VHDX on the Windows machine, convert to raw, configure
   the iSCSI target, enable `ENABLE_WIN11_PXE`.
5. After installing an OS on a workstation: run the matching
   `setup-*-workstation.*` script (re-run any time to converge).

## Notes

- `update-pxe-images.sh` writes to the live server paths and needs root; pass
  `--test` (or `DRY_RUN=true`) to generate into `./pxe_test/` instead. It publishes
  `default.ipxe` atomically and keeps a `.bak` of the previous menu. Set
  `GITHUB_TOKEN` to avoid the 60-req/hr unauthenticated GitHub API rate limit.
- CI discovers every Bash and PowerShell/data file instead of relying on a hand-kept
  list. It runs actionlint on workflows, Bash syntax + ShellCheck, PowerShell parsing +
  PSScriptAnalyzer with a no-growth warning baseline, imports every `.psd1`, and
  parses/tests the Windows workstation helpers under both PowerShell Core and an
  actual Windows PowerShell 5.1 runner. It
  also runs the catalog, WinGet-inventory, Hyper-V state, file-convergence, Arch
  kernel-reboot, and zram-generator tests under `tests/`. The test scripts can be run
  locally; the zram test requires `systemd-zram-generator` and the static checks
  require ShellCheck and PSScriptAnalyzer 1.25.0.
- Build artifacts (`*.vhdx`, `*.iso`, `*.img`, `*.raw`, `pxe_test/`, `archiso/`,
  `custom_archiso/`) are gitignored.
- Server address/ports, mirror URLs, and the iSCSI IQN namespace
  (`iqn.2026-02.lan.pxe`) are currently hard-coded constants at the top of
  `update-pxe-images.sh` and inside the Win11 stanza.
- The Win11 image intentionally trades security for LAN convenience (blank-password
  autologon admin, hardware-check bypasses, no CHAP on the target) — do not expose
  any of this beyond a trusted network.
