#!/usr/bin/env bash
#
# Idempotent Fedora Workstation setup. Replaces the former comtrya manifest
# fedora_workstation.yaml (comtrya is unmaintained upstream). Targets Fedora
# 41+ (dnf5).
#
# Run as your normal user - NOT root - from any directory: the config payloads
# are resolved relative to this script (files/). Privileged steps go through
# sudo (one password prompt; the timestamp is kept alive for the whole run).
#
# Safe to re-run: every step checks state first, config files are rewritten
# only when their content, type, mode, or ownership differs (and relabelled for SELinux when
# they are), package/Flatpak steps apply available updates and install what is
# missing, and the
# follow-ups that only a real change needs (sysctl reload, dconf update,
# dkms build, dracut) run only then. A converged system avoids repeating those
# mutations; vendor installers that manage their own release channel may still
# perform a lightweight update check.
#
# What it does, in order:
#   1. signed third-party repos: VS Code, Claude Code, the jmsqrd/tributary
#      copr, RPM Fusion free+nonfree, Microsoft (PowerShell), sing-box; on
#      x86_64 also Google Chrome and the RPM Fusion nvidia-driver + steam
#      repos. The abandoned Antigravity 1.x RPM repo/package and VSCodium are
#      retired in favor of native Antigravity 2.0+ and VS Code.
#   2. CA-bundle symlinks at the Debian-style paths some tools hard-code
#   3. the dnf package set (plus the x86_64-only set: i686 libs, Chrome, Steam)
#   4. Antigravity desktop 2.0+, Antigravity CLI, OpenCode, Codex CLI, and Zed
#      using the latest native vendor artifacts/installers (checksummed from
#      live upstream release metadata where upstream publishes digests)
#   5. a checksum-pinned Ookla speedtest CLI into ~/.local/bin
#   6. on kernels older than 7.2, the latest stable Realtek r8152 USB NIC
#      driver release, resolved to and fetched by one verified upstream commit;
#      on 7.2+ the now-unneeded out-of-tree DKMS install is purged instead
#   7. flathub + the flatpak set (plus x86_64-only extras)
#   8. dotfiles (~/.bashrc, ~/.vimrc) and system config
#      from files/: /etc/locale.conf, the inotify sysctl limit, the Arch-style
#      prompt as /etc/profile.d/01-arch-prompt.sh
#   9. the service set, graphical.target as default
#  10. publishes ~/.config/monitors.xml to GDM and applies the GDM font setting

set -euo pipefail

#--- Config -----------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=${SCRIPT_DIR}/files
ARCH=$(uname -m)
KERNEL=$(uname -r)
FEDORA_MIN_VERSION=41

TRIBUTARY_COPR=jmsqrd/tributary
RPMFUSION_FREE_URL="https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
RPMFUSION_NONFREE_URL="https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
GOOGLE_KEY_URL=https://dl.google.com/linux/linux_signing_key.pub
MICROSOFT_KEY_URL=https://packages.microsoft.com/keys/microsoft.asc
MICROSOFT_KEY_FINGERPRINT=BC528686B50D79E339D3721CEB3E94ADBE1229CF
MICROSOFT_KEY_FILE=/etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY
CLAUDE_KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
CLAUDE_KEY_FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
CLAUDE_KEY_FILE=/etc/pki/rpm-gpg/ANTHROPIC-CLAUDE-CODE-RPM-GPG-KEY
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
ZED_VERSION=
ZED_URL=
ZED_ARCHIVE_SHA256=
ZED_RELEASE_API=https://api.github.com/repos/zed-industries/zed/releases/latest
SPEEDTEST_VERSION=1.2.0
SPEEDTEST_ARCHIVE_SHA256_X86_64=5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7
SPEEDTEST_BINARY_SHA256_X86_64=31f1124c5ab8acdae6b9fe1741e704df420f9f2e7d429679fabe62075453c051
SPEEDTEST_ARCHIVE_SHA256_AARCH64=3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3
SPEEDTEST_BINARY_SHA256_AARCH64=d99fa13293f658b53eaa79fe81f4b210db39fdfc1e9698f33da3f234a6008df7
R8152_REPO=https://github.com/awesometic/realtek-r8152-dkms.git
R8152_RELEASE_API=https://api.github.com/repos/awesometic/realtek-r8152-dkms/releases/latest
R8152_TAG=
R8152_COMMIT=
R8152_IN_TREE_KERNEL_MIN=7.2
R8152_SOURCE_ROOT=/usr/src
R8152_SYSFS_ROOT=/sys
R8152_UDEV_RULE=/etc/udev/rules.d/50-usb-realtek-net.rules
R8152_UDEV_MARKER=/etc/udev/rules.d/.50-usb-realtek-net.rules.lan-ipxe
# Ownership signature for the udev rule installed by the formerly pinned
# revision of this script. It identifies that legacy file; it is not a release
# selection pin for future DKMS installations.
R8152_LEGACY_UDEV_RULE_SHA256=0858aeb2905c6061f04e3fd55573ae5c01d3673ddb4d60f24ef284279ba2993b
CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

# Entries may be package names, provides (vim -> vim-enhanced), name.arch,
# or @groups
PKGS=(
  abattis-cantarell-fonts
  alsa-sof-firmware
  bash-completion
  bc
  bison
  bluez
  bluez-tools
  boost-devel
  brasero
  cargo
  ccache
  chromium
  chrony
  claude-code
  clang
  clippy
  cmake
  code
  cronie
  cups
  cups-pk-helper
  curl
  dbus-devel
  dkms
  @development-tools
  dos2unix
  dracut
  dtc
  efibootmgr
  elfutils-libelf-devel
  erofs-utils
  flatpak
  flex
  fuse-libs
  gcc
  gdb
  genisoimage
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
  kernel-headers
  gnutls-devel
  golang
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
  libmpc-devel
  libva
  libva-utils
  libxml2
  libxslt
  lld
  lldb
  llvm
  lutris
  lz4
  lzop
  maven
  mesa-vulkan-drivers
  mokutil
  mpfr-devel
  mpv
  nano
  ncurses-devel
  NetworkManager
  openssh-server
  openssl-devel
  pigz
  pipewire
  pipewire-alsa
  pipewire-pulseaudio
  pngcrush
  powershell
  protobuf-compiler
  python3-protobuf
  rhythmbox
  rsync
  ruby
  rust-analyzer
  rust
  rustfmt
  schedtool
  SDL-devel
  seahorse
  sing-box
  squashfs-tools
  sudo
  system-config-printer
  tar
  texinfo
  transmission
  transmission-cli
  transmission-daemon
  transmission-gtk
  transmission-remote-gtk
  tree
  tributary
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

# x86_64 only: 32-bit libraries for Steam/Wine, plus packages that exist
# only for that architecture
PKGS_X86_64=(
  glibc-devel.i686
  google-chrome-stable
  libva-intel-media-driver
  libstdc++-devel.i686
  libva.i686
  mesa-vulkan-drivers.i686
  readline-devel.i686
  steam
  vulkan-loader.i686
  zlib-ng-compat-devel.i686
)

FLATPAKS=(
  io.jor.bugdom
  io.jor.bugdom2
  io.jor.cromagrally
  io.jor.nanosaur
  io.jor.nanosaur2
  io.jor.ottomatic
  io.jor.mightymike
  net.nokyan.Resources
)
FLATPAKS_X86_64=(
  com.google.AndroidStudio
  org.getoutline.OutlineClient
  org.getoutline.OutlineManager
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

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ${0##*/} [-h|--help]

Idempotent Fedora Workstation setup: third-party repos, dnf + flatpak package
sets, the r8152 DKMS driver, dotfiles and system config from files/, services,
GDM settings. Run as your normal user (sudo is used for the privileged steps);
safe to re-run at any time.
USAGE
}

while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "Unknown option: $1" ;;
  esac
done

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

# is_installed <pkg>: true for a package name, name.arch, name-version, or a
# provided capability (vim -> vim-enhanced)
is_installed() {
  rpm -q --quiet -- "$1" || rpm -q --quiet --whatprovides -- "$1"
}

# dnf_install <pkg|@group>...: installs only the entries not present yet
DNF_GROUPS_LOADED=0
INSTALLED_GROUPS=
dnf_install() {
  local p missing=()
  for p in "$@"; do
    if [[ ${p} == @* ]]; then
      if (( ! DNF_GROUPS_LOADED )); then
        # Hidden groups (including gnome-desktop) require --hidden.
        local group_output
        group_output=$(dnf -q group list --installed --hidden 2>/dev/null) \
          || die "could not query installed DNF groups"
        INSTALLED_GROUPS=$(awk 'NR > 1 {print $1}' <<<"${group_output}")
        DNF_GROUPS_LOADED=1
      fi
      grep -qx -- "${p#@}" <<<"${INSTALLED_GROUPS}" || missing+=("${p}")
    else
      is_installed "${p}" || missing+=("${p}")
    fi
  done
  if (( ${#missing[@]} )); then
    note "installing ${#missing[@]} missing: ${missing[*]}"
    sudo dnf -y install "${missing[@]}"
  else
    note "all $# packages present"
  fi
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
# browser_download_url selected here. Release immutability is reported but is
# advisory because GitHub does not apply it retroactively to existing releases.
RESOLVED_VERSION=
RESOLVED_URL=
RESOLVED_SHA256=
resolve_github_release_asset() {
  local repo=$1 api=$2 asset=$3 metadata line tag digest expected_prefix
  local release_immutable
  metadata=$(fetch_release_document "${api}") \
    || die "could not query the latest ${repo} release"
  line=$(jq -er --arg asset "${asset}" '
      select(.draft == false and .prerelease == false)
      | . as $release
      | [.assets[] | select(.name == $asset)] as $matches
      | select(($matches | length) == 1)
      | [$release.tag_name, $matches[0].browser_download_url,
         $matches[0].digest, ($release.immutable == true)] | @tsv
    ' <<<"${metadata}") \
    || die "latest ${repo} metadata is not one stable release with asset ${asset}"
  IFS=$'\t' read -r tag RESOLVED_URL digest release_immutable <<<"${line}"
  [[ ${tag} =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] \
    || die "latest ${repo} release has an unsupported tag '${tag}'"
  RESOLVED_VERSION=${BASH_REMATCH[1]}
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

resolve_r8152_release() {
  local metadata refs sha ref
  metadata=$(fetch_release_document "${R8152_RELEASE_API}") \
    || die "could not query the latest r8152 DKMS release"
  R8152_TAG=$(jq -er '
      select(.draft == false and .prerelease == false) | .tag_name
    ' <<<"${metadata}") \
    || die "latest r8152 release metadata is invalid"
  [[ ${R8152_TAG} =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] \
    || die "latest r8152 release tag has an unsupported form: ${R8152_TAG}"
  refs=$(git ls-remote --exit-code --tags "${R8152_REPO}" \
      "refs/tags/${R8152_TAG}" "refs/tags/${R8152_TAG}^{}") \
    || die "could not resolve latest r8152 tag ${R8152_TAG}"
  R8152_COMMIT=
  while read -r sha ref; do
    [[ ${sha} =~ ^[[:xdigit:]]{40}$ ]] || continue
    case ${ref} in
      "refs/tags/${R8152_TAG}^{}") R8152_COMMIT=${sha,,} ;;
      "refs/tags/${R8152_TAG}") [[ -n ${R8152_COMMIT} ]] || R8152_COMMIT=${sha,,} ;;
    esac
  done <<<"${refs}"
  [[ ${R8152_COMMIT} =~ ^[[:xdigit:]]{40}$ ]] \
    || die "latest r8152 tag did not resolve to one commit"
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
  local image_sha='' image_size=''

  [[ ! -e ${ANTIGRAVITY_COMMAND_LINK} || -L ${ANTIGRAVITY_COMMAND_LINK} ]] \
    || die "refusing to replace unmanaged path: ${ANTIGRAVITY_COMMAND_LINK}"
  if [[ -x ${installed_image} && -f ${marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}"; then
    current_sha=$(sha512sum -- "${installed_image}") \
      || die "could not hash ${installed_image}"
    current_sha=${current_sha%% *}
    current_size=$(stat -c '%s' -- "${installed_image}") \
      || die "could not read the size of ${installed_image}"
    current_version=$(sed -n 's/^version=//p' "${marker}" | tail -1)
    expected_current_sha=$(sed -n 's/^image-sha512=//p' "${marker}" | tail -1)
    if [[ ${current_sha} == "${expected_current_sha}" \
          && ${current_version} == "${ANTIGRAVITY_VERSION}" \
          && ${current_sha} == "${ANTIGRAVITY_DESKTOP_SHA512}" \
          && ${current_size} == "${ANTIGRAVITY_DESKTOP_SIZE}" ]]; then
      note "Antigravity ${ANTIGRAVITY_VERSION}: present and verified"
      ensure_symlink -s "${installed_image}" "${ANTIGRAVITY_COMMAND_LINK}"
      put_file -s "${FILES}/usr/share/applications/antigravity.desktop" \
        "${ANTIGRAVITY_DESKTOP_FILE}"
      return 0
    fi
    if [[ ${current_sha} == "${expected_current_sha}" \
          && ${current_version} != "${ANTIGRAVITY_VERSION}" ]] \
       && is_supported_antigravity_desktop_version "${current_version}" \
       && printf '%s\n%s\n' "${ANTIGRAVITY_VERSION}" "${current_version}" \
          | LC_ALL=C sort -V -C; then
      warn "Antigravity ${current_version} is newer than the current manifest ${ANTIGRAVITY_VERSION}; preserving it to avoid a downgrade"
      ensure_symlink -s "${installed_image}" "${ANTIGRAVITY_COMMAND_LINK}"
      put_file -s "${FILES}/usr/share/applications/antigravity.desktop" \
        "${ANTIGRAVITY_DESKTOP_FILE}"
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
  sudo install -d -o root -g root -m 0755 -- "${stage}"
  sudo install -o root -g root -m 0755 -- "${image}" \
    "${stage}/Antigravity.AppImage"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${ANTIGRAVITY_VERSION}" \
    "source-url=${ANTIGRAVITY_DESKTOP_URL}" \
    "image-size=${ANTIGRAVITY_DESKTOP_SIZE}" \
    "image-sha512=${ANTIGRAVITY_DESKTOP_SHA512}" \
    >"${marker_source}"
  sudo install -o root -g root -m 0644 -- "${marker_source}" \
    "${stage}/.lan-ipxe-release"
  sudo chown -R root:root -- "${stage}"
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
  ensure_symlink -s "${installed_image}" "${ANTIGRAVITY_COMMAND_LINK}"
  put_file -s "${FILES}/usr/share/applications/antigravity.desktop" \
    "${ANTIGRAVITY_DESKTOP_FILE}"
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

# Compare only the numeric major/minor components of a Fedora kernel release.
# uname -r appends patch, Fedora build, flavour, and architecture suffixes
# (for example 7.2.1-200.fc44.x86_64); none of those change the 7.2 cutoff.
kernel_version_at_least() {
  local running=$1 minimum=$2
  local running_major running_minor minimum_major minimum_minor
  [[ ${running} =~ ^([0-9]+)\.([0-9]+)([.-]|$) ]] \
    || die "could not parse running kernel version: ${running}"
  running_major=${BASH_REMATCH[1]}
  running_minor=${BASH_REMATCH[2]}
  [[ ${minimum} =~ ^([0-9]+)\.([0-9]+)$ ]] \
    || die "invalid kernel-version cutoff: ${minimum}"
  minimum_major=${BASH_REMATCH[1]}
  minimum_minor=${BASH_REMATCH[2]}
  (( 10#${running_major} > 10#${minimum_major} \
     || (10#${running_major} == 10#${minimum_major} \
         && 10#${running_minor} >= 10#${minimum_minor}) ))
}

# Remove exact DKMS registrations created under both the historical module
# name used by this setup and the package name declared by current upstream.
# A source tree is deleted only when its immediate /usr/src-style path and its
# dkms.conf both match a captured registration, or when it carries our marker.
R8152_PURGE_CHANGED=0
R8152_PURGE_MODULE_CHANGED=0
R8152_PURGED_KERNELS=()
# shellcheck disable=SC2120
purge_r8152_dkms() {
  local source_root=${1:-${R8152_SOURCE_ROOT}}
  local udev_rule=${2:-${R8152_UDEV_RULE}}
  local udev_marker=${3:-${R8152_UDEV_MARKER}}
  local status remaining line module source_module version entry source package_name package_version
  local source_digest
  local source_stage stage_name retirement retirement_guard retirement_name
  local status_tail registered_kernel
  local marker_version marker_module marker_sha current_rule_sha source_rule
  local rule_owned=0 marker_owned=0
  local -a registrations=()
  local -A seen=() seen_kernels=() registered_versions=() removed_sources=()
  local -A prepared_retirements=()
  R8152_PURGE_CHANGED=0
  R8152_PURGE_MODULE_CHANGED=0
  R8152_PURGED_KERNELS=()

  status=$(dkms status 2>/dev/null) \
    || die "could not query DKMS registrations before purging r8152"
  while IFS= read -r line; do
    if [[ ${line} =~ ^(r8152|realtek-r8152)/([^,:[:space:]]+) ]]; then
      module=${BASH_REMATCH[1]}
      version=${BASH_REMATCH[2]}
      [[ ${version} =~ ^[0-9][0-9A-Za-z._+~-]*$ ]] \
        || die "refusing unsafe r8152 DKMS version from status: ${version}"
      entry=${module}/${version}
      registered_versions[${version}]=1
      if [[ ${line} == *,* ]]; then
        status_tail=${line#*,}
        status_tail=${status_tail#"${status_tail%%[![:space:]]*}"}
        registered_kernel=${status_tail%%,*}
        registered_kernel=${registered_kernel%%[[:space:]]*}
        if [[ ${registered_kernel} =~ ^[0-9][0-9A-Za-z._+~-]*$ \
              && -z ${seen_kernels[${registered_kernel}]:-} ]]; then
          seen_kernels[${registered_kernel}]=1
          R8152_PURGED_KERNELS+=("${registered_kernel}")
        fi
      fi
      [[ -n ${seen[${entry}]:-} ]] && continue
      seen[${entry}]=1
      registrations+=("${entry}")
    fi
  done <<<"${status}"
  if (( ${#R8152_PURGED_KERNELS[@]} )); then
    note "captured r8152 DKMS kernels before removal: ${R8152_PURGED_KERNELS[*]}"
  fi

  if [[ -f ${udev_marker} && ! -L ${udev_marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
       "${udev_marker}"; then
    marker_sha=$(sed -n 's/^rule-sha256=//p' "${udev_marker}" | tail -1)
    if [[ ${marker_sha} =~ ^[[:xdigit:]]{64}$ ]]; then
      marker_owned=1
      marker_sha=${marker_sha,,}
    fi
  fi
  if [[ -f ${udev_rule} && ! -L ${udev_rule} ]]; then
    current_rule_sha=$(sha256sum -- "${udev_rule}") \
      || die "could not hash ${udev_rule} before the r8152 purge"
    current_rule_sha=${current_rule_sha%% *}
    if (( marker_owned )) && [[ ${current_rule_sha} == "${marker_sha}" ]]; then
      rule_owned=1
    elif [[ ${current_rule_sha} == "${R8152_LEGACY_UDEV_RULE_SHA256}" ]]; then
      rule_owned=1
    fi
    # Existing installations predate the ownership marker. Bind their rule to
    # the captured registration by requiring byte-for-byte source equality.
    for version in "${!registered_versions[@]}"; do
      for module in r8152 realtek-r8152; do
        source_rule=${source_root}/${module}-${version}/udev/rules.d/50-usb-realtek-net.rules
        if [[ -f ${source_rule} && ! -L ${source_rule} ]] \
           && cmp -s -- "${source_rule}" "${udev_rule}"; then
          rule_owned=1
        fi
      done
    done
  fi

  for entry in "${registrations[@]}"; do
    module=${entry%%/*}
    version=${entry#*/}
    for source_module in r8152 realtek-r8152; do
      source=${source_root}/${source_module}-${version}
      [[ -e ${source} || -L ${source} ]] || continue
      [[ -z ${prepared_retirements[${source}]:-} ]] || continue
      [[ -d ${source} && ! -L ${source} ]] || continue
      package_name=$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' \
        "${source}/dkms.conf" 2>/dev/null | tail -1)
      package_version=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' \
        "${source}/dkms.conf" 2>/dev/null | tail -1)
      [[ ( ${package_name} == r8152 || ${package_name} == realtek-r8152 ) \
            && ${package_version} == "${version}" ]] || continue
      recover_r8152_source_retirement "${source}" "${source_module}" \
        "${version}" 1
      source_digest=$(r8152_source_tree_sha256 "${source}")
      prepare_r8152_source_retirement "${source}" "${source_module}" \
        "${version}" "${source_digest}"
      prepared_retirements[${source}]=1
    done
    sudo dkms remove -m "${module}" -v "${version}" --all \
      || die "could not remove DKMS registration ${entry}"
    R8152_PURGE_CHANGED=1
    R8152_PURGE_MODULE_CHANGED=1
    note "removed DKMS registration ${entry}"
  done

  remaining=$(dkms status 2>/dev/null) \
    || die "could not query DKMS registrations after purging r8152"
  while IFS= read -r line; do
    [[ ${line} =~ ^(r8152|realtek-r8152)/ ]] \
      && die "an r8152 DKMS registration remains after removal: ${line}"
  done <<<"${remaining}"

  # First cover source trees belonging to registrations captured above. Check
  # both names because older revisions placed realtek-r8152 sources beneath an
  # r8152-* directory.
  for version in "${!registered_versions[@]}"; do
    for module in r8152 realtek-r8152; do
      source=${source_root}/${module}-${version}
      [[ -e ${source} || -L ${source} ]] || continue
      if [[ ! -d ${source} || -L ${source} ]]; then
        warn "leaving unsafe or non-directory r8152 source path: ${source}"
        continue
      fi
      package_name=$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' \
        "${source}/dkms.conf" 2>/dev/null | tail -1)
      package_version=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' \
        "${source}/dkms.conf" 2>/dev/null | tail -1)
      if [[ ${package_name} != r8152 && ${package_name} != realtek-r8152 ]] \
         || [[ ${package_version} != "${version}" ]]; then
        warn "leaving unverified r8152 source tree: ${source}"
        continue
      fi
      source_rule=${source}/udev/rules.d/50-usb-realtek-net.rules
      if [[ -f ${udev_rule} && ! -L ${udev_rule} \
            && -f ${source_rule} && ! -L ${source_rule} ]] \
         && cmp -s -- "${source_rule}" "${udev_rule}"; then
        rule_owned=1
      fi
      if [[ -z ${prepared_retirements[${source}]:-} ]]; then
        source_digest=$(r8152_source_tree_sha256 "${source}")
        prepare_r8152_source_retirement "${source}" "${module}" \
          "${version}" "${source_digest}"
      fi
      retire_r8152_source_tree "${source}" "${module}" "${version}"
      removed_sources[${source}]=1
      R8152_PURGE_CHANGED=1
      note "removed verified DKMS source tree ${source}"
    done
  done

  # A marker lets a future 7.2+ run safely clean a setup-owned source tree even
  # if its DKMS registration was removed out of band first.
  for source in "${source_root}"/r8152-* "${source_root}"/realtek-r8152-*; do
    [[ -e ${source} || -L ${source} ]] || continue
    [[ -z ${removed_sources[${source}]:-} ]] || continue
    [[ -d ${source} && ! -L ${source} \
       && -f ${source}/.lan-ipxe-managed ]] || continue
    grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
      "${source}/.lan-ipxe-managed" || continue
    marker_module=$(sed -n 's/^dkms-module=//p' \
      "${source}/.lan-ipxe-managed" | tail -1)
    marker_version=$(sed -n 's/^version=//p' \
      "${source}/.lan-ipxe-managed" | tail -1)
    [[ ${marker_module} == r8152 || ${marker_module} == realtek-r8152 ]] \
      || continue
    [[ ${marker_version} =~ ^[0-9][0-9A-Za-z._+~-]*$ \
       && ${source} == "${source_root}/${marker_module}-${marker_version}" ]] \
      || continue
    retirement_guard=${source_root}/.${marker_module}-${marker_version}.lan-ipxe-retirement-v1.guard
    if [[ -e ${retirement_guard} || -L ${retirement_guard} ]]; then
      if r8152_retirement_guard_is_valid "${retirement_guard}" \
           "${marker_module}" "${marker_version}"; then
        source_rule=${source}/udev/rules.d/50-usb-realtek-net.rules
        if [[ -f ${udev_rule} && ! -L ${udev_rule} \
              && -f ${source_rule} && ! -L ${source_rule} ]] \
           && cmp -s -- "${source_rule}" "${udev_rule}"; then
          rule_owned=1
        fi
        recover_r8152_source_retirement "${source}" "${marker_module}" \
          "${marker_version}" 0
        R8152_PURGE_CHANGED=1
      else
        warn "leaving invalid r8152 source retirement guard: ${retirement_guard}"
      fi
      continue
    fi
    package_name=$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' \
      "${source}/dkms.conf" 2>/dev/null | tail -1)
    package_version=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' \
      "${source}/dkms.conf" 2>/dev/null | tail -1)
    [[ ${package_name} == "${marker_module}" \
       && ${package_version} == "${marker_version}" ]] || continue
    source_rule=${source}/udev/rules.d/50-usb-realtek-net.rules
    if [[ -f ${udev_rule} && ! -L ${udev_rule} \
          && -f ${source_rule} && ! -L ${source_rule} ]] \
       && cmp -s -- "${source_rule}" "${udev_rule}"; then
      rule_owned=1
    fi
    source_digest=$(r8152_source_tree_sha256 "${source}")
    prepare_r8152_source_retirement "${source}" "${marker_module}" \
      "${marker_version}" "${source_digest}"
    retire_r8152_source_tree "${source}" "${marker_module}" "${marker_version}"
    R8152_PURGE_CHANGED=1
    note "removed marked DKMS source tree ${source}"
  done

  # A pre-7.2 run may have stopped while preparing the hidden atomic source
  # sibling. Limit discovery to the two exact reserved name shapes and remove
  # only an empty root-owned directory or a schema-valid setup transaction.
  for source_stage in "${source_root}"/.r8152-*.lan-ipxe-stage \
      "${source_root}"/.realtek-r8152-*.lan-ipxe-stage; do
    [[ -e ${source_stage} || -L ${source_stage} ]] || continue
    stage_name=${source_stage##*/}
    if [[ ${stage_name} =~ ^\.(r8152|realtek-r8152)-([0-9][0-9A-Za-z._+~-]*)\.lan-ipxe-stage$ ]]; then
      module=${BASH_REMATCH[1]}
      version=${BASH_REMATCH[2]}
    else
      continue
    fi
    if r8152_source_stage_is_recoverable "${source_stage}" "${module}" "${version}"; then
      cleanup_r8152_source_stage "${source_stage}" "${module}" "${version}"
      R8152_PURGE_CHANGED=1
    else
      warn "leaving unverified r8152 source staging residue: ${source_stage}"
    fi
  done

  # Complete a same-version replacement that was interrupted after its DKMS
  # registration was removed. The external empty guard remains trustworthy
  # even if recursive deletion partly consumed the retired source tree.
  for retirement_guard in \
      "${source_root}"/.r8152-*.lan-ipxe-retirement-v1.guard \
      "${source_root}"/.realtek-r8152-*.lan-ipxe-retirement-v1.guard; do
    [[ -e ${retirement_guard} || -L ${retirement_guard} ]] || continue
    retirement_name=${retirement_guard##*/}
    if [[ ${retirement_name} =~ ^\.(r8152|realtek-r8152)-([0-9][0-9A-Za-z._+~-]*)\.lan-ipxe-retirement-v1\.guard$ ]]; then
      module=${BASH_REMATCH[1]}
      version=${BASH_REMATCH[2]}
    else
      continue
    fi
    if r8152_retirement_guard_is_valid "${retirement_guard}" \
         "${module}" "${version}"; then
      source=${source_root}/${module}-${version}
      recover_r8152_source_retirement "${source}" "${module}" "${version}" 0
      R8152_PURGE_CHANGED=1
    else
      warn "leaving invalid r8152 source retirement guard: ${retirement_guard}"
    fi
  done
  for retirement in "${source_root}"/.r8152-*.lan-ipxe-retirement-v1 \
      "${source_root}"/.realtek-r8152-*.lan-ipxe-retirement-v1; do
    [[ -e ${retirement} || -L ${retirement} ]] || continue
    [[ -e ${retirement}.guard || -L ${retirement}.guard ]] \
      || warn "leaving unguarded r8152 source retirement residue: ${retirement}"
  done

  if (( rule_owned )); then
    sudo rm -f -- "${udev_rule}"
    if (( marker_owned )); then
      sudo rm -f -- "${udev_marker}"
    fi
    sudo udevadm control --reload-rules
    R8152_PURGE_CHANGED=1
    note "removed the setup-managed r8152 udev rule and reloaded udev"
  elif (( marker_owned )) && [[ ! -e ${udev_rule} && ! -L ${udev_rule} ]]; then
    sudo rm -f -- "${udev_marker}"
    R8152_PURGE_CHANGED=1
    note "removed the stale r8152 udev ownership marker"
  elif (( marker_owned )); then
    warn "leaving modified or unsafe r8152 udev rule in place: ${udev_rule}"
  fi

  if (( ! R8152_PURGE_CHANGED && ! marker_owned )); then
    note "setup-owned out-of-tree r8152 state: already absent"
  fi
}

# Once the newly resolved driver has been installed and verified, retire every
# other r8152/realtek-r8152 registration. This handles the previous script's
# incorrect r8152 registration name without risking a gap in NIC support.
R8152_SUPERSEDED_CHANGED=0
remove_superseded_r8152_dkms() {
  local current_module=$1 current_version=$2
  local source_root=${3:-${R8152_SOURCE_ROOT}}
  local status remaining line module version entry source package_name package_version
  local source_digest retirement_guard retirement_name registered_flag prepared
  local -a registrations=()
  local -A seen=()
  R8152_SUPERSEDED_CHANGED=0
  status=$(dkms status 2>/dev/null) \
    || die "could not query DKMS registrations before retiring superseded r8152 versions"
  while IFS= read -r line; do
    if [[ ${line} =~ ^(r8152|realtek-r8152)/([^,:[:space:]]+) ]]; then
      module=${BASH_REMATCH[1]}
      version=${BASH_REMATCH[2]}
      [[ ${version} =~ ^[0-9][0-9A-Za-z._+~-]*$ ]] \
        || die "refusing unsafe r8152 DKMS version from status: ${version}"
      entry=${module}/${version}
      [[ ${entry} == "${current_module}/${current_version}" \
         || -n ${seen[${entry}]:-} ]] && continue
      seen[${entry}]=1
      registrations+=("${entry}")
    fi
  done <<<"${status}"

  for entry in "${registrations[@]}"; do
    module=${entry%%/*}
    version=${entry#*/}
    prepared=0
    source=${source_root}/${module}-${version}
    if [[ -e ${source} || -L ${source} ]]; then
      if [[ ! -d ${source} || -L ${source} ]]; then
        warn "leaving unsafe superseded r8152 source path: ${source}"
      else
        package_name=$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' \
          "${source}/dkms.conf" 2>/dev/null | tail -1)
        package_version=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' \
          "${source}/dkms.conf" 2>/dev/null | tail -1)
        if [[ ( ${package_name} == r8152 || ${package_name} == realtek-r8152 ) \
              && ${package_version} == "${version}" ]]; then
          recover_r8152_source_retirement "${source}" "${module}" "${version}" 1
          source_digest=$(r8152_source_tree_sha256 "${source}")
          prepare_r8152_source_retirement "${source}" "${module}" \
            "${version}" "${source_digest}"
          prepared=1
        else
          warn "leaving unverified superseded r8152 source tree: ${source}"
        fi
      fi
    fi
    sudo dkms remove -m "${module}" -v "${version}" --all \
      || die "could not remove superseded DKMS registration ${entry}"
    if (( prepared )); then
      retire_r8152_source_tree "${source}" "${module}" "${version}"
      note "removed superseded DKMS source tree ${source}"
    fi
    R8152_SUPERSEDED_CHANGED=1
    note "removed superseded DKMS registration ${entry}"
  done

  remaining=$(dkms status 2>/dev/null) \
    || die "could not verify r8152 DKMS registrations after migration"
  while IFS= read -r line; do
    if [[ ${line} =~ ^(r8152|realtek-r8152)/([^,:[:space:]]+) ]] \
       && [[ ${BASH_REMATCH[1]}/${BASH_REMATCH[2]} != \
             "${current_module}/${current_version}" ]]; then
      die "superseded r8152 DKMS registration remains: ${line}"
    fi
  done <<<"${remaining}"

  for retirement_guard in \
      "${source_root}"/.r8152-*.lan-ipxe-retirement-v1.guard \
      "${source_root}"/.realtek-r8152-*.lan-ipxe-retirement-v1.guard; do
    [[ -e ${retirement_guard} || -L ${retirement_guard} ]] || continue
    retirement_name=${retirement_guard##*/}
    [[ ${retirement_name} =~ ^\.(r8152|realtek-r8152)-([0-9][0-9A-Za-z._+~-]*)\.lan-ipxe-retirement-v1\.guard$ ]] \
      || continue
    module=${BASH_REMATCH[1]}
    version=${BASH_REMATCH[2]}
    if ! r8152_retirement_guard_is_valid "${retirement_guard}" \
         "${module}" "${version}"; then
      warn "leaving invalid r8152 source retirement guard: ${retirement_guard}"
      continue
    fi
    registered_flag=0
    [[ ${module}/${version} != "${current_module}/${current_version}" ]] \
      || registered_flag=1
    source=${source_root}/${module}-${version}
    recover_r8152_source_retirement "${source}" "${module}" "${version}" \
      "${registered_flag}"
    (( registered_flag )) || R8152_SUPERSEDED_CHANGED=1
  done
}

# Hash a source tree independently of ownership, mtimes and setup markers.
# This makes the marker sensitive to path, file type/mode and content while
# remaining stable after the tree is copied beneath /usr/src.
r8152_source_tree_sha256() {
  local tree=$1 digest
  [[ -d ${tree} && ! -L ${tree} ]] \
    || die "cannot hash unsafe or missing r8152 source tree: ${tree}"
  digest=$(tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
      --format=gnu --exclude='./.git' --exclude='./.lan-ipxe-managed' \
      --exclude='./.lan-ipxe-transaction' \
      --exclude='./.lan-ipxe-retirement-authorized' \
      -cf - -C "${tree}" . | sha256sum) \
    || die "could not calculate the normalized r8152 source-tree digest"
  digest=${digest%% *}
  [[ ${digest} =~ ^[[:xdigit:]]{64}$ ]] \
    || die "normalized r8152 source-tree digest is invalid"
  printf '%s\n' "${digest,,}"
}

# A fixed hidden sibling makes interrupted copies discoverable without a glob.
# Non-empty residue is removable only when both it and its exact transaction
# marker have the ownership/mode established below. An empty root-owned 0755
# directory covers interruption between mkdir and the first marker write.
r8152_source_stage_has_valid_marker() {
  local stage=$1 module=$2 version=$3
  local transaction_marker=${stage}/.lan-ipxe-transaction
  local -a marker_lines=()
  [[ -d ${stage} && ! -L ${stage} \
        && $(stat -c '%u:%g:%a' -- "${stage}" 2>/dev/null) == 0:0:755 \
        && -f ${transaction_marker} && ! -L ${transaction_marker} \
        && $(stat -c '%u:%g:%a' -- "${transaction_marker}" 2>/dev/null) == 0:0:644 \
        && ${stage##*/} == ".${module}-${version}.lan-ipxe-stage" ]] \
    || return 1
  mapfile -t marker_lines <"${transaction_marker}" || return 1
  [[ ${#marker_lines[@]} == 7 \
        && ${marker_lines[0]} == 'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
        && ${marker_lines[1]} == 'transaction=r8152-source-install-v1' \
        && ${marker_lines[2]} == "dkms-module=${module}" \
        && ${marker_lines[3]} == "version=${version}" \
        && ${marker_lines[4]} =~ ^release-tag=[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ \
        && ${marker_lines[5]} =~ ^source-commit=[[:xdigit:]]{40}$ \
        && ${marker_lines[6]} =~ ^source-tree-sha256=[[:xdigit:]]{64}$ ]]
}

r8152_source_stage_is_recoverable() {
  local stage=$1 module=$2 version=$3 first_entry
  [[ ( ${module} == r8152 || ${module} == realtek-r8152 ) \
        && ${version} =~ ^[0-9][0-9A-Za-z._+~-]*$ \
        && -d ${stage} && ! -L ${stage} \
        && ${stage##*/} == ".${module}-${version}.lan-ipxe-stage" \
        && $(stat -c '%u:%g:%a' -- "${stage}" 2>/dev/null) == 0:0:755 ]] \
    || return 1
  first_entry=$(find "${stage}" -mindepth 1 -maxdepth 1 -print -quit) \
    || return 1
  [[ -z ${first_entry} ]] \
    || r8152_source_stage_has_valid_marker "${stage}" "${module}" "${version}"
}

cleanup_r8152_source_stage() {
  local stage=$1 module=$2 version=$3
  [[ ! -e ${stage} && ! -L ${stage} ]] && return 0
  r8152_source_stage_is_recoverable "${stage}" "${module}" "${version}" \
    || die "refusing unsafe r8152 source staging path: ${stage}"
  sudo rm -rf -- "${stage}" \
    || die "could not remove interrupted r8152 source staging tree"
  [[ ! -e ${stage} && ! -L ${stage} ]] \
    || die "r8152 source staging residue remains: ${stage}"
  note "removed interrupted r8152 source staging residue ${stage}"
}

# Keep the retirement guard outside the tree being deleted. If deletion is
# interrupted, the surviving guard still proves that the fixed hidden sibling
# is setup-owned and safe to finish deleting on the next run.
r8152_retirement_guard_is_valid() {
  local guard=$1 module=$2 version=$3 first_entry
  [[ ( ${module} == r8152 || ${module} == realtek-r8152 ) \
        && ${version} =~ ^[0-9][0-9A-Za-z._+~-]*$ \
        && -d ${guard} && ! -L ${guard} \
        && ${guard##*/} == ".${module}-${version}.lan-ipxe-retirement-v1.guard" \
        && $(stat -c '%u:%g:%a' -- "${guard}" 2>/dev/null) == 0:0:700 ]] \
    || return 1
  first_entry=$(find "${guard}" -mindepth 1 -maxdepth 1 -print -quit) \
    || return 1
  [[ -z ${first_entry} ]]
}

r8152_retirement_authorization_is_valid() {
  local source=$1 module=$2 version=$3
  local authorization=${source}/.lan-ipxe-retirement-authorized
  local recorded_digest
  local -a marker_lines=()
  [[ -d ${source} && ! -L ${source} \
        && ${source##*/} == "${module}-${version}" \
        && -f ${authorization} && ! -L ${authorization} \
        && $(stat -c '%u:%g:%a' -- "${authorization}" 2>/dev/null) == 0:0:644 ]] \
    || return 1
  mapfile -t marker_lines <"${authorization}" || return 1
  [[ ${#marker_lines[@]} == 5 \
        && ${marker_lines[0]} == 'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
        && ${marker_lines[1]} == 'transaction=r8152-source-retirement-v1' \
        && ${marker_lines[2]} == "dkms-module=${module}" \
        && ${marker_lines[3]} == "version=${version}" \
        && ${marker_lines[4]} =~ ^source-tree-sha256=[[:xdigit:]]{64}$ ]] \
    || return 1
  recorded_digest=${marker_lines[4]#source-tree-sha256=}
  [[ $(r8152_source_tree_sha256 "${source}") == "${recorded_digest,,}" ]]
}

prepare_r8152_source_retirement() {
  local source=$1 module=$2 version=$3 source_digest=$4
  local retirement=${source%/*}/.${module}-${version}.lan-ipxe-retirement-v1
  local guard=${retirement}.guard
  local authorization=${source}/.lan-ipxe-retirement-authorized
  local authorization_source
  [[ ! -e ${retirement} && ! -L ${retirement} \
        && ! -e ${guard} && ! -L ${guard} ]] \
    || die "r8152 source retirement transaction is already present"
  [[ ${source_digest} =~ ^[[:xdigit:]]{64}$ \
        && $(r8152_source_tree_sha256 "${source}") == "${source_digest}" ]] \
    || die "r8152 source changed before retirement authorization"
  [[ ! -e ${authorization} && ! -L ${authorization} ]] \
    || die "r8152 source already contains a retirement authorization"
  sudo mkdir -m 0700 -- "${guard}" \
    || die "could not establish the r8152 source retirement guard"
  r8152_retirement_guard_is_valid "${guard}" "${module}" "${version}" \
    || die "r8152 source retirement guard validation failed"
  authorization_source=$(mktemp "${WORK_DIR:-/tmp}/r8152-retirement-marker.XXXXXX") \
    || die "could not create the r8152 source retirement marker"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    'transaction=r8152-source-retirement-v1' \
    "dkms-module=${module}" \
    "version=${version}" \
    "source-tree-sha256=${source_digest}" \
    >"${authorization_source}"
  sudo install -o root -g root -m 0644 -- "${authorization_source}" \
    "${authorization}" \
    || die "could not authorize the r8152 source retirement"
  rm -f -- "${authorization_source}"
  r8152_retirement_authorization_is_valid "${source}" "${module}" "${version}" \
    || die "r8152 source retirement authorization validation failed"
}

R8152_RETIREMENT_RECOVERED=0
recover_r8152_source_retirement() {
  local source=$1 module=$2 version=$3 registered=$4
  local retirement=${source%/*}/.${module}-${version}.lan-ipxe-retirement-v1
  local guard=${retirement}.guard
  local authorization=${source}/.lan-ipxe-retirement-authorized
  R8152_RETIREMENT_RECOVERED=0
  if [[ ! -e ${guard} && ! -L ${guard} ]]; then
    [[ ! -e ${retirement} && ! -L ${retirement} ]] \
      || die "refusing unguarded r8152 source retirement residue: ${retirement}"
    if [[ -e ${authorization} || -L ${authorization} ]]; then
      (( registered )) \
        && r8152_retirement_authorization_is_valid \
          "${source}" "${module}" "${version}" \
        || die "refusing unguarded r8152 source retirement authorization"
      sudo rm -f -- "${authorization}" \
        || die "could not clear an orphaned r8152 retirement authorization"
    fi
    return 0
  fi
  r8152_retirement_guard_is_valid "${guard}" "${module}" "${version}" \
    || die "refusing an invalid r8152 source retirement guard: ${guard}"

  if [[ -e ${retirement} || -L ${retirement} ]]; then
    (( ! registered )) \
      || die "r8152 source was retired while its DKMS registration remains"
    [[ -d ${retirement} && ! -L ${retirement} \
          && ! -e ${source} && ! -L ${source} ]] \
      || die "refusing unsafe r8152 source retirement state"
    sudo rm -rf -- "${retirement}" \
      || die "could not finish deleting the retired r8152 source tree"
    [[ ! -e ${retirement} && ! -L ${retirement} ]] \
      || die "retired r8152 source residue remains"
    R8152_RETIREMENT_RECOVERED=1
  elif (( registered )); then
    [[ -d ${source} && ! -L ${source} ]] \
      || die "guarded r8152 registration has no safe source tree"
    if [[ -e ${authorization} || -L ${authorization} ]]; then
      sudo rm -f -- "${authorization}" \
        || die "could not clear the canceled r8152 retirement authorization"
    fi
  elif [[ -e ${source} || -L ${source} ]]; then
    [[ -d ${source} && ! -L ${source} ]] \
      || die "refusing unsafe guarded r8152 source path: ${source}"
    r8152_retirement_authorization_is_valid "${source}" "${module}" "${version}" \
      || die "refusing to retire a changed or unauthorized r8152 source tree"
    sudo mv -T -- "${source}" "${retirement}" \
      || die "could not resume retiring the unregistered r8152 source tree"
    sudo rm -rf -- "${retirement}" \
      || die "could not finish deleting the retired r8152 source tree"
    [[ ! -e ${source} && ! -L ${source} \
          && ! -e ${retirement} && ! -L ${retirement} ]] \
      || die "r8152 source retirement recovery did not finish"
    R8152_RETIREMENT_RECOVERED=1
  fi
  sudo rmdir -- "${guard}" \
    || die "could not clear the r8152 source retirement guard"
  [[ ! -e ${guard} && ! -L ${guard} ]] \
    || die "r8152 source retirement guard remains"
}

retire_r8152_source_tree() {
  local source=$1 module=$2 version=$3
  local retirement=${source%/*}/.${module}-${version}.lan-ipxe-retirement-v1
  local guard=${retirement}.guard
  [[ -d ${source} && ! -L ${source} \
        && ! -e ${retirement} && ! -L ${retirement} ]] \
    || die "refusing unsafe r8152 source retirement state"
  r8152_retirement_guard_is_valid "${guard}" "${module}" "${version}" \
    || die "refusing to retire r8152 source without its valid guard"
  r8152_retirement_authorization_is_valid "${source}" "${module}" "${version}" \
    || die "refusing to retire a changed or unauthorized r8152 source tree"
  sudo mv -T -- "${source}" "${retirement}" \
    || die "could not atomically retire the r8152 source tree"
  sudo rm -rf -- "${retirement}" \
    || die "could not delete the retired r8152 source tree"
  [[ ! -e ${source} && ! -L ${source} \
        && ! -e ${retirement} && ! -L ${retirement} ]] \
    || die "retired r8152 source tree remains"
  sudo rmdir -- "${guard}" \
    || die "could not clear the r8152 source retirement guard"
  [[ ! -e ${guard} && ! -L ${guard} ]] \
    || die "r8152 source retirement guard remains"
}

R8152_SOURCE_CHANGED=0
R8152_SOURCE_REPLACED=0
R8152_SOURCE_REPLACED_KERNELS=()
ensure_r8152_source_registration() {
  local module=$1 version=$2 staged_source=$3 expected_digest=$4
  local release_tag=$5 release_commit=$6
  local source_root=${7:-${R8152_SOURCE_ROOT}}
  local source=${source_root}/${module}-${version}
  local source_stage=${source_root}/.${module}-${version}.lan-ipxe-stage
  local status line status_tail registered_kernel
  local package_name package_version installed_digest
  local marker=${source}/.lan-ipxe-managed marker_source
  local transaction_marker=${source_stage}/.lan-ipxe-transaction
  local transaction_marker_source
  local marker_module marker_version marker_tag marker_commit marker_digest
  local registered=0 marker_managed=0 replace_source=0 need_source_install=0
  local -A seen_kernels=()
  R8152_SOURCE_CHANGED=0
  R8152_SOURCE_REPLACED=0
  R8152_SOURCE_REPLACED_KERNELS=()

  [[ ${module} == r8152 || ${module} == realtek-r8152 ]] \
    || die "refusing unsupported r8152 DKMS module name: ${module}"
  [[ ${version} =~ ^[0-9][0-9A-Za-z._+~-]*$ \
     && ${release_tag} =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ \
     && ${release_commit} =~ ^[[:xdigit:]]{40}$ \
     && ${expected_digest} =~ ^[[:xdigit:]]{64}$ ]] \
    || die "invalid resolved r8152 source identity"
  [[ $(r8152_source_tree_sha256 "${staged_source}") == "${expected_digest}" ]] \
    || die "staged r8152 source-tree digest changed before registration"
  [[ ! -e ${staged_source}/.lan-ipxe-managed \
        && ! -L ${staged_source}/.lan-ipxe-managed \
        && ! -e ${staged_source}/.lan-ipxe-transaction \
        && ! -L ${staged_source}/.lan-ipxe-transaction \
        && ! -e ${staged_source}/.lan-ipxe-retirement-authorized \
        && ! -L ${staged_source}/.lan-ipxe-retirement-authorized ]] \
    || die "resolved r8152 source unexpectedly contains a setup marker"
  [[ -d ${source_root} && ! -L ${source_root} ]] \
    || die "refusing unsafe r8152 source root: ${source_root}"

  marker_source=${WORK_DIR}/r8152-source-marker
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "dkms-module=${module}" \
    "version=${version}" \
    "release-tag=${release_tag}" \
    "source-commit=${release_commit}" \
    "source-tree-sha256=${expected_digest}" \
    >"${marker_source}"
  transaction_marker_source=${WORK_DIR}/r8152-source-transaction-marker
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    'transaction=r8152-source-install-v1' \
    "dkms-module=${module}" \
    "version=${version}" \
    "release-tag=${release_tag}" \
    "source-commit=${release_commit}" \
    "source-tree-sha256=${expected_digest}" \
    >"${transaction_marker_source}"
  cleanup_r8152_source_stage "${source_stage}" "${module}" "${version}"

  status=$(dkms status -m "${module}" -v "${version}" 2>/dev/null) \
    || die "could not query ${module}/${version} DKMS registration state"
  if grep -F "${module}/${version}" <<<"${status}" >/dev/null; then
    registered=1
  fi
  recover_r8152_source_retirement "${source}" "${module}" "${version}" \
    "${registered}"
  if (( R8152_RETIREMENT_RECOVERED )); then
    replace_source=1
    R8152_SOURCE_CHANGED=1
    R8152_SOURCE_REPLACED=1
    note "${module}/${version}: recovered an interrupted source retirement"
  fi
  if [[ -d ${source} && ! -L ${source} && -f ${marker} && ! -L ${marker} ]] \
     && grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}"; then
    marker_module=$(sed -n 's/^dkms-module=//p' "${marker}" | tail -1)
    marker_version=$(sed -n 's/^version=//p' "${marker}" | tail -1)
    marker_tag=$(sed -n 's/^release-tag=//p' "${marker}" | tail -1)
    marker_commit=$(sed -n 's/^source-commit=//p' "${marker}" | tail -1)
    marker_digest=$(sed -n 's/^source-tree-sha256=//p' "${marker}" | tail -1)
    if [[ ${marker_module} == "${module}" \
          && ${marker_version} == "${version}" \
          && ${marker_tag} =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ \
          && ${marker_commit} =~ ^[[:xdigit:]]{40}$ \
          && ${marker_digest} =~ ^[[:xdigit:]]{64}$ ]]; then
      marker_managed=1
    fi
  fi

  if (( registered )); then
    [[ -d ${source} && ! -L ${source} ]] \
      || die "registered ${module}/${version} has an unsafe or missing source tree: ${source}"
    package_name=$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' \
      "${source}/dkms.conf" 2>/dev/null | tail -1)
    package_version=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' \
      "${source}/dkms.conf" 2>/dev/null | tail -1)
    [[ ${package_name} == "${module}" && ${package_version} == "${version}" ]] \
      || die "registered ${module}/${version} source identity is invalid"
    installed_digest=$(r8152_source_tree_sha256 "${source}")
    if (( marker_managed )) \
       && [[ ${marker_tag} == "${release_tag}" \
          && ${marker_commit} == "${release_commit}" \
          && ${marker_digest} == "${expected_digest}" \
          && ${installed_digest} == "${expected_digest}" ]]; then
      note "${module}/${version}: source tag, commit and tree digest verified"
      return 0
    fi
    if (( ! marker_managed )) && [[ ${installed_digest} == "${expected_digest}" ]]; then
      note "${module}/${version}: adopting the verified existing source tree"
    else
      replace_source=1
      need_source_install=1
      while IFS= read -r line; do
        [[ ${line} == "${module}/${version}"* && ${line} == *,* ]] || continue
        status_tail=${line#*,}
        status_tail=${status_tail#"${status_tail%%[![:space:]]*}"}
        registered_kernel=${status_tail%%,*}
        registered_kernel=${registered_kernel%%[[:space:]]*}
        if [[ ${registered_kernel} =~ ^[0-9][0-9A-Za-z._+~-]*$ \
              && -z ${seen_kernels[${registered_kernel}]:-} ]]; then
          seen_kernels[${registered_kernel}]=1
          R8152_SOURCE_REPLACED_KERNELS+=("${registered_kernel}")
        fi
      done <<<"${status}"
      R8152_SOURCE_CHANGED=1
      R8152_SOURCE_REPLACED=1
      note "${module}/${version}: preparing source from a different release commit"
    fi
  fi

  if (( ! registered )); then
    if [[ -e ${source} || -L ${source} ]]; then
      [[ -d ${source} && ! -L ${source} ]] \
        || die "refusing unsafe unregistered r8152 source path: ${source}"
      package_name=$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' \
        "${source}/dkms.conf" 2>/dev/null | tail -1)
      package_version=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' \
        "${source}/dkms.conf" 2>/dev/null | tail -1)
      installed_digest=$(r8152_source_tree_sha256 "${source}")
      if [[ ${package_name} != "${module}" || ${package_version} != "${version}" \
            || ( ${marker_managed} == 0 && ${installed_digest} != "${expected_digest}" ) ]]; then
        die "${source} exists without a matching registration and cannot be safely replaced"
      fi
      replace_source=1
      R8152_SOURCE_CHANGED=1
      R8152_SOURCE_REPLACED=1
    fi
    need_source_install=1
  fi

  if (( need_source_install )); then
    # Finish the complete, verified replacement before disturbing the current
    # registration or its source tree.
    sudo install -d -o root -g root -m 0755 -- "${source_stage}" \
      || die "could not create r8152 source staging directory"
    [[ $(stat -c '%u:%g:%a' -- "${source_stage}" 2>/dev/null) == 0:0:755 ]] \
      || die "r8152 source staging directory has unsafe ownership or mode"
    sudo install -o root -g root -m 0644 -- "${transaction_marker_source}" \
      "${transaction_marker}" \
      || die "could not establish the r8152 source transaction marker"
    r8152_source_stage_has_valid_marker "${source_stage}" "${module}" "${version}" \
      && cmp -s -- "${transaction_marker_source}" "${transaction_marker}" \
      || die "r8152 source transaction marker validation failed"
    if ! sudo cp -a --no-preserve=ownership -- "${staged_source}/." "${source_stage}/"; then
      cleanup_r8152_source_stage "${source_stage}" "${module}" "${version}"
      die "failed to install the resolved r8152 source tree"
    fi
    [[ ! -e ${source_stage}/.lan-ipxe-retirement-authorized \
          && ! -L ${source_stage}/.lan-ipxe-retirement-authorized ]] \
      || die "staged r8152 source contains a retirement authorization"
    sudo install -o root -g root -m 0644 -- "${marker_source}" \
      "${source_stage}/.lan-ipxe-managed" \
      || die "could not install the r8152 source ownership marker"
    sudo chown -R root:root -- "${source_stage}" \
      || die "could not set ownership on the staged r8152 source tree"
    r8152_source_stage_has_valid_marker "${source_stage}" "${module}" "${version}" \
      && cmp -s -- "${transaction_marker_source}" "${transaction_marker}" \
      || die "staged r8152 source lost its transaction identity"
    [[ $(r8152_source_tree_sha256 "${source_stage}") == "${expected_digest}" ]] \
      || die "staged r8152 source-tree digest mismatch"

    if [[ -e ${source} || -L ${source} ]]; then
      prepare_r8152_source_retirement "${source}" "${module}" "${version}" \
        "${installed_digest}"
    fi
    if (( registered )); then
      sudo dkms remove -m "${module}" -v "${version}" --all \
        || die "could not remove stale ${module}/${version} before source replacement"
      if dkms status -m "${module}" -v "${version}" 2>/dev/null \
           | grep -F "${module}/${version}" >/dev/null; then
        die "stale ${module}/${version} registration remains after removal"
      fi
      registered=0
    fi
    if [[ -e ${source} || -L ${source} ]]; then
      retire_r8152_source_tree "${source}" "${module}" "${version}"
      note "${module}/${version}: retired the superseded source tree"
    fi
    [[ ! -e ${source} && ! -L ${source} ]] \
      || die "r8152 source path appeared while staging: ${source}"
    sudo mv -T -- "${source_stage}" "${source}" \
      || die "could not atomically activate the r8152 source tree"
    [[ -d ${source} && ! -L ${source} \
          && $(r8152_source_tree_sha256 "${source}") == "${expected_digest}" ]] \
      || die "activated r8152 source-tree digest mismatch"
    sudo rm -f -- "${source}/.lan-ipxe-transaction" \
      || die "could not finish the r8152 source installation transaction"
    [[ ! -e ${source}/.lan-ipxe-transaction \
          && ! -L ${source}/.lan-ipxe-transaction ]] \
      || die "r8152 source transaction marker remains after activation"
    sudo dkms add -m "${module}" -v "${version}" \
      || die "failed to register ${module} ${version} with DKMS"
    R8152_SOURCE_CHANGED=1
    note "registered ${module} ${version} from ${release_tag} (${release_commit})"
  fi

  put_file -s "${marker_source}" "${marker}"
  (( replace_source == 0 )) || note "${module}/${version}: replacement source registered"
}

# select_dkms_kernel <running-kernel> <modules-root> <boot-root>: prefer the
# running kernel when it has usable headers and a boot image; otherwise choose
# the newest installed kernel that has both. Sets DKMS_KERNEL.
DKMS_KERNEL=
select_dkms_kernel() {
  local running_kernel=$1 modules_root=$2 boot_root=$3
  local kernel_tree candidate_kernel sorted_kernels
  local kernel_candidates=()
  DKMS_KERNEL=${running_kernel}
  if [[ -f ${modules_root}/${DKMS_KERNEL}/build/Makefile \
        && -s ${boot_root}/vmlinuz-${DKMS_KERNEL} ]]; then
    return 0
  fi
  for kernel_tree in "${modules_root}"/*; do
    [[ -d ${kernel_tree} ]] || continue
    candidate_kernel=${kernel_tree#"${modules_root}"/}
    [[ -f ${kernel_tree}/build/Makefile \
       && -s ${boot_root}/vmlinuz-${candidate_kernel} ]] || continue
    kernel_candidates+=("${candidate_kernel}")
  done
  (( ${#kernel_candidates[@]} )) \
    || die "no installed kernel has both usable headers and a boot image"
  sorted_kernels=$(printf '%s\n' "${kernel_candidates[@]}" | sort -V) \
    || die "could not sort installed kernel/header candidates"
  mapfile -t kernel_candidates <<<"${sorted_kernels}"
  DKMS_KERNEL=${kernel_candidates[${#kernel_candidates[@]} - 1]}
}

R8152_KERNEL_REBOOT_REQUIRED=0
R8152_SECURE_BOOT_WARNING=0
R8152_PURGE_REBOOT_REQUIRED=0
R8152_LOADED_OUT_OF_TREE=0
install_r8152_dkms() {
  local running_kernel=$1
  local actual_r8152_commit repo_ver repo_module source_stage source_digest target_kernel
  local kernel_tree
  local rule_sha udev_marker_source r8152_changed=0 udev_rule_changed=0
  local -a target_kernels=()
  local -A seen_target_kernels=()

  if [[ ! -f /usr/lib/modules/${running_kernel}/build/Makefile \
        || ! -s /boot/vmlinuz-${running_kernel} ]]; then
    note "installing headers for running kernel ${running_kernel}"
    if ! sudo dnf -y install "kernel-devel-${running_kernel}" \
       || [[ ! -f /usr/lib/modules/${running_kernel}/build/Makefile \
             || ! -s /boot/vmlinuz-${running_kernel} ]]; then
      warn "Headers for running kernel ${running_kernel} are no longer available; installing the newest kernel and headers instead."
      sudo dnf -y --refresh install kernel kernel-devel
    fi
  fi
  select_dkms_kernel "${running_kernel}" /usr/lib/modules /boot
  if [[ ${DKMS_KERNEL} != "${running_kernel}" ]]; then
    R8152_KERNEL_REBOOT_REQUIRED=1
    warn "Building r8152 for installed kernel ${DKMS_KERNEL}; reboot into that kernel after setup (currently running ${running_kernel})."
  fi

  git init -q "${WORK_DIR}/r8152"
  git -C "${WORK_DIR}/r8152" remote add origin "${R8152_REPO}"
  git -C "${WORK_DIR}/r8152" fetch -q --depth 1 origin "${R8152_COMMIT}"
  git -C "${WORK_DIR}/r8152" checkout -q --detach FETCH_HEAD
  actual_r8152_commit=$(git -C "${WORK_DIR}/r8152" rev-parse HEAD) \
    || die "could not identify the fetched r8152 revision"
  [[ ${actual_r8152_commit} == "${R8152_COMMIT}" ]] \
    || die "r8152 revision mismatch (expected ${R8152_COMMIT}, got ${actual_r8152_commit})"
  repo_module=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' \
    "${WORK_DIR}/r8152/dkms.conf")
  repo_ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' \
    "${WORK_DIR}/r8152/dkms.conf")
  [[ ${repo_module} == r8152 || ${repo_module} == realtek-r8152 ]] \
    || die "the resolved r8152 dkms.conf has an unexpected PACKAGE_NAME"
  [[ ${repo_ver} =~ ^[0-9][0-9A-Za-z._+~-]*$ ]] \
    || die "the resolved r8152 dkms.conf has an invalid PACKAGE_VERSION"
  note "verified upstream release ${R8152_TAG} at ${R8152_COMMIT}"

  source_stage=${WORK_DIR}/r8152-source-stage
  mkdir -p "${source_stage}"
  if ! git -C "${WORK_DIR}/r8152" archive --format=tar HEAD \
       | tar -xf - -C "${source_stage}"; then
    die "failed to stage the resolved r8152 source tree"
  fi
  source_digest=$(r8152_source_tree_sha256 "${source_stage}")
  ensure_r8152_source_registration "${repo_module}" "${repo_ver}" \
    "${source_stage}" "${source_digest}" "${R8152_TAG}" "${R8152_COMMIT}"
  (( ! R8152_SOURCE_CHANGED )) || r8152_changed=1

  target_kernels+=("${DKMS_KERNEL}")
  seen_target_kernels[${DKMS_KERNEL}]=1
  # A recovered retirement no longer has the old `dkms status` lines. Rebuild
  # every usable installed kernel after any source replacement so crash
  # recovery cannot silently omit a previously registered boot image.
  if (( R8152_SOURCE_REPLACED )); then
    for kernel_tree in /usr/lib/modules/*; do
      [[ -d ${kernel_tree} ]] || continue
      target_kernel=${kernel_tree##*/}
      [[ -f ${kernel_tree}/build/Makefile \
         && -s /boot/vmlinuz-${target_kernel} \
         && -z ${seen_target_kernels[${target_kernel}]:-} ]] || continue
      seen_target_kernels[${target_kernel}]=1
      target_kernels+=("${target_kernel}")
    done
  fi
  for target_kernel in "${R8152_SOURCE_REPLACED_KERNELS[@]}"; do
    [[ -z ${seen_target_kernels[${target_kernel}]:-} ]] || continue
    if [[ -f /usr/lib/modules/${target_kernel}/build/Makefile \
          && -s /boot/vmlinuz-${target_kernel} ]]; then
      seen_target_kernels[${target_kernel}]=1
      target_kernels+=("${target_kernel}")
    else
      warn "not rebuilding replaced r8152 registration for unavailable kernel ${target_kernel}"
    fi
  done
  for target_kernel in "${target_kernels[@]}"; do
    if ! dkms status -m "${repo_module}" -v "${repo_ver}" -k "${target_kernel}" 2>/dev/null \
         | grep -F ': installed' >/dev/null; then
      note "building ${repo_module} ${repo_ver} for ${target_kernel}"
      sudo dkms install -m "${repo_module}" -v "${repo_ver}" -k "${target_kernel}"
      r8152_changed=1
    else
      note "${repo_module} ${repo_ver}: installed for ${target_kernel}"
    fi
  done
  for target_kernel in "${target_kernels[@]}"; do
    dkms status -m "${repo_module}" -v "${repo_ver}" -k "${target_kernel}" 2>/dev/null \
      | grep -F ': installed' >/dev/null \
      || die "DKMS did not report ${repo_module} ${repo_ver} installed for ${target_kernel}"
  done

  remove_superseded_r8152_dkms "${repo_module}" "${repo_ver}"
  if (( R8152_SUPERSEDED_CHANGED )); then
    dkms status -m "${repo_module}" -v "${repo_ver}" -k "${DKMS_KERNEL}" 2>/dev/null \
      | grep -F ': installed' >/dev/null \
      || die "current ${repo_module} ${repo_ver} was disturbed while retiring superseded registrations"
    r8152_changed=1
  fi

  put_file -s "${WORK_DIR}/r8152/udev/rules.d/50-usb-realtek-net.rules" \
    "${R8152_UDEV_RULE}"
  udev_rule_changed=${PUT_FILE_CHANGED}
  rule_sha=$(sha256sum -- "${WORK_DIR}/r8152/udev/rules.d/50-usb-realtek-net.rules") \
    || die "could not hash the verified r8152 udev rule"
  rule_sha=${rule_sha%% *}
  udev_marker_source=${WORK_DIR}/r8152-udev-marker
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "rule-sha256=${rule_sha}" \
    >"${udev_marker_source}"
  put_file -s "${udev_marker_source}" "${R8152_UDEV_MARKER}"
  if (( udev_rule_changed )); then
    sudo udevadm control --reload-rules
    note "udev rules reloaded"
  fi
  if (( R8152_SUPERSEDED_CHANGED || R8152_SOURCE_REPLACED )); then
    sudo dracut --force --regenerate-all
    note "regenerated all installed-kernel initramfs images after replacing r8152 registrations"
  elif (( r8152_changed )); then
    sudo dracut --force "/boot/initramfs-${DKMS_KERNEL}.img" "${DKMS_KERNEL}"
  fi

  if mokutil --sb-state 2>/dev/null | grep -Fi 'SecureBoot enabled' >/dev/null; then
    if [[ -f /var/lib/dkms/mok.pub ]] \
       && sudo mokutil --test-key /var/lib/dkms/mok.pub >/dev/null 2>&1; then
      note "Secure Boot: DKMS MOK is enrolled"
    else
      R8152_SECURE_BOOT_WARNING=1
      warn "Secure Boot is enabled but the DKMS MOK is not enrolled; enroll /var/lib/dkms/mok.pub before expecting r8152 to load."
    fi
  fi
}

R8152_INITRAMFS_REBUILT=0
# shellcheck disable=SC2120
reconcile_r8152_initramfs() {
  local modules_root=${1:-/usr/lib/modules}
  local boot_root=${2:-/boot}
  local kernel_tree kernel image contents
  local needs_rebuild=${R8152_PURGE_MODULE_CHANGED}
  local -a installed_kernels=()
  R8152_INITRAMFS_REBUILT=0

  for kernel_tree in "${modules_root}"/*; do
    [[ -d ${kernel_tree} ]] || continue
    kernel=${kernel_tree#"${modules_root}"/}
    [[ ${kernel} =~ ^[0-9][0-9A-Za-z._+~-]*$ \
       && -s ${boot_root}/vmlinuz-${kernel} ]] || continue
    installed_kernels+=("${kernel}")
    image=${boot_root}/initramfs-${kernel}.img
    if ! sudo test -s "${image}"; then
      needs_rebuild=1
      continue
    fi
    if ! contents=$(sudo lsinitrd "${image}" 2>/dev/null); then
      needs_rebuild=1
      continue
    fi
    if grep -Eq 'modules/[^/[:space:]]+/(extra|updates|weak-updates)(/[^[:space:]]*)*/(realtek-)?r8152[.]ko([.]|$)' \
         <<<"${contents}"; then
      needs_rebuild=1
    fi
  done
  (( ${#installed_kernels[@]} )) \
    || die "no installed Fedora kernels with boot images were found"

  if (( needs_rebuild )); then
    sudo dracut --force --regenerate-all
    R8152_INITRAMFS_REBUILT=1
  fi

  for kernel in "${installed_kernels[@]}"; do
    image=${boot_root}/initramfs-${kernel}.img
    sudo test -s "${image}" \
      || die "dracut did not produce ${image} while reconciling r8152"
    contents=$(sudo lsinitrd "${image}" 2>/dev/null) \
      || die "could not inspect ${image} after reconciling r8152"
    if grep -Eq 'modules/[^/[:space:]]+/(extra|updates|weak-updates)(/[^[:space:]]*)*/(realtek-)?r8152[.]ko([.]|$)' \
         <<<"${contents}"; then
      die "${image} still contains an out-of-tree r8152 module after reconciliation"
    fi
  done
}

manage_r8152_driver() {
  local running_kernel=$1
  local sysfs_root=${2:-${R8152_SYSFS_ROOT}}
  if kernel_version_at_least "${running_kernel}" "${R8152_IN_TREE_KERNEL_MIN}"; then
    note "kernel ${running_kernel} is ${R8152_IN_TREE_KERNEL_MIN}+; using its in-tree r8152 driver"
    purge_r8152_dkms "${R8152_SOURCE_ROOT}" "${R8152_UDEV_RULE}" \
      "${R8152_UDEV_MARKER}"
    reconcile_r8152_initramfs /usr/lib/modules /boot
    if (( R8152_PURGE_MODULE_CHANGED || R8152_INITRAMFS_REBUILT )); then
      R8152_PURGE_REBOOT_REQUIRED=1
      note "installed-kernel initramfs images contain no out-of-tree r8152 module"
    fi
    if [[ -r ${sysfs_root}/module/r8152/taint ]] \
       && grep -Fq 'O' "${sysfs_root}/module/r8152/taint"; then
      R8152_LOADED_OUT_OF_TREE=1
      R8152_PURGE_REBOOT_REQUIRED=1
      warn "The loaded r8152 module is marked out-of-tree; reboot to switch kernel ${running_kernel} to its in-tree driver."
    fi
    return 0
  fi

  resolve_r8152_release
  note "resolved latest stable upstream ${R8152_TAG} (${R8152_COMMIT})"
  install_r8152_dkms "${running_kernel}"
}

#--- Preflight --------------------------------------------------------------
[[ ${EUID} -ne 0 ]] || die "Run as your normal user, not root (sudo is used where needed)."
[[ -f /etc/fedora-release ]] || die "This script is for Fedora."
[[ -d ${FILES} ]] || die "Payload directory not found: ${FILES}"
command -v sudo >/dev/null || die "sudo is required."
command -v dnf  >/dev/null || die "dnf is required."
command -v sha256sum >/dev/null || die "sha256sum is required."
FEDORA_VERSION=$(rpm -E %fedora)
[[ ${FEDORA_VERSION} =~ ^[0-9]+$ ]] || die "could not determine the Fedora release number"
(( FEDORA_VERSION >= FEDORA_MIN_VERSION )) \
  || die "Fedora ${FEDORA_MIN_VERSION}+ is required (found ${FEDORA_VERSION})."
DNF_VERSION_OUTPUT=$(dnf --version 2>/dev/null) || die "could not query the DNF version"
[[ ${DNF_VERSION_OUTPUT} == dnf5\ version* ]] || die "DNF5 is required."
if [[ ${ARCH} == x86_64 ]]; then IS_X86_64=1; X86_64_EXTRAS=on; else IS_X86_64=0; X86_64_EXTRAS=off; fi
case ${ARCH} in
  x86_64)
    SPEEDTEST_ARCHIVE_SHA256=${SPEEDTEST_ARCHIVE_SHA256_X86_64}
    SPEEDTEST_BINARY_SHA256=${SPEEDTEST_BINARY_SHA256_X86_64}
    ANTIGRAVITY_DESKTOP_MANIFEST_URL=${ANTIGRAVITY_DESKTOP_MANIFEST_BASE}/latest-x64-linux.yml
    ANTIGRAVITY_DESKTOP_URL_SUFFIX=/linux-x64/Antigravity.AppImage
    ANTIGRAVITY_CLI_MANIFEST_URL=${ANTIGRAVITY_CLI_MANIFEST_BASE}/linux_amd64.json
    ANTIGRAVITY_CLI_URL_SUFFIX=/linux-x64/cli_linux_x64.tar.gz
    ZED_ARCH=x86_64
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
    OPENCODE_ASSET=opencode-linux-arm64.tar.gz
    ;;
  *)
    die "Antigravity, OpenCode, Codex, and Zed support only x86_64 and aarch64 (found ${ARCH})."
    ;;
esac
log "Fedora ${FEDORA_VERSION} on ${ARCH} (x86_64-only extras: ${X86_64_EXTRAS})"

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
import_rpm_key "${MICROSOFT_KEY_URL}" gpgsecurity@microsoft.com \
  "${MICROSOFT_KEY_FINGERPRINT}" "${MICROSOFT_KEY_FILE}"
import_rpm_key "${CLAUDE_KEY_URL}" security@anthropic.com \
  "${CLAUDE_KEY_FINGERPRINT}" "${CLAUDE_KEY_FILE}"
put_file -s "${FILES}/etc/yum.repos.d/vscode.repo" /etc/yum.repos.d/vscode.repo
put_file -s "${FILES}/etc/yum.repos.d/claude-code.repo" /etc/yum.repos.d/claude-code.repo
dnf_repo_enabled code || die "the Microsoft VS Code repository is not enabled"
dnf_repo_enabled claude-code || die "the Claude Code repository is not enabled"

if dnf_repo_enabled "copr:copr.fedorainfracloud.org:jmsqrd:tributary"; then
  note "copr ${TRIBUTARY_COPR}: enabled"
else
  sudo dnf copr enable -y "${TRIBUTARY_COPR}"
  dnf_repo_enabled "copr:copr.fedorainfracloud.org:jmsqrd:tributary" \
    || die "copr ${TRIBUTARY_COPR} was not enabled successfully"
  note "copr ${TRIBUTARY_COPR}: enabled now"
fi

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
log "Repositories (x86_64, keys, Microsoft, sing-box)"
if (( IS_X86_64 )); then
  for repo in google-chrome rpmfusion-nonfree-nvidia-driver rpmfusion-nonfree-steam; do
    put_file -s "${FILES}/etc/yum.repos.d/${repo}.repo" "/etc/yum.repos.d/${repo}.repo"
  done
fi
if (( IS_X86_64 )); then
  import_rpm_key "${GOOGLE_KEY_URL}" linux-packages-keymaster@google.com
fi
put_file -s "${FILES}/etc/yum.repos.d/microsoft-prod.repo" /etc/yum.repos.d/microsoft-prod.repo
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

#--- 3. Packages ------------------------------------------------------------
log "Applying all available DNF package updates"
sudo dnf -y upgrade --refresh

log "Package set (${#PKGS[@]} entries)"
dnf_install "${PKGS[@]}"
if (( IS_X86_64 )); then
  log "x86_64 package set (${#PKGS_X86_64[@]} entries)"
  dnf_install "${PKGS_X86_64[@]}"
fi
locale -a | grep -Fxi 'en_US.utf8' >/dev/null \
  || die "glibc-langpack-en was installed, but the en_US.UTF-8 locale is unavailable"
for required_command in base64 git jq od sha512sum; do
  command -v "${required_command}" >/dev/null \
    || die "release resolution requires ${required_command}"
done

#--- 4. Native developer tools ---------------------------------------------
log "Resolving latest verified native developer-tool releases"
resolve_native_tool_releases

log "Antigravity 2.0+ desktop + CLI"
install_antigravity_desktop
install_antigravity_cli

log "OpenCode CLI (verified native release)"
install_opencode_cli

# OpenAI's supported standalone installer resolves the current native release
# and validates its published checksums before activating it under ~/.local.
log "Codex CLI (official standalone release)"
install_codex_cli

# Fedora has no first-party Zed RPM. Install Zed's official release archive
# only after checking the digest published with the immutable GitHub asset.
log "Zed (verified official native release)"
install_zed

for command_name in agy antigravity claude code codex opencode zed; do
  PATH="${HOME}/.local/bin:${PATH}" command -v "${command_name}" >/dev/null \
    || die "expected workstation command is unavailable: ${command_name}"
done

#--- 5. speedtest CLI -------------------------------------------------------
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

#--- 6. Realtek r8152 DKMS driver -------------------------------------------
# Resolve upstream's latest stable release, bind its tag to one commit, and
# perform the small DKMS workflow directly instead of executing a mutable
# master-branch helper as root. Kernel 7.2 and newer carries the required
# driver in-tree, so that path performs only a bounded purge and never queries
# the upstream release API.
log "Realtek r8152 USB NIC driver (DKMS)"
manage_r8152_driver "${KERNEL}"

#--- 7. Flatpaks ------------------------------------------------------------
log "Flatpaks"
sudo flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak_install "${FLATPAKS[@]}"
if (( IS_X86_64 )); then
  flatpak_install "${FLATPAKS_X86_64[@]}"
fi
sudo flatpak update -y --system --noninteractive
note "all installed system Flatpaks checked for updates"

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
for unit in "${SERVICES[@]}"; do
  enable_unit "${unit}"
done
if [[ $(systemctl get-default) == graphical.target ]]; then
  note "default target: graphical.target"
else
  sudo systemctl set-default graphical.target
  note "default target: graphical.target (set now)"
fi

#--- 10. GDM ----------------------------------------------------------------
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
if (( R8152_SECURE_BOOT_WARNING )); then
  warn "r8152 will remain unavailable under Secure Boot until the DKMS MOK is enrolled and the host is rebooted."
fi
if (( R8152_KERNEL_REBOOT_REQUIRED )); then
  warn "Reboot into ${DKMS_KERNEL} to use r8152; headers for the running kernel ${KERNEL} were unavailable."
fi
if (( R8152_PURGE_REBOOT_REQUIRED && ! R8152_LOADED_OUT_OF_TREE )); then
  warn "Reboot to finish switching from the removed out-of-tree r8152 module to the kernel ${KERNEL} in-tree driver."
fi
