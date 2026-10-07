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
`SetupComplete.cmd` that disables supported NIC sleep features without restarting adapters.
The helper logs errors to `%SystemRoot%\Logs\DisableNetPower.log`; SetupComplete
logs to `DisableNetPower-setup.log` in the same directory. OEM-keyed editions can
skip SetupComplete, so confirm execution on the target.

- `-Drivers` runs every NIC/Wi-Fi `Get-*Drivers.ps1` scraper in parallel (the
  `Get-*GraphicsDrivers.ps1` shims are excluded — see `-GraphicsDrivers`) and injects
  the results with `DISM /Add-Driver`.
- `-DriverPath .\drivers\boot-nic` injects extracted, tested driver packages from a
  local directory (recursively) or an individual INF. Multiple paths are allowed.
  Use it instead of `-Drivers` to avoid changing the NIC package on each catalog
  refresh; it can still be combined with `-GraphicsDrivers`. The original driver
  directory is never deleted. DISM servicing failures stop the build.
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

**Boot NIC (`-BootAdapterGuid`):** optionally run the undocumented DISM
`/Add-NetAdapter` operation. The adapter must be present with a working driver in
**the Windows session running this builder**. A GUID from another machine or a
previous WinPE session is not a portable hardware identifier. Invalid/missing
host adapters fail validation before a VHDX is created; a failed requested DISM
operation stops the build.

```powershell
# Run on the build host; select the intended NIC rather than the first result:
Get-CimInstance Win32_NetworkAdapter | Select-Object GUID,Name,ServiceName
.\build_win11pxe.ps1 -IsoPath .\Win11_25H2_English_x64.iso -DriverPath .\drivers\boot-nic -BootAdapterGuid '{GUID}'
```

GUID-less builds remain available with boot-NIC preparation marked **unverified**.
Windows can enumerate new hardware during first boot; missing pre-existing PnP
entries alone do not prove failure. Driver staging and the fallback service table
also do not prove iSCSI first-boot compatibility. Different `.sys` binaries with
the same filename now stop fallback service creation instead of selecting the
first file found; byte-identical duplicates are accepted. The fallback still
cannot reproduce arbitrary INF/WDF/device installation requirements.

**Output and diagnostics:** builds use a unique temporary VHDX beside `-OutPath`.
The previous output is replaced only after image preparation, registry hive
unloads and image dismounts succeed. Failed builds retain their temporary VHDX
for inspection; a hive-unload failure deliberately leaves that disk attached.
Each run writes `<OutPath>.<build-id>.build.json` and a DISM log alongside the
output. The report includes source/serviced Windows versions, NIC package
versions, native DISM results, service paths, start overrides and warnings.
`Complete` means the build and cleanup succeeded, **not** that hardware boot was
tested; `ColdBootValidated` remains false. Keep the matching report when copying
an image. The large failed temporary images can be removed after inspection and
successful hive/disk cleanup.

**PXE interface selection:** the Windows menu entry tries interfaces `net0` through
`net63` individually, preserving existing IPv4 settings and using DHCP only when
an interface lacks an address. A successful iSCSI attachment identifies the NIC
whose MAC supplies the initiator IQN. For ordinary subnet/default-gateway routing,
it first tests attachment without a gateway; failure restores the gateway and
tries routed access. DHCP option 121 routes bypass this workaround because a
no-gateway probe would not establish on-link access. Each client's ACL must map
LUN 0 to a separate writable backstore; unique initiator IQNs alone do not isolate
NTFS volumes. The entry closes other iPXE interfaces to prevent ambiguous routing.

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

**Status:** offline build hardening is implemented; first boot, OOBE and subsequent
cold boots still require testing on the intended NIC, firmware and Windows build.
There is no automatic WinPE provisioning stage. If offline NIC preparation is
insufficient, Setup over an iBFT-attached LUN remains an alternative.

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

One convergent script per platform. Package-manager
refreshes and updates normally run on each pass (including Arch's full `pacman -Syu` and AUR
update). They replaced the earlier comtrya manifests; comtrya is
unmaintained upstream. Run from any directory: the Linux scripts resolve their config
payloads (`files/`) relative to their own location.

macOS now has `setup-macos-workstation.sh`, targeting native Apple Silicon on
macOS 26 and macOS 27. Its default **core** profile includes Linux CLI parity, **wget and Go**,
Python/Rust, everyday apps and the portable Bash configuration. **Full** adds
large toolchains, Java/Maven/Gradle, stable Android SDK/build-tools/NDK, optional
apps and games. All Store apps and supplemental game-data downloads are excluded.
Full prints the per-engine data directories to populate manually.

Start with `./setup-macos-workstation.sh --dry-run` or `--check`; both are offline
and read-only. Apply as the console user with no arguments for core, or
`--profile full`. `--no-upgrade` retains installed versions; Xcode selection,
Sharing and power settings each require their explicit `--with-*` flag.
Exit codes are 0 for satisfied/dry-run, 1 for failures and 2 for drift/manual work.
See the [macOS guide](docs/macos-workstation.md), [approved plan](docs/setup-macos-workstation-plan.md)
and [package comparison](docs/macos-package-parity.md) for ownership, exclusions,
manual steps and validation limits. Initial validation uses mocked tests and
read-only previews; a clean-machine installation smoke test remains outstanding.

Every workstation script takes the same profile and mode options (PowerShell spells
them `-Profile`, `-Check`, `-DryRun`, `-NoUpgrade`):

- `--profile core|full` — core (the default) installs every developer toolchain,
  editor, AI agent, and everyday app; full adds games and media servers/apps.
  Switching a machine from full to core removes nothing.
- `--dry-run` — offline, read-only plan for the selected profile (no sudo, network, or
  writes); exits 0.
- `--check` — read-only state report (`CURRENT`/`DRIFT`); exits 0 when converged, 2 on
  drift, 1 on error.
- `--no-upgrade` — install what is missing without upgrading what is already
  installed. On Arch this refuses without existing sync databases and warns that it is
  a partial upgrade.
- `--wazuh-manager HOST` (Linux scripts, or `WAZUH_MANAGER`) — configure and start the
  Wazuh agent against that manager. Without it the agent is installed but left
  disabled: no manager exists yet, and an agent newer than its manager cannot connect.

Every platform installs Balun alongside Tributary in core (`balun` from the
`jmsqrd/balun` COPR on Fedora, `balun-bin` from the AUR on Arch, release apps on macOS
and Windows). Fedora and Arch also install Cockpit with file management, package
updates, Podman containers, and storage/LVM support, and start `cockpit.socket` for access at `https://localhost:9090`.

- `setup-arch-workstation.sh` — run as your normal user; sudo is used for the
  privileged steps (AUR builds refuse to run as root). Requires an existing GRUB
  installation, safely enables `[multilib]`, runs `pacman -Syu`, installs the official
  package set and detected Intel/AMD microcode, installs dotfiles/system config and
  zram policy from `files/`, explicitly generates and validates every dracut image
  before removing mkinitcpio, then enables services and GDM settings. The AI tools then
  come from self-updating native installs, as on Fedora: the Antigravity 2.0+ AppImage
  (user-owned under `/opt/Antigravity`, mounted through `fuse2`) and its CLI from the
  checksummed vendor manifests, and Claude Code and Codex CLI from their official
  installers under `~/.local/bin`; reruns keep a copy that updated itself. The
  `antigravity`, `antigravity-cli`, `claude-code`, and `openai-codex` packages they
  replace are removed. AUR work is last: a self-bootstrapped `yay` interactively presents
  PKGBUILD diffs, updates installed AUR packages (including VCS/devel packages), and
  installs the requested set. Arch's signed repositories provide Code OSS, OpenCode,
  and Zed. The script removes VSCodium, Antigravity IDE, and any installed Antigravity
  1.x package before installing their replacements. The package selection intentionally includes Intel/AMD graphics
  support and NVIDIA open modules for both `linux` and `linux-lts`. Rust comes only
  from rustup: an installed distro `rust` (and its split packages) is replaced by
  `rustup`, and each user gets the stable toolchain with rustfmt, clippy, and
  rust-analyzer. `[multilib]` is enabled only by the full profile, which adds Steam,
  Lutris, the lib32 graphics stack, and the AUR games. GNOME uses Vitals for sensors,
  Dash to Dock from the AUR, and the bundled System Monitor extension with `libgtop`.
  The security baseline (see "Workstation security layer" under the Fedora bullet)
  uses the same ClamAV/firewalld/auditd/AIDE/Wazuh pieces with Arch package and unit
  names: `clamav-daemon` on the `/run/clamav/clamd.ctl` socket, `audit` from the
  official repos (the Arch kernel builds `CONFIG_AUDIT=y`, so no GRUB change), and
  `aide` + `wazuh-agent` from the AUR — their privileged setup (AIDE database init,
  Wazuh enablement) runs right after the interactive AUR phase.
- `setup-fedora-workstation.sh` — run as your normal user; Fedora 41+ (dnf5). Adds the
  signed third-party repos (`files/etc/yum.repos.d/`, the Tributary/Balun coprs, RPM Fusion,
  Microsoft VS Code, Chrome, sing-box; the PowerShell repo on x86_64, plus the Steam/Plex
  repos in the full profile), installs the dnf and flatpak sets,
  applies available DNF/Flatpak updates, and installs Zed plus native AI tools. Rust
  comes only from rustup (`rustup-init` per user, stable with rustfmt, clippy, and
  rust-analyzer); installed distro Rust packages are purged first.
  Both x86_64 and aarch64 are supported, including Fedora Asahi's 16K kernel variant.
  DNF reconciles the package/group set directly with visible output and automatic
  confirmation; there is no separate user-cache group query to block on hidden
  repository-key prompts. Chrome and GitHub CLI are installed on both architectures;
  ARM64 PowerShell uses Microsoft's checksum-verified release archive.
  Media servers (full profile only): Plex Media Server comes from Plex's signed
  repository (x86_64 only; Plex publishes no aarch64 RPM), Navidrome from its latest GitHub release RPM, and
  OwnTone from its latest release tarball, built unprivileged into an RPM with
  `files/rpm/owntone.spec`. Navidrome and OwnTone downloads are checked against the
  SHA-256 digests GitHub publishes, and both are skipped when the installed version is
  already current, and their services are enabled. Full also adds Lutris, Steam with its
  i686 libraries (x86_64), the io.jor.* game Flatpaks, and desktop media apps.
  Installs `dnf5-plugin-automatic` and enables `dnf5-automatic.timer` immediately,
  with the controller setup's `apply_updates = yes` and `reboot = when-needed`
  policy in `/etc/dnf/automatic.conf`.
  Antigravity 2.0+ and its CLI, OpenCode, and Zed resolve the latest stable native
  artifacts and their published checksums on each run; Codex and Claude Code use
  OpenAI's and Anthropic's checksum-verifying native installers under `~/.local/bin`.
  Antigravity, its CLI, Claude Code, and Codex all update themselves in place. The
  Antigravity AppImage under `/opt/Antigravity` is owned by the desktop user (and
  needs the `fuse` package's `fusermount`); reruns keep a self-updated AppImage or
  `agy` that is at least the manifest version, and install the bundled launcher icon.
  The abandoned unsigned Antigravity 1.x RPM/repository, its exact
  script-managed IDE settings, VSCodium, and the retired Claude Code RPM, repository,
  and signing key are removed (the RPM only after the native `claude` is in place), while customized settings or
  repo files are preserved (and retired repos disabled). The script also installs a
  deliberately fixed, checksum-pinned Ookla speedtest CLI, then applies dotfiles, zram
  policy, services, and GDM settings.
  **Workstation security layer** (core profile, Arch gets the same layer with its own
  package/unit names): ClamAV with a light footprint — the freshclam daemon plus a
  one-time `freshclam` database bootstrap, `clamd@scan` with a real LocalSocket,
  notify-only on-access scanning of `~/Downloads` (never all of `/home`; detections
  are logged, nothing is blocked or quarantined), and a `clamav-media-scan` watcher
  service that follows the mount table (`findmnt --poll`) and read-only-scans each
  newly mounted USB/removable filesystem under `/run/media` via
  `clamdscan --fdpass --multiscan --infected` with per-filesystem scan stamps (each
  distinct filesystem is scanned once; the journal is the source of truth and desktop
  notifications are best effort). firewalld replaces the permissive stock
  FedoraWorkstation default: a custom `workstation` zone keeps SSH and Plex Remote
  Access (32400/tcp only) broadly reachable (WAN port forwarding is in use) and
  rejects everything else, while the
  source-bound `workstation-lan` zone (192.168.1.0/24 + SD-WAN 192.168.2.0/23) opens
  SSH (firewalld puts each packet in exactly one zone, so LAN peers never fall
  through to the default zone) plus the LAN services — Cockpit, GNOME Remote
  Desktop, mDNS/printer discovery, iperf3, and the hand-run LanCache (HTTP/HTTPS/DNS),
  NFS (with mountd/rpcbind) and Samba in every profile; Navidrome, OwnTone, Plex
  (with its DLNA/GDM ports), Transmission's RPC/peer ports and Steam in-home
  streaming in full. Arch opens the media servers, Transmission and iperf3 in
  every profile because its hosts run them outside the script. auditd runs with curated high-signal rules (identity/auth
  files, sudoers, sshd config, unit/cron/shell-rc persistence, module loading, time
  changes, mounts, auditd itself — no per-execve logging); Fedora's stock
  `-a task,never` rule, which silently disables all syscall auditing, is commented out. AIDE is scoped to
  configuration trees (`/etc`, `/usr/local`, `/root`) because `rpm -Va` already
  verifies packaged files and a whole-tree baseline would drown in nightly-update
  noise; the database is initialized once and a daily timer checks it without
  auto-rebaselining. The Wazuh agent is installed from Wazuh's signed repository
  (GPG key pinned by fingerprint, repo disabled by default so the agent never
  outpaces a future manager) and collects the audit log plus the ClamAV journal
  units — it stays disabled until `--wazuh-manager` is supplied.
- `setup-win11-workstation.ps1` — run from an elevated PowerShell (5.1 is enough):
  `powershell -ExecutionPolicy Bypass -File .\setup-win11-workstation.ps1`
  (`-Check`/`-DryRun` also run unelevated). Sets up
  OpenSSH Server via `enable-openssh-win11.ps1`, then installs the winget package set.
  Every managed package is checked for upgrades on every run unless explicitly marked
  presence-only: the deliberately fixed Speedtest CLI, and the Antigravity app, which
  updates itself. Claude Code, Codex CLI, and the Antigravity CLI come from each
  vendor's official per-user `install.ps1` so they update themselves; once a native
  command runs, the `Anthropic.ClaudeCode`, `OpenAI.Codex`, or `Google.AntigravityCLI`
  WinGet package it replaces is uninstalled. The highest stable Python 3 minor-package channel is resolved from WinGet
  rather than hard-coded. Antigravity IDE and VSCodium are removed, with
  Microsoft VS Code kept as the supported Windows editor. One `winget export` snapshot
  decides the remaining state; `--include-unknown` keeps versionless registrations from
  silently freezing, so those vendor installers may run again. "Already installed" /
  "reboot required" results count as success, and any other failure is reported at the
  end (exit code 1) without stopping the run. `-HyperV`
  additionally enables the supported Windows optional feature on Pro, Enterprise, or
  Education; Windows 11 Home is rejected. Rust comes only from `Rustlang.Rustup`
  (legacy Rust MSI packages are removed). Balun has no WinGet package yet, so it
  installs from its SHA-256-verified GitHub release (silent Inno Setup) and switches to
  `jm2.Balun` automatically once that ID resolves. Full adds Steam, GOG Galaxy, the
  SuperTux games, benchmarks, Plex, iTunes, HDHomeRun, MakeMKV, and Google Drive.

Missing package-set entries are installed and existing Arch/AUR packages are updated.
Config files are rewritten only when their content, type, mode, or ownership differs;
follow-ups (`grub-mkconfig`, `sysctl`, `dconf update`, dracut builds) run only when
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
`etc/dnf/automatic.conf` (Fedora automatic updates + reboot when needed),
`etc/dnf/libdnf5.conf.d/80-protobuf3-c.conf` (Fedora 45 protobuf-c repair),
`etc/dconf/db/gdm.d/10-font-settings`, Fedora repo definitions under
`etc/yum.repos.d/` (including the disabled-by-default `wazuh.repo`), and the Fedora
Antigravity desktop entry under `usr/share/applications/`. `etc/pacman.conf` is kept
for reference only — the Arch script deliberately does not install it.

The workstation security layer also lives here, mirroring its destination paths:
`etc/clamd.d/scan.conf` and `etc/clamav/clamd.conf` (ClamAV daemon configs whose
watched `~/Downloads` directories are generated at apply time, since clamd.conf has
no glob support), the `clamav-clamonacc.service.d/` drop-ins (notify-only on-access:
detections go to the journal; Arch's packaged `--move` quarantine flag is reset),
`etc/systemd/system/clamav-media-scan.service` plus
`usr/local/libexec/clamav-media-scan` (mount watcher that read-only-scans newly
mounted removable media), `etc/firewalld/zones/workstation.xml` and the service
definitions under `etc/firewalld/services/` (the source-bound
`workstation-lan.xml` zone is rendered per profile), `etc/audit/rules.d/50-workstation.rules`, `etc/aide.conf`, and the
`aide-check.{service,timer}` units.

### Untrusted-media malware triage — `scan-untrusted-media.sh`

Read-only triage of untrusted removable media from any platform (Windows,
macOS, iOS/iPadOS/tvOS, Linux, Android) — USB drives, disk images, or
already-mounted directories. Run as your normal
user; privileged steps go through sudo. Fedora 41+ installs missing tools with
dnf; on Arch they must already be present (apfs-fuse is AUR-only).

```bash
scan-untrusted-media.sh --prepare-session          # first, before any drive is plugged in
scan-untrusted-media.sh /dev/sdb                   # scan the drive in place, read-only
scan-untrusted-media.sh --image-dir /data/images /dev/sdb   # image it first, scan the image
scan-untrusted-media.sh /data/images/drive1.img    # rescan an existing image
scan-untrusted-media.sh --restore-session          # afterwards, undo --prepare-session
```

Run `--prepare-session` before attaching any drive: it turns GNOME automount,
autorun, thumbnailers and removable-media indexing off (saving a restore script
under `~/.local/state/scan-untrusted-media/`) and exits, so a freshly plugged drive
is never mounted or previewed. A scan run also hardens the session itself, but by
then a drive plugged in earlier may already be mounted, and the scanner refuses
mounted devices. Block devices are
refused while mounted, set read-only and scanned in place — or, only with
`--image-dir`, imaged with ddrescue first (image SHA-256 and unreadable
sectors recorded) and the image attached read-only; every
partition and APFS volume is mounted `ro,nosuid,nodev,noexec` with journal
replay off: FAT/exFAT, NTFS, ext2/3/4, XFS, Btrfs, F2FS, HFS+, ISO/UDF,
SquashFS/EROFS, and APFS via apfs-fuse (per-volume enumeration, FileVault
password prompt). LVM volume groups are activated with every logical volume
read-only (refused when the VG name clashes with one on the host), and LUKS
or BitLocker volumes are unlocked read-only after a y/N prompt for their
passphrase or recovery key, so the usual LUKS→LVM→ext4/XFS layouts are
covered. Any other filesystem type is not mounted at all: obsolete or rarely
audited kernel drivers (classic HFS, JFS, ReiserFS, UFS, ...) are not exposed
to hostile metadata. Each
volume is scanned inside a transient systemd sandbox — invoking user +
`CAP_DAC_READ_SEARCH` only, no network, read-only host: full inventory with
SHA-256 manifest, ClamAV with raised limits (PUA and macro alerts;
encrypted/oversize files become coverage gaps, not silent passes), YARA with
the checksum-verified YARA Forge rules (score ≥ 75 → LIKELY, lower → REVIEW),
an executable/auto-run inventory for every platform (PE/ELF/Mach-O/DEX
binaries; APK, IPA, MSI/MSIX, DMG/PKG, deb/rpm/AppImage packages; scripts;
app bundles and extensions; iOS/macOS configuration profiles; shortcuts and
disk images; macro documents; launch agents, Startup folders, scheduled tasks,
autostart/systemd/cron entries, shell start-up files; setuid), and
content-vs-extension checks (an executable named like a document is LIKELY,
any other mismatch such as a ".pdf" that is not a PDF is REVIEW). OS metadata
(AppleDouble `._*`, Spotlight, Recycle Bin) is scanned but counted separately.
Files of 2 GiB or more are recorded as ClamAV coverage gaps (its hard limit).
The report TSVs escape every control character in file names, so they are safe
to view in a terminal; `clamscan.log`/`yara.log` are raw tool output. The
report lists DEFINITE / LIKELY / REVIEW findings plus coverage gaps; exit 0 no
findings, 3 findings, 1 error. Everything printed during the run is also saved as
`console.log` in the report directory (colour codes and control characters
stripped), so the report folder alone is a complete record. While each volume scans, its phase and progress are
printed once a minute (inventory size, hashing files/GiB with an ETA, file
typing, classification, ClamAV batches with an ETA, YARA); the data is read
three times (hashing, ClamAV, YARA), and the classification pass is CPU-only,
so a pause in disk activity there is expected.

- `--image-dir DIR` — image block devices with ddrescue into DIR (an existing
  directory) and scan the image; without it devices are scanned in place,
  strictly read-only;
  `--report-dir DIR` (default `./media-scan-YYYYmmdd-HHMMSS`); `--resume` continues
  an interrupted image of the same drive (an existing image or map is otherwise
  refused, since readers and serial-less sticks would reuse another drive's image).
- `--yara-set core|extended|full` (default extended), `--yara-rules FILE`,
  `--no-yara`, `--clam-db PATH`, `--no-update` — rule and signature sources,
  and whether definitions/rules are refreshed.
- `--vt` — VirusTotal lookups of SHA-256 hashes only, never file contents (key
  from `$VT_API_KEY` or `~/.config/virustotal/api-key`), rate-limited to the
  public-API 4/min (`--vt-rate N`; `--vt-all` looks up every file).
- `--keep-mounted` — leave volumes mounted read-only for manual review;
  `--no-session-hardening` — skip the GNOME changes.

Limitations: HFS+ transparent-compression (decmpfs) files read as zero-length
on Linux; encrypted volumes need their passphrase at the terminal; md RAID,
ZFS, Windows ReFS/Storage Spaces, LVM groups spanning other disks and
unlisted filesystems are not opened — all of these surface as coverage gaps;
no scan can prove media clean — the coverage-gap list is the confidence
indicator.

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
