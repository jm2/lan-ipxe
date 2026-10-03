#!/usr/bin/env bash
# Mocked, CI-safe checks for setup-arch-workstation.sh profiles and modes.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${REPO_ROOT}/setup-arch-workstation.sh
TEST_ROOT=$(mktemp -d -t arch-profiles.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'ASSERT: %s\n' "$*" >&2
  exit 1
}

load_helpers() {
  set --
  # Every helper is declared before the preflight marker.
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
}

array_contains() {
  local wanted=$1 item
  shift
  for item in "$@"; do
    [[ ${item} == "${wanted}" ]] && return 0
  done
  return 1
}

test_argument_parsing() {
  local args rc output
  "${SCRIPT}" --help | grep -Fq -- '--profile core|full' \
    || fail '--help does not document --profile'
  for args in '--profile' '--profile other' '--check --dry-run' '--dry-run --check' '--unknown'; do
    rc=0
    # shellcheck disable=SC2086 # deliberate word splitting of the case
    output=$("${SCRIPT}" ${args} 2>&1 >/dev/null) || rc=$?
    [[ ${rc} == 1 ]] || fail "'${args}' exited ${rc}, expected 1"
    [[ ${output} == *Usage:* ]] || fail "'${args}' did not print usage on stderr"
  done
}

test_profile_selection() (
  load_helpers
  local package
  local -a games=(steam lutris lib32-vulkan-radeon ollama-cuda ollama-vulkan)
  local -a games_aur=(steamcmd bugdom nanosaur cro-mag-rally-net lgogdownloader)
  local -a media=(brasero video-downloader)
  [[ ${PROFILE} == core ]] || fail 'default profile is not core'
  for package in "${games[@]}" "${media[@]}"; do
    ! array_contains "${package}" "${PKGS_OFFICIAL[@]}" \
      || fail "core official set includes ${package}"
  done
  for package in "${games_aur[@]}" makemkv; do
    ! array_contains "${package}" "${PKGS_AUR[@]}" \
      || fail "core AUR set includes ${package}"
  done
  for package in rustup chromium code gcc clang go jdk-openjdk cockpit; do
    array_contains "${package}" "${PKGS_OFFICIAL[@]}" \
      || fail "core official set omits ${package}"
  done
  for package in google-chrome balun-bin tributary-bin claude-code powershell-bin android-studio; do
    array_contains "${package}" "${PKGS_AUR[@]}" \
      || fail "core AUR set omits ${package}"
  done
  select_profile full
  for package in "${games[@]}" "${media[@]}" rustup chromium; do
    array_contains "${package}" "${PKGS_OFFICIAL[@]}" \
      || fail "full official set omits ${package}"
  done
  for package in "${games_aur[@]}" makemkv balun-bin tributary-bin; do
    array_contains "${package}" "${PKGS_AUR[@]}" \
      || fail "full AUR set omits ${package}"
  done
  select_profile full
  [[ ${#PKGS_OFFICIAL[@]} == $(( ${#PKGS_OFFICIAL_CORE[@]} + ${#PKGS_OFFICIAL_FULL[@]} )) ]] \
    || fail 'select_profile is not idempotent'
  for package in rust rust-analyzer r8152-dkms; do
    ! array_contains "${package}" "${PKGS_OFFICIAL[@]}" "${PKGS_AUR[@]}" \
      || fail "a profile still requests ${package}"
  done
  ! grep -qi r8152 "${SCRIPT}" || fail 'Arch setup still references r8152'
)

test_managed_files_are_applied() (
  load_helpers
  local entry owner src dst mode flag
  for entry in "${MANAGED_FILES[@]}"; do
    IFS='|' read -r owner src dst mode <<<"${entry}"
    flag=''
    [[ ${owner} == root ]] && flag='-s '
    dst=${dst/#"${HOME}"/'"${HOME}'}
    [[ ${dst} == '"${HOME}'* ]] && dst+='"'
    [[ ${mode} == 0644 ]] && mode='' || mode=" ${mode}"
    awk -v want="put_file ${flag}\"\${FILES}/${src}\" ${dst}${mode}" \
      '{ line = $0; gsub(/  +/, " ", line) } line == want { found = 1 } END { exit !found }' \
      "${SCRIPT}" || fail "managed file ${src} has no matching apply-time put_file"
  done
)

# Dry-run must not reach sudo, the network, pacman, yay or rustup, and must not
# write anything, even on a non-Arch host.
test_dry_run_is_offline() {
  local shims=${TEST_ROOT}/shims home=${TEST_ROOT}/home log=${TEST_ROOT}/calls profile
  local name output before after
  mkdir -p "${shims}" "${home}"
  : >"${log}"
  for name in sudo pacman pacman-conf curl wget git yay makepkg rustup systemctl \
              dracut grub-mkconfig locale-gen dconf install ln cp; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 97\n' "${name}" "${log}" >"${shims}/${name}"
    chmod +x "${shims}/${name}"
  done
  before=$(find "${home}" "${REPO_ROOT}" -newer "${log}" -print 2>/dev/null | sort)
  for profile in core full; do
    output=$(HOME=${home} PATH=${shims}:${PATH} "${SCRIPT}" --dry-run --profile "${profile}") \
      || fail "dry-run ${profile} failed"
    [[ ${output} == "Profile: ${profile}; mode: dry-run"* ]] \
      || fail "dry-run ${profile} did not announce its profile"
    if [[ ${profile} == core ]]; then
      ! grep -Eq '^  (steam|lutris|bugdom|makemkv)$' <<<"${output}" \
        || fail 'core dry-run plans game/media packages'
    else
      grep -Eq '^  steam$' <<<"${output}" || fail 'full dry-run omits steam'
      grep -Fq 'enable [multilib]' <<<"${output}" || fail 'full dry-run omits [multilib]'
    fi
    grep -Eq '^  rustup$' <<<"${output}" || fail "${profile} dry-run omits rustup"
  done
  output=$(HOME=${home} PATH=${shims}:${PATH} "${SCRIPT}" --dry-run --no-upgrade) \
    || fail 'dry-run --no-upgrade failed'
  [[ ${output} == *'--no-upgrade: skip pacman -Syu'* ]] || fail 'dry-run ignores --no-upgrade'
  [[ ! -s ${log} ]] || fail "dry-run invoked commands: $(<"${log}")"
  after=$(find "${home}" "${REPO_ROOT}" -newer "${log}" -print 2>/dev/null | sort)
  [[ ${before} == "${after}" ]] || fail 'dry-run wrote files'
}

test_check_exit_codes() (
  load_helpers
  local installed rc output
  pacman-conf() { [[ $1 == --repo-list ]] && printf 'core\nextra\nmultilib\n'; }
  vercmp() { printf '1\n'; }
  systemctl() { return 0; }
  check_managed_file() { report CURRENT "$3"; }
  check_system_state() { report CURRENT 'system state'; }
  RUSTUP_HOME=${TEST_ROOT}/rustup
  mkdir -p "${RUSTUP_HOME}/toolchains/${RUST_TOOLCHAIN}/lib/rustlib"
  printf 'default_toolchain = "stable-x86_64-unknown-linux-gnu"\n' >"${RUSTUP_HOME}/settings.toml"
  printf 'rustc-x86_64\nrustfmt-preview-x86_64\nclippy-preview-x86_64\nrust-analyzer-preview-x86_64\n' \
    >"${RUSTUP_HOME}/toolchains/${RUST_TOOLCHAIN}/lib/rustlib/components"
  installed=' antigravity '
  pacman() {
    case $1 in
      -Sg) return 0 ;;
      -Q) [[ ${installed} == *" $2 "* ]] && printf '%s 2.1.0-1\n' "$2" && return 0; return 1 ;;
      -T) shift; local p; for p in "$@"; do [[ ${p} == steam ]] && printf '%s\n' "${p}"; done
          [[ ${missing:-0} == 1 ]] && printf 'zed\n'; return 0 ;;
    esac
    return 1
  }
  missing=0
  rc=0; output=$(run_check) || rc=$?
  [[ ${rc} == 0 ]] || fail "converged core check exited ${rc}: ${output}"
  missing=1
  rc=0; output=$(run_check) || rc=$?
  [[ ${rc} == 2 && ${output} == *'DRIFT    official package zed'* ]] \
    || fail "core check did not report missing zed with exit 2 (${rc})"
  missing=0
  installed=' antigravity rust mkinitcpio '
  rc=0; output=$(run_check) || rc=$?
  [[ ${rc} == 2 && ${output} == *'distro Rust: rust installed'* && ${output} == *mkinitcpio* ]] \
    || fail 'check did not flag distro Rust / mkinitcpio'
  installed=' antigravity '
  PROFILE=full; select_profile full
  rc=0; output=$(run_check) || rc=$?
  [[ ${rc} == 2 && ${output} == *'official package steam: not installed'* ]] \
    || fail 'full check did not report missing steam'
  pacman-conf() { [[ $1 == --repo-list ]] && printf 'core\nextra\n'; }
  output=$(run_check) || true
  [[ ${output} == *'[multilib]: disabled'* ]] || fail 'full check ignores disabled [multilib]'
  PROFILE=core; select_profile core
  output=$(run_check) || true
  [[ ${output} == *'[multilib]: not required'* ]] || fail 'core check requires [multilib]'
)

test_rust_transition() (
  load_helpers
  local calls=${TEST_ROOT}/rust-calls installed=' rust rust-src '
  : >"${calls}"
  pacman() { [[ $1 == -Q ]] && [[ ${installed} == *" $2 "* ]]; }
  sudo() {
    printf '%s\n' "$*" >>"${calls}"
    case $* in
      'pacman -Rdd --noconfirm rust rust-src') installed=' ' ;;
      'pacman -S --needed --noconfirm rustup') installed=' rustup ' ;;
      *) fail "unexpected sudo call: $*" ;;
    esac
  }
  transition_rust_to_rustup_arch >/dev/null
  [[ $(<"${calls}") == $'pacman -Rdd --noconfirm rust rust-src\npacman -S --needed --noconfirm rustup' ]] \
    || fail "unexpected Rust transition: $(<"${calls}")"
  : >"${calls}"
  transition_rust_to_rustup_arch >/dev/null
  [[ ! -s ${calls} ]] || fail 'Rust transition is not idempotent'
)

# NO_UPGRADE and RUSTUP_HOME are read by the dynamically sourced helpers.
# shellcheck disable=SC2034
test_rustup_toolchain() (
  load_helpers
  local calls=${TEST_ROOT}/rustup-calls
  RUSTUP_HOME=${TEST_ROOT}/rustup-apply
  : >"${calls}"
  rustup() {
    printf '%s\n' "$*" >>"${calls}"
    local tc=${RUSTUP_HOME}/toolchains/${RUST_TOOLCHAIN}
    case $1 in
      toolchain) mkdir -p "${tc}/lib/rustlib"; touch "${tc}/lib/rustlib/components" ;;
      component) shift 3; printf '%s-preview\n' "$@" >>"${tc}/lib/rustlib/components" ;;
      default) printf 'default_toolchain = "%s"\n' "$2" >"${RUSTUP_HOME}/settings.toml" ;;
    esac
  }
  NO_UPGRADE=0
  configure_rustup_toolchain >/dev/null
  [[ $(<"${calls}") == $'toolchain install stable --profile minimal --no-self-update\ncomponent add --toolchain stable rustfmt clippy rust-analyzer\ndefault stable' ]] \
    || fail "unexpected rustup bootstrap: $(<"${calls}")"
  : >"${calls}"
  NO_UPGRADE=1
  configure_rustup_toolchain >/dev/null
  [[ ! -s ${calls} ]] || fail "--no-upgrade rerun still called rustup: $(<"${calls}")"
  NO_UPGRADE=0
  printf 'default_toolchain = "nightly-x86_64-unknown-linux-gnu"\n' >"${RUSTUP_HOME}/settings.toml"
  configure_rustup_toolchain >/dev/null
  [[ $(<"${calls}") == 'toolchain install stable --profile minimal --no-self-update' ]] \
    || fail "an existing non-stable default was changed: $(<"${calls}")"
)

test_no_upgrade_sync_dbs() (
  load_helpers
  local db=${TEST_ROOT}/pacman-db
  mkdir -p "${db}/sync"
  pacman-conf() {
    case $1 in
      DBPath) printf '%s/\n' "${db}" ;;
      --repo-list) printf 'core\nextra\nmultilib\n' ;;
    esac
  }
  printf 'x' >"${db}/sync/core.db"
  printf 'x' >"${db}/sync/extra.db"
  ! sync_dbs_present || fail 'missing multilib.db was accepted'
  printf 'x' >"${db}/sync/multilib.db"
  sync_dbs_present || fail 'complete sync databases were rejected'
)

test_argument_parsing
printf 'PASS Arch argument parsing and usage errors\n'
test_profile_selection
printf 'PASS Arch core/full package selection (games/media full-only, rustup, no r8152)\n'
test_managed_files_are_applied
printf 'PASS Arch managed-file list matches apply-time put_file calls\n'
test_dry_run_is_offline
printf 'PASS Arch dry-run is offline and read-only for both profiles\n'
test_check_exit_codes
printf 'PASS Arch check exit codes and drift reporting\n'
test_rust_transition
printf 'PASS Arch distro Rust -> rustup transition\n'
test_rustup_toolchain
printf 'PASS Arch rustup stable toolchain reconciliation\n'
test_no_upgrade_sync_dbs
printf 'PASS Arch --no-upgrade sync-database guard\n'
