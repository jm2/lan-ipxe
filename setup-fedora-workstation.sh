#!/usr/bin/env bash
#
# Idempotent Fedora Workstation setup. Replaces the former comtrya manifest
# fedora_workstation.yaml (comtrya is unmaintained upstream). Targets Fedora
# 41+ (dnf5) on x86_64 and aarch64, including Fedora Asahi Remix.
#
# Run as your normal user - NOT root - from any directory: the config payloads
# are resolved relative to this script (files/). Privileged steps go through
# sudo (one password prompt; the timestamp is kept alive for the whole run).
#
# Profiles (--profile, default core):
#   core  every developer toolchain, -devel library, editor, agent, browser,
#         Cockpit (including machines/podman) and desktop setting
#   full  core plus games (Lutris, Steam and its i686 libraries, the
#         io.jor.* Flatpaks) and media extras (Navidrome, OwnTone, Plex,
#         Rhythmbox, Brasero, the Transmission GUI/daemon/remote)
# Modes: --dry-run prints the plan offline (no sudo, network, or writes);
# --check reports CURRENT/DRIFT read-only and exits 2 on drift;
# --no-upgrade installs only what is missing and keeps installed versions.
#
# Safe to re-run: every step checks state first, config files are rewritten
# only when their content, type, mode, or ownership differs (and relabelled for SELinux when
# they are), package/Flatpak steps apply available updates and install what is
# missing, and the follow-ups that only a real change needs (sysctl reload,
# dconf update) run only then. A converged system avoids repeating those
# mutations; vendor installers that manage their own release channel may still
# perform a lightweight update check.
#
# What it does, in order:
#   1. signed third-party repos: VS Code, the jmsqrd/tributary and
#      jmsqrd/balun coprs, RPM Fusion free+nonfree, Chrome, sing-box; on
#      x86_64 also Microsoft (PowerShell), plus (full) the RPM Fusion steam
#      repo and Plex Media Server. The abandoned Antigravity 1.x RPM
#      repo/package, VSCodium and the Claude Code RPM repo/key are retired in
#      favor of native Antigravity 2.0+, VS Code and native Claude Code.
#   2. CA-bundle symlinks at the Debian-style paths some tools hard-code
#   3. the dnf package set, including native Chrome and Chromium on both
#      architectures (plus the x86_64-only PowerShell RPM and Intel VA driver);
#      full adds the games/media packages, the x86_64-only i686 libs, Steam
#      and Plex Media Server, then the latest Navidrome release RPM,
#      checksummed from its GitHub release metadata, and OwnTone built into an
#      RPM from its checksummed latest release tarball with
#      files/rpm/owntone.spec
#   4. Antigravity desktop 2.0+, Antigravity CLI, OpenCode, Claude Code,
#      Codex CLI, and Zed using the latest native vendor artifacts/installers
#      (checksummed from live upstream release metadata where upstream
#      publishes digests). Antigravity, its CLI, Claude Code and Codex update
#      themselves in place; reruns keep a self-updated copy rather than
#      downgrading it, and the Claude Code RPM is removed
#   5. Rust via rustup only: a per-user stable toolchain with rustfmt, clippy
#      and rust-analyzer (distro rust/cargo packages are purged)
#   6. a checksum-pinned Ookla speedtest CLI into ~/.local/bin
#   7. flathub + the flatpak set (plus x86_64-only extras; full adds games)
#   8. dotfiles (~/.bashrc, ~/.vimrc) and system config
#      from files/: /etc/locale.conf, the inotify sysctl limit, the Arch-style
#      prompt as /etc/profile.d/01-arch-prompt.sh
#   9. the service set, graphical.target as default, Cockpit, and automatic
#      DNF updates with the controller's apply-updates/reboot-when-needed policy
#  10. ClamAV: freshclam daemon + one-time DB bootstrap, clamd@scan with a
#      real LocalSocket, notify-only on-access scanning of the invoking
#      user's ~/Downloads, and a mount-table watcher that read-only-scans each
#      newly mounted USB/removable drive under /run/media (never whole-/home on-access: the
#      DDD watch cannot follow later mounts, and developer trees are noisy)
#  11. firewalld: a custom workstation default zone (SSH broadly reachable
#      because WAN port forwarding is in use; everything else rejected) plus a
#      source-bound workstation-lan zone for the LAN 192.168.1.0/24 and the
#      SD-WAN 192.168.2.0/23 with the profile's LAN services
#  12. auditd with curated high-signal rules (identity/auth files, sudoers,
#      sshd config, unit/cron/shell-rc persistence, module loads, time
#      changes, mounts, auditd itself; no per-execve logging)
#  13. AIDE, scoped to configuration trees (/etc, /usr/local, /root) because
#      rpm -Va already verifies package-owned files and a whole-tree baseline
#      would drown in nightly-update noise; database initialized once, daily
#      check via systemd timer
#  14. the Wazuh agent (client only) from Wazuh's signed repository: installed
#      always, but configured for a manager and enabled only when
#      --wazuh-manager/WAZUH_MANAGER is supplied; the agent version must not
#      exceed the future manager's, so the repository stays disabled by
#      default and upgrades never happen implicitly
#  15. publishes ~/.config/monitors.xml to GDM and applies the GDM font setting

set -euo pipefail

#--- Config -----------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=${SCRIPT_DIR}/files
ARCH=$(uname -m)
FEDORA_MIN_VERSION=41

COPRS=(jmsqrd/tributary jmsqrd/balun)
# Completed with the release number after preflight; no rpm call at load time
# keeps --dry-run usable on non-Fedora hosts.
RPMFUSION_FREE_URL_BASE=https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-
RPMFUSION_NONFREE_URL_BASE=https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-
GOOGLE_KEY_URL=https://dl.google.com/linux/linux_signing_key.pub
MICROSOFT_KEY_URL=https://packages.microsoft.com/keys/microsoft.asc
MICROSOFT_KEY_FINGERPRINT=BC528686B50D79E339D3721CEB3E94ADBE1229CF
MICROSOFT_KEY_FILE=/etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY
PLEX_KEY_URL=https://downloads.plex.tv/plex-keys/PlexSign.v2.key
PLEX_KEY_FINGERPRINT=6EFFEB478A6559D75C7C4FE706C521790B9CFFDE
PLEX_KEY_FILE=/etc/pki/rpm-gpg/PLEX-RPM-GPG-KEY
# Claude Code moved from Anthropic's RPM repo to its self-updating native
# install; the repo file this script used to install and its key are retired.
LEGACY_CLAUDE_REPO=/etc/yum.repos.d/claude-code.repo
LEGACY_CLAUDE_REPO_SHA256=8489cb2a1106315f3f5884a8b3170da6d59ea003635f7852d37e6a121cf71ac3
LEGACY_CLAUDE_KEY_FILE=/etc/pki/rpm-gpg/ANTHROPIC-CLAUDE-CODE-RPM-GPG-KEY
LEGACY_CLAUDE_KEY_FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
# Wazuh publishes no fingerprint in its documentation; this pin was verified by
# fetching the key served for their documented rpm --import URL and confirming
# it is the key that actually signs packages.wazuh.com RPMs (rpm -Kv reports
# signature key ID 96B3EE5F29111145, the tail of this fingerprint; UID
# "Wazuh.com (Wazuh Signing Key) <support@wazuh.com>", created 2016-08-01).
WAZUH_KEY_URL=https://packages.wazuh.com/key/GPG-KEY-WAZUH
WAZUH_KEY_FINGERPRINT=0DCFCA5547B19D2A6099506096B3EE5F29111145
WAZUH_KEY_FILE=/etc/pki/rpm-gpg/WAZUH-RPM-GPG-KEY
WAZUH_MANAGER=${WAZUH_MANAGER:-}
SINGBOX_REPO_URL=https://sing-box.app/sing-box.repo
SINGBOX_REPO_FILE=/etc/yum.repos.d/sing-box.repo
LEGACY_ANTIGRAVITY_REPO=/etc/yum.repos.d/antigravity.repo
LEGACY_ANTIGRAVITY_REPO_SHA256=f179474ce91bed5003bb3ea4958fe940900d1e84f868ffef3cfd2e7365d4b3d9
LEGACY_ANTIGRAVITY_REPO_DISABLED_SHA256=97aa428366213a248c2ee1d0fb276481c1a14ef37fd7dd8e99ae306697f7d384
LEGACY_ANTIGRAVITY_SETTINGS=${HOME}/.config/Antigravity/User/settings.json
LEGACY_ANTIGRAVITY_SETTINGS_SHA256=aadc2b67f9758ef209bb7bfdbecd8b4f1662d8f7d225da23c14eaa25ff09db81
LEGACY_VSCODIUM_REPO=/etc/yum.repos.d/vscodium.repo
LEGACY_VSCODIUM_REPO_SHA256=0796014003d89b1c1dcd5f38d8c54e54cead5862039d7a574c28f02d3e3ac079
ANTIGRAVITY_INSTALL_DIR=/opt/Antigravity
ANTIGRAVITY_COMMAND_LINK=/usr/local/bin/antigravity
ANTIGRAVITY_DESKTOP_FILE=/usr/share/applications/antigravity.desktop
ANTIGRAVITY_ICON_FILE=/usr/share/icons/hicolor/512x512/apps/antigravity.png
ANTIGRAVITY_VERSION=
ANTIGRAVITY_DESKTOP_URL=
ANTIGRAVITY_DESKTOP_SHA512=
ANTIGRAVITY_DESKTOP_SIZE=
ANTIGRAVITY_CLI_VERSION=
ANTIGRAVITY_CLI_URL=
ANTIGRAVITY_CLI_ARCHIVE_SHA512=
ANTIGRAVITY_CLI_MANIFEST_BASE=https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests
ANTIGRAVITY_DESKTOP_MANIFEST_BASE=https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest
OPENCODE_VERSION=
OPENCODE_URL=
OPENCODE_ARCHIVE_SHA256=
OPENCODE_RELEASE_API=https://api.github.com/repos/anomalyco/opencode/releases/latest
CODEX_INSTALLER_URL=https://chatgpt.com/codex/install.sh
CLAUDE_INSTALLER_URL=https://claude.ai/install.sh
ZED_VERSION=
ZED_URL=
ZED_ARCHIVE_SHA256=
ZED_RELEASE_API=https://api.github.com/repos/zed-industries/zed/releases/latest
NAVIDROME_RELEASE_API=https://api.github.com/repos/navidrome/navidrome/releases/latest
OWNTONE_RELEASE_API=https://api.github.com/repos/owntone/owntone-server/releases/latest
OWNTONE_SPEC=${FILES}/rpm/owntone.spec
SPEEDTEST_VERSION=1.2.0
SPEEDTEST_ARCHIVE_SHA256_X86_64=5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7
SPEEDTEST_BINARY_SHA256_X86_64=31f1124c5ab8acdae6b9fe1741e704df420f9f2e7d429679fabe62075453c051
SPEEDTEST_ARCHIVE_SHA256_AARCH64=3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3
SPEEDTEST_BINARY_SHA256_AARCH64=d99fa13293f658b53eaa79fe81f4b210db39fdfc1e9698f33da3f234a6008df7
CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

# Entries may be package names, provides (vim -> vim-enhanced), name.arch,
# or @groups
PKGS=(
  abattis-cantarell-fonts
  aide
  alsa-lib-devel
  alsa-sof-firmware
  audit
  autoconf
  automake
  avahi-devel
  balun
  bash-completion
  bc
  bison
  bluez
  bluez-tools
  boost-devel
  ccache
  chromium
  chrony
  clamav
  clamav-update
  clamd
  clang
  cmake
  cockpit
  cockpit-files
  cockpit-machines
  cockpit-networkmanager
  cockpit-packagekit
  cockpit-podman
  cockpit-selinux
  cockpit-sosreport
  cockpit-storaged
  cockpit-system
  code
  colordiff
  cronie
  cups
  cups-pk-helper
  curl
  dbus-devel
  dnf5-plugin-automatic
  @development-tools
  dos2unix
  dracut
  dtc
  efibootmgr
  elfutils-libelf-devel
  erofs-utils
  ffmpeg-free-devel
  firewalld
  flatpak
  flex
  fuse
  fuse-libs
  gcc
  gdb
  genisoimage
  gettext-devel
  gh
  git
  git-lfs
  glibc-langpack-en
  gmp-devel
  @gnome-desktop
  gnome-extensions-app
  gnome-shell-extension-appindicator
  gnome-shell-extension-dash-to-dock
  gnome-shell-extension-freon
  gnome-shell-extension-system-monitor
  gnome-tweaks
  gnupg2
  htop
  iperf3
  json-c-devel
  kernel-headers
  gnutls-devel
  golang
  google-chrome-stable
  google-noto-cjk-fonts
  google-noto-emoji-color-fonts
  google-noto-sans-fonts
  google-noto-serif-fonts
  gparted
  gperf
  grub2
  gstreamer1-devel
  gtk4-devel
  hfsutils
  ImageMagick
  jq
  less
  libadwaita-devel
  libasan
  libconfuse-devel
  libcurl-devel
  libdecor-devel
  libevent-devel
  libgcrypt-devel
  libicu
  libmpc-devel
  libplist-devel
  libsodium-devel
  libstdc++-devel
  libtool
  libubsan
  libunistring-devel
  libva
  libva-utils
  libwebsockets-devel
  libxkbcommon-devel
  libxml2
  libxml2-devel
  libxslt
  lld
  lldb
  llvm
  lz4
  lzop
  maven
  meld
  mesa-vulkan-drivers
  meson
  mpfr-devel
  mpv
  nano
  ncurses-devel
  NetworkManager
  nodejs
  npm
  openal-soft-devel
  openssh-server
  openssl-devel
  openssl-libs
  pacman
  pigz
  pipewire
  pipewire-alsa
  pipewire-devel
  pipewire-pulseaudio
  pngcrush
  protobuf-c-devel
  protobuf-compiler
  pulseaudio-libs-devel
  python3-protobuf
  rpm-build
  rpmdevtools
  rsync
  ruby
  rustup
  schedtool
  SDL-devel
  seahorse
  sing-box
  sqlite
  sqlite-devel
  squashfs-tools
  sudo
  system-config-printer
  tar
  texinfo
  tmux
  transmission-cli
  tree
  tributary
  udisks2-lvm2
  unar
  vim
  vlc
  vulkan-loader
  vulkan-tools
  vulkan-validation-layers
  wget
  wireplumber
  wpa_supplicant
  zip
  zlib-ng-compat-devel
  zram-generator
)

# Full profile only: games and media extras (transmission-cli stays in core)
PKGS_FULL=(
  brasero
  lutris
  rhythmbox
  transmission
  transmission-daemon
  transmission-gtk
  transmission-remote-gtk
)

# x86_64 only: packages that exist only for that architecture
PKGS_X86_64=(
  libva-intel-media-driver
  powershell
)
# x86_64 + full: Steam, its 32-bit Steam/Wine libraries, and Plex
PKGS_FULL_X86_64=(
  glibc-devel.i686
  libstdc++-devel.i686
  libva.i686
  mesa-vulkan-drivers.i686
  plexmediaserver
  readline-devel.i686
  steam
  vulkan-loader.i686
  zlib-ng-compat-devel.i686
)

FLATPAKS=(
  net.nokyan.Resources
)
FLATPAKS_X86_64=(
  com.google.AndroidStudio
  org.getoutline.OutlineClient
  org.getoutline.OutlineManager
)
FLATPAKS_FULL=(
  io.jor.bugdom
  io.jor.bugdom2
  io.jor.cromagrally
  io.jor.nanosaur
  io.jor.nanosaur2
  io.jor.ottomatic
  io.jor.mightymike
)

SERVICES=(
  bluetooth.service
  chronyd.service
  crond.service
  gdm.service
  gnome-remote-desktop.service
  NetworkManager-dispatcher.service
  NetworkManager-wait-online.service
  NetworkManager.service
  sshd.service
)
SERVICES_FULL=(
  navidrome.service
  owntone.service
)
SERVICES_FULL_X86_64=(
  plexmediaserver.service
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

Idempotent Fedora Workstation setup: third-party repos, dnf + flatpak package
sets, rustup, native developer tools, dotfiles and system config from files/,
services, GDM settings. Run as your normal user (sudo is used for the
privileged steps); safe to re-run at any time.

  --profile core  developer toolchains, editors, agents, browsers (default)
  --profile full  core plus games and media extras
  --check         read-only state report; no sudo or network
  --dry-run       offline plan for the selected profile; no sudo, network,
                  or writes
  --no-upgrade    install only what is missing; skip system/Flatpak upgrades
                  and keep installed vendor tools at their current version
  --wazuh-manager HOST
                  write HOST into the Wazuh agent configuration and enable
                  plus start wazuh-agent (also via \$WAZUH_MANAGER). Without
                  it the agent is installed but left disabled: no manager
                  exists yet, and an agent newer than its manager cannot
                  connect.

Exit: 0 converged/dry-run, 1 error, 2 drift found by --check.
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
        *) usage >&2; die "Invalid profile: $2" ;;
      esac
      shift ;;
    --check|--dry-run)
      [[ ${MODE} == apply ]] || { usage >&2; die "Choose one of --check or --dry-run"; }
      MODE=${1#--} ;;
    --no-upgrade) NO_UPGRADE=1 ;;
    --wazuh-manager)
      (( $# >= 2 )) || { usage >&2; die "--wazuh-manager requires a host name or address"; }
      WAZUH_MANAGER=$2
      shift ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done
if [[ ${ARCH} == x86_64 ]]; then IS_X86_64=1; else IS_X86_64=0; fi
if [[ -n ${WAZUH_MANAGER} && ! ${WAZUH_MANAGER} =~ ^[A-Za-z0-9._:-]+$ ]]; then
  die "--wazuh-manager must be a host name or address: ${WAZUH_MANAGER}"
fi

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
  printf '# Generated at apply time by setup-fedora-workstation.sh: watched\n'
  printf '# Downloads directories (realtime coverage is Downloads-only).\n'
  for path in "$@"; do
    printf 'OnAccessIncludePath %s\n' "${path}"
  done
}

# clamav_db_missing <db-dir>: true while the main or daily definition database
# is absent (each ships as .cvd or the freshclam-optimized .cld form).
clamav_db_missing() {
  local db_dir=$1
  [[ -f ${db_dir}/main.cvd || -f ${db_dir}/main.cld ]] || return 0
  [[ -f ${db_dir}/daily.cvd || -f ${db_dir}/daily.cld ]] || return 0
  return 1
}

# bootstrap_clamav_db <db-dir>: one-time `sudo freshclam`. The running
# freshclam daemon holds the update lock, so it is stopped first (and
# restarted afterwards by the caller's enable+start). Optional dir keeps the
# mocked test unprivileged.
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
  # freshclam runs as the clamupdate user; labels drift when the directory was
  # first created by root (as our put_file runs do).
  if command -v restorecon >/dev/null; then
    sudo restorecon -R "${db_dir}" \
      || die "could not restore SELinux labels under ${db_dir}"
  fi
  note "ClamAV definition database: bootstrapped"
}

# clamd runs as antivirus_t and may only traverse the filesystem when this
# boolean is on (off by default); clamonacc itself is unconfined (bin_t).
ensure_antivirus_selinux_boolean() {
  local state
  if ! command -v getsebool >/dev/null; then
    note "SELinux boolean antivirus_can_scan_system: unverified (getsebool absent)"
    return 0
  fi
  # getsebool also fails outright when SELinux is disabled (not just when
  # absent); treat both the same so such hosts are neither aborted by apply
  # nor reported as drifted by --check.
  state=$(getsebool antivirus_can_scan_system 2>/dev/null) || state=
  if [[ -z ${state} ]]; then
    note "SELinux boolean antivirus_can_scan_system: unverified (getsebool failed; SELinux disabled?)"
    return 0
  fi
  if [[ ${state} == *' --> on' ]]; then
    note "SELinux boolean antivirus_can_scan_system: on"
    return 0
  fi
  sudo setsebool -P antivirus_can_scan_system on \
    || die "could not enable the antivirus_can_scan_system SELinux boolean"
  state=$(getsebool antivirus_can_scan_system 2>/dev/null)
  [[ ${state} == *' --> on' ]] \
    || die "antivirus_can_scan_system is still off after setsebool"
  note "SELinux boolean antivirus_can_scan_system: on (set now)"
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
# audit log (Wazuh's audit log format understands the rules above) and the
# ClamAV journal units (journald collection, Wazuh 4.8+; clamd/clamonacc log
# via syslog to the journal, so there is no plain file to tail). Pure stdout
# so --check-style comparisons and tests can render it offline.
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

#--- Helpers ----------------------------------------------------------------
# put_file [-s] <src> <dst> [mode]
# Installs <src> at <dst> (default mode 0644, parent dirs created) only when
# content, file type, mode, or ownership differs; -s installs root:root through
# sudo and restores the SELinux label. PUT_FILE_CHANGED is set to 1 when a
# write occurred. The helper always succeeds or exits fatally so a caller's
# conditional context cannot disable errexit and mask an install failure.
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
  if (( ${#as_root[@]} )) && command -v restorecon >/dev/null; then
    sudo restorecon "${dst}" || die "failed to restore the SELinux label on ${dst}"
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

# flatpak_install <app-id>...: system-wide from flathub, only what is missing
flatpak_install() {
  local id installed missing=()
  installed=$(flatpak list --system --app --columns=application 2>/dev/null) \
    || die "could not query the installed system Flatpaks"
  for id in "$@"; do
    grep -qx -- "${id}" <<<"${installed}" || missing+=("${id}")
  done
  if (( ${#missing[@]} )); then
    note "installing ${#missing[@]} missing: ${missing[*]}"
    sudo flatpak install -y --system --noninteractive flathub "${missing[@]}"
  else
    note "all $# flatpaks present"
  fi
}

# import_rpm_key <url> <uid-fragment> [fingerprint] [trusted-path]: when a
# fingerprint is published, always download and verify that exact key, install
# it at the root-owned path used by repository definitions, then idempotently
# offer it to RPM. Otherwise, use the UID fragment to avoid a redundant import.
import_rpm_key() {
  local url=$1 frag=$2 expected_fingerprint=${3:-} trusted_path=${4:-}
  local key_summaries key_file actual_fingerprint
  local gnupg_home=${WORK_DIR}/gnupg
  if [[ -n ${expected_fingerprint} ]]; then
    [[ -n ${trusted_path} ]] \
      || die "a trusted local path is required for fingerprint-pinned key ${frag}"
    key_file=${WORK_DIR}/$(basename "${url}")
    curl --proto '=https' --tlsv1.2 -fsSL "${url}" -o "${key_file}" \
      || die "could not download signing key: ${url}"
    install -d -m 0700 "${gnupg_home}"
    actual_fingerprint=$(GNUPGHOME="${gnupg_home}" \
      gpg --batch --show-keys --with-colons "${key_file}" 2>/dev/null \
      | awk -F: '$1 == "fpr" && !found { print toupper($10); found = 1 }') \
      || die "could not inspect signing key: ${url}"
    [[ ${actual_fingerprint} == "${expected_fingerprint}" ]] \
      || die "signing-key fingerprint mismatch for ${frag}"
    put_file -s "${key_file}" "${trusted_path}" 0644
    # rpmkeys --import is idempotent. Always offer RPM the verified key instead
    # of trusting an already-imported key merely because its UID looks right.
    sudo rpmkeys --import "${trusted_path}"
    note "key ${frag}: verified and import ensured"
    return 0
  fi
  key_summaries=$(rpm -q gpg-pubkey --qf '%{SUMMARY}\n' 2>/dev/null) \
    || die "could not query imported RPM signing keys"
  if grep -F -- "${frag}" <<<"${key_summaries}" >/dev/null; then
    note "key ${frag}: imported"
    return 0
  fi
  sudo rpmkeys --import "${url}"
  note "key ${frag}: imported now"
}

# dnf_repo_enabled <repo-id>: true only when DNF currently exposes the exact
# repository as enabled. A stale file existing under /etc/yum.repos.d is not
# treated as sufficient state.
dnf_repo_enabled() {
  local repo_output
  repo_output=$(dnf -q repolist --enabled 2>/dev/null) || return 1
  awk -v repo="$1" 'NR > 1 && $1 == repo { found = 1 } END { exit !found }' \
    <<<"${repo_output}"
}

# Retire only the exact repository file previously deployed by this project.
# A customized administrator-owned definition is disabled and preserved.
# The optional path is a test seam exercised from the migration test script.
# shellcheck disable=SC2120
remove_legacy_antigravity_repo() {
  local path=${1:-${LEGACY_ANTIGRAVITY_REPO}} sha=
  if [[ -f ${path} && ! -L ${path} ]]; then
    sha=$(sha256sum -- "${path}") || die "could not hash ${path}"
    sha=${sha%% *}
  fi
  case ${sha} in
    "${LEGACY_ANTIGRAVITY_REPO_SHA256}"|"${LEGACY_ANTIGRAVITY_REPO_DISABLED_SHA256}")
      sudo rm -f -- "${path}" || die "could not remove ${path}"
      note "legacy Antigravity RPM repository: removed"
      ;;
    *)
      if dnf_repo_enabled antigravity-rpm; then
        sudo dnf config-manager setopt antigravity-rpm.enabled=0
        dnf_repo_enabled antigravity-rpm \
          && die "could not disable the legacy Antigravity RPM repository"
      fi
      if [[ -e ${path} || -L ${path} ]]; then
        warn "Preserving customized ${path}; its legacy repository is disabled."
      else
        note "legacy Antigravity RPM repository: absent"
      fi
      ;;
  esac
}

is_supported_antigravity_desktop_version() {
  local version=$1
  [[ ${version} =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || return 1
  printf '%s\n%s\n' 2.0.0 "${version}" | LC_ALL=C sort -V -C
}

remove_legacy_antigravity_rpm() {
  local package_version epoch version extra
  if ! rpm -q --quiet antigravity; then
    note "legacy Antigravity 1.x RPM: absent"
    return 0
  fi

  # The abandoned repository shipped epoch-zero 1.x packages. Fail closed for
  # every other EVR: a current or future native RPM may legitimately reuse the
  # package name, and removing an unrecognized installation would be unsafe.
  package_version=$(rpm -q --qf '%{EPOCHNUM}\t%{VERSION}\n' antigravity 2>/dev/null) \
    || {
      warn "Preserving the installed Antigravity RPM because its epoch/version could not be determined."
      return 0
    }
  if [[ ${package_version} == *$'\n'* ]]; then
    warn "Preserving multiple installed Antigravity RPMs; automatic legacy removal requires exactly one package."
    return 0
  fi
  IFS=$'\t' read -r epoch version extra <<<"${package_version}"
  if [[ -z ${extra} && ${epoch} == 0 \
        && ${version} =~ ^1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    sudo dnf -y remove antigravity \
      || die "could not remove the legacy Antigravity 1.x RPM"
    rpm -q --quiet antigravity \
      && die "legacy Antigravity RPM is still installed"
    note "legacy Antigravity ${version} RPM: removed"
  elif [[ -z ${extra} && ${epoch} == 0 ]] \
       && is_supported_antigravity_desktop_version "${version}"; then
    note "Antigravity ${version} RPM: preserved (native 2.0.0-or-newer package)"
  else
    warn "Preserving installed Antigravity RPM with unrecognized epoch/version '${epoch:-?}:${version:-?}'; only epoch-zero stable 1.x packages are retired automatically."
  fi
}

# Optional path is used by migration tests for safe temporary fixtures.
# shellcheck disable=SC2120
remove_legacy_antigravity_settings() {
  local path=${1:-${LEGACY_ANTIGRAVITY_SETTINGS}} sha=
  if [[ ! -e ${path} && ! -L ${path} ]]; then
    note "legacy Antigravity IDE settings: absent"
    return 0
  fi
  if [[ -f ${path} && ! -L ${path} ]]; then
    sha=$(sha256sum -- "${path}") || die "could not hash ${path}"
    sha=${sha%% *}
  fi
  if [[ ${sha} == "${LEGACY_ANTIGRAVITY_SETTINGS_SHA256}" ]]; then
    rm -f -- "${path}" || die "could not remove ${path}"
    note "legacy Antigravity IDE settings: removed"
  else
    warn "Preserving customized legacy Antigravity settings at ${path}."
  fi
}

# Optional path is used by migration tests for safe temporary fixtures.
# shellcheck disable=SC2120
remove_replaced_vscodium_fedora() {
  local path=${1:-${LEGACY_VSCODIUM_REPO}} sha=
  if rpm -q --quiet codium; then
    sudo dnf -y remove codium || die "could not remove VSCodium"
    rpm -q --quiet codium && die "VSCodium is still installed"
    note "VSCodium: removed (replaced by Microsoft VS Code)"
  else
    note "VSCodium: absent"
  fi
  if [[ -f ${path} && ! -L ${path} ]]; then
    sha=$(sha256sum -- "${path}") || die "could not hash ${path}"
    sha=${sha%% *}
  fi
  if [[ ${sha} == "${LEGACY_VSCODIUM_REPO_SHA256}" ]]; then
    sudo rm -f -- "${path}" || die "could not remove ${path}"
    note "VSCodium repository: removed"
  else
    if dnf_repo_enabled gitlab.com_paulcarroty_vscodium_repo; then
      sudo dnf config-manager setopt gitlab.com_paulcarroty_vscodium_repo.enabled=0
      dnf_repo_enabled gitlab.com_paulcarroty_vscodium_repo \
        && die "could not disable the VSCodium repository"
    fi
    if [[ -e ${path} || -L ${path} ]]; then
      warn "Preserving customized ${path}; its VSCodium repository is disabled."
    else
      note "VSCodium repository: absent"
    fi
  fi
}

# The Claude Code repo file is removed only while it matches the copy this
# script installed; its signing key goes once no repo file references it.
# The optional paths are test seams exercised from the migration test script.
# shellcheck disable=SC2120
remove_legacy_claude_repo() {
  local path=${1:-${LEGACY_CLAUDE_REPO}} key=${2:-${LEGACY_CLAUDE_KEY_FILE}} sha=
  if [[ -f ${path} && ! -L ${path} ]]; then
    sha=$(sha256sum -- "${path}") || die "could not hash ${path}"
    sha=${sha%% *}
  fi
  if [[ ${sha} == "${LEGACY_CLAUDE_REPO_SHA256}" ]]; then
    sudo rm -f -- "${path}" || die "could not remove ${path}"
    note "Claude Code RPM repository: removed"
  else
    if dnf_repo_enabled claude-code; then
      sudo dnf config-manager setopt claude-code.enabled=0
      dnf_repo_enabled claude-code \
        && die "could not disable the Claude Code RPM repository"
    fi
    if [[ -e ${path} || -L ${path} ]]; then
      warn "Preserving customized ${path}; its Claude Code repository is disabled."
    else
      note "Claude Code RPM repository: absent"
    fi
  fi
  if grep -rlsF -- "${key}" /etc/yum.repos.d >/dev/null; then
    warn "Preserving ${key}: a repository file still references it."
    return 0
  fi
  if [[ -e ${key} ]]; then
    sudo rm -f -- "${key}" || die "could not remove ${key}"
  fi
  if rpmkeys --list 2>/dev/null \
      | awk -v fpr="${LEGACY_CLAUDE_KEY_FINGERPRINT,,}" 'tolower($1) == fpr { found = 1 } END { exit !found }'; then
    sudo rpmkeys --delete "${LEGACY_CLAUDE_KEY_FINGERPRINT}" \
      || die "could not remove the retired Claude Code RPM signing key"
    note "Claude Code RPM signing key: removed"
  fi
}

# Runs after the native install so a failed download never leaves the
# workstation without a claude command.
remove_legacy_claude_rpm() {
  if ! rpm -q --quiet claude-code; then
    note "Claude Code RPM: absent"
    return 0
  fi
  sudo dnf -y remove claude-code || die "could not remove the Claude Code RPM"
  rpm -q --quiet claude-code && die "the Claude Code RPM is still installed"
  note "Claude Code RPM: removed (replaced by the self-updating native install)"
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

# Sets RESOLVED_VERSION/URL/SHA256 from one stable GitHub release asset. The
# digest comes from GitHub's release metadata and is bound to the exact
# browser_download_url selected here. An optional fourth argument replaces the
# default vX.Y.Z tag pattern; its first capture group is the version. Release immutability is reported but is
# advisory because GitHub does not apply it retroactively to existing releases.
RESOLVED_VERSION=
RESOLVED_URL=
RESOLVED_SHA256=
resolve_github_release_asset() {
  local repo=$1 api=$2 asset=$3 tag_pattern=${4:-'^v([0-9]+\.[0-9]+\.[0-9]+)$'}
  local metadata line tag digest expected_prefix release_immutable
  metadata=$(fetch_release_document "${api}") \
    || die "could not query the latest ${repo} release"
  line=$(jq -er --arg asset "${asset}" '
      select(.draft == false and .prerelease == false)
      | . as $release
      | ($asset | split("{version}") | join($release.tag_name | ltrimstr("v"))) as $asset
      | [.assets[] | select(.name == $asset)] as $matches
      | select(($matches | length) == 1)
      | [$release.tag_name, $matches[0].browser_download_url,
         $matches[0].digest, ($release.immutable == true)] | @tsv
    ' <<<"${metadata}") \
    || die "latest ${repo} metadata is not one stable release with asset ${asset}"
  IFS=$'\t' read -r tag RESOLVED_URL digest release_immutable <<<"${line}"
  [[ ${tag} =~ ${tag_pattern} ]] \
    || die "latest ${repo} release has an unsupported tag '${tag}'"
  RESOLVED_VERSION=${BASH_REMATCH[1]}
  asset=${asset//\{version\}/${RESOLVED_VERSION}}
  expected_prefix="https://github.com/${repo}/releases/download/${tag}/"
  [[ ${RESOLVED_URL} == "${expected_prefix}${asset}" ]] \
    || die "latest ${repo} asset URL is outside the expected GitHub release path"
  [[ ${digest} =~ ^sha256:([[:xdigit:]]{64})$ ]] \
    || die "latest ${repo} asset has no valid published SHA-256 digest"
  RESOLVED_SHA256=${BASH_REMATCH[1],,}
  if [[ ${release_immutable} != true ]]; then
    warn "latest ${repo} release is not GitHub-immutable; continuing with its published asset digest"
  fi
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

resolve_native_tool_releases() {
  resolve_antigravity_desktop_release
  resolve_antigravity_cli_release

  resolve_github_release_asset anomalyco/opencode "${OPENCODE_RELEASE_API}" \
    "${OPENCODE_ASSET}"
  OPENCODE_VERSION=${RESOLVED_VERSION}
  OPENCODE_URL=${RESOLVED_URL}
  OPENCODE_ARCHIVE_SHA256=${RESOLVED_SHA256}

  resolve_github_release_asset zed-industries/zed "${ZED_RELEASE_API}" \
    "zed-linux-${ZED_ARCH}.tar.gz"
  ZED_VERSION=${RESOLVED_VERSION}
  ZED_URL=${RESOLVED_URL}
  ZED_ARCHIVE_SHA256=${RESOLVED_SHA256}

  note "resolved Antigravity ${ANTIGRAVITY_VERSION}, Antigravity CLI ${ANTIGRAVITY_CLI_VERSION}, OpenCode ${OPENCODE_VERSION}, and Zed ${ZED_VERSION}"
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
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}"; then
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
      && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}" \
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
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
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
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}" \
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
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}" \
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
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
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

# Optional bin directory keeps artifact/convergence tests isolated.
# shellcheck disable=SC2120
install_opencode_cli() {
  local bin_dir=${1:-${HOME}/.local/bin}
  local dest=${bin_dir}/opencode archive=${WORK_DIR}/opencode.tar.gz
  local marker=${dest}.lan-ipxe-release marker_source=${WORK_DIR}/opencode-release-marker
  local extract_dir=${WORK_DIR}/opencode current_version='' archive_sha=''
  local binary_sha='' expected_binary_sha=''
  if [[ -x ${dest} && -f ${marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}" \
     && grep -Fxq "version=${OPENCODE_VERSION}" "${marker}" \
     && grep -Fxq "asset=${OPENCODE_ASSET}" "${marker}" \
     && grep -Fxq "archive-sha256=${OPENCODE_ARCHIVE_SHA256}" "${marker}"; then
    current_version=$("${dest}" --version 2>/dev/null || true)
    binary_sha=$(sha256sum -- "${dest}") || die "could not hash ${dest}"
    binary_sha=${binary_sha%% *}
    expected_binary_sha=$(sed -n 's/^binary-sha256=//p' "${marker}" | tail -1)
    if [[ ${current_version} == "${OPENCODE_VERSION}" \
          && ${binary_sha} == "${expected_binary_sha}" ]]; then
      note "OpenCode ${OPENCODE_VERSION}: present and verified"
      return 0
    fi
  fi
  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    -o "${archive}" "${OPENCODE_URL}" \
    || die "could not download OpenCode ${OPENCODE_VERSION}"
  archive_sha=$(sha256sum -- "${archive}") || die "could not hash ${archive}"
  archive_sha=${archive_sha%% *}
  [[ ${archive_sha} == "${OPENCODE_ARCHIVE_SHA256}" ]] \
    || die "OpenCode archive checksum mismatch for ${OPENCODE_ASSET}"
  mkdir -p "${extract_dir}"
  tar -xzf "${archive}" -C "${extract_dir}" opencode \
    || die "OpenCode archive has an unexpected layout"
  current_version=$("${extract_dir}/opencode" --version 2>/dev/null) \
    || die "the verified OpenCode CLI is not runnable"
  [[ ${current_version} == "${OPENCODE_VERSION}" ]] \
    || die "OpenCode reported unexpected version ${current_version}"
  binary_sha=$(sha256sum -- "${extract_dir}/opencode") \
    || die "could not hash the extracted OpenCode binary"
  binary_sha=${binary_sha%% *}
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${OPENCODE_VERSION}" \
    "asset=${OPENCODE_ASSET}" \
    "source-url=${OPENCODE_URL}" \
    "archive-sha256=${OPENCODE_ARCHIVE_SHA256}" \
    "binary-sha256=${binary_sha}" \
    >"${marker_source}"
  put_file "${extract_dir}/opencode" "${dest}" 0755
  put_file "${marker_source}" "${marker}" 0644
  "${dest}" --version >/dev/null 2>&1 \
    || die "the installed OpenCode CLI is not runnable"
  note "OpenCode ${current_version}: installed from verified native archive"
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

# Microsoft's RHEL repo carries x86_64 PowerShell. ARM uses the official
# binary archive, with each verified release kept in its own directory.
install_powershell_arm64() {
  resolve_github_release_asset PowerShell/PowerShell \
    https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
    'powershell-{version}-linux-arm64.tar.gz'
  local archive=${WORK_DIR}/powershell.tar.gz
  local install_dir=${HOME}/.local/share/powershell/${RESOLVED_VERSION}-arm64
  local command_link=${HOME}/.local/bin/pwsh
  local version=
  [[ ! -e ${command_link} || -L ${command_link} ]] \
    || die "refusing to replace unmanaged path: ${command_link}"
  if [[ -x ${install_dir}/pwsh ]]; then
    version=$("${install_dir}/pwsh" -NoLogo -NoProfile -Command \
      '$PSVersionTable.PSVersion.ToString()') \
      || die "the installed ARM64 PowerShell is not runnable"
  fi
  if [[ ${version} != "${RESOLVED_VERSION}" ]]; then
    [[ ! -e ${install_dir} && ! -L ${install_dir} ]] \
      || die "unexpected PowerShell installation at ${install_dir}"
    curl --proto '=https' --tlsv1.2 -fL --retry 3 \
      -o "${archive}" "${RESOLVED_URL}" \
      || die "could not download ARM64 PowerShell"
    printf '%s  %s\n' "${RESOLVED_SHA256}" "${archive}" | sha256sum -c - \
      || die "PowerShell archive checksum mismatch"
    mkdir -p "${WORK_DIR}/powershell"
    tar -xzf "${archive}" -C "${WORK_DIR}/powershell"
    chmod 0755 "${WORK_DIR}/powershell/pwsh"
    version=$("${WORK_DIR}/powershell/pwsh" -NoLogo -NoProfile -Command \
      '$PSVersionTable.PSVersion.ToString()') \
      || die "the downloaded ARM64 PowerShell is not runnable"
    [[ ${version} == "${RESOLVED_VERSION}" ]] \
      || die "PowerShell reported unexpected version ${version}"
    mkdir -p "$(dirname "${install_dir}")"
    mv -- "${WORK_DIR}/powershell" "${install_dir}"
  fi
  mkdir -p "${HOME}/.local/bin"
  ensure_symlink "${install_dir}/pwsh" "${command_link}"
  note "PowerShell ${RESOLVED_VERSION}: native ARM64 release installed"
}

installed_rpm_version() {
  if rpm -q --quiet "$1"; then
    rpm -q --qf '%{VERSION}' "$1"
  fi
}

# rpm_version_at_least <installed> <release>: true when the installed dotted
# numeric version is that release or newer, so converged hosts skip the work.
rpm_version_at_least() {
  [[ $1 =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    && [[ $(printf '%s\n' "$2" "$1" | sort -V | tail -1) == "$1" ]]
}

# Navidrome publishes no repository. Install its official release RPM only
# after checking the digest GitHub publishes for that exact asset; DNF then
# upgrades in place and the package scriptlet restarts a running service.
install_navidrome() {
  local rpm_file installed_version
  resolve_github_release_asset navidrome/navidrome "${NAVIDROME_RELEASE_API}" \
    "navidrome_{version}_linux_${NAVIDROME_ARCH}.rpm"
  installed_version=$(installed_rpm_version navidrome)
  if rpm_version_at_least "${installed_version}" "${RESOLVED_VERSION}"; then
    note "Navidrome ${installed_version}: installed (latest release ${RESOLVED_VERSION})"
    return 0
  fi
  rpm_file=${WORK_DIR}/navidrome_${RESOLVED_VERSION}_linux_${NAVIDROME_ARCH}.rpm
  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    -o "${rpm_file}" "${RESOLVED_URL}" \
    || die "could not download Navidrome ${RESOLVED_VERSION}"
  printf '%s  %s\n' "${RESOLVED_SHA256}" "${rpm_file}" | sha256sum -c - \
    || die "Navidrome RPM checksum mismatch"
  sudo dnf -y install "${rpm_file}"
  installed_version=$(installed_rpm_version navidrome)
  [[ ${installed_version} == "${RESOLVED_VERSION}" ]] \
    || die "Navidrome ${RESOLVED_VERSION} did not install (found '${installed_version:-none}')"
  note "Navidrome ${RESOLVED_VERSION}: installed from verified release RPM"
}

# OwnTone has no Fedora package or repository. Build the latest upstream
# release tarball, checked against its GitHub digest, into an RPM with the
# repository's spec, then let DNF upgrade in place. The build runs unprivileged
# in WORK_DIR; only build dependencies and the finished RPM go through sudo.
install_owntone() {
  local topdir=${WORK_DIR}/rpmbuild installed_version spec tarball
  local build_log=${WORK_DIR}/owntone-build.log built_rpms=()
  resolve_github_release_asset owntone/owntone-server "${OWNTONE_RELEASE_API}" \
    'owntone-{version}.tar.xz' '^([0-9]+\.[0-9]+(\.[0-9]+)?)$'
  installed_version=$(installed_rpm_version owntone)
  if rpm_version_at_least "${installed_version}" "${RESOLVED_VERSION}"; then
    note "OwnTone ${installed_version}: installed (latest release ${RESOLVED_VERSION})"
    return 0
  fi
  spec=${topdir}/SPECS/owntone.spec
  tarball=${topdir}/SOURCES/owntone-${RESOLVED_VERSION}.tar.xz
  install -d "${topdir}/SOURCES" "${topdir}/SPECS"
  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    -o "${tarball}" "${RESOLVED_URL}" \
    || die "could not download OwnTone ${RESOLVED_VERSION}"
  printf '%s  %s\n' "${RESOLVED_SHA256}" "${tarball}" | sha256sum -c - \
    || die "OwnTone source checksum mismatch"
  install -m 0644 -- "${OWNTONE_SPEC}" "${spec}"
  sudo dnf -y builddep --define "owntone_version ${RESOLVED_VERSION}" "${spec}"
  note "building OwnTone ${RESOLVED_VERSION} from source"
  if ! rpmbuild -bb \
      --define "_topdir ${topdir}" \
      --define "owntone_version ${RESOLVED_VERSION}" \
      --define 'debug_package %{nil}' \
      "${spec}" >"${build_log}" 2>&1; then
    tail -n 60 -- "${build_log}" >&2
    die "OwnTone ${RESOLVED_VERSION} failed to build (build log tail above)"
  fi
  mapfile -t built_rpms < <(find "${topdir}/RPMS/${ARCH}" -maxdepth 1 -type f \
    -name "owntone-${RESOLVED_VERSION}-*.${ARCH}.rpm")
  (( ${#built_rpms[@]} == 1 )) \
    || die "OwnTone build did not produce exactly one ${ARCH} package"
  sudo dnf -y install "${built_rpms[0]}"
  installed_version=$(installed_rpm_version owntone)
  [[ ${installed_version} == "${RESOLVED_VERSION}" ]] \
    || die "OwnTone ${RESOLVED_VERSION} did not install (found '${installed_version:-none}')"
  note "OwnTone ${RESOLVED_VERSION}: built and installed from verified release"
}

reconcile_zed_entrypoints() {
  local install_dir=$1 command_link=$2 desktop_dest=$3
  local desktop_source=${WORK_DIR}/dev.zed.Zed.desktop
  [[ ! -e ${command_link} || -L ${command_link} ]] \
    || die "refusing to replace unmanaged path: ${command_link}"
  ensure_symlink "${install_dir}/bin/zed" "${command_link}"
  cp -- "${install_dir}/share/applications/dev.zed.Zed.desktop" "${desktop_source}"
  sed -i \
    -e "s|Icon=zed|Icon=${install_dir}/share/icons/hicolor/512x512/apps/zed.png|g" \
    -e "s|Exec=zed|Exec=${install_dir}/bin/zed|g" \
    "${desktop_source}"
  grep -Fq "Exec=${install_dir}/bin/zed" "${desktop_source}" \
    || die "could not set the managed Zed launcher executable"
  grep -Fq "Icon=${install_dir}/share/icons/hicolor/512x512/apps/zed.png" \
    "${desktop_source}" || die "could not set the managed Zed launcher icon"
  put_file "${desktop_source}" "${desktop_dest}" 0644
}

# Optional install root keeps artifact/convergence tests isolated.
# shellcheck disable=SC2120
install_zed() {
  local install_dir=${1:-${HOME}/.local/zed.app}
  local marker=${install_dir}/.lan-ipxe-release
  local archive=${WORK_DIR}/zed-linux-${ZED_ARCH}.tar.gz
  local extract_dir=${WORK_DIR}/zed-desktop
  local source_dir=${extract_dir}/zed.app
  local marker_source=${WORK_DIR}/zed-release-marker
  local command_link=${HOME}/.local/bin/zed
  local desktop_dest=${HOME}/.local/share/applications/dev.zed.Zed.desktop
  local stage=${install_dir}.lan-ipxe-stage.$$
  local backup=${install_dir}.lan-ipxe-backup.$$
  local archive_sha='' version='' reported_version=''

  [[ ! -e ${command_link} || -L ${command_link} ]] \
    || die "refusing to replace unmanaged path: ${command_link}"
  if [[ -x ${install_dir}/bin/zed \
        && -f ${install_dir}/share/applications/dev.zed.Zed.desktop \
        && -f ${install_dir}/share/icons/hicolor/512x512/apps/zed.png \
        && -f ${marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}" \
     && grep -Fxq "version=${ZED_VERSION}" "${marker}" \
     && grep -Fxq "archive-sha256=${ZED_ARCHIVE_SHA256}" "${marker}"; then
    version=$("${install_dir}/bin/zed" --version 2>/dev/null) \
      || die "the installed Zed command is not runnable"
    [[ ${version} =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] \
      || die "the managed Zed bundle reported no recognizable version: ${version}"
    reported_version=${BASH_REMATCH[1]}
    [[ ${reported_version} == "${ZED_VERSION}" ]] \
      || die "the managed Zed bundle reported unexpected version ${version}"
    reconcile_zed_entrypoints "${install_dir}" "${command_link}" "${desktop_dest}"
    note "Zed ${ZED_VERSION}: present and runnable"
    return 0
  fi

  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    -o "${archive}" "${ZED_URL}" \
    || die "could not download Zed ${ZED_VERSION}"
  archive_sha=$(sha256sum -- "${archive}") || die "could not hash ${archive}"
  archive_sha=${archive_sha%% *}
  [[ ${archive_sha} == "${ZED_ARCHIVE_SHA256}" ]] \
    || die "Zed archive checksum mismatch for ${ARCH}"
  mkdir -p "${extract_dir}"
  tar -xzf "${archive}" -C "${extract_dir}" \
    || die "could not extract the Zed archive"
  [[ -x ${source_dir}/bin/zed && -x ${source_dir}/libexec/zed-editor \
     && -f ${source_dir}/share/applications/dev.zed.Zed.desktop \
     && -f ${source_dir}/share/icons/hicolor/512x512/apps/zed.png ]] \
    || die "Zed archive has an unexpected layout"
  version=$("${source_dir}/bin/zed" --version 2>/dev/null) \
    || die "the extracted Zed command is not runnable"
  [[ ${version} =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] \
    || die "the extracted Zed command reported no recognizable version: ${version}"
  reported_version=${BASH_REMATCH[1]}
  [[ ${reported_version} == "${ZED_VERSION}" ]] \
    || die "the extracted Zed command reported unexpected version ${version}"

  [[ ! -e ${stage} && ! -L ${stage} && ! -e ${backup} && ! -L ${backup} ]] \
    || die "stale Zed staging path exists beside ${install_dir}"
  mkdir -p "$(dirname "${install_dir}")"
  cp -a -- "${source_dir}" "${stage}" \
    || die "could not stage Zed under $(dirname "${install_dir}")"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${ZED_VERSION}" \
    "archive-sha256=${ZED_ARCHIVE_SHA256}" \
    >"${marker_source}"
  install -m 0644 -- "${marker_source}" "${stage}/.lan-ipxe-release"
  if [[ -e ${install_dir} || -L ${install_dir} ]]; then
    mv -- "${install_dir}" "${backup}"
    if ! mv -- "${stage}" "${install_dir}"; then
      mv -- "${backup}" "${install_dir}" || true
      die "could not activate Zed ${ZED_VERSION}"
    fi
    rm -rf -- "${backup}"
  else
    mv -- "${stage}" "${install_dir}"
  fi
  reconcile_zed_entrypoints "${install_dir}" "${command_link}" "${desktop_dest}"
  note "Zed ${ZED_VERSION}: installed from verified official release archive"
}

# keep_installed <command|rpm:name>: with --no-upgrade, succeed (and skip the
# installer) when the tool is already present; otherwise fail so it runs.
tool_present() {
  case $1 in
    rpm:*) rpm -q --quiet -- "${1#rpm:}" 2>/dev/null ;;
    *) PATH="${HOME}/.local/bin:${PATH}" command -v "$1" >/dev/null ;;
  esac
}
keep_installed() {
  (( NO_UPGRADE )) && tool_present "$1" || return 1
  note "${1#rpm:}: installed; kept at its current version (--no-upgrade)"
}

# Fedora 45's protobuf3-c compat package Obsoletes protobuf-c < 1.5.2-52 even
# though protobuf-c 1.5.2-5 is the current library, so an earlier upgrade may
# already have replaced protobuf-c (x86_64 and i686) and protobuf-c-devel can
# then never install. Swap it back once. obsoletes=0 lets protobuf-c beat the
# installed obsoleter; disable_excludes lets the transaction see the package
# that files/etc/dnf/libdnf5.conf.d/80-protobuf3-c.conf hides from every other
# run. DNF pulls protobuf-c.i686 back in for the 32-bit libprotobuf-c users.
restore_protobuf_c() {
  if ! rpm -q --quiet protobuf3-c 2>/dev/null; then
    note "protobuf3-c: absent"
    return 0
  fi
  sudo dnf -y --setopt=obsoletes=0 --setopt=disable_excludes='*' \
    swap protobuf3-c protobuf-c \
    || die "could not replace protobuf3-c with protobuf-c"
  ! rpm -q --quiet protobuf3-c 2>/dev/null \
    || die "protobuf3-c is still installed"
  rpm -q --quiet protobuf-c 2>/dev/null \
    || die "protobuf-c was not installed in place of protobuf3-c"
  note "protobuf3-c replaced by protobuf-c"
}

# Per-user rustup is the only Rust source on every platform: distro rust/cargo
# packages are purged first (only Rust-family packages depend on them).
purge_distro_rust() {
  local pkg installed=()
  for pkg in "${DISTRO_RUST_PKGS[@]}"; do
    if rpm -q --quiet -- "${pkg}" 2>/dev/null; then
      installed+=("${pkg}")
    fi
  done
  if (( ! ${#installed[@]} )); then
    note "distro Rust packages: absent"
    return 0
  fi
  sudo dnf -y remove "${installed[@]}"
  for pkg in "${installed[@]}"; do
    ! rpm -q --quiet -- "${pkg}" 2>/dev/null \
      || die "distro package ${pkg} is still installed"
  done
  note "distro Rust packages purged in favor of rustup: ${installed[*]}"
}

install_rustup_toolchain() {
  local rustup=${CARGO_HOME:-${HOME}/.cargo}/bin/rustup
  if [[ ! -x ${rustup} ]]; then
    command -v rustup-init >/dev/null \
      || die "rustup-init is unavailable; the rustup package did not provide it"
    rustup-init -y --no-modify-path --default-toolchain stable --profile minimal
    [[ -x ${rustup} ]] || die "rustup-init did not produce ${rustup}"
    note "rustup: stable toolchain installed"
  elif (( NO_UPGRADE )) && "${rustup}" toolchain list 2>/dev/null | grep -q '^stable'; then
    note "rustup: stable toolchain kept at its current version (--no-upgrade)"
  else
    "${rustup}" toolchain install stable --profile minimal --no-self-update
  fi
  "${rustup}" default >/dev/null 2>&1 || "${rustup}" default stable
  "${rustup}" component add --toolchain stable "${RUST_COMPONENTS[@]}"
}

#--- Profile selection, dry-run plan, and read-only check -------------------
SELECTED_PKGS=()
SELECTED_FLATPAKS=()
SELECTED_SERVICES=()
SELECTED_REPOS=()
SELECTED_TOOLS=()
FIREWALL_LAN_SERVICES=()
MANAGED_FILES=()
RUST_COMPONENTS=(rustfmt clippy rust-analyzer)
DISTRO_RUST_PKGS=(rust cargo clippy rustfmt rust-analyzer rust-std-static rust-src
  rust-gdb rust-lldb rust-debugger-common rust-doc)
select_profile() {
  SELECTED_PKGS=("${PKGS[@]}")
  SELECTED_FLATPAKS=("${FLATPAKS[@]}")
  SELECTED_SERVICES=("${SERVICES[@]}")
  SELECTED_REPOS=(code google-chrome sing-box rpmfusion-free rpmfusion-nonfree)
  local copr
  for copr in "${COPRS[@]}"; do
    SELECTED_REPOS+=("copr:copr.fedorainfracloud.org:${copr/\//:}")
  done
  SELECTED_TOOLS=(antigravity agy opencode claude codex zed speedtest)
  # LAN-reachable services for the source-bound workstation-lan zone. Only
  # services whose server the profile actually installs are opened. SSH is
  # listed too: firewalld puts each packet in exactly one zone, so LAN peers
  # never fall through to the default workstation zone (where SSH stays
  # broadly reachable for WAN port forwarding) and would otherwise be
  # rejected. GNOME Remote Desktop (rdp) and Cockpit are core; iperf3 ships
  # in the core package set.
  FIREWALL_LAN_SERVICES=(ssh cockpit rdp ipp-client mdns iperf3)
  # Config payloads as source under files/|destination (no owner/mode fields:
  # --check only compares content). The *rendered* security configs
  # (/etc/clamd.d/scan.conf, /etc/firewalld/zones/workstation-lan.xml, and
  # /var/ossec/etc/ossec.conf, all generated from the invoking user's HOME,
  # the selected profile, or the Wazuh manager) are deliberately not listed
  # here; they have dedicated apply and check logic around
  # render_clamd_config, render_lan_zone, and configure_wazuh_agent instead.
  MANAGED_FILES=(
    "etc/yum.repos.d/vscode.repo|/etc/yum.repos.d/vscode.repo"
    "etc/yum.repos.d/google-chrome.repo|/etc/yum.repos.d/google-chrome.repo"
    "etc/yum.repos.d/wazuh.repo|/etc/yum.repos.d/wazuh.repo"
    "bashrc|${HOME}/.bashrc"
    "vimrc|${HOME}/.vimrc"
    "etc/locale.conf|/etc/locale.conf"
    "etc/sysctl.d/99-inotify.conf|/etc/sysctl.d/99-inotify.conf"
    "etc/systemd/zram-generator.conf|/etc/systemd/zram-generator.conf"
    "etc/bash.bashrc|/etc/profile.d/01-arch-prompt.sh"
    "etc/dnf/automatic.conf|/etc/dnf/automatic.conf"
    "etc/dnf/libdnf5.conf.d/80-protobuf3-c.conf|/etc/dnf/libdnf5.conf.d/80-protobuf3-c.conf"
    "etc/dconf/db/gdm.d/10-font-settings|/etc/dconf/db/gdm.d/10-font-settings"
    "etc/audit/rules.d/50-workstation.rules|/etc/audit/rules.d/50-workstation.rules"
    "etc/aide.conf|/etc/aide.conf"
    "etc/firewalld/zones/workstation.xml|/etc/firewalld/zones/workstation.xml"
    "etc/firewalld/services/navidrome.xml|/etc/firewalld/services/navidrome.xml"
    "etc/firewalld/services/owntone.xml|/etc/firewalld/services/owntone.xml"
    "etc/firewalld/services/plexmediaserver.xml|/etc/firewalld/services/plexmediaserver.xml"
    "etc/firewalld/services/steam-streaming.xml|/etc/firewalld/services/steam-streaming.xml"
    "etc/firewalld/services/transmission.xml|/etc/firewalld/services/transmission.xml"
    "etc/firewalld/services/iperf3.xml|/etc/firewalld/services/iperf3.xml"
    "etc/systemd/system/clamav-clamonacc.service.d/50-fedora-workstation.conf|/etc/systemd/system/clamav-clamonacc.service.d/50-fedora-workstation.conf"
    "etc/systemd/system/clamav-media-scan.service|/etc/systemd/system/clamav-media-scan.service"
    "usr/local/libexec/clamav-media-scan|/usr/local/libexec/clamav-media-scan"
    "etc/systemd/system/aide-check.service|/etc/systemd/system/aide-check.service"
    "etc/systemd/system/aide-check.timer|/etc/systemd/system/aide-check.timer"
  )
  if (( IS_X86_64 )); then
    SELECTED_PKGS+=("${PKGS_X86_64[@]}")
    SELECTED_FLATPAKS+=("${FLATPAKS_X86_64[@]}")
    SELECTED_REPOS+=(packages-microsoft-com-prod)
    MANAGED_FILES+=(
      "etc/yum.repos.d/microsoft-prod.repo|/etc/yum.repos.d/microsoft-prod.repo"
    )
  else
    # Microsoft's PowerShell RPM is x86_64-only; aarch64 uses the release tarball.
    SELECTED_TOOLS+=(pwsh)
  fi
  if [[ ${PROFILE} == full ]]; then
    SELECTED_PKGS+=("${PKGS_FULL[@]}")
    SELECTED_FLATPAKS+=("${FLATPAKS_FULL[@]}")
    SELECTED_SERVICES+=("${SERVICES_FULL[@]}")
    SELECTED_TOOLS+=(navidrome owntone)
    # Media servers join the LAN zone with the profile that installs them;
    # transmission-daemon's RPC/peer ports are full-profile only as well.
    FIREWALL_LAN_SERVICES+=(navidrome owntone transmission)
    if (( IS_X86_64 )); then
      SELECTED_PKGS+=("${PKGS_FULL_X86_64[@]}")
      SELECTED_SERVICES+=("${SERVICES_FULL_X86_64[@]}")
      SELECTED_REPOS+=(rpmfusion-nonfree-steam PlexTv)
      # Plex publishes x86_64 RPMs only; Steam's i686 stack is x86_64-only,
      # and so is its in-home streaming surface.
      FIREWALL_LAN_SERVICES+=(plexmediaserver steam-streaming)
      MANAGED_FILES+=(
        "etc/yum.repos.d/rpmfusion-nonfree-steam.repo|/etc/yum.repos.d/rpmfusion-nonfree-steam.repo"
        "etc/yum.repos.d/plex.repo|/etc/yum.repos.d/plex.repo"
      )
    fi
  fi
}

print_plan() {
  local entry
  printf 'Profile: %s; mode: dry-run (offline; no sudo, network, or writes)\n' "${PROFILE}"
  printf 'Architecture: %s; upgrades: %s\n' "${ARCH}" \
    "$( (( NO_UPGRADE )) && echo 'skipped (--no-upgrade)' || echo 'dnf upgrade --refresh + flatpak update')"
  printf 'PLAN: retire legacy Antigravity 1.x repo/package/settings, VSCodium, and the Claude Code RPM repo/key/package\n'
  printf 'PLAN: enable %d repositories:\n' "${#SELECTED_REPOS[@]}"
  printf '  %s\n' "${SELECTED_REPOS[@]}"
  printf 'PLAN: CA-bundle symlinks /etc/ssl/certs/ca-certificates.crt, /etc/pki/tls/certs/ca-bundle.crt\n'
  printf 'PLAN: exclude protobuf3-c* from DNF; swap an installed protobuf3-c back to protobuf-c\n'
  printf 'PLAN: dnf install %d entries:\n' "${#SELECTED_PKGS[@]}"
  printf '  %s\n' "${SELECTED_PKGS[@]}"
  printf 'PLAN: native vendor tools (%s):\n' \
    "$( (( NO_UPGRADE )) && echo 'missing only' || echo 'latest verified release')"
  printf '  %s\n' "${SELECTED_TOOLS[@]}"
  printf 'PLAN: rustup stable toolchain (minimal) + %s; purge installed distro rust packages\n' \
    "${RUST_COMPONENTS[*]}"
  printf 'PLAN: flathub + %d flatpaks:\n' "${#SELECTED_FLATPAKS[@]}"
  printf '  %s\n' "${SELECTED_FLATPAKS[@]}"
  printf 'PLAN: managed files:\n'
  for entry in "${MANAGED_FILES[@]}"; do
    printf '  %s -> %s\n' "files/${entry%%|*}" "${entry#*|}"
  done
  printf 'PLAN: enable %d services:\n' "${#SELECTED_SERVICES[@]}"
  printf '  %s\n' "${SELECTED_SERVICES[@]}"
  printf 'PLAN: graphical.target default, cockpit.socket, dnf5-automatic.timer\n'
  printf 'PLAN: ClamAV: freshclam daemon + one-time DB bootstrap, clamd@scan,\n'
  printf '      notify-only on-access for ~/Downloads, /run/media mount watcher (read-only scans)\n'
  printf 'PLAN: firewalld workstation default zone (ssh, dhcpv6-client, mdns; reject\n'
  printf '      otherwise) + workstation-lan source zone (192.168.1.0/24, 192.168.2.0/23):\n'
  printf '  %s\n' "${FIREWALL_LAN_SERVICES[*]}"
  printf 'PLAN: auditd with curated high-signal rules (no per-execve logging)\n'
  printf 'PLAN: AIDE baseline over /etc, /usr/local, /root (initialized once; daily check timer)\n'
  printf 'PLAN: Wazuh agent from the disabled-by-default wazuh repo%s\n' \
    "$( if [[ -n ${WAZUH_MANAGER} ]]; then printf ', configured for %s and enabled' "${WAZUH_MANAGER}"; else printf '; left disabled (pass --wazuh-manager)'; fi )"
  printf 'PLAN: publish ~/.config/monitors.xml to GDM when present; dconf update\n'
}

CHECK_DRIFT=0
check_report() {
  printf '%-8s %s\n' "$1" "$2"
  [[ $1 != DRIFT ]] || CHECK_DRIFT=1
}

package_present() {
  rpm -q --quiet -- "$1" 2>/dev/null || rpm -q --quiet --whatprovides -- "$1" 2>/dev/null
}

# check_security_state: read-only mirror of the security steps (split out so
# tests can stub the parts that need a live system). Rendered files are
# compared against the same deterministic rendering the apply steps install.
check_security_state() {
  local unit state
  if cmp -s \
      <(render_clamd_config "${FILES}/etc/clamd.d/scan.conf" "${HOME}/Downloads") \
      /etc/clamd.d/scan.conf; then
    check_report CURRENT "file /etc/clamd.d/scan.conf (rendered)"
  else
    check_report DRIFT "file /etc/clamd.d/scan.conf (rendered)"
  fi
  if cmp -s <(render_lan_zone "${FIREWALL_LAN_SERVICES[@]}") \
      /etc/firewalld/zones/workstation-lan.xml; then
    check_report CURRENT "file /etc/firewalld/zones/workstation-lan.xml (rendered)"
  else
    check_report DRIFT "file /etc/firewalld/zones/workstation-lan.xml (rendered)"
  fi
  for unit in clamav-freshclam.service clamd@scan.service clamav-clamonacc.service \
              clamav-media-scan.service firewalld.service auditd.service aide-check.timer; do
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
      check_report CURRENT "unit ${unit}"
    else
      check_report DRIFT "unit ${unit}"
    fi
  done
  if command -v getsebool >/dev/null; then
    # A failing getsebool (SELinux disabled) is a NOTE, not drift.
    state=$(getsebool antivirus_can_scan_system 2>/dev/null) || state=
    if [[ -z ${state} ]]; then
      check_report NOTE "SELinux boolean antivirus_can_scan_system: unverified (getsebool failed; SELinux disabled?)"
    elif [[ ${state} == *' --> on' ]]; then
      check_report CURRENT "SELinux boolean antivirus_can_scan_system"
    else
      check_report DRIFT "SELinux boolean antivirus_can_scan_system"
    fi
  fi
  # /var/lib/aide is root-only (0700), so an unprivileged test always fails;
  # ask sudo non-interactively and say so when it cannot answer.
  if sudo -n test -f /var/lib/aide/aide.db.gz 2>/dev/null; then
    check_report CURRENT "AIDE database"
  elif sudo -n true 2>/dev/null; then
    check_report NOTE "AIDE database: initialized on the next apply"
  else
    check_report NOTE "AIDE database: unverified (root-only /var/lib/aide; run sudo -v first)"
  fi
  if [[ -n ${WAZUH_MANAGER} ]]; then
    package_present wazuh-agent \
      && check_report CURRENT "package wazuh-agent" \
      || check_report DRIFT "package wazuh-agent"
    systemctl is-enabled --quiet wazuh-agent 2>/dev/null \
      && check_report CURRENT "unit wazuh-agent" \
      || check_report DRIFT "unit wazuh-agent"
  else
    check_report NOTE "wazuh-agent: manager not configured (pass --wazuh-manager to enable)"
  fi
}

check_state() {
  local entry pkg id unit repo repolist groups='' groups_ok=0 tool src dst
  local rustup=${CARGO_HOME:-${HOME}/.cargo}/bin/rustup components
  printf 'Profile: %s; mode: check (read-only)\n' "${PROFILE}"
  repolist=$(dnf -q repolist --enabled 2>/dev/null) || repolist=''
  for repo in "${SELECTED_REPOS[@]}"; do
    if awk -v repo="${repo}" 'NR > 1 && $1 == repo { found = 1 } END { exit !found }' \
        <<<"${repolist}"; then
      check_report CURRENT "repo ${repo}"
    else
      check_report DRIFT "repo ${repo}"
    fi
  done
  # -C keeps the group query on the local cache: --check never touches the network.
  if groups=$(dnf -q -C group list --installed 2>/dev/null); then groups_ok=1; fi
  for pkg in "${SELECTED_PKGS[@]}"; do
    if [[ ${pkg} == @* ]]; then
      if (( ! groups_ok )); then
        check_report NOTE "group ${pkg#@}: unverified (no local dnf cache)"
      elif awk -v id="${pkg#@}" '$1 == id { found = 1 } END { exit !found }' <<<"${groups}"; then
        check_report CURRENT "group ${pkg#@}"
      else
        check_report DRIFT "group ${pkg#@}"
      fi
    elif package_present "${pkg}"; then
      check_report CURRENT "package ${pkg}"
    else
      check_report DRIFT "package ${pkg}"
    fi
  done
  for tool in "${SELECTED_TOOLS[@]}"; do
    case ${tool} in
      navidrome|owntone) id=rpm:${tool} ;;
      # The RPM's /usr/bin/claude does not count as the native install.
      claude) id=${HOME}/.local/bin/claude ;;
      *) id=${tool} ;;
    esac
    if tool_present "${id}"; then
      check_report CURRENT "tool ${tool}"
    else
      check_report DRIFT "tool ${tool}"
    fi
  done
  if [[ -x ${rustup} ]] && "${rustup}" default >/dev/null 2>&1; then
    components=$("${rustup}" component list --installed --toolchain stable 2>/dev/null) || components=''
    for id in "${RUST_COMPONENTS[@]}"; do
      if grep -q "^${id}" <<<"${components}"; then
        check_report CURRENT "rustup component ${id}"
      else
        check_report DRIFT "rustup component ${id}"
      fi
    done
  else
    check_report DRIFT "rustup stable toolchain (${rustup})"
  fi
  for pkg in "${DISTRO_RUST_PKGS[@]}"; do
    ! rpm -q --quiet -- "${pkg}" 2>/dev/null \
      || check_report DRIFT "distro package ${pkg}: installed (purged in favor of rustup)"
  done
  ! rpm -q --quiet claude-code 2>/dev/null \
    || check_report DRIFT "package claude-code: installed (replaced by the native install)"
  [[ ! -e ${LEGACY_CLAUDE_REPO} ]] \
    || check_report DRIFT "file ${LEGACY_CLAUDE_REPO}: present (retired)"
  ! rpm -q --quiet protobuf3-c 2>/dev/null \
    || check_report DRIFT "package protobuf3-c: installed (obsoletes protobuf-c; swapped back)"
  for id in "${SELECTED_FLATPAKS[@]}"; do
    if flatpak info --system "${id}" >/dev/null 2>&1; then
      check_report CURRENT "flatpak ${id}"
    else
      check_report DRIFT "flatpak ${id}"
    fi
  done
  for entry in "${MANAGED_FILES[@]}"; do
    src=${FILES}/${entry%%|*} dst=${entry#*|}
    if cmp -s -- "${src}" "${dst}"; then
      check_report CURRENT "file ${dst}"
    else
      check_report DRIFT "file ${dst}"
    fi
  done
  for dst in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    if [[ -L ${dst} && $(readlink -- "${dst}") == "${CA_BUNDLE}" ]]; then
      check_report CURRENT "symlink ${dst}"
    else
      check_report DRIFT "symlink ${dst}"
    fi
  done
  for unit in "${SELECTED_SERVICES[@]}" cockpit.socket dnf5-automatic.timer; do
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
      check_report CURRENT "unit ${unit}"
    else
      check_report DRIFT "unit ${unit}"
    fi
  done
  if [[ $(systemctl get-default 2>/dev/null) == graphical.target ]]; then
    check_report CURRENT "default target graphical.target"
  else
    check_report DRIFT "default target graphical.target"
  fi
  check_security_state
  if (( CHECK_DRIFT )); then
    printf 'Result: drift found\n'
    return 2
  fi
  printf 'Result: converged\n'
}

select_profile
if [[ ${MODE} == dry-run ]]; then
  print_plan
  exit 0
fi

#--- Preflight --------------------------------------------------------------
[[ ${EUID} -ne 0 ]] || die "Run as your normal user, not root (sudo is used where needed)."
[[ -f /etc/fedora-release ]] || die "This script is for Fedora."
[[ -d ${FILES} ]] || die "Payload directory not found: ${FILES}"
if [[ ${MODE} == check ]]; then
  command -v rpm >/dev/null || die "rpm is required."
  check_status=0
  check_state || check_status=$?
  exit "${check_status}"
fi
command -v sudo >/dev/null || die "sudo is required."
command -v dnf  >/dev/null || die "dnf is required."
command -v sha256sum >/dev/null || die "sha256sum is required."
FEDORA_VERSION=$(rpm -E %fedora)
[[ ${FEDORA_VERSION} =~ ^[0-9]+$ ]] || die "could not determine the Fedora release number"
(( FEDORA_VERSION >= FEDORA_MIN_VERSION )) \
  || die "Fedora ${FEDORA_MIN_VERSION}+ is required (found ${FEDORA_VERSION})."
RPMFUSION_FREE_URL=${RPMFUSION_FREE_URL_BASE}${FEDORA_VERSION}.noarch.rpm
RPMFUSION_NONFREE_URL=${RPMFUSION_NONFREE_URL_BASE}${FEDORA_VERSION}.noarch.rpm
DNF_VERSION_OUTPUT=$(dnf --version 2>/dev/null) || die "could not query the DNF version"
[[ ${DNF_VERSION_OUTPUT} == dnf5\ version* ]] || die "DNF5 is required."
if (( IS_X86_64 )); then X86_64_EXTRAS=on; else X86_64_EXTRAS=off; fi
case ${ARCH} in
  x86_64)
    SPEEDTEST_ARCHIVE_SHA256=${SPEEDTEST_ARCHIVE_SHA256_X86_64}
    SPEEDTEST_BINARY_SHA256=${SPEEDTEST_BINARY_SHA256_X86_64}
    ANTIGRAVITY_DESKTOP_MANIFEST_URL=${ANTIGRAVITY_DESKTOP_MANIFEST_BASE}/latest-x64-linux.yml
    ANTIGRAVITY_DESKTOP_URL_SUFFIX=/linux-x64/Antigravity.AppImage
    ANTIGRAVITY_CLI_MANIFEST_URL=${ANTIGRAVITY_CLI_MANIFEST_BASE}/linux_amd64.json
    ANTIGRAVITY_CLI_URL_SUFFIX=/linux-x64/cli_linux_x64.tar.gz
    ZED_ARCH=x86_64
    NAVIDROME_ARCH=amd64
    if grep -qwi avx2 /proc/cpuinfo; then
      OPENCODE_ASSET=opencode-linux-x64.tar.gz
    else
      OPENCODE_ASSET=opencode-linux-x64-baseline.tar.gz
    fi
    ;;
  aarch64)
    SPEEDTEST_ARCHIVE_SHA256=${SPEEDTEST_ARCHIVE_SHA256_AARCH64}
    SPEEDTEST_BINARY_SHA256=${SPEEDTEST_BINARY_SHA256_AARCH64}
    ANTIGRAVITY_DESKTOP_MANIFEST_URL=${ANTIGRAVITY_DESKTOP_MANIFEST_BASE}/latest-arm64-linux-arm64.yml
    ANTIGRAVITY_DESKTOP_URL_SUFFIX=/linux-arm/Antigravity.AppImage
    ANTIGRAVITY_CLI_MANIFEST_URL=${ANTIGRAVITY_CLI_MANIFEST_BASE}/linux_arm64.json
    ANTIGRAVITY_CLI_URL_SUFFIX=/linux-arm/cli_linux_arm64.tar.gz
    ZED_ARCH=aarch64
    NAVIDROME_ARCH=arm64
    OPENCODE_ASSET=opencode-linux-arm64.tar.gz
    ;;
  *)
    die "Antigravity, OpenCode, Codex, and Zed support only x86_64 and aarch64 (found ${ARCH})."
    ;;
esac
log "Fedora ${FEDORA_VERSION} on ${ARCH} (profile: ${PROFILE}; x86_64-only extras: ${X86_64_EXTRAS}$( (( NO_UPGRADE )) && echo '; --no-upgrade'))"

WORK_DIR=$(mktemp -d)
SUDO_KEEPALIVE=
cleanup() {
  [[ -z ${SUDO_KEEPALIVE} ]] || kill "${SUDO_KEEPALIVE}" 2>/dev/null || true
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log "Authenticating sudo (kept alive for the rest of the run)"
sudo -v || die "sudo authentication failed"
# Detached from stdout/stderr so a lingering sleep never holds a pipe open
# (./setup ... | tee log) after the script has finished
( while kill -0 "$$" 2>/dev/null; do sudo -n true || true; sleep 50; done ) >/dev/null 2>&1 &
SUDO_KEEPALIVE=$!

# copr and config-manager live in dnf5-plugins; gpg verifies published key
# fingerprints. Fedora Minimal normally supplies curl-minimal, but bootstrap it
# explicitly if an even smaller starting package set omitted the curl command.
REPO_PREREQS=()
if ! dnf copr --help &>/dev/null || ! dnf config-manager --help &>/dev/null; then
  REPO_PREREQS+=(dnf5-plugins)
fi
command -v gpg >/dev/null || REPO_PREREQS+=(gnupg2)
command -v curl >/dev/null || REPO_PREREQS+=(curl-minimal)
if (( ${#REPO_PREREQS[@]} )); then
  log "Installing repository prerequisites: ${REPO_PREREQS[*]}"
  sudo dnf -y install "${REPO_PREREQS[@]}"
fi

#--- 1. Repositories --------------------------------------------------------
log "Repositories"
remove_legacy_antigravity_repo
remove_legacy_antigravity_rpm
remove_legacy_antigravity_settings
remove_replaced_vscodium_fedora
remove_legacy_claude_repo
import_rpm_key "${MICROSOFT_KEY_URL}" gpgsecurity@microsoft.com \
  "${MICROSOFT_KEY_FINGERPRINT}" "${MICROSOFT_KEY_FILE}"
put_file -s "${FILES}/etc/yum.repos.d/vscode.repo" /etc/yum.repos.d/vscode.repo
dnf_repo_enabled code || die "the Microsoft VS Code repository is not enabled"

for copr in "${COPRS[@]}"; do
  repo_id="copr:copr.fedorainfracloud.org:${copr/\//:}"
  if dnf_repo_enabled "${repo_id}"; then
    note "copr ${copr}: enabled"
  else
    sudo dnf copr enable -y "${copr}"
    dnf_repo_enabled "${repo_id}" || die "copr ${copr} was not enabled successfully"
    note "copr ${copr}: enabled now"
  fi
done

if rpm -q --quiet rpmfusion-free-release rpmfusion-nonfree-release; then
  note "RPM Fusion free + nonfree: installed"
else
  sudo dnf -y install "${RPMFUSION_FREE_URL}" "${RPMFUSION_NONFREE_URL}"
  note "RPM Fusion free + nonfree: installed now"
fi

#--- 2. CA bundle paths -----------------------------------------------------
log "CA bundle symlinks"
ensure_symlink -s "${CA_BUNDLE}" /etc/ssl/certs/ca-certificates.crt
ensure_symlink -s "${CA_BUNDLE}" /etc/pki/tls/certs/ca-bundle.crt

#--- 1b. Repositories, continued (x86_64 repo files overwrite the disabled
#        ones RPM Fusion ships, so they come after that install) ------------
log "Repositories (Chrome, x86_64 extras, Microsoft, full-profile Steam/Plex, sing-box)"
put_file -s "${FILES}/etc/yum.repos.d/google-chrome.repo" /etc/yum.repos.d/google-chrome.repo
import_rpm_key "${GOOGLE_KEY_URL}" linux-packages-keymaster@google.com
if (( IS_X86_64 )); then
  put_file -s "${FILES}/etc/yum.repos.d/microsoft-prod.repo" /etc/yum.repos.d/microsoft-prod.repo
fi
if (( IS_X86_64 )) && [[ ${PROFILE} == full ]]; then
  put_file -s "${FILES}/etc/yum.repos.d/rpmfusion-nonfree-steam.repo" \
    /etc/yum.repos.d/rpmfusion-nonfree-steam.repo
  # Plex publishes x86_64 RPMs only; the key signs both metadata and packages.
  import_rpm_key "${PLEX_KEY_URL}" "Plex Inc." \
    "${PLEX_KEY_FINGERPRINT}" "${PLEX_KEY_FILE}"
  put_file -s "${FILES}/etc/yum.repos.d/plex.repo" /etc/yum.repos.d/plex.repo
  dnf_repo_enabled PlexTv || die "the Plex Media Server repository is not enabled"
fi
# sing-box: modern multi-protocol proxy (shadowsocks incl. 2022 ciphers).
# Reconcile enabled state rather than treating any file as sufficient.
if dnf_repo_enabled sing-box; then
  note "${SINGBOX_REPO_FILE}: enabled"
else
  if [[ -f ${SINGBOX_REPO_FILE} ]]; then
    sudo dnf config-manager setopt sing-box.enabled=1
  else
    sudo dnf config-manager addrepo --from-repofile="${SINGBOX_REPO_URL}"
  fi
  dnf_repo_enabled sing-box || die "sing-box repository was not enabled successfully"
  note "${SINGBOX_REPO_FILE}: enabled now"
fi

# Wazuh agent repository. Deliberately enabled=0 (see files/etc/yum.repos.d/
# wazuh.repo): an agent newer than its manager cannot connect, and Wazuh's own
# documentation recommends keeping the repository disabled so the agent only
# moves when the manager does. The install step below uses --enablerepo.
import_rpm_key "${WAZUH_KEY_URL}" 'Wazuh.com' \
  "${WAZUH_KEY_FINGERPRINT}" "${WAZUH_KEY_FILE}"
put_file -s "${FILES}/etc/yum.repos.d/wazuh.repo" /etc/yum.repos.d/wazuh.repo

#--- 3. Packages ------------------------------------------------------------
# Before any upgrade: Fedora 45's protobuf3-c would otherwise obsolete
# protobuf-c again and make protobuf-c-devel uninstallable.
log "protobuf-c (Fedora 45 protobuf3-c obsolete workaround)"
put_file -s "${FILES}/etc/dnf/libdnf5.conf.d/80-protobuf3-c.conf" \
  /etc/dnf/libdnf5.conf.d/80-protobuf3-c.conf
restore_protobuf_c

if (( NO_UPGRADE )); then
  log "Skipping DNF package updates (--no-upgrade)"
else
  log "Applying all available DNF package updates"
  sudo dnf -y upgrade --refresh
fi

log "Package set (${PROFILE}: ${#SELECTED_PKGS[@]} entries)"
# DNF handles installed packages and partially installed groups itself. Keep
# queries/transactions in the same root cache, with prompts answered and output
# visible: an unprivileged, captured `group list` can wait on unseen key prompts.
sudo dnf -y install "${SELECTED_PKGS[@]}"
locale -a | grep -Fxi 'en_US.utf8' >/dev/null \
  || die "glibc-langpack-en was installed, but the en_US.UTF-8 locale is unavailable"
for required_command in base64 git jq od sha512sum; do
  command -v "${required_command}" >/dev/null \
    || die "release resolution requires ${required_command}"
done

if [[ ${PROFILE} == full ]]; then
  log "Navidrome (verified official release RPM)"
  keep_installed rpm:navidrome || install_navidrome

  log "OwnTone (verified upstream release, built as an RPM)"
  keep_installed rpm:owntone || install_owntone
fi

#--- 4. Native developer tools ---------------------------------------------
if [[ ${ARCH} == aarch64 ]]; then
  log "PowerShell (verified native ARM64 release)"
  keep_installed pwsh || install_powershell_arm64
fi
# --no-upgrade resolves upstream releases only when a tool is still missing.
if (( ! NO_UPGRADE )) || ! tool_present antigravity || ! tool_present agy \
    || ! tool_present opencode || ! tool_present zed; then
  log "Resolving latest verified native developer-tool releases"
  resolve_native_tool_releases
fi

log "Antigravity 2.0+ desktop + CLI"
keep_installed antigravity || install_antigravity_desktop
keep_installed agy || install_antigravity_cli

log "OpenCode CLI (verified native release)"
keep_installed opencode || install_opencode_cli

# OpenAI's supported standalone installer resolves the current native release
# and validates its published checksums before activating it under ~/.local.
log "Codex CLI (official standalone release)"
keep_installed codex || install_codex_cli

# Anthropic's native install updates itself in the background; the RPM it
# replaces is removed only after the native command is in place.
log "Claude Code (official native release)"
if (( NO_UPGRADE )) && [[ -x ${HOME}/.local/bin/claude ]]; then
  note "claude: installed; kept at its current version (--no-upgrade)"
else
  install_claude_cli
fi
remove_legacy_claude_rpm

# Fedora has no first-party Zed RPM. Install Zed's official release archive
# only after checking the digest published with the immutable GitHub asset.
log "Zed (verified official native release)"
keep_installed zed || install_zed

for command_name in agy antigravity claude code codex opencode zed; do
  PATH="${HOME}/.local/bin:${PATH}" command -v "${command_name}" >/dev/null \
    || die "expected workstation command is unavailable: ${command_name}"
done

#--- 5. Rust (rustup only) --------------------------------------------------
log "Rust via rustup (stable + ${RUST_COMPONENTS[*]})"
purge_distro_rust
install_rustup_toolchain

#--- 6. speedtest CLI -------------------------------------------------------
log "Ookla speedtest CLI"
if [[ -z ${SPEEDTEST_ARCHIVE_SHA256} ]]; then
  warn "Ookla publishes no ${ARCH} archive; skipping speedtest CLI"
else
  speedtest_dest=${HOME}/.local/bin/speedtest
  speedtest_current_sha=
  if [[ -f ${speedtest_dest} ]]; then
    speedtest_current_sha=$(sha256sum -- "${speedtest_dest}") \
      || die "could not hash ${speedtest_dest}"
    speedtest_current_sha=${speedtest_current_sha%% *}
  fi
  if [[ ${speedtest_current_sha} == "${SPEEDTEST_BINARY_SHA256}" \
        && -x ${speedtest_dest} ]]; then
    note "${SPEEDTEST_VERSION}: present and checksum verified"
  else
    curl -fsSL -o "${WORK_DIR}/speedtest.tgz" \
      "https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VERSION}-linux-${ARCH}.tgz"
    speedtest_archive_sha=$(sha256sum -- "${WORK_DIR}/speedtest.tgz") \
      || die "could not hash the speedtest archive"
    speedtest_archive_sha=${speedtest_archive_sha%% *}
    [[ ${speedtest_archive_sha} == "${SPEEDTEST_ARCHIVE_SHA256}" ]] \
      || die "speedtest archive checksum mismatch for ${ARCH}"
    mkdir -p "${WORK_DIR}/speedtest"
    tar xzf "${WORK_DIR}/speedtest.tgz" -C "${WORK_DIR}/speedtest" speedtest
    speedtest_binary_sha=$(sha256sum -- "${WORK_DIR}/speedtest/speedtest") \
      || die "could not hash the extracted speedtest binary"
    speedtest_binary_sha=${speedtest_binary_sha%% *}
    [[ ${speedtest_binary_sha} == "${SPEEDTEST_BINARY_SHA256}" ]] \
      || die "extracted speedtest binary checksum mismatch for ${ARCH}"
    put_file "${WORK_DIR}/speedtest/speedtest" "${speedtest_dest}" 0755
    note "installed checksum-verified ${SPEEDTEST_VERSION} to ~/.local/bin/speedtest"
  fi
fi

#--- 7. Flatpaks ------------------------------------------------------------
log "Flatpaks"
sudo flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak_install "${SELECTED_FLATPAKS[@]}"
if (( NO_UPGRADE )); then
  note "Flatpak updates skipped (--no-upgrade)"
else
  sudo flatpak update -y --system --noninteractive
  note "all installed system Flatpaks checked for updates"
fi

#--- 8. Dotfiles and system config ------------------------------------------
log "Dotfiles"
put_file "${FILES}/bashrc" "${HOME}/.bashrc"
put_file "${FILES}/vimrc"  "${HOME}/.vimrc"

log "System config"
put_file -s "${FILES}/etc/locale.conf" /etc/locale.conf
put_file -s "${FILES}/etc/sysctl.d/99-inotify.conf" /etc/sysctl.d/99-inotify.conf
if (( PUT_FILE_CHANGED )); then
  sudo sysctl -q -p /etc/sysctl.d/99-inotify.conf
fi
put_file -s "${FILES}/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
# The Arch-style colour prompt, hooked in through profile.d on Fedora
put_file -s "${FILES}/etc/bash.bashrc" /etc/profile.d/01-arch-prompt.sh

#--- 9. Services ------------------------------------------------------------
# Enabled only, not started: they come up on the next boot (starting gdm
# from inside a session would tear that session down)
log "Services"
for unit in "${SELECTED_SERVICES[@]}"; do
  enable_unit "${unit}"
done
if [[ $(systemctl get-default) == graphical.target ]]; then
  note "default target: graphical.target"
else
  sudo systemctl set-default graphical.target
  note "default target: graphical.target (set now)"
fi

# Socket activation makes Cockpit available without starting a desktop session.
log "Cockpit (https://localhost:9090)"
sudo systemctl enable --now cockpit.socket

log "Automatic OS updates (apply updates, reboot when needed)"
put_file -s "${FILES}/etc/dnf/automatic.conf" /etc/dnf/automatic.conf
sudo systemctl enable --now dnf5-automatic.timer

#--- 10. ClamAV --------------------------------------------------------------
# Light footprint by design: realtime coverage for ~/Downloads (where browser
# downloads land) plus newly mounted removable media, not all of /home.
# Everything is notify-only; nothing is ever blocked or quarantined
# automatically.
log "ClamAV (freshclam, clamd@scan, Downloads on-access, media scan)"
CLAMD_CONF_CHANGED=0
CLAMONACC_CONF_CHANGED=0
SYSTEMD_RELOAD=0
render_clamd_config "${FILES}/etc/clamd.d/scan.conf" "${HOME}/Downloads" \
  >"${WORK_DIR}/clamd-scan.conf"
put_file -s "${WORK_DIR}/clamd-scan.conf" /etc/clamd.d/scan.conf
(( PUT_FILE_CHANGED )) && CLAMD_CONF_CHANGED=1
put_file -s "${FILES}/etc/systemd/system/clamav-clamonacc.service.d/50-fedora-workstation.conf" /etc/systemd/system/clamav-clamonacc.service.d/50-fedora-workstation.conf
(( PUT_FILE_CHANGED )) && CLAMONACC_CONF_CHANGED=1 SYSTEMD_RELOAD=1
MEDIA_SCAN_CHANGED=0
put_file -s "${FILES}/usr/local/libexec/clamav-media-scan" \
  /usr/local/libexec/clamav-media-scan 0755
(( PUT_FILE_CHANGED )) && MEDIA_SCAN_CHANGED=1
put_file -s "${FILES}/etc/systemd/system/clamav-media-scan.service" \
  /etc/systemd/system/clamav-media-scan.service
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
ensure_antivirus_selinux_boolean
# The DB bootstrap must precede the clamd start: clamd@scan blocks in its
# start job until the database is loaded, and with no database it fails.
bootstrap_clamav_db /var/lib/clamav
enable_unit clamav-freshclam.service
enable_unit clamd@scan.service
enable_unit clamav-clamonacc.service
ensure_started_unit clamav-freshclam.service 0
# Restarting clamd propagates a stop to clamonacc (Requires=), so clamonacc is
# only restarted here when its own drop-in changed; otherwise the start below
# converges it after a clamd restart - no double restart.
ensure_started_unit clamd@scan.service "${CLAMD_CONF_CHANGED}"
ensure_started_unit clamav-clamonacc.service "${CLAMONACC_CONF_CHANGED}"
enable_unit clamav-media-scan.service
ensure_started_unit clamav-media-scan.service "${MEDIA_SCAN_CHANGED}"

#--- 11. Firewall ------------------------------------------------------------
# See the zone files under files/etc/firewalld/ for the policy. libvirt and
# podman manage their own zones (libvirt/trusted on virbr0/podman*) and are
# deliberately left alone.
log "Firewall (firewalld: workstation default + workstation-lan source zone)"
FIREWALL_CHANGED=0
put_file -s "${FILES}/etc/firewalld/zones/workstation.xml" \
  /etc/firewalld/zones/workstation.xml
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
# Fedora Workstation ships the permissive FedoraWorkstation zone
# (1025-65535/tcp open) as the effective default; move every interface that
# landed in a stock general-purpose zone into workstation so the reject policy
# actually covers them. Virtualization/container interfaces stay put.
STOCK_ZONES='FedoraWorkstation block dmz drop external home internal public trusted work'
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

#--- 12. auditd --------------------------------------------------------------
log "auditd (curated high-signal rules)"
AUDIT_RULES_CHANGED=0
put_file -s "${FILES}/etc/audit/rules.d/50-workstation.rules" \
  /etc/audit/rules.d/50-workstation.rules
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

#--- 13. AIDE ----------------------------------------------------------------
log "AIDE (configuration integrity baseline)"
AIDE_UNIT_CHANGED=0
put_file -s "${FILES}/etc/aide.conf" /etc/aide.conf
put_file -s "${FILES}/etc/systemd/system/aide-check.service" \
  /etc/systemd/system/aide-check.service
(( PUT_FILE_CHANGED )) && AIDE_UNIT_CHANGED=1
put_file -s "${FILES}/etc/systemd/system/aide-check.timer" \
  /etc/systemd/system/aide-check.timer
(( PUT_FILE_CHANGED )) && AIDE_UNIT_CHANGED=1
(( AIDE_UNIT_CHANGED )) && sudo systemctl daemon-reload
# /var/lib/aide is root-only (0700): every existence test goes through sudo.
if ! sudo test -f /var/lib/aide/aide.db.gz; then
  # One-time baseline. Deliberately not re-run after updates: see the scope
  # rationale in files/etc/aide.conf (rpm -Va covers packaged files).
  sudo aide --init || die "could not initialize the AIDE database"
  sudo test -f /var/lib/aide/aide.db.new.gz \
    || die "aide --init did not produce /var/lib/aide/aide.db.new.gz"
  sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz \
    || die "could not activate the AIDE database"
  if command -v restorecon >/dev/null; then
    sudo restorecon /var/lib/aide/aide.db.gz \
      || die "could not restore the SELinux label on the AIDE database"
  fi
  note "AIDE database initialized (configuration scope)"
else
  note "AIDE database: present"
fi
sudo systemctl enable --now aide-check.timer
systemctl is-active --quiet aide-check.timer \
  || die "aide-check.timer did not become active"

#--- 14. Wazuh agent ---------------------------------------------------------
log "Wazuh agent (client only)"
if ! rpm -q --quiet wazuh-agent 2>/dev/null; then
  # The repository is disabled by default (version pinning; see 1b), so the
  # agent is pulled in explicitly. wazuh-agent publishes x86_64 and aarch64
  # RPMs, so both Fedora architectures install it.
  sudo dnf -y --enablerepo=wazuh install wazuh-agent \
    || die "could not install wazuh-agent from the (pinned) Wazuh repository"
  rpm -q --quiet wazuh-agent || die "wazuh-agent did not install"
  note "wazuh-agent installed"
else
  note "wazuh-agent: installed"
fi
if [[ -n ${WAZUH_MANAGER} ]]; then
  configure_wazuh_agent
  wazuh_service_action
else
  wazuh_service_action
fi

#--- 15. GDM -----------------------------------------------------------------
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
  sudo restorecon -R /etc/dconf || die "failed to restore SELinux labels under /etc/dconf"
  note "dconf database updated"
fi
log "Done. Newly enabled services, zram and the default target take effect on the next boot."
