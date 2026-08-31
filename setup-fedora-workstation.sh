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
# dkms build, dracut) run only then. A converged system is a fast no-op.
#
# What it does, in order:
#   1. third-party repos: Antigravity, VSCodium, the jmsqrd/tributary copr,
#      RPM Fusion free+nonfree, Microsoft (PowerShell), sing-box; on x86_64
#      also Google Chrome and the RPM Fusion nvidia-driver + steam repos
#   2. CA-bundle symlinks at the Debian-style paths some tools hard-code
#   3. the dnf package set (plus the x86_64-only set: i686 libs, Chrome, Steam)
#   4. a checksum-pinned Ookla speedtest CLI into ~/.local/bin
#   5. the Realtek r8152 USB NIC driver from an immutable, verified upstream
#      revision via DKMS (awesometic/realtek-r8152-dkms)
#   6. flathub + the flatpak set (plus x86_64-only extras)
#   7. dotfiles (~/.bashrc, ~/.vimrc, Antigravity settings) and system config
#      from files/: /etc/locale.conf, the inotify sysctl limit, the Arch-style
#      prompt as /etc/profile.d/01-arch-prompt.sh
#   8. the service set, graphical.target as default
#   9. publishes ~/.config/monitors.xml to GDM and applies the GDM font setting

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
VSCODIUM_KEY_URL=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/-/raw/master/pub.gpg
GOOGLE_KEY_URL=https://dl.google.com/linux/linux_signing_key.pub
MICROSOFT_KEY_URL=https://packages.microsoft.com/keys/microsoft.asc
SINGBOX_REPO_URL=https://sing-box.app/sing-box.repo
SINGBOX_REPO_FILE=/etc/yum.repos.d/sing-box.repo
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
  antigravity
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
  clang
  clippy
  cmake
  codium
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

# import_rpm_key <url> <uid-fragment>: imports the signing key unless one
# whose user id contains <uid-fragment> is already in the rpm database
import_rpm_key() {
  local url=$1 frag=$2 key_summaries
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
    ;;
  aarch64)
    SPEEDTEST_ARCHIVE_SHA256=${SPEEDTEST_ARCHIVE_SHA256_AARCH64}
    SPEEDTEST_BINARY_SHA256=${SPEEDTEST_BINARY_SHA256_AARCH64}
    ;;
  *)
    SPEEDTEST_ARCHIVE_SHA256=
    SPEEDTEST_BINARY_SHA256=
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

# copr and config-manager live in the dnf5 plugins package
if ! dnf copr --help &>/dev/null || ! dnf config-manager --help &>/dev/null; then
  log "Installing dnf5-plugins (copr / config-manager)"
  sudo dnf -y install dnf5-plugins
fi

#--- 1. Repositories --------------------------------------------------------
log "Repositories"
warn "The Antigravity vendor publishes no RPM signing key; its repository has gpgcheck=0."
put_file -s "${FILES}/etc/yum.repos.d/antigravity.repo" /etc/yum.repos.d/antigravity.repo
put_file -s "${FILES}/etc/yum.repos.d/vscodium.repo"    /etc/yum.repos.d/vscodium.repo

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
import_rpm_key "${VSCODIUM_KEY_URL}" paulcarroty@riseup.net
if (( IS_X86_64 )); then
  import_rpm_key "${GOOGLE_KEY_URL}" linux-packages-keymaster@google.com
fi
put_file -s "${FILES}/etc/yum.repos.d/microsoft-prod.repo" /etc/yum.repos.d/microsoft-prod.repo
import_rpm_key "${MICROSOFT_KEY_URL}" gpgsecurity@microsoft.com
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

#--- 4. speedtest CLI -------------------------------------------------------
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

#--- 5. Realtek r8152 DKMS driver -------------------------------------------
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

#--- 6. Flatpaks ------------------------------------------------------------
log "Flatpaks"
sudo flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak_install "${FLATPAKS[@]}"
if (( IS_X86_64 )); then
  flatpak_install "${FLATPAKS_X86_64[@]}"
fi

#--- 7. Dotfiles and system config ------------------------------------------
log "Dotfiles"
put_file "${FILES}/bashrc" "${HOME}/.bashrc"
put_file "${FILES}/vimrc"  "${HOME}/.vimrc"
put_file "${FILES}/config/Antigravity/User/settings.json" \
         "${HOME}/.config/Antigravity/User/settings.json"

log "System config"
put_file -s "${FILES}/etc/locale.conf" /etc/locale.conf
put_file -s "${FILES}/etc/sysctl.d/99-inotify.conf" /etc/sysctl.d/99-inotify.conf
if (( PUT_FILE_CHANGED )); then
  sudo sysctl -q -p /etc/sysctl.d/99-inotify.conf
fi
put_file -s "${FILES}/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
# The Arch-style colour prompt, hooked in through profile.d on Fedora
put_file -s "${FILES}/etc/bash.bashrc" /etc/profile.d/01-arch-prompt.sh

#--- 8. Services ------------------------------------------------------------
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

#--- 9. GDM -----------------------------------------------------------------
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
