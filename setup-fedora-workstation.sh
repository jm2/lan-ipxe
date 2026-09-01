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
# they are), package/flatpak steps install only what is missing, and the
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
#      retired in favor of native Antigravity 2.x and VS Code.
#   2. CA-bundle symlinks at the Debian-style paths some tools hard-code
#   3. the dnf package set (plus the x86_64-only set: i686 libs, Chrome, Steam)
#   4. Antigravity 2.x + CLI, OpenCode, Codex CLI, and Zed using native vendor
#      artifacts/installers (checksummed where upstream publishes digests)
#   5. a checksum-pinned Ookla speedtest CLI into ~/.local/bin
#   6. the Realtek r8152 USB NIC driver from an immutable, verified upstream
#      revision via DKMS (awesometic/realtek-r8152-dkms)
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
ANTIGRAVITY_VERSION=2.11.0
ANTIGRAVITY_BUILD=6376446768316416
ANTIGRAVITY_INSTALL_DIR=/opt/Antigravity
ANTIGRAVITY_COMMAND_LINK=/usr/local/bin/antigravity
ANTIGRAVITY_DESKTOP_FILE=/usr/share/applications/antigravity.desktop
ANTIGRAVITY_CLI_VERSION=1.1.22
ANTIGRAVITY_CLI_BUILD=5711547746615296
ANTIGRAVITY_APP_ASAR_SHA256=c21a013797376cf92cc2a821706e6af4d77f020aa233796c4f9e8ee066a29187
OPENCODE_VERSION=1.18.25
CODEX_INSTALLER_URL=https://chatgpt.com/codex/install.sh
ZED_VERSION=1.17.2
SPEEDTEST_VERSION=1.2.0
SPEEDTEST_ARCHIVE_SHA256_X86_64=5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7
SPEEDTEST_BINARY_SHA256_X86_64=31f1124c5ab8acdae6b9fe1741e704df420f9f2e7d429679fabe62075453c051
SPEEDTEST_ARCHIVE_SHA256_AARCH64=3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3
SPEEDTEST_BINARY_SHA256_AARCH64=d99fa13293f658b53eaa79fe81f4b210db39fdfc1e9698f33da3f234a6008df7
R8152_REPO=https://github.com/awesometic/realtek-r8152-dkms.git
R8152_TAG=2.22.1-1
R8152_COMMIT=d93c9f89ca5a831c9437e35319c546e48c710f9a
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

remove_legacy_antigravity_rpm() {
  if rpm -q --quiet antigravity; then
    sudo dnf -y remove antigravity \
      || die "could not remove the legacy Antigravity 1.x RPM"
    rpm -q --quiet antigravity \
      && die "legacy Antigravity RPM is still installed"
    note "legacy Antigravity 1.x RPM: removed"
  else
    note "legacy Antigravity 1.x RPM: absent"
  fi
}

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

install_antigravity_desktop() {
  local install_dir=${1:-${ANTIGRAVITY_INSTALL_DIR}}
  local marker=${install_dir}/.lan-ipxe-release
  local archive=${WORK_DIR}/Antigravity-${ANTIGRAVITY_VERSION}.tar.gz
  local extract_dir=${WORK_DIR}/antigravity-desktop
  local source_dir=${extract_dir}/${ANTIGRAVITY_ARCHIVE_ROOT}
  local marker_source=${WORK_DIR}/antigravity-release-marker
  local stage=${install_dir}.lan-ipxe-stage.$$
  local backup=${install_dir}.lan-ipxe-backup.$$
  local current_sha='' current_asar_sha='' archive_sha='' binary_sha='' app_asar_sha=''

  [[ ! -e ${ANTIGRAVITY_COMMAND_LINK} || -L ${ANTIGRAVITY_COMMAND_LINK} ]] \
    || die "refusing to replace unmanaged path: ${ANTIGRAVITY_COMMAND_LINK}"
  if [[ -x ${install_dir}/antigravity && -f ${install_dir}/resources/app.asar \
        && -f ${marker} ]]; then
    current_sha=$(sha256sum -- "${install_dir}/antigravity") \
      || die "could not hash ${install_dir}/antigravity"
    current_sha=${current_sha%% *}
    current_asar_sha=$(sha256sum -- "${install_dir}/resources/app.asar") \
      || die "could not hash ${install_dir}/resources/app.asar"
    current_asar_sha=${current_asar_sha%% *}
    if grep -Fxq 'managed-by=lan-ipxe/setup-fedora-workstation.sh' "${marker}" \
       && grep -Fxq "version=${ANTIGRAVITY_VERSION}" "${marker}" \
       && grep -Fxq "archive-sha256=${ANTIGRAVITY_ARCHIVE_SHA256}" "${marker}" \
       && grep -Fxq "app-asar-sha256=${ANTIGRAVITY_APP_ASAR_SHA256}" "${marker}" \
       && [[ ${current_sha} == "${ANTIGRAVITY_BINARY_SHA256}" \
          && ${current_asar_sha} == "${ANTIGRAVITY_APP_ASAR_SHA256}" ]]; then
      note "Antigravity ${ANTIGRAVITY_VERSION}: present and verified"
      ensure_symlink -s "${install_dir}/antigravity" "${ANTIGRAVITY_COMMAND_LINK}"
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
    -o "${archive}" "${ANTIGRAVITY_DESKTOP_URL}" \
    || die "could not download Antigravity ${ANTIGRAVITY_VERSION}"
  archive_sha=$(sha256sum -- "${archive}") || die "could not hash ${archive}"
  archive_sha=${archive_sha%% *}
  [[ ${archive_sha} == "${ANTIGRAVITY_ARCHIVE_SHA256}" ]] \
    || die "Antigravity desktop archive checksum mismatch for ${ARCH}"
  mkdir -p "${extract_dir}"
  tar -xzf "${archive}" -C "${extract_dir}" \
    || die "could not extract the Antigravity desktop archive"
  [[ -x ${source_dir}/antigravity && -f ${source_dir}/resources/app.asar ]] \
    || die "Antigravity desktop archive has an unexpected layout"
  binary_sha=$(sha256sum -- "${source_dir}/antigravity") \
    || die "could not hash the extracted Antigravity binary"
  binary_sha=${binary_sha%% *}
  [[ ${binary_sha} == "${ANTIGRAVITY_BINARY_SHA256}" ]] \
    || die "extracted Antigravity binary checksum mismatch for ${ARCH}"
  app_asar_sha=$(sha256sum -- "${source_dir}/resources/app.asar") \
    || die "could not hash the extracted Antigravity application bundle"
  app_asar_sha=${app_asar_sha%% *}
  [[ ${app_asar_sha} == "${ANTIGRAVITY_APP_ASAR_SHA256}" ]] \
    || die "extracted Antigravity application-bundle checksum mismatch for ${ARCH}"

  [[ ! -e ${stage} && ! -L ${stage} && ! -e ${backup} && ! -L ${backup} ]] \
    || die "stale Antigravity staging path exists beside ${install_dir}"
  sudo cp -a -- "${source_dir}" "${stage}" \
    || die "could not stage Antigravity under $(dirname "${install_dir}")"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${ANTIGRAVITY_VERSION}" \
    "archive-sha256=${ANTIGRAVITY_ARCHIVE_SHA256}" \
    "app-asar-sha256=${ANTIGRAVITY_APP_ASAR_SHA256}" \
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
  ensure_symlink -s "${install_dir}/antigravity" "${ANTIGRAVITY_COMMAND_LINK}"
  put_file -s "${FILES}/usr/share/applications/antigravity.desktop" \
    "${ANTIGRAVITY_DESKTOP_FILE}"
  note "Antigravity ${ANTIGRAVITY_VERSION}: installed from verified native archive"
}

install_antigravity_cli() {
  local bin_dir=${1:-${HOME}/.local/bin}
  local dest=${bin_dir}/agy archive=${WORK_DIR}/antigravity-cli.tar.gz
  local extract_dir=${WORK_DIR}/antigravity-cli archive_sha='' binary_sha='' version=''
  if [[ -x ${dest} ]]; then
    binary_sha=$(sha256sum -- "${dest}") || die "could not hash ${dest}"
    binary_sha=${binary_sha%% *}
    if [[ ${binary_sha} == "${ANTIGRAVITY_CLI_BINARY_SHA256}" ]]; then
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
  [[ ${binary_sha} == "${ANTIGRAVITY_CLI_BINARY_SHA256}" ]] \
    || die "extracted Antigravity CLI checksum mismatch for ${ARCH}"
  put_file "${extract_dir}/antigravity" "${dest}" 0755
  version=$("${dest}" --version 2>/dev/null) \
    || die "the installed Antigravity CLI is not runnable"
  [[ ${version} == "${ANTIGRAVITY_CLI_VERSION}" ]] \
    || die "Antigravity CLI reported unexpected version ${version}"
  note "Antigravity CLI ${version}: installed as ~/.local/bin/agy"
}

install_opencode_cli() {
  local bin_dir=${1:-${HOME}/.local/bin}
  local dest=${bin_dir}/opencode archive=${WORK_DIR}/opencode.tar.gz
  local extract_dir=${WORK_DIR}/opencode current_version='' archive_sha=''
  if [[ -x ${dest} ]]; then
    current_version=$("${dest}" --version 2>/dev/null || true)
  fi
  if [[ ${current_version} == "${OPENCODE_VERSION}" ]]; then
    note "OpenCode ${OPENCODE_VERSION}: present"
    return 0
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
  put_file "${extract_dir}/opencode" "${dest}" 0755
  current_version=$("${dest}" --version 2>/dev/null) \
    || die "the installed OpenCode CLI is not runnable"
  [[ ${current_version} == "${OPENCODE_VERSION}" ]] \
    || die "OpenCode reported unexpected version ${current_version}"
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
    ANTIGRAVITY_DESKTOP_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/${ANTIGRAVITY_VERSION}-${ANTIGRAVITY_BUILD}/linux-x64/Antigravity.tar.gz"
    ANTIGRAVITY_ARCHIVE_SHA256=43b1e257fd2614ddb9a5a578b03f8ac391f6579b3b06283abe15964157f65129
    ANTIGRAVITY_BINARY_SHA256=b0d127772d2983a93771055a93b673d5fdd1726d6e47db8e269b204e665972d6
    ANTIGRAVITY_ARCHIVE_ROOT=Antigravity-x64
    ANTIGRAVITY_CLI_URL="https://storage.googleapis.com/antigravity-public/antigravity-cli/${ANTIGRAVITY_CLI_VERSION}-${ANTIGRAVITY_CLI_BUILD}/linux-x64/cli_linux_x64.tar.gz"
    ANTIGRAVITY_CLI_ARCHIVE_SHA512=40225d4b1f009412e905f0a234ba3d51487038d1ad1b8fa19331c84be55610a01f5b0ad9916fb871151cc45456c6bc30cc0b1ea5dab6c0616bc8fb262bcdd7a9
    ANTIGRAVITY_CLI_BINARY_SHA256=2822292f90deea4556938a8728fe4ed02a1d66d1525cf75fa07a171e36a38c25
    ZED_ARCH=x86_64
    ZED_ARCHIVE_SHA256=3682dd058a305d2b246a14d64419fcf42e86a06e27755d23b5a28622ed9aef85
    if grep -qwi avx2 /proc/cpuinfo; then
      OPENCODE_ASSET=opencode-linux-x64.tar.gz
      OPENCODE_ARCHIVE_SHA256=58a3729a6f3432dd6d2917fcc4a949788891a035818646ad480e12c947f56e78
    else
      OPENCODE_ASSET=opencode-linux-x64-baseline.tar.gz
      OPENCODE_ARCHIVE_SHA256=ccd10586611b598b1eaed7c05cfbcbc68e3ec09e736b360da09b1d615d922968
    fi
    ;;
  aarch64)
    SPEEDTEST_ARCHIVE_SHA256=${SPEEDTEST_ARCHIVE_SHA256_AARCH64}
    SPEEDTEST_BINARY_SHA256=${SPEEDTEST_BINARY_SHA256_AARCH64}
    ANTIGRAVITY_DESKTOP_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/${ANTIGRAVITY_VERSION}-${ANTIGRAVITY_BUILD}/linux-arm/Antigravity.tar.gz"
    ANTIGRAVITY_ARCHIVE_SHA256=d59b193df733bf50ef3e4db069bcd1227be9b0ddc3b1de3d3ff78bbd78f85261
    ANTIGRAVITY_BINARY_SHA256=e706505fdd89003390c256b084ee44625e4ab0aacd068b8f62290af8b0a6f6ed
    ANTIGRAVITY_ARCHIVE_ROOT=Antigravity-arm64
    ANTIGRAVITY_CLI_URL="https://storage.googleapis.com/antigravity-public/antigravity-cli/${ANTIGRAVITY_CLI_VERSION}-${ANTIGRAVITY_CLI_BUILD}/linux-arm/cli_linux_arm64.tar.gz"
    ANTIGRAVITY_CLI_ARCHIVE_SHA512=b37a718330eb5e270e1ca70135bf964a407ba626fbff7537ac58e094ea31bc623e6d216ef197188fe8b5c46e6f57aee64a3b7c9e23fc855cefee43fe434179d3
    ANTIGRAVITY_CLI_BINARY_SHA256=05b149ad7266acf96c5dfad10535a11ed9a6ceb9910149f4d6c66ce461daf9d1
    ZED_ARCH=aarch64
    ZED_ARCHIVE_SHA256=4f75332ab8155a5a62b0cdc473473cf8938959cf3cd2b0145e2975969d7e8929
    OPENCODE_ASSET=opencode-linux-arm64.tar.gz
    OPENCODE_ARCHIVE_SHA256=35ef77897425e41b5183a2c21ac4fb1d4d944d82a94e3c920f57b5490af11ac5
    ;;
  *)
    die "Antigravity, OpenCode, Codex, and Zed support only x86_64 and aarch64 (found ${ARCH})."
    ;;
esac
OPENCODE_URL="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${OPENCODE_ASSET}"
ZED_URL="https://github.com/zed-industries/zed/releases/download/v${ZED_VERSION}/zed-linux-${ZED_ARCH}.tar.gz"
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
log "Package set (${#PKGS[@]} entries)"
dnf_install "${PKGS[@]}"
if (( IS_X86_64 )); then
  log "x86_64 package set (${#PKGS_X86_64[@]} entries)"
  dnf_install "${PKGS_X86_64[@]}"
fi
locale -a | grep -Fxi 'en_US.utf8' >/dev/null \
  || die "glibc-langpack-en was installed, but the en_US.UTF-8 locale is unavailable"

#--- 4. Native developer tools ---------------------------------------------
log "Antigravity 2.x desktop + CLI"
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
# Fetch an immutable upstream revision, verify the exact commit, and perform
# the small DKMS workflow directly instead of executing a mutable master-branch
# helper as root.
log "Realtek r8152 USB NIC driver (DKMS)"
if [[ ! -f /usr/lib/modules/${KERNEL}/build/Makefile \
      || ! -s /boot/vmlinuz-${KERNEL} ]]; then
  note "installing headers for running kernel ${KERNEL}"
  if ! sudo dnf -y install "kernel-devel-${KERNEL}" \
     || [[ ! -f /usr/lib/modules/${KERNEL}/build/Makefile \
           || ! -s /boot/vmlinuz-${KERNEL} ]]; then
    warn "Headers for running kernel ${KERNEL} are no longer available; installing the newest kernel and headers instead."
    sudo dnf -y --refresh install kernel kernel-devel
  fi
fi
select_dkms_kernel "${KERNEL}" /usr/lib/modules /boot
R8152_KERNEL_REBOOT_REQUIRED=0
if [[ ${DKMS_KERNEL} != "${KERNEL}" ]]; then
  R8152_KERNEL_REBOOT_REQUIRED=1
  warn "Building r8152 for installed kernel ${DKMS_KERNEL}; reboot into that kernel after setup (currently running ${KERNEL})."
fi
git init -q "${WORK_DIR}/r8152"
git -C "${WORK_DIR}/r8152" remote add origin "${R8152_REPO}"
git -C "${WORK_DIR}/r8152" fetch -q --depth 1 origin "${R8152_COMMIT}"
git -C "${WORK_DIR}/r8152" checkout -q --detach FETCH_HEAD
actual_r8152_commit=$(git -C "${WORK_DIR}/r8152" rev-parse HEAD) \
  || die "could not identify the fetched r8152 revision"
[[ ${actual_r8152_commit} == "${R8152_COMMIT}" ]] \
  || die "r8152 revision mismatch (expected ${R8152_COMMIT}, got ${actual_r8152_commit})"
repo_ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "${WORK_DIR}/r8152/dkms.conf")
[[ -n ${repo_ver} ]] || die "could not read PACKAGE_VERSION from the r8152 dkms.conf"
note "pinned upstream ${R8152_TAG} (${R8152_COMMIT})"

r8152_changed=0
if ! dkms status -m r8152 -v "${repo_ver}" 2>/dev/null \
     | grep -F "r8152/${repo_ver}" >/dev/null; then
  r8152_source=/usr/src/r8152-${repo_ver}
  [[ ! -e ${r8152_source} ]] \
    || die "${r8152_source} exists but DKMS has no matching registration; inspect and remove the stale directory, then re-run"
  sudo install -d -o root -g root -m 0755 -- "${r8152_source}"
  if ! git -C "${WORK_DIR}/r8152" archive --format=tar HEAD \
       | sudo tar -xf - -C "${r8152_source}"; then
    sudo rm -rf -- "${r8152_source}"
    die "failed to install the pinned r8152 source tree"
  fi
  if ! sudo dkms add -m r8152 -v "${repo_ver}"; then
    sudo rm -rf -- "${r8152_source}"
    die "failed to register r8152 ${repo_ver} with DKMS"
  fi
  r8152_changed=1
  note "registered r8152 ${repo_ver}"
fi

if ! dkms status -m r8152 -v "${repo_ver}" -k "${DKMS_KERNEL}" 2>/dev/null \
     | grep -F ': installed' >/dev/null; then
  note "building r8152 ${repo_ver} for ${DKMS_KERNEL}"
  sudo dkms install -m r8152 -v "${repo_ver}" -k "${DKMS_KERNEL}"
  r8152_changed=1
else
  note "r8152 ${repo_ver}: installed for ${DKMS_KERNEL}"
fi

dkms status -m r8152 -v "${repo_ver}" -k "${DKMS_KERNEL}" 2>/dev/null \
  | grep -F ': installed' >/dev/null \
  || die "DKMS did not report r8152 ${repo_ver} installed for ${DKMS_KERNEL}"

put_file -s "${WORK_DIR}/r8152/udev/rules.d/50-usb-realtek-net.rules" \
  /etc/udev/rules.d/50-usb-realtek-net.rules
if (( PUT_FILE_CHANGED )); then
  sudo udevadm control --reload-rules
  note "udev rules reloaded"
fi
if (( r8152_changed )); then
  sudo dracut --force "/boot/initramfs-${DKMS_KERNEL}.img" "${DKMS_KERNEL}"
fi

R8152_SECURE_BOOT_WARNING=0
if mokutil --sb-state 2>/dev/null | grep -Fi 'SecureBoot enabled' >/dev/null; then
  if [[ -f /var/lib/dkms/mok.pub ]] \
     && sudo mokutil --test-key /var/lib/dkms/mok.pub >/dev/null 2>&1; then
    note "Secure Boot: DKMS MOK is enrolled"
  else
    R8152_SECURE_BOOT_WARNING=1
    warn "Secure Boot is enabled but the DKMS MOK is not enrolled; enroll /var/lib/dkms/mok.pub before expecting r8152 to load."
  fi
fi

#--- 7. Flatpaks ------------------------------------------------------------
log "Flatpaks"
sudo flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak_install "${FLATPAKS[@]}"
if (( IS_X86_64 )); then
  flatpak_install "${FLATPAKS_X86_64[@]}"
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

log "Done. Newly enabled services, zram, the default target and the r8152 module take effect on the next boot."
if (( R8152_SECURE_BOOT_WARNING )); then
  warn "r8152 will remain unavailable under Secure Boot until the DKMS MOK is enrolled and the host is rebooted."
fi
if (( R8152_KERNEL_REBOOT_REQUIRED )); then
  warn "Reboot into ${DKMS_KERNEL} to use r8152; headers for the running kernel ${KERNEL} were unavailable."
fi
