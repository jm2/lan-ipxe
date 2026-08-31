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
# Safe to re-run: every step checks state first, config files are rewritten
# only when their content, type, mode, or ownership differs, and the follow-ups that only a
# real change needs (grub-mkconfig, sysctl reload, dconf update) run only
# then. Package steps install only what is missing, so a converged system is
# a fast no-op - with one deliberate exception: the official-repo step is a
# full `pacman -Syu` (partial upgrades are unsupported on Arch), so a re-run
# also applies pending updates.
#
# What it does, in order:
#   1. enables [multilib] in /etc/pacman.conf
#   2. pacman -Syu, then installs the official-repo package set
#   3. installs dotfiles (~/.bashrc, ~/.vimrc) and system config from files/:
#      /etc/default/grub (+ grub-mkconfig), /etc/bash.bashrc, /etc/locale.conf,
#      locale generation, the inotify sysctl limit, zram, the daily
#      pacman-update cron job, vi -> vim
#   4. generates and validates dracut images before removing mkinitcpio
#   5. enables the service set (bluetooth, chrony, cronie, cups, gdm, ...)
#   6. publishes ~/.config/monitors.xml to GDM and applies the GDM font setting
#   7. bootstraps yay (yay-bin from the AUR), interactively reviews/updates
#      installed AUR packages, and installs the requested AUR set

set -euo pipefail

#--- Config -----------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=${SCRIPT_DIR}/files
YAY_AUR_URL=https://aur.archlinux.org/yay-bin.git

# Official repositories (groups are fine: gnome, gnome-circle, gnome-extra,
# vulkan-devel are expanded before the installed-check)
PKGS_OFFICIAL=(
  base-devel
  bash-completion
  bash-preexec
  bison
  bluez
  bluez-utils
  boost
  brasero
  cantarell-fonts
  ccache
  cdrtools
  chrony
  clang
  chromium
  cmake
  colordiff
  cronie
  cups
  cups-pk-helper
  dos2unix
  dracut
  efibootmgr
  erofs-utils
  flex
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
  less
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
  lutris
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
  ollama-cuda
  ollama-vulkan
  opencl-mesa
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
  rust
  screen
  seahorse
  sof-firmware
  steam
  sudo
  system-config-printer
  texinfo
  tree
  unarchiver
  video-downloader
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
  zram-generator
)

# AUR (via yay)
PKGS_AUR=(
  airshipper
  android-ndk
  android-sdk-build-tools
  android-sdk-cmdline-tools-latest
  android-sdk-platform-tools
  android-studio
  antigravity
  bugdom
  bugdom2
  claude-code
  cro-mag-rally-net
  downgrade
  dxvk-bin
  gnome-icon-theme
  gnome-icon-theme-symbolic
  gnome-shell-extension-dash-to-dock
  google-chrome
  hfsutils
  lgogdownloader
  lineageos-devel
  luxtorpeda-bin
  maelstrom
  makemkv
  maniadrive
  mightymike
  mstflint
  nanosaur
  nanosaur2
  ookla-speedtest-bin
  openarena
  ottomatic
  payload-dumper-go-bin
  powershell-bin
  sit-git
  steamcmd
  tremulous-grangerhub-bin
  tributary-bin
  tuxracer
  unigine-heaven
  ventoy-bin
  vscodium-bin
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

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ${0##*/} [-h|--help]

Idempotent Arch Linux workstation setup: official + AUR package sets, dotfiles
and system config from files/, services, GDM settings. Run as your normal
user (sudo is used for the privileged steps); safe to re-run at any time.
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
declare -A IS_GROUP=()
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
  local output rc=0
  MISSING_PKGS=()
  (( $# )) || return 0
  output=$(pacman -T "$@" 2>&1) || rc=$?
  if (( rc != 0 && rc != 127 )); then
    die "pacman dependency check failed (exit ${rc}): ${output}"
  fi
  if [[ -n ${output} ]]; then
    mapfile -t MISSING_PKGS <<<"${output}"
  fi
}

#--- Preflight --------------------------------------------------------------
[[ ${EUID} -ne 0 ]] || die "Run as your normal user, not root (AUR builds refuse to run as root; sudo is used where needed)."
[[ -f /etc/arch-release ]] || die "This script is for Arch Linux."
[[ $(uname -m) == x86_64 ]] || die "This package set targets Arch Linux x86_64."
[[ -d ${FILES} ]] || die "Payload directory not found: ${FILES}"
command -v sudo >/dev/null || die "sudo is required."
command -v pacman-conf >/dev/null || die "pacman-conf is required."
pacman -Q pacman &>/dev/null || die "the local pacman database is not readable."
[[ -f /etc/pacman.conf ]] || die "/etc/pacman.conf is missing."
[[ -d /boot/grub ]] || die "This setup targets an existing GRUB installation; /boot/grub is missing."

case $(awk -F ': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo) in
  AuthenticAMD) PKGS_OFFICIAL+=(amd-ucode) ;;
  GenuineIntel) PKGS_OFFICIAL+=(intel-ucode) ;;
  *)            warn "CPU vendor not recognized; no microcode package will be selected" ;;
esac

WORK_DIR=$(mktemp -d)
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log "Authenticating sudo"
sudo -v || die "sudo authentication failed"

#--- 1. [multilib] ----------------------------------------------------------
# Must be enabled before any lib32-* / steam package can be installed
log "[multilib] repository"
repo_list=$(pacman-conf --repo-list 2>/dev/null) || die "could not read /etc/pacman.conf"
if grep -qx multilib <<<"${repo_list}"; then
  note "enabled"
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
log "Syncing databases and applying updates (pacman -Syu)"
sudo pacman -Syu --noconfirm

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

#--- 7. AUR -----------------------------------------------------------------
# AUR PKGBUILDs are third-party code. Keep this phase last so an AUR build
# cannot alter user-writable repository payloads before they are installed as
# root, drop the setup script's cached sudo credential, and leave yay's review
# prompts enabled.
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

log "Updating installed AUR packages"
yay -Sua

log "AUR package set (${#PKGS_AUR[@]} entries)"
find_missing_pkgs "${PKGS_AUR[@]}"
if (( ${#MISSING_PKGS[@]} )); then
  note "installing ${#MISSING_PKGS[@]} missing: ${MISSING_PKGS[*]}"
  yay -S --needed "${MISSING_PKGS[@]}"
else
  note "all ${#PKGS_AUR[@]} packages present"
fi

log "Done. Kernel/initramfs/GRUB changes and newly enabled services take effect on the next boot."
