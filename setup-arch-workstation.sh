#!/usr/bin/env bash
#
# Idempotent Arch Linux workstation setup. Replaces the former comtrya
# manifest arch_workstation.yaml (comtrya is unmaintained upstream).
#
# Run as your normal user - NOT root - from any directory: the config payloads
# are resolved relative to this script (files/). Privileged steps go through
# sudo. AUR review/install remains interactive and deliberately does not inherit
# a script-managed sudo keepalive.
# AUR builds (makepkg/yay) refuse to run as root, which is why the script
# itself must not.
#
# Profiles: core (the default) is the full developer workstation - every
# toolchain, editor, agent, browser and admin tool. full adds games (Steam,
# Lutris, the lib32 graphics stack and [multilib], game AUR packages) and
# desktop media extras (Brasero, Video Downloader, MakeMKV).
#
# Modes: --dry-run prints the selected plan offline (no sudo, network, pacman
# or writes; works on any host). --check reports CURRENT/DRIFT read-only, no
# sudo or network (exit 0 converged, 2 drift, 1 error). Without either, the
# plan is applied.
#
# Safe to re-run: every step checks state first, config files are rewritten
# only when their content, type, mode, or ownership differs, and the follow-ups that only a
# real change needs (grub-mkconfig, sysctl reload, dconf update) run only
# then. Package steps install only what is missing, so a converged system is
# a fast no-op - with one deliberate exception: the official-repo step is a
# full `pacman -Syu` (partial upgrades are unsupported on Arch), so a re-run
# also applies pending updates. --no-upgrade skips that sync/upgrade and the
# AUR/rustup updates; it requires existing sync databases and risks a partial
# upgrade, so use it only for short offline-ish reruns.
#
# What it does, in order:
#   1. full only: enables [multilib] in /etc/pacman.conf (core leaves it as is)
#   2. pacman -Syu, replaces jre-openjdk and distro rust with jdk-openjdk and
#      rustup, then installs the official-repo package set and the per-user
#      rustup stable toolchain (rustfmt, clippy, rust-analyzer)
#   3. installs dotfiles (~/.bashrc, ~/.vimrc) and system config from files/:
#      /etc/default/grub (+ grub-mkconfig), /etc/bash.bashrc, /etc/locale.conf,
#      locale generation, the inotify sysctl limit, zram, the daily
#      pacman-update cron job, vi -> vim
#   4. generates and validates dracut images before removing mkinitcpio
#   5. enables the service set (bluetooth, chrony, cronie, cups, gdm, ...)
#   6. publishes ~/.config/monitors.xml to GDM and applies the GDM font setting
#   7. installs the self-updating native AI tools: the Antigravity 2.0+
#      AppImage (user-owned under /opt/Antigravity so it can update itself,
#      run through FUSE 2) and its CLI from checksummed vendor manifests, plus
#      Claude Code and Codex CLI from their official native installers under
#      ~/.local. Reruns keep a copy that updated itself rather than downgrade
#      it, and the AUR/pacman antigravity, antigravity-cli, claude-code and
#      openai-codex packages they replace are removed
#   8. ClamAV: freshclam daemon + one-time DB bootstrap, clamav-daemon (socket
#      path /run/clamav/clamd.ctl), notify-only on-access scanning of the
#      invoking user's ~/Downloads, and a mount-table watcher that
#      read-only-scans each newly mounted USB/removable drive under /run/media
#      (never whole-/home on-access: the DDD watch cannot follow later mounts)
#   9. firewalld: a custom workstation default zone (SSH and Plex Remote
#      Access on 32400/tcp broadly reachable because WAN port forwarding is in
#      use; everything else rejected) plus a
#      source-bound workstation-lan zone for the LAN 192.168.1.0/24 and the
#      SD-WAN 192.168.2.0/23 with the profile's LAN services
#  10. auditd (Arch's kernel builds CONFIG_AUDIT=y, so no audit=1 kernel
#      parameter is needed and /etc/default/grub stays untouched) with curated
#      high-signal rules (identity/auth, sudoers, sshd, unit/cron/shell-rc
#      persistence, module loads, time changes, mounts, auditd itself; no
#      per-execve logging)
#  11. AIDE config-scoped to /etc, /usr/local and /root (pacman -Qkk already
#      verifies package-owned files), daily check via systemd timer; the
#      database is initialized after the AUR phase, when the AUR-built aide
#      binary exists
#  12. bootstraps yay (yay-bin from the AUR), interactively reviews/updates
#      installed AUR packages (including VCS/devel packages), and installs the
#      requested AUR set (including aide and wazuh-agent)
#  13. after the AUR phase: initializes the AIDE database once, enables the
#      AIDE timer, and configures/starts the Wazuh agent for
#      --wazuh-manager/WAZUH_MANAGER (installed but left disabled without it:
#      no manager exists yet and an agent newer than its manager cannot
#      connect)

set -euo pipefail

#--- Config -----------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=${SCRIPT_DIR}/files
YAY_AUR_URL=https://aur.archlinux.org/yay-bin.git
YAY_VCS_DB=${XDG_CACHE_HOME:-${HOME}/.cache}/yay/vcs.json
WAZUH_MANAGER=${WAZUH_MANAGER:-}
RUST_COMPONENTS=(rustfmt clippy rust-analyzer)
# Native, self-updating AI tools (x86_64 only, like the rest of this package set).
ANTIGRAVITY_INSTALL_DIR=/opt/Antigravity
ANTIGRAVITY_COMMAND_LINK=/usr/local/bin/antigravity
ANTIGRAVITY_DESKTOP_FILE=/usr/share/applications/antigravity.desktop
ANTIGRAVITY_ICON_FILE=/usr/share/icons/hicolor/512x512/apps/antigravity.png
ANTIGRAVITY_DESKTOP_MANIFEST_URL=https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-x64-linux.yml
ANTIGRAVITY_DESKTOP_URL_SUFFIX=/linux-x64/Antigravity.AppImage
ANTIGRAVITY_CLI_MANIFEST_URL=https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json
ANTIGRAVITY_CLI_URL_SUFFIX=/linux-x64/cli_linux_x64.tar.gz
ANTIGRAVITY_VERSION=
ANTIGRAVITY_DESKTOP_URL=
ANTIGRAVITY_DESKTOP_SHA512=
ANTIGRAVITY_DESKTOP_SIZE=
ANTIGRAVITY_CLI_VERSION=
ANTIGRAVITY_CLI_URL=
ANTIGRAVITY_CLI_ARCHIVE_SHA512=
ARCH=x86_64
CODEX_INSTALLER_URL=https://chatgpt.com/codex/install.sh
CLAUDE_INSTALLER_URL=https://claude.ai/install.sh
# Packages the native installs replace; none of them can update in place.
RETIRED_AI_PKGS=(antigravity antigravity-cli claude-code openai-codex)
RUST_TOOLCHAIN=stable-x86_64-unknown-linux-gnu
# Arch's rust split packages all pin the rust package version, which rustup's
# unversioned provides cannot satisfy, so they leave together; the standalone
# rust-analyzer package goes too because rustup ships that component.
RUST_DISTRO_PKGS=(rust rust-src rust-musl rust-wasm rust-aarch64-gnu
                  rust-aarch64-musl lib32-rust-libs rust-analyzer)

# Official repositories, core profile (groups are fine: gnome, gnome-circle,
# gnome-extra, vulkan-devel are expanded before the installed-check)
PKGS_OFFICIAL_CORE=(
  archlinux-appstream-data
  audit
  base-devel
  bash-completion
  bash-preexec
  bison
  bluez
  bluez-utils
  boost
  cantarell-fonts
  ccache
  cdrtools
  chrony
  clang
  chromium
  code
  cmake
  cockpit
  cockpit-files
  cockpit-packagekit
  cockpit-podman
  cockpit-storaged
  colordiff
  cronie
  cups
  cups-pk-helper
  curl
  dos2unix
  dracut
  efibootmgr
  erofs-utils
  firewalld
  flex
  fuse2
  gcc
  gdb
  git
  github-cli
  gmp
  gnome
  gnome-circle
  gnome-extra
  gnome-firmware
  gnome-shell-extension-appindicator
  gnome-shell-extension-dash-to-panel
  gnome-shell-extension-desktop-icons-ng
  gnome-shell-extension-vitals
  # Arch bundles System Monitor here; Fedora splits it into its own RPM.
  gnome-shell-extensions
  go
  gparted
  gradle
  grub
  gst-plugin-pipewire
  gst-plugins-ugly
  hivex
  htop
  jdk-openjdk
  jq
  less
  libgtop # Optional upstream, required by the System Monitor shell extension.
  libmpc
  libpulse
  libva-intel-driver
  libva-nvidia-driver
  libva-utils
  linux
  linux-firmware
  linux-headers
  linux-lts
  linux-lts-headers
  lldb
  llvm
  lvm2
  maven
  mesa-utils
  mpfr
  mpv
  nano
  net-tools
  networkmanager
  noto-fonts
  noto-fonts-cjk
  noto-fonts-extra
  nvidia-open
  nvidia-open-lts
  nvidia-utils
  opencl-mesa
  opencode
  openssh
  pacman-contrib
  pipewire
  pipewire-alsa
  pipewire-jack
  pipewire-pulse
  power-profiles-daemon
  ptyxis
  rpm-tools
  rsync
  ruby
  # Rust comes only from rustup; the toolchain is installed per user below.
  rustup
  screen
  seahorse
  sof-firmware
  sudo
  system-config-printer
  texinfo
  tmux
  tree
  unarchiver
  vim
  vlc
  vulkan-devel
  vulkan-intel
  vulkan-mesa-layers
  vulkan-radeon
  wget
  wireplumber
  wpa_supplicant
  yt-dlp
  zed
  zram-generator
)

# Official repositories added by the full profile: games, the 32-bit graphics
# stack that exists for Steam/Wine (needs [multilib]), and desktop media apps
PKGS_OFFICIAL_FULL=(
  brasero
  lib32-libva-intel-driver
  lib32-vulkan-asahi
  lib32-vulkan-broadcom
  lib32-vulkan-dzn
  lib32-vulkan-freedreno
  lib32-vulkan-gfxstream
  lib32-vulkan-intel
  lib32-vulkan-nouveau
  lib32-vulkan-panfrost
  lib32-vulkan-powervr
  lib32-vulkan-radeon
  lib32-vulkan-swrast
  lib32-vulkan-virtio
  lutris
  # Local LLM runtime, not a toolchain: ollama-cuda pulls in CUDA (~6.4 GB with
  # it). The split backends are co-installable and depend on the base ollama.
  ollama-cuda
  ollama-vulkan
  steam
  video-downloader
)

# AUR (via yay), core profile. aide and wazuh-agent live here because neither
# is in the official repositories; the AIDE database and the Wazuh enablement
# therefore run after the AUR phase (step 13).
PKGS_AUR_CORE=(
  aide
  android-ndk
  android-sdk-build-tools
  android-sdk-cmdline-tools-latest
  android-sdk-platform-tools
  android-studio
  balun-bin
  downgrade
  gnome-icon-theme
  gnome-icon-theme-symbolic
  gnome-shell-extension-dash-to-dock
  google-chrome
  hfsutils
  lineageos-devel
  mstflint
  ookla-speedtest-bin
  payload-dumper-go-bin
  powershell-bin
  sit-git
  tributary-bin
  ventoy-bin
  wazuh-agent
)

# AUR packages added by the full profile: games, game launchers/compat tools,
# and desktop media
PKGS_AUR_FULL=(
  airshipper
  bugdom
  bugdom2
  cro-mag-rally-net
  dxvk-bin
  lgogdownloader
  luxtorpeda-bin
  maelstrom
  makemkv
  maniadrive
  mightymike
  nanosaur
  nanosaur2
  openarena
  ottomatic
  steamcmd
  tremulous-grangerhub-bin
  tuxracer
  unigine-heaven
)

SERVICES=(
  bluetooth.service
  chronyd.service
  cronie.service
  cups.service
  gdm.service
  gnome-remote-desktop.service
  NetworkManager-dispatcher.service
  NetworkManager-wait-online.service
  NetworkManager.service
  sshd.service
)

# Config payloads as owner|source under files/|destination|mode. --check and
# --dry-run read this list; the apply steps below install each entry with
# put_file next to the follow-up its change requires. The two *rendered*
# security configs (/etc/clamav/clamd.conf and
# /etc/firewalld/zones/workstation-lan.xml, both generated from the invoking
# user's HOME and the selected profile) are deliberately not listed here; they
# have dedicated apply and check logic around render_clamd_config and
# render_lan_zone instead.
MANAGED_FILES=(
  "user|bashrc|${HOME}/.bashrc|0644"
  "user|vimrc|${HOME}/.vimrc|0644"
  "root|grub|/etc/default/grub|0644"
  "root|etc/bash.bashrc|/etc/bash.bashrc|0644"
  "root|etc/locale.conf|/etc/locale.conf|0644"
  "root|etc/sysctl.d/99-inotify.conf|/etc/sysctl.d/99-inotify.conf|0644"
  "root|etc/systemd/zram-generator.conf|/etc/systemd/zram-generator.conf|0644"
  "root|etc/cron.daily/pacman-update|/etc/cron.daily/pacman-update|0755"
  "root|etc/dconf/db/gdm.d/10-font-settings|/etc/dconf/db/gdm.d/10-font-settings|0644"
  "root|etc/audit/rules.d/50-workstation.rules|/etc/audit/rules.d/50-workstation.rules|0644"
  "root|etc/aide.conf|/etc/aide.conf|0644"
  "root|etc/firewalld/zones/workstation.xml|/etc/firewalld/zones/workstation.xml|0644"
  "root|etc/firewalld/services/navidrome.xml|/etc/firewalld/services/navidrome.xml|0644"
  "root|etc/firewalld/services/owntone.xml|/etc/firewalld/services/owntone.xml|0644"
  "root|etc/firewalld/services/plexmediaserver.xml|/etc/firewalld/services/plexmediaserver.xml|0644"
  "root|etc/firewalld/services/steam-streaming.xml|/etc/firewalld/services/steam-streaming.xml|0644"
  "root|etc/firewalld/services/transmission.xml|/etc/firewalld/services/transmission.xml|0644"
  "root|etc/firewalld/services/iperf3.xml|/etc/firewalld/services/iperf3.xml|0644"
  "root|etc/firewalld/services/lancache.xml|/etc/firewalld/services/lancache.xml|0644"
  "root|etc/firewalld/services/plex-remote.xml|/etc/firewalld/services/plex-remote.xml|0644"
  "root|etc/systemd/system/clamav-clamonacc.service.d/50-arch-workstation.conf|/etc/systemd/system/clamav-clamonacc.service.d/50-arch-workstation.conf|0644"
  "root|etc/systemd/system/clamav-media-scan.service|/etc/systemd/system/clamav-media-scan.service|0644"
  "root|usr/local/libexec/clamav-media-scan|/usr/local/libexec/clamav-media-scan|0755"
  "root|etc/systemd/system/aide-check.service|/etc/systemd/system/aide-check.service|0644"
  "root|etc/systemd/system/aide-check.timer|/etc/systemd/system/aide-check.timer|0644"
)

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ${0##*/} [--profile core|full] [--check | --dry-run] [--no-upgrade]
       [--wazuh-manager HOST]
       ${0##*/} -h|--help

Idempotent Arch Linux workstation setup: official + AUR package sets, the
rustup toolchain, dotfiles and system config from files/, services, GDM
settings. Run as your normal user (sudo is used for the privileged steps);
safe to re-run at any time.

  --profile core   developer workstation: every toolchain, editor, agent,
                   browser and admin tool (default)
  --profile full   core plus games, [multilib]/lib32 and desktop media extras
  --dry-run        print the selected plan offline and exit 0; no sudo,
                   network, pacman or writes
  --check          report CURRENT/DRIFT read-only without sudo or network;
                   exit 0 converged, 2 drift, 1 error
  --no-upgrade     skip pacman -Syu and AUR/rustup updates; install missing
                   packages from the existing sync databases (refused when a
                   repository database is missing; risks a partial upgrade)
  --wazuh-manager HOST
                   after the AUR phase, write HOST into the Wazuh agent
                   configuration and enable plus start wazuh-agent (also via
                   \$WAZUH_MANAGER). Without it the agent stays installed but
                   disabled: no manager exists yet, and an agent newer than
                   its manager cannot connect.
USAGE
}

PROFILE=core
MODE=apply
NO_UPGRADE=0
while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --profile)
      (( $# >= 2 )) || { usage >&2; die "--profile requires core or full"; }
      case $2 in
        core|full) PROFILE=$2 ;;
        *) usage >&2; die "Invalid profile: $2 (expected core or full)" ;;
      esac
      shift
      ;;
    --check|--dry-run)
      [[ ${MODE} == apply ]] || { usage >&2; die "--check and --dry-run are mutually exclusive"; }
      MODE=${1#--}
      ;;
    --no-upgrade) NO_UPGRADE=1 ;;
    --wazuh-manager)
      (( $# >= 2 )) || { usage >&2; die "--wazuh-manager requires a host name or address"; }
      WAZUH_MANAGER=$2
      shift
      ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done
if [[ -n ${WAZUH_MANAGER} && ! ${WAZUH_MANAGER} =~ ^[A-Za-z0-9._:-]+$ ]]; then
  die "--wazuh-manager must be a host name or address: ${WAZUH_MANAGER}"
fi

# select_profile <core|full>: rebuild PKGS_OFFICIAL and PKGS_AUR from the core
# lists plus, for full, the game/media extras. Safe to call repeatedly.
PKGS_OFFICIAL=()
PKGS_AUR=()
FIREWALL_LAN_SERVICES=()
select_profile() {
  case $1 in
    core|full) ;;
    *) die "Invalid profile: $1" ;;
  esac
  PKGS_OFFICIAL=("${PKGS_OFFICIAL_CORE[@]}")
  PKGS_AUR=("${PKGS_AUR_CORE[@]}")
  # LAN-reachable services for the source-bound workstation-lan zone. SSH is
  # listed too: firewalld puts each packet in exactly one zone, so LAN peers
  # never fall through to the default workstation zone (where SSH stays
  # broadly reachable for WAN port forwarding) and would otherwise be
  # rejected. GNOME Remote Desktop (rdp), Cockpit and printing discovery
  # (ipp-client, mdns) are core. The media servers, Transmission, iperf3,
  # LanCache, NFS (v4 plus the v3 mountd/rpcbind surface) and Samba are not
  # installed by this script but run by hand on some Arch hosts, so their
  # ports open in every profile.
  FIREWALL_LAN_SERVICES=(ssh cockpit rdp ipp-client mdns iperf3
    plexmediaserver navidrome owntone transmission
    lancache nfs mountd rpc-bind samba)
  if [[ $1 == full ]]; then
    PKGS_OFFICIAL+=("${PKGS_OFFICIAL_FULL[@]}")
    PKGS_AUR+=("${PKGS_AUR_FULL[@]}")
    # Steam joins the LAN zone with the full profile that installs it.
    FIREWALL_LAN_SERVICES+=(steam-streaming)
  fi
}
select_profile "${PROFILE}"

#--- Helpers ----------------------------------------------------------------
# put_file [-s] <src> <dst> [mode]
# Installs <src> at <dst> (default mode 0644, parent dirs created) only when
# content, file type, mode, or ownership differs; -s installs root:root through
# sudo. PUT_FILE_CHANGED is set to 1 when a write occurred. The helper itself
# always succeeds or exits fatally, so Bash conditional contexts cannot mask an
# install failure by disabling errexit inside the function.
PUT_FILE_CHANGED=0
put_file() {
  local as_root=()
  local expected_uid=${EUID} expected_gid
  expected_gid=$(id -g) || die "could not determine the current user's primary group"
  PUT_FILE_CHANGED=0
  if [[ $1 == -s ]]; then
    as_root=(sudo)
    expected_uid=0
    expected_gid=0
    shift
  fi
  local src=$1 dst=$2 mode=${3:-0644} expected_mode
  expected_mode=$(printf '%o' "$((8#${mode}))")
  if [[ -f ${dst} && ! -L ${dst} ]] && cmp -s -- "${src}" "${dst}" \
     && [[ $(stat -c '%a:%u:%g' -- "${dst}") == "${expected_mode}:${expected_uid}:${expected_gid}" ]]; then
    note "${dst}: up to date"
    return 0
  fi
  if (( ${#as_root[@]} )); then
    sudo install -D -o root -g root -m "${mode}" -- "${src}" "${dst}" \
      || die "failed to install ${dst}"
  else
    install -D -m "${mode}" -- "${src}" "${dst}" \
      || die "failed to install ${dst}"
  fi
  PUT_FILE_CHANGED=1
  note "${dst}: installed"
}

# ensure_symlink [-s] <target> <link>
ensure_symlink() {
  local as_root=()
  if [[ $1 == -s ]]; then as_root=(sudo); shift; fi
  local target=$1 link=$2
  # Compare resolved paths: a relative link to the same file is already correct
  if [[ -L ${link} && $(readlink -f -- "${link}") == $(readlink -f -- "${target}") ]]; then
    note "${link} -> ${target}: up to date"
    return 0
  fi
  "${as_root[@]}" ln -sfn -- "${target}" "${link}"
  note "${link} -> ${target}: linked"
}

# enable_unit <unit>: enable (not start) a systemd unit unless it already is
enable_unit() {
  if systemctl is-enabled --quiet "$1" 2>/dev/null; then
    note "$1: enabled"
    return 0
  fi
  sudo systemctl --quiet enable "$1"
  note "$1: enabled now"
}

# expand_groups <name>...: populate WANTED_PKGS, expanding pacman groups and
# de-duplicating their members. Operational pacman errors are fatal.
declare -gA IS_GROUP=()
WANTED_PKGS=()
expand_groups() {
  local p member output
  declare -A seen=()
  WANTED_PKGS=()
  for p in "$@"; do
    if [[ -n ${IS_GROUP[${p}]:-} ]]; then
      output=$(pacman -Sgq "${p}") || die "could not expand pacman group: ${p}"
      while IFS= read -r member; do
        [[ -z ${member} || -n ${seen[${member}]:-} ]] && continue
        seen[${member}]=1
        WANTED_PKGS+=("${member}")
      done <<<"${output}"
    else
      [[ -n ${seen[${p}]:-} ]] && continue
      seen[${p}]=1
      WANTED_PKGS+=("${p}")
    fi
  done
}

# find_missing_pkgs <name>...: populate MISSING_PKGS. pacman -T returns 127
# when dependencies are merely unsatisfied; every other nonzero status is an
# operational error and must stop the run.
MISSING_PKGS=()
find_missing_pkgs() {
  local output error_output error_file rc=0
  MISSING_PKGS=()
  (( $# )) || return 0
  error_file=$(mktemp "${WORK_DIR:-/tmp}/pacman-T.XXXXXX") \
    || die "could not create temporary pacman error file"
  output=$(pacman -T "$@" 2>"${error_file}") || rc=$?
  error_output=$(<"${error_file}")
  rm -f -- "${error_file}" || die "could not remove temporary pacman error file"
  if (( rc != 0 && rc != 127 )); then
    die "pacman dependency check failed (exit ${rc}): ${error_output:-${output}}"
  fi
  if [[ -n ${error_output} ]]; then
    warn "pacman dependency check reported: ${error_output}"
  fi
  if [[ -n ${output} ]]; then
    mapfile -t MISSING_PKGS <<<"${output}"
  fi
}

# Remove products that have explicit successors in this package set. The old
# Antigravity IDE can coexist with Antigravity 2.x, so installing the new app
# alone would not retire it. Code OSS replaces the less-native VSCodium AUR
# package on Arch.
purge_legacy_antigravity_arch() {
  local package_line version comparison
  local legacy_packages=()
  if pacman -Q antigravity-ide &>/dev/null; then
    legacy_packages+=(antigravity-ide)
  fi
  if package_line=$(pacman -Q antigravity 2>/dev/null); then
    version=${package_line#* }
    comparison=$(vercmp "${version}" 2.0.0) \
      || die "could not compare the installed Antigravity version"
    (( comparison >= 0 )) || legacy_packages+=(antigravity)
  fi
  if (( ${#legacy_packages[@]} )); then
    sudo pacman -Rns --noconfirm "${legacy_packages[@]}" \
      || die "could not remove legacy Antigravity package(s): ${legacy_packages[*]}"
    for package_name in "${legacy_packages[@]}"; do
      pacman -Q "${package_name}" &>/dev/null \
        && die "legacy Antigravity package is still installed: ${package_name}"
    done
    note "legacy Antigravity package(s) removed: ${legacy_packages[*]}"
  else
    note "legacy Antigravity 1.x / IDE packages: absent"
  fi
}

purge_replaced_editor_arch() {
  if pacman -Q vscodium-bin &>/dev/null; then
    sudo pacman -Rns --noconfirm vscodium-bin \
      || die "could not remove VSCodium before switching to Code OSS"
    pacman -Q vscodium-bin &>/dev/null \
      && die "VSCodium is still installed"
    note "VSCodium: removed (replaced by the official Arch code package)"
  else
    note "VSCodium: absent"
  fi
}

# The retired comtrya manifest explicitly removed the standalone runtime before
# requesting the full JDK. Preserve that one-time migration: jre-openjdk and
# jdk-openjdk conflict, so leaving the old package installed makes the
# non-interactive official-package transaction abort instead of converging.
transition_openjdk_runtime_arch() {
  if ! pacman -Q jre-openjdk &>/dev/null; then
    note "standalone OpenJDK JRE: absent"
    return 0
  fi

  sudo pacman -Rdd --noconfirm jre-openjdk \
    || die "could not remove jre-openjdk before installing jdk-openjdk"
  ! pacman -Q jre-openjdk &>/dev/null \
    || die "jre-openjdk is still installed"

  # Install the replacement immediately so the migration does not leave Java
  # absent until the much larger workstation package transaction completes.
  sudo pacman -S --needed --noconfirm jdk-openjdk \
    || die "could not install jdk-openjdk after removing jre-openjdk"
  pacman -Q jdk-openjdk &>/dev/null \
    || die "jdk-openjdk was not installed after the JRE transition"
  note "standalone OpenJDK JRE replaced by jdk-openjdk"
}

is_supported_antigravity_desktop_version() {
  local version=$1
  [[ ${version} =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || return 1
  printf '%s\n%s\n' 2.0.0 "${version}" | LC_ALL=C sort -V -C
}

# Fetch release metadata without following a redirect to plaintext. GitHub's
# API token is optional; when supplied it raises the rate limit without
# changing which public release metadata is trusted.
fetch_release_document() {
  local url=$1
  local curl_args=(--proto '=https' --tlsv1.2 -fsSL --retry 3
                   --connect-timeout 30 --max-time 120)
  case ${url} in
    https://api.github.com/*)
      curl_args+=(-H 'Accept: application/vnd.github+json'
                  -H 'X-GitHub-Api-Version: 2022-11-28')
      if [[ -n ${GITHUB_TOKEN:-} ]]; then
        curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
      fi
      ;;
  esac
  curl "${curl_args[@]}" "${url}"
}

parse_antigravity_desktop_manifest() {
  local manifest=$1
  awk '
    BEGIN { rollout = 100 }
    $1 == "version:" { version = $2 }
    $1 == "-" && $2 == "url:" {
      in_appimage = ($3 ~ /\/Antigravity[.]AppImage$/)
      if (in_appimage) { count += 1; url = $3 }
      next
    }
    in_appimage && $1 == "sha512:" { checksum = $2; next }
    in_appimage && $1 == "size:" { size = $2; in_appimage = 0; next }
    $1 == "stagingPercentage:" { rollout = $2 }
    END {
      if (count != 1 || version == "" || url == "" || checksum == "" ||
          size == "") exit 1
      printf "%s\t%s\t%s\t%s\t%s\n", version, url, checksum, size, rollout
    }
  ' <<<"${manifest}"
}

resolve_antigravity_desktop_release() {
  local manifest line checksum_base64 decoded_hex
  manifest=$(fetch_release_document "${ANTIGRAVITY_DESKTOP_MANIFEST_URL}") \
    || die "could not query the latest Antigravity desktop release"
  line=$(parse_antigravity_desktop_manifest "${manifest}") \
    || die "latest Antigravity desktop manifest has an unexpected layout"
  IFS=$'\t' read -r ANTIGRAVITY_VERSION ANTIGRAVITY_DESKTOP_URL \
    checksum_base64 ANTIGRAVITY_DESKTOP_SIZE ANTIGRAVITY_DESKTOP_ROLLOUT <<<"${line}"
  is_supported_antigravity_desktop_version "${ANTIGRAVITY_VERSION}" \
    || die "latest Antigravity desktop manifest is not a stable release at or above 2.0.0"
  [[ ${ANTIGRAVITY_DESKTOP_URL} == \
      "https://storage.googleapis.com/antigravity-public/"*"/${ANTIGRAVITY_VERSION}-"*"${ANTIGRAVITY_DESKTOP_URL_SUFFIX}" ]] \
    || die "latest Antigravity desktop manifest selected an unexpected ${ARCH} URL"
  [[ ${ANTIGRAVITY_DESKTOP_SIZE} =~ ^[0-9]+$ ]] \
    && (( ANTIGRAVITY_DESKTOP_SIZE > 0 )) \
    || die "latest Antigravity desktop manifest has an invalid artifact size"
  [[ ${ANTIGRAVITY_DESKTOP_ROLLOUT} =~ ^[0-9]+$ ]] \
    && (( ANTIGRAVITY_DESKTOP_ROLLOUT >= 1 && ANTIGRAVITY_DESKTOP_ROLLOUT <= 100 )) \
    || die "latest Antigravity desktop manifest has an invalid rollout percentage"
  decoded_hex=$(printf '%s' "${checksum_base64}" | base64 --decode 2>/dev/null \
    | od -An -v -tx1 | tr -d ' \n') \
    || die "latest Antigravity desktop manifest has invalid Base64 checksum data"
  [[ ${decoded_hex} =~ ^[[:xdigit:]]{128}$ ]] \
    || die "latest Antigravity desktop manifest checksum is not SHA-512"
  ANTIGRAVITY_DESKTOP_SHA512=${decoded_hex,,}
}

resolve_antigravity_cli_release() {
  local metadata line
  metadata=$(fetch_release_document "${ANTIGRAVITY_CLI_MANIFEST_URL}") \
    || die "could not query the latest Antigravity CLI release"
  line=$(jq -er '
      select(type == "object"
        and (.version | type) == "string"
        and (.url | type) == "string"
        and (.sha512 | type) == "string")
      | [.version, .url, .sha512] | @tsv
    ' <<<"${metadata}") \
    || die "latest Antigravity CLI manifest has an unexpected layout"
  IFS=$'\t' read -r ANTIGRAVITY_CLI_VERSION ANTIGRAVITY_CLI_URL \
    ANTIGRAVITY_CLI_ARCHIVE_SHA512 <<<"${line}"
  [[ ${ANTIGRAVITY_CLI_VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "latest Antigravity CLI manifest has an invalid version"
  [[ ${ANTIGRAVITY_CLI_URL} == \
      "https://storage.googleapis.com/antigravity-public/antigravity-cli/${ANTIGRAVITY_CLI_VERSION}-"*"${ANTIGRAVITY_CLI_URL_SUFFIX}" ]] \
    || die "latest Antigravity CLI manifest selected an unexpected ${ARCH} URL"
  [[ ${ANTIGRAVITY_CLI_ARCHIVE_SHA512} =~ ^[[:xdigit:]]{128}$ ]] \
    || die "latest Antigravity CLI manifest has no valid SHA-512 digest"
  ANTIGRAVITY_CLI_ARCHIVE_SHA512=${ANTIGRAVITY_CLI_ARCHIVE_SHA512,,}
}

# antigravity_appimage_extract <image> <member> <dir>: extracts one AppImage
# member to <dir>/squashfs-root/<member> without FUSE; fails if it is absent.
antigravity_appimage_extract() {
  local image=$1 member=$2 dir=$3
  rm -rf -- "${dir}"
  install -d -- "${dir}"
  ( cd -- "${dir}" && "${image}" --appimage-extract "${member}" ) >/dev/null 2>&1 \
    && [[ -f ${dir}/squashfs-root/${member} && ! -L ${dir}/squashfs-root/${member} ]]
}

# Prints the X-AppImage-Version embedded in an Antigravity AppImage. Unlike the
# release marker, it stays accurate after the app updates itself in place.
antigravity_appimage_version() {
  local dir=${WORK_DIR}/antigravity-version version
  antigravity_appimage_extract "$1" antigravity.desktop "${dir}" || return 1
  version=$(sed -n 's/^X-AppImage-Version=//p' \
    "${dir}/squashfs-root/antigravity.desktop" | tail -1)
  rm -rf -- "${dir}"
  [[ -n ${version} ]] || return 1
  printf '%s\n' "${version}"
}

# electron-updater replaces the AppImage by unlinking it and moving the new
# image into the same directory, so the desktop user must own the install.
ensure_antigravity_owner() {
  local install_dir=$1 uid gid
  uid=$(id -u) || die "could not determine the current user"
  gid=$(id -g) || die "could not determine the current user's primary group"
  if [[ -n $(find "${install_dir}" \( ! -uid "${uid}" -o ! -gid "${gid}" \) \
               -print -quit) ]]; then
    sudo chown -R -- "${uid}:${gid}" "${install_dir}" \
      || die "could not hand ${install_dir} to UID ${uid} for in-app updates"
    note "${install_dir}: owned by UID ${uid} so Antigravity can update itself"
  fi
}

# Installs the icon bundled in the AppImage under the name the launcher uses.
install_antigravity_icon() {
  local image=$1 dir=${WORK_DIR}/antigravity-icon
  local member=usr/share/icons/hicolor/512x512/apps/antigravity.png
  local theme_dir=${ANTIGRAVITY_ICON_FILE%/*/*/*}
  if ! antigravity_appimage_extract "${image}" "${member}" "${dir}"; then
    warn "could not extract the Antigravity icon from ${image}; the launcher icon may be generic"
    return 0
  fi
  put_file -s "${dir}/squashfs-root/${member}" "${ANTIGRAVITY_ICON_FILE}"
  rm -rf -- "${dir}"
  if (( PUT_FILE_CHANGED )) && [[ -f ${theme_dir}/index.theme ]] \
     && command -v gtk-update-icon-cache >/dev/null; then
    sudo gtk-update-icon-cache -q -t -f -- "${theme_dir}" \
      || warn "could not refresh the icon cache in ${theme_dir}"
  fi
}

# Shared tail of every successful desktop install or reconcile.
finish_antigravity_desktop() {
  local install_dir=$1
  ensure_antigravity_owner "${install_dir}"
  ensure_symlink -s "${install_dir}/Antigravity.AppImage" "${ANTIGRAVITY_COMMAND_LINK}"
  put_file -s "${FILES}/usr/share/applications/antigravity.desktop" \
    "${ANTIGRAVITY_DESKTOP_FILE}"
  install_antigravity_icon "${install_dir}/Antigravity.AppImage"
}

# Optional install root keeps artifact/convergence tests unprivileged.
# shellcheck disable=SC2120
install_antigravity_desktop() {
  local install_dir=${1:-${ANTIGRAVITY_INSTALL_DIR}}
  local marker=${install_dir}/.lan-ipxe-release
  local installed_image=${install_dir}/Antigravity.AppImage
  local image=${WORK_DIR}/Antigravity-${ANTIGRAVITY_VERSION}.AppImage
  local marker_source=${WORK_DIR}/antigravity-release-marker
  local stage=${install_dir}.lan-ipxe-stage.$$
  local backup=${install_dir}.lan-ipxe-backup.$$
  local current_sha='' current_size='' current_version='' expected_current_sha=''
  local image_sha='' image_size='' self_updated=0 owner='' group=''

  [[ ! -e ${ANTIGRAVITY_COMMAND_LINK} || -L ${ANTIGRAVITY_COMMAND_LINK} ]] \
    || die "refusing to replace unmanaged path: ${ANTIGRAVITY_COMMAND_LINK}"
  if [[ -x ${installed_image} && -f ${marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-arch-workstation.sh' "${marker}"; then
    current_sha=$(sha512sum -- "${installed_image}") \
      || die "could not hash ${installed_image}"
    current_sha=${current_sha%% *}
    current_size=$(stat -c '%s' -- "${installed_image}") \
      || die "could not read the size of ${installed_image}"
    expected_current_sha=$(sed -n 's/^image-sha512=//p' "${marker}" | tail -1)
    if [[ ${current_sha} == "${expected_current_sha}" ]]; then
      current_version=$(sed -n 's/^version=//p' "${marker}" | tail -1)
    elif current_version=$(antigravity_appimage_version "${installed_image}"); then
      # The app replaced the image this script installed with its own update.
      self_updated=1
    else
      current_version=''
    fi
    if [[ ${current_version} == "${ANTIGRAVITY_VERSION}" \
          && ${current_sha} == "${ANTIGRAVITY_DESKTOP_SHA512}" \
          && ${current_size} == "${ANTIGRAVITY_DESKTOP_SIZE}" ]]; then
      note "Antigravity ${ANTIGRAVITY_VERSION}: present and verified"
      finish_antigravity_desktop "${install_dir}"
      return 0
    fi
    if [[ -n ${current_version} && ${current_version} != "${ANTIGRAVITY_VERSION}" ]] \
       && is_supported_antigravity_desktop_version "${current_version}" \
       && printf '%s\n%s\n' "${ANTIGRAVITY_VERSION}" "${current_version}" \
          | LC_ALL=C sort -V -C; then
      if (( self_updated )); then
        note "Antigravity ${current_version}: updated in place by the app (manifest ${ANTIGRAVITY_VERSION}); preserving it"
      else
        warn "Antigravity ${current_version} is newer than the current manifest ${ANTIGRAVITY_VERSION}; preserving it to avoid a downgrade"
      fi
      finish_antigravity_desktop "${install_dir}"
      return 0
    fi
  fi

  if [[ -e ${install_dir} || -L ${install_dir} ]]; then
    [[ -f ${marker} ]] \
      && grep -Fxq 'managed-by=lan-ipxe/setup-arch-workstation.sh' "${marker}" \
      || die "refusing to replace unmanaged Antigravity path: ${install_dir}"
  fi
  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    -o "${image}" "${ANTIGRAVITY_DESKTOP_URL}" \
    || die "could not download Antigravity ${ANTIGRAVITY_VERSION}"
  image_sha=$(sha512sum -- "${image}") || die "could not hash ${image}"
  image_sha=${image_sha%% *}
  [[ ${image_sha} == "${ANTIGRAVITY_DESKTOP_SHA512}" ]] \
    || die "Antigravity AppImage checksum mismatch for ${ARCH}"
  image_size=$(stat -c '%s' -- "${image}") \
    || die "could not read the Antigravity AppImage size"
  [[ ${image_size} == "${ANTIGRAVITY_DESKTOP_SIZE}" ]] \
    || die "Antigravity AppImage size mismatch for ${ARCH}"
  chmod 0755 "${image}"
  "${image}" --appimage-version >/dev/null 2>&1 \
    || die "the verified Antigravity artifact is not a runnable AppImage"

  [[ ! -e ${stage} && ! -L ${stage} && ! -e ${backup} && ! -L ${backup} ]] \
    || die "stale Antigravity staging path exists beside ${install_dir}"
  # User-owned so the app's own updater can replace the AppImage in place.
  owner=$(id -un) || die "could not determine the current user"
  group=$(id -gn) || die "could not determine the current user's primary group"
  sudo install -d -o "${owner}" -g "${group}" -m 0755 -- "${stage}"
  sudo install -o "${owner}" -g "${group}" -m 0755 -- "${image}" \
    "${stage}/Antigravity.AppImage"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-arch-workstation.sh' \
    "version=${ANTIGRAVITY_VERSION}" \
    "source-url=${ANTIGRAVITY_DESKTOP_URL}" \
    "image-size=${ANTIGRAVITY_DESKTOP_SIZE}" \
    "image-sha512=${ANTIGRAVITY_DESKTOP_SHA512}" \
    >"${marker_source}"
  sudo install -o "${owner}" -g "${group}" -m 0644 -- "${marker_source}" \
    "${stage}/.lan-ipxe-release"
  if [[ -e ${install_dir} || -L ${install_dir} ]]; then
    sudo mv -- "${install_dir}" "${backup}"
    if ! sudo mv -- "${stage}" "${install_dir}"; then
      sudo mv -- "${backup}" "${install_dir}" || true
      die "could not activate Antigravity ${ANTIGRAVITY_VERSION}"
    fi
    sudo rm -rf -- "${backup}"
  else
    sudo mv -- "${stage}" "${install_dir}"
  fi
  if command -v restorecon >/dev/null; then
    sudo restorecon -R "${install_dir}" \
      || die "failed to restore SELinux labels under ${install_dir}"
  fi
  "${installed_image}" --appimage-version >/dev/null 2>&1 \
    || die "installed Antigravity AppImage is not runnable"
  finish_antigravity_desktop "${install_dir}"
  note "Antigravity ${ANTIGRAVITY_VERSION}: installed from the verified latest AppImage"
}

# Optional bin directory keeps artifact/convergence tests isolated.
# shellcheck disable=SC2120
install_antigravity_cli() {
  local bin_dir=${1:-${HOME}/.local/bin}
  local dest=${bin_dir}/agy archive=${WORK_DIR}/antigravity-cli.tar.gz
  local marker=${dest}.lan-ipxe-release marker_source=${WORK_DIR}/antigravity-cli-release-marker
  local extract_dir=${WORK_DIR}/antigravity-cli archive_sha='' binary_sha='' version=''
  local expected_binary_sha=''
  if [[ -x ${dest} && -f ${marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-arch-workstation.sh' "${marker}" \
     && grep -Fxq "version=${ANTIGRAVITY_CLI_VERSION}" "${marker}" \
     && grep -Fxq "archive-sha512=${ANTIGRAVITY_CLI_ARCHIVE_SHA512}" "${marker}"; then
    binary_sha=$(sha256sum -- "${dest}") || die "could not hash ${dest}"
    binary_sha=${binary_sha%% *}
    expected_binary_sha=$(sed -n 's/^binary-sha256=//p' "${marker}" | tail -1)
    if [[ ${binary_sha} == "${expected_binary_sha}" ]]; then
      version=$("${dest}" --version 2>/dev/null) \
        || die "the installed Antigravity CLI is not runnable"
      [[ ${version} == "${ANTIGRAVITY_CLI_VERSION}" ]] \
        || die "the verified Antigravity CLI reported unexpected version ${version}"
      note "Antigravity CLI ${version}: present and verified"
      return 0
    fi
  fi
  # agy replaces itself in place when it self-updates, so a managed binary
  # that no longer matches its marker but is at least the manifest version
  # is the app's own update, not drift.
  if [[ -x ${dest} && -f ${marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-arch-workstation.sh' "${marker}" \
     && version=$("${dest}" --version 2>/dev/null) \
     && [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
     && printf '%s\n%s\n' "${ANTIGRAVITY_CLI_VERSION}" "${version}" \
        | LC_ALL=C sort -V -C; then
    note "Antigravity CLI ${version}: updated in place by agy (manifest ${ANTIGRAVITY_CLI_VERSION}); preserving it"
    return 0
  fi
  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    -o "${archive}" "${ANTIGRAVITY_CLI_URL}" \
    || die "could not download Antigravity CLI ${ANTIGRAVITY_CLI_VERSION}"
  archive_sha=$(sha512sum -- "${archive}") || die "could not hash ${archive}"
  archive_sha=${archive_sha%% *}
  [[ ${archive_sha} == "${ANTIGRAVITY_CLI_ARCHIVE_SHA512}" ]] \
    || die "Antigravity CLI archive checksum mismatch for ${ARCH}"
  mkdir -p "${extract_dir}"
  tar -xzf "${archive}" -C "${extract_dir}" antigravity \
    || die "Antigravity CLI archive has an unexpected layout"
  binary_sha=$(sha256sum -- "${extract_dir}/antigravity") \
    || die "could not hash the extracted Antigravity CLI"
  binary_sha=${binary_sha%% *}
  version=$("${extract_dir}/antigravity" --version 2>/dev/null) \
    || die "the verified Antigravity CLI is not runnable"
  [[ ${version} == "${ANTIGRAVITY_CLI_VERSION}" ]] \
    || die "Antigravity CLI reported unexpected version ${version}"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-arch-workstation.sh' \
    "version=${ANTIGRAVITY_CLI_VERSION}" \
    "source-url=${ANTIGRAVITY_CLI_URL}" \
    "archive-sha512=${ANTIGRAVITY_CLI_ARCHIVE_SHA512}" \
    "binary-sha256=${binary_sha}" \
    >"${marker_source}"
  put_file "${extract_dir}/antigravity" "${dest}" 0755
  put_file "${marker_source}" "${marker}" 0644
  "${dest}" --version >/dev/null 2>&1 \
    || die "the installed Antigravity CLI is not runnable"
  note "Antigravity CLI ${version}: installed as ~/.local/bin/agy"
}

install_codex_cli() {
  local installer=${WORK_DIR}/codex-install.sh
  curl --proto '=https' --tlsv1.2 -fsSL "${CODEX_INSTALLER_URL}" -o "${installer}" \
    || die "could not download the official Codex CLI installer"
  sh -n "${installer}" || die "the downloaded Codex CLI installer is not valid POSIX shell"
  PATH="${HOME}/.local/bin:${PATH}" \
    CODEX_INSTALL_DIR="${HOME}/.local/bin" \
    CODEX_NON_INTERACTIVE=true \
    CODEX_INSTALLER_USE_RELEASES_OPENAI_COM=true \
    sh "${installer}" \
    || die "the official Codex CLI installer failed"
  [[ -x ${HOME}/.local/bin/codex ]] \
    || die "the Codex CLI installer did not create ~/.local/bin/codex"
  "${HOME}/.local/bin/codex" --version >/dev/null \
    || die "the installed Codex CLI is not runnable"
  note "Codex CLI: current official standalone release installed"
}

install_claude_cli() {
  local installer=${WORK_DIR}/claude-install.sh
  curl --proto '=https' --tlsv1.2 -fsSL "${CLAUDE_INSTALLER_URL}" -o "${installer}" \
    || die "could not download the official Claude Code installer"
  bash -n "${installer}" || die "the downloaded Claude Code installer is not valid Bash"
  PATH="${HOME}/.local/bin:${PATH}" bash "${installer}" \
    || die "the official Claude Code installer failed"
  [[ -x ${HOME}/.local/bin/claude ]] \
    || die "the Claude Code installer did not create ~/.local/bin/claude"
  "${HOME}/.local/bin/claude" --version >/dev/null \
    || die "the installed Claude Code CLI is not runnable"
  note "Claude Code: current official native release installed (self-updating)"
}

# Removes the pacman/AUR builds the native installs replace. The AUR
# antigravity package owns /opt/Antigravity, so it must go before the AppImage
# install claims that path; the CLI packages go after their native successors
# are in place so the commands are never missing.
remove_retired_ai_pkgs_arch() {
  local package installed=()
  for package in "$@"; do
    if pacman -Q "${package}" &>/dev/null; then
      installed+=("${package}")
    fi
  done
  if (( ! ${#installed[@]} )); then
    note "pacman/AUR builds replaced by native installs: absent ($*)"
    return 0
  fi
  sudo pacman -Rns --noconfirm "${installed[@]}" \
    || die "could not remove packages replaced by native installs: ${installed[*]}"
  for package in "${installed[@]}"; do
    ! pacman -Q "${package}" &>/dev/null \
      || die "${package} is still installed"
  done
  note "removed in favor of self-updating native installs: ${installed[*]}"
}

verify_native_ai_tools_arch() {
  local package
  for package in "${RETIRED_AI_PKGS[@]}" antigravity-ide; do
    ! pacman -Q "${package}" &>/dev/null \
      || die "${package} is still installed"
  done
  [[ -x ${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage ]] \
    || die "the Antigravity AppImage is not installed"
  command -v antigravity >/dev/null \
    || die "the antigravity command is unavailable"
  for package in agy claude codex; do
    [[ -x ${HOME}/.local/bin/${package} ]] \
      || die "the native ${package} command is missing from ~/.local/bin"
  done
  "${HOME}/.local/bin/agy" --version >/dev/null 2>&1 \
    || die "the installed Antigravity CLI is not runnable"
  note "Antigravity AppImage, agy, claude, codex: native and self-updating"
}

# Rust comes only from rustup. rustup conflicts with Arch's rust package, so
# a non-interactive transaction cannot swap them; remove the distro toolchain
# (and its version-pinned split packages) and install rustup immediately so
# cargo/rustc are absent only for the length of this step.
installed_rust_distro_pkgs() {
  local package
  INSTALLED_RUST_DISTRO_PKGS=()
  for package in "${RUST_DISTRO_PKGS[@]}"; do
    if pacman -Q "${package}" &>/dev/null; then
      INSTALLED_RUST_DISTRO_PKGS+=("${package}")
    fi
  done
}

transition_rust_to_rustup_arch() {
  installed_rust_distro_pkgs
  if (( ! ${#INSTALLED_RUST_DISTRO_PKGS[@]} )); then
    note "distro Rust packages: absent"
    return 0
  fi
  sudo pacman -Rdd --noconfirm "${INSTALLED_RUST_DISTRO_PKGS[@]}" \
    || die "could not remove distro Rust before installing rustup: ${INSTALLED_RUST_DISTRO_PKGS[*]}"
  ! pacman -Q rust &>/dev/null || die "rust is still installed"
  sudo pacman -S --needed --noconfirm rustup \
    || die "could not install rustup after removing distro Rust"
  pacman -Q rustup &>/dev/null || die "rustup was not installed after the Rust transition"
  note "distro Rust replaced by rustup: ${INSTALLED_RUST_DISTRO_PKGS[*]}"
}

# rustup_state: read the per-user rustup state from disk without running
# rustup (which may auto-install toolchains). Sets RUSTUP_DEFAULT_SET,
# RUSTUP_TOOLCHAIN_PRESENT and RUSTUP_MISSING_COMPONENTS.
rustup_state() {
  local home=${RUSTUP_HOME:-${HOME}/.rustup} component components=''
  local toolchain=${home}/toolchains/${RUST_TOOLCHAIN}
  RUSTUP_DEFAULT_SET=0
  RUSTUP_TOOLCHAIN_PRESENT=0
  RUSTUP_MISSING_COMPONENTS=()
  if [[ -f ${home}/settings.toml ]] \
     && grep -Eq '^[[:space:]]*default_toolchain[[:space:]]*=' "${home}/settings.toml"; then
    RUSTUP_DEFAULT_SET=1
  fi
  [[ -d ${toolchain} ]] && RUSTUP_TOOLCHAIN_PRESENT=1
  if [[ -f ${toolchain}/lib/rustlib/components ]]; then
    components=$(<"${toolchain}/lib/rustlib/components")
  fi
  for component in "${RUST_COMPONENTS[@]}"; do
    grep -Eq "^${component}(-|$)" <<<"${components}" \
      || RUSTUP_MISSING_COMPONENTS+=("${component}")
  done
}

# Per-user stable toolchain. Existing project overrides and a non-stable
# default are preserved; only an unset default becomes stable.
configure_rustup_toolchain() {
  command -v rustup >/dev/null || die "rustup is not installed"
  rustup_state
  if (( ! RUSTUP_TOOLCHAIN_PRESENT || ! NO_UPGRADE )); then
    rustup toolchain install stable --profile minimal --no-self-update \
      || die "could not install/update the rustup stable toolchain"
  fi
  rustup_state
  if (( ${#RUSTUP_MISSING_COMPONENTS[@]} )); then
    rustup component add --toolchain stable "${RUSTUP_MISSING_COMPONENTS[@]}" \
      || die "could not add Rust components: ${RUSTUP_MISSING_COMPONENTS[*]}"
  fi
  if (( ! RUSTUP_DEFAULT_SET )); then
    rustup default stable || die "could not set the rustup default toolchain"
  fi
  rustup_state
  (( RUSTUP_TOOLCHAIN_PRESENT && RUSTUP_DEFAULT_SET && ! ${#RUSTUP_MISSING_COMPONENTS[@]} )) \
    || die "rustup stable toolchain is incomplete"
  note "rustup stable + ${RUST_COMPONENTS[*]}: present"
}

# microcode_package: print the microcode package for this CPU, if any.
microcode_package() {
  local vendor
  vendor=$(awk -F ': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null) || vendor=
  case ${vendor} in
    AuthenticAMD) printf 'amd-ucode\n' ;;
    GenuineIntel) printf 'intel-ucode\n' ;;
  esac
}

# sync_dbs_present: succeed only when every configured repository already has
# a sync database, which --no-upgrade needs to install without syncing.
sync_dbs_present() {
  local db_path repo repos
  db_path=$(pacman-conf DBPath 2>/dev/null) || db_path=/var/lib/pacman/
  repos=$(pacman-conf --repo-list 2>/dev/null) || die "could not read /etc/pacman.conf"
  while IFS= read -r repo; do
    [[ -z ${repo} || -s ${db_path%/}/sync/${repo}.db ]] || return 1
  done <<<"${repos}"
}

#--- Security helpers (ClamAV, firewalld, auditd, AIDE, Wazuh) --------------

# render_clamd_config <base-config> <downloads-dir>...: print the managed
# clamd config. clamd.conf has no glob support for OnAccessIncludePath, so the
# watched directories are generated at apply time from the invoking user's
# $HOME; apply installs this exact rendering and --check compares against it,
# keeping drift well-defined.
render_clamd_config() {
  local base=$1 path
  shift
  cat -- "${base}"
  printf '# Generated at apply time by setup-arch-workstation.sh: watched\n'
  printf '# Downloads directories (realtime coverage is Downloads-only).\n'
  for path in "$@"; do
    printf 'OnAccessIncludePath %s\n' "${path}"
  done
}

# clamav_db_missing <db-dir>: true while the main or daily definition database
# is absent (each ships as .cvd or the freshclam-optimized .cld form). Arch's
# clamav-daemon units gate on exactly these files (ConditionPathExistsGlob),
# so the database must exist before the daemon is started.
clamav_db_missing() {
  local db_dir=$1
  [[ -f ${db_dir}/main.cvd || -f ${db_dir}/main.cld ]] || return 0
  [[ -f ${db_dir}/daily.cvd || -f ${db_dir}/daily.cld ]] || return 0
  return 1
}

# bootstrap_clamav_db <db-dir>: one-time `sudo freshclam`. The running
# freshclam daemon holds the update lock, so it is stopped first (and
# restarted afterwards by the caller's enable+start). Optional dir keeps the
# mocked test unprivileged. No SELinux relabelling exists on Arch.
# shellcheck disable=SC2120
bootstrap_clamav_db() {
  local db_dir=${1:-/var/lib/clamav}
  if ! clamav_db_missing "${db_dir}"; then
    note "ClamAV definition database: present"
    return 0
  fi
  log "Bootstrapping the ClamAV definition database (one-time freshclam)"
  if systemctl is-active --quiet clamav-freshclam.service 2>/dev/null; then
    sudo systemctl stop clamav-freshclam.service \
      || die "could not stop clamav-freshclam.service, which holds the freshclam lock"
  fi
  sudo freshclam || die "freshclam could not download the initial database"
  clamav_db_missing "${db_dir}" \
    && die "freshclam completed but ${db_dir} still lacks the main/daily database"
  note "ClamAV definition database: bootstrapped"
}

# ensure_started_unit <unit> <changed>: start the unit now (the user wants
# protection immediately, unlike the enable-only SERVICES set), restart it
# only when its configuration actually changed, and fail closed.
ensure_started_unit() {
  local unit=$1 changed=$2
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    if (( changed )); then
      sudo systemctl restart "${unit}" || die "could not restart ${unit}"
      note "${unit}: restarted (configuration changed)"
    else
      note "${unit}: active"
    fi
  else
    sudo systemctl start "${unit}" || die "could not start ${unit}"
    note "${unit}: started"
  fi
  systemctl is-active --quiet "${unit}" || die "${unit} did not become active"
}

# render_lan_zone <service>...: print the source-bound workstation-lan zone.
# The service list is decided by select_profile, so profile-gated ports never
# open for profiles that do not install the service behind them. Apply
# installs this exact rendering; --check compares against it.
render_lan_zone() {
  local service
  printf '<?xml version="1.0" encoding="utf-8"?>\n'
  printf '<zone>\n'
  printf '  <short>Workstation LAN</short>\n'
  printf '  <description>Trusted LAN (192.168.1.0/24) and SD-WAN (192.168.2.0/23) sources: services that must never be reachable from the Internet. firewalld classifies each packet into exactly one zone, so SSH is listed here too: LAN peers never fall through to the default workstation zone, which keeps SSH reachable for WAN port forwarding.</description>\n'
  printf '  <source address="192.168.1.0/24"/>\n'
  printf '  <source address="192.168.2.0/23"/>\n'
  for service in "$@"; do
    printf '  <service name="%s"/>\n' "${service}"
  done
  printf '</zone>\n'
}

# render_wazuh_config <stock-ossec.conf> <manager>: the agent configuration
# with the manager address applied and local log collection appended: the
# audit log (Wazuh's audit log format understands the rules installed by this
# script) and the ClamAV journal units (journald collection, Wazuh 4.8+;
# clamd/clamonacc log via syslog to the journal, so there is no plain file to
# tail). Pure stdout so tests can render it offline.
render_wazuh_config() {
  local conf=$1 manager=$2
  sed -e "s|<address>[^<]*</address>|<address>${manager}</address>|" -- "${conf}" \
    | awk '
        { lines[NR] = $0 }
        index($0, "/var/log/audit/audit.log") { have_audit = 1 }
        index($0, "clamav-clamonacc.service") { have_clamav = 1 }
        END {
          stanza_audit = \
            "  <localfile>\n" \
            "    <log_format>audit</log_format>\n" \
            "    <location>/var/log/audit/audit.log</location>\n" \
            "  </localfile>"
          stanza_clamav = \
            "  <localfile>\n" \
            "    <log_format>journald</log_format>\n" \
            "    <location>clamav-clamonacc.service</location>\n" \
            "  </localfile>\n" \
            "  <localfile>\n" \
            "    <log_format>journald</log_format>\n" \
            "    <location>clamav-media-scan.service</location>\n" \
            "  </localfile>"
          for (i = NR; i >= 1; i--)
            if (lines[i] == "</ossec_conf>") break
          for (j = 1; j <= NR; j++) {
            if (j == i) {
              if (!have_audit) print stanza_audit
              if (!have_clamav) print stanza_clamav
            }
            print lines[j]
          }
        }'
}

# Install the rendered ossec.conf. Split from render_wazuh_config so the
# manager-gated enable logic stays testable without /var/ossec.
# shellcheck disable=SC2120
configure_wazuh_agent() {
  local conf=${1:-/var/ossec/etc/ossec.conf}
  local rendered=${WORK_DIR}/ossec.conf
  local count
  [[ -f ${conf} ]] || die "the Wazuh agent configuration ${conf} is missing"
  count=$(grep -c '<address>' -- "${conf}" || true)
  # The stock agent ossec.conf has exactly one <address> (the manager entry
  # under <client><server>); a different layout means someone customized it
  # and blind editing could corrupt it.
  (( count == 1 )) \
    || die "unexpected Wazuh agent configuration (${count} <address> elements in ${conf}); configure it manually"
  render_wazuh_config "${conf}" "${WAZUH_MANAGER}" >"${rendered}"
  put_file -s "${rendered}" "${conf}"
  grep -Fq "<address>${WAZUH_MANAGER}</address>" -- "${conf}" \
    || die "the manager address did not land in ${conf}"
  # The awk append silently no-ops when </ossec_conf> is missing, so verify
  # the audit-log stanza landed too instead of trusting the rendering.
  grep -Fq '<location>/var/log/audit/audit.log</location>' -- "${conf}" \
    || die "the audit log collection stanza did not land in ${conf}"
}

# wazuh_service_action: enable+start the agent for a configured manager, or
# disable+stop it when none is (a running agent would only log connection
# failures, and an enrolled-but-orphaned agent is worse than a disabled one).
# Split out so the manager gating is testable with a mocked systemctl.
wazuh_service_action() {
  if [[ -n ${WAZUH_MANAGER} ]]; then
    sudo systemctl enable --now wazuh-agent \
      || die "could not enable wazuh-agent for manager ${WAZUH_MANAGER}"
    systemctl is-active --quiet wazuh-agent \
      || die "wazuh-agent did not become active for manager ${WAZUH_MANAGER}"
    note "wazuh-agent: configured for ${WAZUH_MANAGER} and started"
  else
    if systemctl is-enabled --quiet wazuh-agent 2>/dev/null \
       || systemctl is-active --quiet wazuh-agent 2>/dev/null; then
      sudo systemctl disable --now wazuh-agent \
        || die "could not disable wazuh-agent (no manager configured)"
    fi
    ! systemctl is-active --quiet wazuh-agent 2>/dev/null \
      || die "wazuh-agent is still active without a configured manager"
    note "wazuh-agent: left disabled (no --wazuh-manager supplied)"
  fi
}

#--- Check / dry-run --------------------------------------------------------
CHECK_DRIFT=0
CHECK_CURRENT=0
report() {
  local status=$1
  shift
  printf '%-8s %s\n' "${status}" "$*"
  case ${status} in
    DRIFT)   CHECK_DRIFT=$((CHECK_DRIFT + 1)) ;;
    CURRENT) CHECK_CURRENT=$((CHECK_CURRENT + 1)) ;;
  esac
}

# check_managed_file <user|root> <src> <dst> <mode>: the read-only mirror of
# put_file's convergence test.
check_managed_file() {
  local owner=$1 src=$2 dst=$3 mode=$4 uid=${EUID} gid expected_mode
  gid=$(id -g) || die "could not determine the current user's primary group"
  if [[ ${owner} == root ]]; then uid=0; gid=0; fi
  expected_mode=$(printf '%o' "$((8#${mode}))")
  if [[ -f ${dst} && ! -L ${dst} ]] && cmp -s -- "${src}" "${dst}" \
     && [[ $(stat -c '%a:%u:%g' -- "${dst}") == "${expected_mode}:${uid}:${gid}" ]]; then
    report CURRENT "${dst}"
  else
    report DRIFT "${dst}: differs from files/${src#"${FILES}"/} (content, type, mode or owner)"
  fi
}

# check_packages <label> <name>...: report every missing package (pacman -T
# against the local database; groups expanded from the existing sync DBs).
check_packages() {
  local label=$1 package
  shift
  expand_groups "$@"
  find_missing_pkgs "${WANTED_PKGS[@]}"
  for package in "${MISSING_PKGS[@]}"; do
    report DRIFT "${label} package ${package}: not installed"
  done
  (( ${#MISSING_PKGS[@]} )) \
    || report CURRENT "${label} packages (${#WANTED_PKGS[@]})"
}

# check_system_state: locale, vi link and GRUB config (split out for tests).
check_system_state() {
  if grep -Eq '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8([[:space:]]|$)' /etc/locale.gen 2>/dev/null \
     && locale -a 2>/dev/null | grep -Fxi 'en_US.utf8' >/dev/null; then
    report CURRENT "en_US.UTF-8 locale"
  else
    report DRIFT "en_US.UTF-8 locale: not enabled/generated"
  fi
  if [[ -L /usr/bin/vi && $(readlink -f -- /usr/bin/vi) == $(readlink -f -- /usr/bin/vim) ]]; then
    report CURRENT "/usr/bin/vi -> vim"
  else
    report DRIFT "/usr/bin/vi: not a link to vim"
  fi
  if [[ -s /boot/grub/grub.cfg ]]; then
    report CURRENT "/boot/grub/grub.cfg: present"
  else
    report DRIFT "/boot/grub/grub.cfg: missing"
  fi
}

# check_security_state: read-only mirror of the security steps (split out for
# tests, like check_system_state). The two *rendered* files are compared
# against the same deterministic rendering the apply steps install.
check_security_state() {
  local unit
  if cmp -s \
      <(render_clamd_config "${FILES}/etc/clamav/clamd.conf" "${HOME}/Downloads") \
      /etc/clamav/clamd.conf; then
    report CURRENT "/etc/clamav/clamd.conf (rendered)"
  else
    report DRIFT "/etc/clamav/clamd.conf: differs from the rendered configuration"
  fi
  if cmp -s <(render_lan_zone "${FIREWALL_LAN_SERVICES[@]}") \
      /etc/firewalld/zones/workstation-lan.xml; then
    report CURRENT "/etc/firewalld/zones/workstation-lan.xml (rendered)"
  else
    report DRIFT "/etc/firewalld/zones/workstation-lan.xml: differs from the rendered zone"
  fi
  for unit in clamav-freshclam.service clamav-daemon.service \
              clamav-clamonacc.service clamav-media-scan.service \
              firewalld.service auditd.service aide-check.timer; do
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
      report CURRENT "${unit}: enabled"
    else
      report DRIFT "${unit}: not enabled"
    fi
  done
  # /var/lib/aide is root-only (0700), so an unprivileged test always fails;
  # ask sudo non-interactively and say so when it cannot answer.
  if sudo -n test -f /var/lib/aide/aide.db.gz 2>/dev/null; then
    report CURRENT "AIDE database"
  elif sudo -n true 2>/dev/null; then
    report NOTE "AIDE database: initialized after the AUR phase on apply"
  else
    report NOTE "AIDE database: unverified (root-only /var/lib/aide; run sudo -v first)"
  fi
  if pacman -Q wazuh-agent &>/dev/null; then
    if [[ -n ${WAZUH_MANAGER} ]]; then
      systemctl is-enabled --quiet wazuh-agent 2>/dev/null \
        && report CURRENT "wazuh-agent: enabled" \
        || report DRIFT "wazuh-agent: not enabled for ${WAZUH_MANAGER}"
    else
      ! systemctl is-active --quiet wazuh-agent 2>/dev/null \
        && report CURRENT "wazuh-agent: installed and disabled (no manager configured)" \
        || report DRIFT "wazuh-agent: active without a configured manager"
    fi
  else
    report NOTE "wazuh-agent: installed by the AUR phase on apply"
  fi
}

run_check() {
  local repo_list group_output group package_line version comparison entry
  local owner src dst mode unit package
  CHECK_DRIFT=0
  CHECK_CURRENT=0
  printf 'Profile: %s; mode: check (read-only)\n' "${PROFILE}"

  repo_list=$(pacman-conf --repo-list 2>/dev/null) || die "could not read /etc/pacman.conf"
  if grep -qx multilib <<<"${repo_list}"; then
    report CURRENT "[multilib]: enabled"
  elif [[ ${PROFILE} == full ]]; then
    report DRIFT "[multilib]: disabled (required by the full profile)"
  else
    report CURRENT "[multilib]: not required by the core profile"
  fi

  pacman -Q antigravity-ide &>/dev/null \
    && report DRIFT "legacy antigravity-ide: installed (will be removed)"
  if package_line=$(pacman -Q antigravity 2>/dev/null); then
    version=${package_line#* }
    comparison=$(vercmp "${version}" 2.0.0) \
      || die "could not compare the installed Antigravity version"
    (( comparison >= 0 )) \
      || report DRIFT "legacy Antigravity ${version}: installed (2.0+ required)"
  fi
  pacman -Q vscodium-bin &>/dev/null \
    && report DRIFT "vscodium-bin: installed (replaced by code)"
  for package in "${RETIRED_AI_PKGS[@]}"; do
    pacman -Q "${package}" &>/dev/null \
      && report DRIFT "${package}: installed (replaced by a self-updating native install)"
  done
  if [[ -x ${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage ]]; then
    report CURRENT "Antigravity AppImage: ${ANTIGRAVITY_INSTALL_DIR}"
  else
    report DRIFT "Antigravity AppImage: not installed under ${ANTIGRAVITY_INSTALL_DIR}"
  fi
  for package in agy claude codex; do
    if [[ -x ${HOME}/.local/bin/${package} ]]; then
      report CURRENT "native ${package}: ~/.local/bin/${package}"
    else
      report DRIFT "native ${package}: missing from ~/.local/bin"
    fi
  done
  pacman -Q jre-openjdk &>/dev/null \
    && report DRIFT "jre-openjdk: installed (replaced by jdk-openjdk)"
  installed_rust_distro_pkgs
  (( ${#INSTALLED_RUST_DISTRO_PKGS[@]} )) \
    && report DRIFT "distro Rust: ${INSTALLED_RUST_DISTRO_PKGS[*]} installed (replaced by rustup)"
  pacman -Q mkinitcpio &>/dev/null \
    && report DRIFT "mkinitcpio: installed (replaced by dracut)"

  # pacman -Sg reads only the existing sync databases; it never downloads.
  IS_GROUP=()
  group_output=$(pacman -Sg) || die "could not enumerate pacman groups"
  while read -r group _; do
    [[ -n ${group} ]] && IS_GROUP[${group}]=1
  done <<<"${group_output}"
  check_packages official "${PKGS_OFFICIAL[@]}"
  check_packages AUR "${PKGS_AUR[@]}"

  rustup_state
  if (( RUSTUP_TOOLCHAIN_PRESENT && RUSTUP_DEFAULT_SET && ! ${#RUSTUP_MISSING_COMPONENTS[@]} )); then
    report CURRENT "rustup stable + ${RUST_COMPONENTS[*]}"
  else
    (( RUSTUP_TOOLCHAIN_PRESENT )) || report DRIFT "rustup: stable toolchain not installed"
    (( RUSTUP_DEFAULT_SET )) || report DRIFT "rustup: no default toolchain"
    (( ! ${#RUSTUP_MISSING_COMPONENTS[@]} )) \
      || report DRIFT "rustup: missing components ${RUSTUP_MISSING_COMPONENTS[*]}"
  fi

  for entry in "${MANAGED_FILES[@]}"; do
    IFS='|' read -r owner src dst mode <<<"${entry}"
    check_managed_file "${owner}" "${FILES}/${src}" "${dst}" "${mode}"
  done
  if [[ -f ${HOME}/.config/monitors.xml ]]; then
    check_managed_file root "${HOME}/.config/monitors.xml" /etc/xdg/monitors.xml 0644
  fi
  check_system_state
  check_security_state

  for unit in "${SERVICES[@]}" cockpit.socket; do
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
      report CURRENT "${unit}: enabled"
    else
      report DRIFT "${unit}: not enabled"
    fi
  done
  report NOTE "initramfs images are validated only on apply (inspection needs sudo)"

  printf '\nResult: %s current, %s drift\n' "${CHECK_CURRENT}" "${CHECK_DRIFT}"
  (( CHECK_DRIFT == 0 )) || return 2
}

# print_plan: the offline --dry-run plan. Reads only this script's lists and
# /proc/cpuinfo, so it also runs on non-Arch hosts.
print_plan() {
  local entry owner src dst mode microcode package count
  printf 'Profile: %s; mode: dry-run (offline, nothing is changed)\n' "${PROFILE}"
  if [[ ${PROFILE} == full ]]; then
    printf 'PLAN: enable [multilib] in /etc/pacman.conf if disabled (backup /etc/pacman.conf.pre-workstation)\n'
  else
    printf 'PLAN: [multilib] not required by core; left as configured\n'
  fi
  printf 'PLAN: remove legacy antigravity-ide / Antigravity < 2.0 and vscodium-bin if installed\n'
  if (( NO_UPGRADE )); then
    printf 'PLAN: --no-upgrade: skip pacman -Syu; refuse unless every repository sync DB exists\n'
  else
    printf 'PLAN: sudo pacman -Syu --noconfirm\n'
  fi
  printf 'PLAN: replace jre-openjdk with jdk-openjdk if installed\n'
  printf 'PLAN: replace distro Rust (%s) with rustup if installed\n' "${RUST_DISTRO_PKGS[*]}"
  microcode=$(microcode_package)
  count=${#PKGS_OFFICIAL[@]}
  if [[ -n ${microcode} ]]; then count=$((count + 1)); fi
  printf 'PLAN: install missing official packages (%s entries; groups expanded on the host):\n' \
    "${count}"
  for package in "${PKGS_OFFICIAL[@]}" ${microcode:+"${microcode}"}; do
    printf '  %s\n' "${package}"
  done
  printf 'PLAN: rustup stable toolchain + %s; default stable if unset%s\n' \
    "${RUST_COMPONENTS[*]}" "$( (( NO_UPGRADE )) && printf '; no update' )"
  printf 'PLAN: managed files (installed when content, mode or owner differs):\n'
  for entry in "${MANAGED_FILES[@]}"; do
    IFS='|' read -r owner src dst mode <<<"${entry}"
    printf '  files/%s -> %s (%s, %s)\n' "${src}" "${dst}" "${mode}" "${owner}"
  done
  printf '  ~/.config/monitors.xml -> /etc/xdg/monitors.xml (if present)\n'
  printf 'PLAN: en_US.UTF-8 in /etc/locale.gen + locale-gen; /usr/bin/vi -> vim\n'
  printf 'PLAN: dracut images regenerated/validated when boot packages change; remove mkinitcpio; grub-mkconfig when needed\n'
  printf 'PLAN: enable services:\n'
  for package in "${SERVICES[@]}"; do
    printf '  %s\n' "${package}"
  done
  printf '  cockpit.socket (enable --now)\n'
  printf 'PLAN: ClamAV: freshclam daemon + one-time DB bootstrap, clamav-daemon,\n'
  printf '      notify-only on-access for ~/Downloads, /run/media mount watcher (read-only scans)\n'
  printf 'PLAN: firewalld workstation default zone (ssh, plex-remote, dhcpv6-client, mdns; reject\n'
  printf '      otherwise) + workstation-lan source zone (192.168.1.0/24, 192.168.2.0/23):\n'
  printf '  %s\n' "${FIREWALL_LAN_SERVICES[*]}"
  printf 'PLAN: auditd with curated high-signal rules (no per-execve logging);\n'
  printf '      the Arch kernel already enables CONFIG_AUDIT (no grub change)\n'
  printf 'PLAN: AIDE config-scoped baseline over /etc, /usr/local, /root\n'
  printf '      (database initialized after the AUR phase; daily check timer)\n'
  printf 'PLAN: Wazuh agent (AUR wazuh-agent)%s\n' \
    "$( if [[ -n ${WAZUH_MANAGER} ]]; then printf ': configured for %s and enabled after the AUR phase' "${WAZUH_MANAGER}"; else printf '; left disabled (pass --wazuh-manager)'; fi )"
  printf 'PLAN: dconf update for the GDM database when its font setting changes\n'
  printf 'PLAN: native self-updating AI tools (%s):\n' \
    "$( (( NO_UPGRADE )) && echo 'missing only' || echo 'latest verified release')"
  printf '  %s\n' 'Antigravity AppImage -> /opt/Antigravity (user-owned)' \
    'agy -> ~/.local/bin' 'claude -> ~/.local/bin (official installer)' \
    'codex -> ~/.local/bin (official installer)'
  printf 'PLAN: remove pacman/AUR builds replaced by the native installs: %s\n' \
    "${RETIRED_AI_PKGS[*]}"
  printf 'PLAN: bootstrap yay-bin from the AUR if needed (interactive PKGBUILD review)\n'
  if (( NO_UPGRADE )); then
    printf 'PLAN: --no-upgrade: skip yay -Sua --devel\n'
  else
    printf 'PLAN: yay -Sua --devel (interactive review)\n'
  fi
  printf 'PLAN: install missing AUR packages (%s):\n' "${#PKGS_AUR[@]}"
  for package in "${PKGS_AUR[@]}"; do
    printf '  %s\n' "${package}"
  done
  printf 'PLAN: verify native Antigravity + CLI/Claude/Codex and the claude code codex opencode zed cargo rustc commands\n'
}

#--- Preflight --------------------------------------------------------------
if [[ ${MODE} == dry-run ]]; then
  print_plan
  exit 0
fi

[[ ${EUID} -ne 0 ]] || die "Run as your normal user, not root (AUR builds refuse to run as root; sudo is used where needed)."
[[ -f /etc/arch-release ]] || die "This script is for Arch Linux."
[[ $(uname -m) == x86_64 ]] || die "This package set targets Arch Linux x86_64."
[[ -d ${FILES} ]] || die "Payload directory not found: ${FILES}"
command -v pacman-conf >/dev/null || die "pacman-conf is required."
command -v cmp >/dev/null || die "cmp (diffutils) is required."
pacman -Q pacman &>/dev/null || die "the local pacman database is not readable."
[[ -f /etc/pacman.conf ]] || die "/etc/pacman.conf is missing."
[[ -d /boot/grub ]] || die "This setup targets an existing GRUB installation; /boot/grub is missing."

MICROCODE=$(microcode_package)
if [[ -n ${MICROCODE} ]]; then
  PKGS_OFFICIAL+=("${MICROCODE}")
else
  warn "CPU vendor not recognized; no microcode package will be selected"
fi

WORK_DIR=$(mktemp -d)
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

if [[ ${MODE} == check ]]; then
  run_check
  exit 0
fi

command -v sudo >/dev/null || die "sudo is required."
log "Profile: ${PROFILE}$( (( NO_UPGRADE )) && printf ' (--no-upgrade)' )"
log "Authenticating sudo"
sudo -v || die "sudo authentication failed"

log "Retired workstation packages"
purge_legacy_antigravity_arch
purge_replaced_editor_arch

#--- 1. [multilib] ----------------------------------------------------------
# Must be enabled before any lib32-* / steam package can be installed. Only the
# full profile needs it; core leaves an already-enabled repository alone.
log "[multilib] repository"
repo_list=$(pacman-conf --repo-list 2>/dev/null) || die "could not read /etc/pacman.conf"
if grep -qx multilib <<<"${repo_list}"; then
  note "enabled"
elif [[ ${PROFILE} != full ]]; then
  note "not required by the core profile; left disabled"
else
  cp -- /etc/pacman.conf "${WORK_DIR}/pacman.conf"
  sed -Ei \
    -e 's/^[[:space:]]*#[[:space:]]*\[multilib\][[:space:]]*$/[multilib]/' \
    -e '/^\[multilib\][[:space:]]*$/,/^\[/{s/^[[:space:]]*#[[:space:]]*(Include[[:space:]]*=)/\1/}' \
    "${WORK_DIR}/pacman.conf"
  repo_list=$(pacman-conf --config "${WORK_DIR}/pacman.conf" --repo-list 2>/dev/null) \
    || die "the generated pacman.conf is invalid"
  grep -qx multilib <<<"${repo_list}" \
    || die "could not enable [multilib] in a validated temporary pacman.conf"
  if [[ ! -e /etc/pacman.conf.pre-workstation ]]; then
    sudo cp -a -- /etc/pacman.conf /etc/pacman.conf.pre-workstation
    note "saved /etc/pacman.conf.pre-workstation"
  fi
  put_file -s "${WORK_DIR}/pacman.conf" /etc/pacman.conf
  repo_list=$(pacman-conf --repo-list 2>/dev/null) || die "could not re-read /etc/pacman.conf"
  grep -qx multilib <<<"${repo_list}" || die "[multilib] is still disabled after installation"
  note "enabled in /etc/pacman.conf"
fi

# Capture boot-package state so kernel, microcode, GRUB, NVIDIA, and initramfs
# changes can trigger the follow-ups they require.
boot_package_state() {
  local package line
  for package in linux linux-lts dracut grub intel-ucode amd-ucode \
                 nvidia-open nvidia-open-lts mkinitcpio; do
    if line=$(pacman -Q "${package}" 2>/dev/null); then
      printf '%s\n' "${line}"
    else
      printf '%s <absent>\n' "${package}"
    fi
  done
}
BOOT_STATE_BEFORE=$(boot_package_state)

#--- 2. Official packages ---------------------------------------------------
if (( NO_UPGRADE )); then
  sync_dbs_present \
    || die "--no-upgrade needs an existing sync database for every enabled repository (a newly enabled [multilib] has none); rerun without --no-upgrade"
  warn "--no-upgrade: skipping pacman -Syu. Installing against stale sync databases is a partial upgrade (unsupported on Arch) and can fail on rotated mirror files."
else
  log "Syncing databases and applying updates (pacman -Syu)"
  sudo pacman -Syu --noconfirm
fi

transition_openjdk_runtime_arch
transition_rust_to_rustup_arch

log "Official package set (${#PKGS_OFFICIAL[@]} entries)"
group_output=$(pacman -Sg) || die "could not enumerate pacman groups"
while read -r group _; do
  [[ -n ${group} ]] && IS_GROUP[${group}]=1
done <<<"${group_output}"
expand_groups "${PKGS_OFFICIAL[@]}"
find_missing_pkgs "${WANTED_PKGS[@]}"
if (( ${#MISSING_PKGS[@]} )); then
  note "installing ${#MISSING_PKGS[@]} missing: ${MISSING_PKGS[*]}"
  sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
else
  note "all ${#WANTED_PKGS[@]} packages present"
fi

log "Rust (rustup stable toolchain)"
configure_rustup_toolchain

#--- 3. Dotfiles and system config ------------------------------------------
log "Dotfiles"
put_file "${FILES}/bashrc" "${HOME}/.bashrc"
put_file "${FILES}/vimrc"  "${HOME}/.vimrc"

log "System config"
GRUB_REBUILD=0
put_file -s "${FILES}/grub" /etc/default/grub
(( PUT_FILE_CHANGED )) && GRUB_REBUILD=1
put_file -s "${FILES}/etc/bash.bashrc" /etc/bash.bashrc
# /etc/pacman.conf is deliberately not managed (files/etc/pacman.conf is
# kept for reference); the manifest had this disabled as well:
#   put_file -s "${FILES}/etc/pacman.conf" /etc/pacman.conf
put_file -s "${FILES}/etc/locale.conf" /etc/locale.conf

LOCALE_REBUILD=0
if ! grep -Eq '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8([[:space:]]|$)' /etc/locale.gen; then
  cp -- /etc/locale.gen "${WORK_DIR}/locale.gen"
  sed -Ei 's/^[[:space:]]*#[[:space:]]*(en_US\.UTF-8[[:space:]]+UTF-8([[:space:]]|$))/\1/' \
    "${WORK_DIR}/locale.gen"
  if ! grep -Eq '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8([[:space:]]|$)' "${WORK_DIR}/locale.gen"; then
    printf '\nen_US.UTF-8 UTF-8\n' >>"${WORK_DIR}/locale.gen"
  fi
  put_file -s "${WORK_DIR}/locale.gen" /etc/locale.gen
  LOCALE_REBUILD=1
fi
if ! locale -a | grep -Fxi 'en_US.utf8' >/dev/null; then
  LOCALE_REBUILD=1
fi
if (( LOCALE_REBUILD )); then
  sudo locale-gen
  note "en_US.UTF-8 locale: generated"
else
  note "en_US.UTF-8 locale: present"
fi

put_file -s "${FILES}/etc/sysctl.d/99-inotify.conf" /etc/sysctl.d/99-inotify.conf
if (( PUT_FILE_CHANGED )); then
  sudo sysctl -q -p /etc/sysctl.d/99-inotify.conf
fi
put_file -s "${FILES}/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
put_file -s "${FILES}/etc/cron.daily/pacman-update" /etc/cron.daily/pacman-update 0755
ensure_symlink -s /usr/bin/vim /usr/bin/vi

#--- 4. dracut / mkinitcpio / GRUB ------------------------------------------
# Installing dracut alone does not trigger its ALPM hook for kernels that were
# already installed. Rebuild and validate every exact Arch image before the old
# generator is removed.
log "dracut initramfs validation"
command -v dracut >/dev/null || die "dracut was not installed"
command -v lsinitrd >/dev/null || die "lsinitrd was not installed"

BOOT_STATE_AFTER=$(boot_package_state)
DRACUT_REBUILD=0
[[ ${BOOT_STATE_BEFORE} == "${BOOT_STATE_AFTER}" ]] || DRACUT_REBUILD=1
pacman -Q mkinitcpio &>/dev/null && DRACUT_REBUILD=1

kernel_count=0
for pkgbase_file in /usr/lib/modules/*/pkgbase; do
  [[ -f ${pkgbase_file} ]] || continue
  (( kernel_count += 1 ))
  kver=${pkgbase_file#/usr/lib/modules/}
  kver=${kver%/pkgbase}
  read -r pkgbase <"${pkgbase_file}"
  image=/boot/initramfs-${pkgbase}.img
  if ! sudo test -s "${image}" \
     || ! sudo lsinitrd "${image}" 2>/dev/null | grep -F "modules/${kver}/" >/dev/null; then
    DRACUT_REBUILD=1
  fi
done
(( kernel_count )) || die "no installed kernels with /usr/lib/modules/*/pkgbase were found"

if (( DRACUT_REBUILD )); then
  sudo dracut --force --regenerate-all
  GRUB_REBUILD=1
  note "regenerated all installed-kernel images"
else
  note "all installed-kernel images are current"
fi

for pkgbase_file in /usr/lib/modules/*/pkgbase; do
  [[ -f ${pkgbase_file} ]] || continue
  kver=${pkgbase_file#/usr/lib/modules/}
  kver=${kver%/pkgbase}
  read -r pkgbase <"${pkgbase_file}"
  image=/boot/initramfs-${pkgbase}.img
  sudo test -s "${image}" || die "dracut did not produce ${image}"
  sudo lsinitrd "${image}" 2>/dev/null | grep -F "modules/${kver}/" >/dev/null \
    || die "${image} does not contain modules for ${kver}"
done

log "mkinitcpio"
if pacman -Q mkinitcpio &>/dev/null; then
  sudo pacman -Rsn --noconfirm mkinitcpio
  GRUB_REBUILD=1
  note "removed"
else
  note "not installed"
fi

if (( GRUB_REBUILD )) || [[ ! -s /boot/grub/grub.cfg ]]; then
  sudo grub-mkconfig -o /boot/grub/grub.cfg
  note "GRUB configuration regenerated"
else
  note "GRUB configuration: up to date"
fi

#--- 5. Services ------------------------------------------------------------
# Enabled only, not started: they come up on the next boot (starting gdm
# from inside a session would tear that session down)
log "Services"
for unit in "${SERVICES[@]}"; do
  enable_unit "${unit}"
done

log "Cockpit (https://localhost:9090)"
sudo systemctl enable --now cockpit.socket

#--- 6. GDM -----------------------------------------------------------------
log "GDM"
# Give the login screen the user's monitor layout
if [[ -f ${HOME}/.config/monitors.xml ]]; then
  put_file -s "${HOME}/.config/monitors.xml" /etc/xdg/monitors.xml
else
  note "no ~/.config/monitors.xml - not publishing a monitor layout to GDM"
fi
# Font setting for the login screen; dconf update compiles the gdm database
put_file -s "${FILES}/etc/dconf/db/gdm.d/10-font-settings" /etc/dconf/db/gdm.d/10-font-settings
if (( PUT_FILE_CHANGED )) || [[ ! -f /etc/dconf/db/gdm ]]; then
  sudo dconf update
  note "dconf database updated"
fi

#--- 7. Native self-updating AI tools ---------------------------------------
# --no-upgrade resolves vendor manifests only when an Antigravity piece is missing.
if (( ! NO_UPGRADE )) || [[ ! -x ${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage \
      || ! -x ${HOME}/.local/bin/agy ]]; then
  log "Resolving latest verified Antigravity releases"
  resolve_antigravity_desktop_release
  resolve_antigravity_cli_release
  note "resolved Antigravity ${ANTIGRAVITY_VERSION} and Antigravity CLI ${ANTIGRAVITY_CLI_VERSION}"
fi

log "Antigravity 2.0+ desktop (self-updating AppImage) + CLI"
command -v fusermount >/dev/null || die "fuse2 did not provide fusermount for the AppImage"
remove_retired_ai_pkgs_arch antigravity
if (( NO_UPGRADE )) && [[ -x ${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage ]]; then
  note "Antigravity: installed; kept at its current version (--no-upgrade)"
else
  install_antigravity_desktop
fi
if (( NO_UPGRADE )) && [[ -x ${HOME}/.local/bin/agy ]]; then
  note "agy: installed; kept at its current version (--no-upgrade)"
else
  install_antigravity_cli
fi

log "Codex CLI (official standalone release)"
if (( NO_UPGRADE )) && [[ -x ${HOME}/.local/bin/codex ]]; then
  note "codex: installed; kept at its current version (--no-upgrade)"
else
  install_codex_cli
fi

log "Claude Code (official native release)"
if (( NO_UPGRADE )) && [[ -x ${HOME}/.local/bin/claude ]]; then
  note "claude: installed; kept at its current version (--no-upgrade)"
else
  install_claude_cli
fi
remove_retired_ai_pkgs_arch antigravity-cli claude-code openai-codex

#--- 8. ClamAV ---------------------------------------------------------------
# Light footprint by design: realtime coverage for ~/Downloads (where browser
# downloads land) plus newly mounted removable media, not all of /home.
# Everything is notify-only; nothing is ever blocked or quarantined
# automatically (the packaged clamonacc unit's --move=/root/quarantine is
# reset by the drop-in below).
log "ClamAV (freshclam, clamav-daemon, Downloads on-access, media scan)"
CLAMD_CONF_CHANGED=0
CLAMONACC_CONF_CHANGED=0
SYSTEMD_RELOAD=0
render_clamd_config "${FILES}/etc/clamav/clamd.conf" "${HOME}/Downloads" \
  >"${WORK_DIR}/clamd.conf"
put_file -s "${WORK_DIR}/clamd.conf" /etc/clamav/clamd.conf
(( PUT_FILE_CHANGED )) && CLAMD_CONF_CHANGED=1
put_file -s "${FILES}/etc/systemd/system/clamav-clamonacc.service.d/50-arch-workstation.conf" /etc/systemd/system/clamav-clamonacc.service.d/50-arch-workstation.conf
(( PUT_FILE_CHANGED )) && CLAMONACC_CONF_CHANGED=1 SYSTEMD_RELOAD=1
MEDIA_SCAN_CHANGED=0
put_file -s "${FILES}/usr/local/libexec/clamav-media-scan" /usr/local/libexec/clamav-media-scan 0755
(( PUT_FILE_CHANGED )) && MEDIA_SCAN_CHANGED=1
put_file -s "${FILES}/etc/systemd/system/clamav-media-scan.service" /etc/systemd/system/clamav-media-scan.service
(( PUT_FILE_CHANGED )) && MEDIA_SCAN_CHANGED=1 SYSTEMD_RELOAD=1
# Earlier revisions triggered the scan from a clamav-media-scan.path unit,
# which only ever saw /run/media/<user> being created (the first drive per
# boot); the long-running watcher service replaces it.
if [[ -e /etc/systemd/system/clamav-media-scan.path ]]; then
  sudo systemctl disable --now clamav-media-scan.path 2>/dev/null || true
  sudo rm -f /etc/systemd/system/clamav-media-scan.path
  SYSTEMD_RELOAD=1
  note "clamav-media-scan.path: retired (replaced by the watcher service)"
fi
if (( SYSTEMD_RELOAD )); then
  sudo systemctl daemon-reload
fi
# The DB bootstrap must precede the clamav-daemon start: both the daemon and
# its socket unit carry ConditionPathExistsGlob on the database files and
# would refuse to start (leaving clamonacc looping on a missing socket).
bootstrap_clamav_db /var/lib/clamav
enable_unit clamav-freshclam.service
enable_unit clamav-daemon.service
enable_unit clamav-clamonacc.service
ensure_started_unit clamav-freshclam.service 0
# Restarting clamav-daemon propagates a stop to clamonacc (Requires=), so
# clamonacc is only restarted when its own drop-in changed; otherwise the
# start below converges it - no double restart.
ensure_started_unit clamav-daemon.service "${CLAMD_CONF_CHANGED}"
ensure_started_unit clamav-clamonacc.service "${CLAMONACC_CONF_CHANGED}"
enable_unit clamav-media-scan.service
ensure_started_unit clamav-media-scan.service "${MEDIA_SCAN_CHANGED}"

#--- 9. Firewall -------------------------------------------------------------
# See the zone files under files/etc/firewalld/ for the policy. libvirt and
# podman manage their own zones (libvirt/trusted on virbr0/podman*) and are
# deliberately left alone.
log "Firewall (firewalld: workstation default + workstation-lan source zone)"
if pacman -Q ufw &>/dev/null; then
  warn "ufw is installed; firewalld does not merge with other firewall front-ends. Remove ufw or keep exactly one enabled."
fi
FIREWALL_CHANGED=0
put_file -s "${FILES}/etc/firewalld/zones/workstation.xml" /etc/firewalld/zones/workstation.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
render_lan_zone "${FIREWALL_LAN_SERVICES[@]}" >"${WORK_DIR}/workstation-lan.xml"
put_file -s "${WORK_DIR}/workstation-lan.xml" /etc/firewalld/zones/workstation-lan.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
# The service definitions are installed unconditionally: a definition only
# names ports, the rendered workstation-lan zone decides which are actually
# opened for the selected profile.
put_file -s "${FILES}/etc/firewalld/services/navidrome.xml" /etc/firewalld/services/navidrome.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
put_file -s "${FILES}/etc/firewalld/services/owntone.xml" /etc/firewalld/services/owntone.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
put_file -s "${FILES}/etc/firewalld/services/plexmediaserver.xml" /etc/firewalld/services/plexmediaserver.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
put_file -s "${FILES}/etc/firewalld/services/steam-streaming.xml" /etc/firewalld/services/steam-streaming.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
put_file -s "${FILES}/etc/firewalld/services/transmission.xml" /etc/firewalld/services/transmission.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
put_file -s "${FILES}/etc/firewalld/services/iperf3.xml" /etc/firewalld/services/iperf3.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
put_file -s "${FILES}/etc/firewalld/services/lancache.xml" /etc/firewalld/services/lancache.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
put_file -s "${FILES}/etc/firewalld/services/plex-remote.xml" /etc/firewalld/services/plex-remote.xml
(( PUT_FILE_CHANGED )) && FIREWALL_CHANGED=1
enable_unit firewalld.service
systemctl is-active --quiet firewalld.service || sudo systemctl start firewalld.service
systemctl is-active --quiet firewalld.service \
  || die "firewalld did not become active"
if [[ $(firewall-cmd --get-default-zone 2>/dev/null) == workstation ]]; then
  note "default zone: workstation"
else
  sudo firewall-cmd --set-default-zone workstation
  [[ $(firewall-cmd --get-default-zone 2>/dev/null) == workstation ]] \
    || die "could not make workstation the default firewalld zone"
  note "default zone: workstation (set now)"
fi
# Move every interface that landed in a stock general-purpose zone into
# workstation so the reject policy actually covers them. Virtualization and
# container interfaces stay put.
STOCK_ZONES='block dmz drop external home internal public trusted work'
while read -r zone interface; do
  [[ -n ${zone} && -n ${interface} ]] || continue
  if grep -qw "${zone}" <<<"${STOCK_ZONES}"; then
    # --permanent only, and deliberately so: NetworkManager-owned interfaces
    # take their zone from the NM connection profile instead (reconciled in
    # the nmcli step below), while interfaces NM does not own get an
    # <interface> entry persisted into the managed workstation.xml here --
    # acceptable drift that --check reports for that zone file.
    sudo firewall-cmd --permanent --zone=workstation --change-interface="${interface}"
    FIREWALL_CHANGED=1
    note "${interface}: moved from ${zone} to workstation"
  fi
done < <(firewall-cmd --get-active-zones 2>/dev/null | awk '
  /^[^ ]/ { zone = $1; next }
  /^  interfaces:/ { sub(/^  interfaces: */, ""); for (i = 1; i <= NF; i++) print zone, $i }
')
# NetworkManager pins a connection to its zone when one is set explicitly;
# clear pins to retired stock zones so re-activations follow the new default.
if command -v nmcli >/dev/null; then
  while read -r connection zone; do
    [[ -n ${connection} && -n ${zone} ]] || continue
    if grep -qw "${zone}" <<<"${STOCK_ZONES}"; then
      sudo nmcli connection modify "${connection}" connection.zone ""
      note "connection ${connection}: zone pin ${zone} cleared"
    fi
  done < <(nmcli -g NAME,connection.zone connection show 2>/dev/null \
    | awk -F: 'length($2) > 0 { print $1, $2 }')
fi
if (( FIREWALL_CHANGED )); then
  sudo firewall-cmd --reload
  note "firewalld reloaded"
fi
# Fail closed: verify the effective policy.
[[ $(firewall-cmd --get-default-zone 2>/dev/null) == workstation ]] \
  || die "the default firewalld zone is not workstation"
for lan_source in 192.168.1.0/24 192.168.2.0/23; do
  firewall-cmd --zone=workstation-lan --list-sources 2>/dev/null \
    | grep -qw "${lan_source}" \
    || die "workstation-lan does not include ${lan_source}"
done
while read -r zone interface; do
  [[ -n ${zone} && -n ${interface} ]] || continue
  grep -qw "${zone}" <<<"${STOCK_ZONES}" \
    && die "${interface} is still in the stock zone ${zone}"
done < <(firewall-cmd --get-active-zones 2>/dev/null | awk '
  /^[^ ]/ { zone = $1; next }
  /^  interfaces:/ { sub(/^  interfaces: */, ""); for (i = 1; i <= NF; i++) print zone, $i }
')
note "workstation-lan services: ${FIREWALL_LAN_SERVICES[*]}"

#--- 10. auditd --------------------------------------------------------------
# Arch's official kernel builds CONFIG_AUDIT=y and CONFIG_AUDITSYSCALL=y, so
# auditd works without an audit=1 kernel parameter and /etc/default/grub is
# deliberately left alone.
log "auditd (curated high-signal rules)"
AUDIT_RULES_CHANGED=0
put_file -s "${FILES}/etc/audit/rules.d/50-workstation.rules" /etc/audit/rules.d/50-workstation.rules
(( PUT_FILE_CHANGED )) && AUDIT_RULES_CHANGED=1
enable_unit auditd.service
# Started now (not merely enabled): the rules only protect once loaded.
systemctl is-active --quiet auditd.service || sudo systemctl start auditd.service
systemctl is-active --quiet auditd.service || die "auditd did not become active"
if (( AUDIT_RULES_CHANGED )); then
  sudo augenrules --load || die "could not load the audit rules"
  # The watch rules above show up as key-tagged entries in auditctl -l.
  sudo auditctl -l 2>/dev/null | grep -q 'key=identity' \
    || die "the identity audit rules are not loaded (auditctl -l)"
  note "audit rules loaded"
fi

#--- 11. AIDE (config; the database waits for the AUR-built binary) ---------
log "AIDE (configuration integrity baseline)"
put_file -s "${FILES}/etc/aide.conf" /etc/aide.conf
put_file -s "${FILES}/etc/systemd/system/aide-check.service" /etc/systemd/system/aide-check.service
AIDE_UNIT_CHANGED=${PUT_FILE_CHANGED}
put_file -s "${FILES}/etc/systemd/system/aide-check.timer" /etc/systemd/system/aide-check.timer
(( PUT_FILE_CHANGED )) && AIDE_UNIT_CHANGED=1
(( AIDE_UNIT_CHANGED )) && sudo systemctl daemon-reload
note "AIDE database initialization and timer: after the AUR phase below"

#--- 12. AUR -----------------------------------------------------------------
# AUR PKGBUILDs are third-party code. Keep this phase last so an AUR build
# cannot alter user-writable repository payloads before they are installed as
# root, drop the setup script's cached sudo credential, and leave yay's review
# prompts enabled. The AUR set includes the security tooling that upstream
# does not package (aide, wazuh-agent); their privileged follow-ups run in
# step 13, after the interactive builds.
log "AUR packages (interactive review required)"
warn "AUR PKGBUILDs execute third-party code. Read yay's diffs before approving builds."
sudo -k

if command -v yay >/dev/null && yay --version >/dev/null 2>&1; then
  note "yay: present and runnable"
else
  git clone -q --depth 1 "${YAY_AUR_URL}" "${WORK_DIR}/yay-bin"
  [[ -t 0 ]] || die "yay bootstrap requires an interactive terminal to review its PKGBUILD"
  printf '\n--- yay-bin PKGBUILD (review before continuing) ---\n'
  sed -n '1,240p' "${WORK_DIR}/yay-bin/PKGBUILD"
  printf '%s' 'Build and install this yay-bin PKGBUILD? [y/N] '
  read -r answer
  [[ ${answer} == y || ${answer} == Y ]] || die "yay-bin bootstrap declined"
  ( cd "${WORK_DIR}/yay-bin" && makepkg -si )
  command -v yay >/dev/null && yay --version >/dev/null 2>&1 \
    || die "yay did not end up runnable after makepkg -si"
  note "installed yay-bin"
fi

# Yay records VCS source commits as it installs packages. Generate that database
# only when it is absent, which also covers packages migrated from another AUR
# helper without resetting known commit baselines on every setup run.
if [[ ! -f ${YAY_VCS_DB} ]]; then
  log "Initializing yay development-package database"
  yay -Y --gendb
fi

if (( NO_UPGRADE )); then
  note "--no-upgrade: installed AUR packages are not updated"
else
  log "Updating installed AUR packages (including VCS/devel packages)"
  yay -Sua --devel
fi

log "AUR package set (${#PKGS_AUR[@]} entries)"
find_missing_pkgs "${PKGS_AUR[@]}"
if (( ${#MISSING_PKGS[@]} )); then
  note "installing ${#MISSING_PKGS[@]} missing: ${MISSING_PKGS[*]}"
  yay -S --needed "${MISSING_PKGS[@]}"
else
  note "all ${#PKGS_AUR[@]} packages present"
fi

verify_native_ai_tools_arch
for command_name in claude code codex opencode zed; do
  PATH="${HOME}/.local/bin:${PATH}" command -v "${command_name}" >/dev/null \
    || die "expected workstation command is unavailable: ${command_name}"
done
for command_name in cargo rustc; do
  command -v "${command_name}" >/dev/null \
    || die "rustup did not provide ${command_name}"
done
! pacman -Q vscodium-bin &>/dev/null || die "VSCodium is still installed"
pacman -Q aide &>/dev/null || die "the AUR phase did not install aide"
pacman -Q wazuh-agent &>/dev/null || die "the AUR phase did not install wazuh-agent"

#--- 13. AIDE database + Wazuh enablement (after the AUR phase) --------------
# The AUR phase dropped the cached sudo credential on purpose, so
# re-authenticate here - but only when work actually remains, keeping
# converged reruns prompt-free.
log "AIDE database and Wazuh agent (post-AUR)"
# /var/lib/aide is root-only, so the database cannot be tested before
# re-authenticating; the timer is only enabled after a successful init, so an
# enabled+active timer stands in for "database present".
aide_work=0
systemctl is-enabled --quiet aide-check.timer 2>/dev/null || aide_work=1
systemctl is-active --quiet aide-check.timer 2>/dev/null || aide_work=1
wazuh_work=0
if [[ -n ${WAZUH_MANAGER} ]]; then
  wazuh_work=1
else
  systemctl is-enabled --quiet wazuh-agent 2>/dev/null && wazuh_work=1
  systemctl is-active --quiet wazuh-agent 2>/dev/null && wazuh_work=1
fi
if (( aide_work || wazuh_work )); then
  sudo -v || die "sudo re-authentication failed for the post-AUR security steps"
fi
if (( aide_work )) && ! sudo test -f /var/lib/aide/aide.db.gz; then
  # One-time baseline. Deliberately not re-run after updates: see the scope
  # rationale in files/etc/aide.conf (pacman -Qkk covers packaged files).
  sudo aide --init || die "could not initialize the AIDE database"
  sudo test -f /var/lib/aide/aide.db.new.gz \
    || die "aide --init did not produce /var/lib/aide/aide.db.new.gz"
  sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz \
    || die "could not activate the AIDE database"
  note "AIDE database initialized (configuration scope)"
else
  note "AIDE database: present"
fi
if (( aide_work )); then
  sudo systemctl enable --now aide-check.timer
  systemctl is-active --quiet aide-check.timer \
    || die "aide-check.timer did not become active"
fi
if [[ -n ${WAZUH_MANAGER} ]]; then
  configure_wazuh_agent
  wazuh_service_action
else
  wazuh_service_action
fi

log "Done. Kernel/initramfs/GRUB changes and newly enabled services take effect on the next boot."
