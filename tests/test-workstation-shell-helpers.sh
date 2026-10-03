#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/var/tmp}/workstation-helpers.XXXXXX")
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

load_helpers() {
  local script=$1
  set --
  # Fedora's URL constants expand %fedora before preflight. Stub only that
  # read so these platform-independent helpers can also run on Ubuntu CI.
  rpm() {
    [[ ${1:-} == -E && ${2:-} == %fedora ]] || return 1
    printf '44\n'
  }
  # The preflight marker follows every helper definition in both scripts.
  # The selected repository script is intentionally dynamic.
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${REPO_ROOT}/${script}")
}

test_put_file() (
  load_helpers "$1"
  local case_dir=${TEST_ROOT}/${1%.sh}
  install -d "${case_dir}"
  printf 'desired\n' >"${case_dir}/source"

  put_file "${case_dir}/source" "${case_dir}/target" 0640
  (( PUT_FILE_CHANGED == 1 ))
  [[ $(stat -c '%a' "${case_dir}/target") == 640 ]]
  put_file "${case_dir}/source" "${case_dir}/target" 0640
  (( PUT_FILE_CHANGED == 0 ))

  printf 'do-not-change\n' >"${case_dir}/link-target"
  ln -s "${case_dir}/link-target" "${case_dir}/symlink-dest"
  put_file "${case_dir}/source" "${case_dir}/symlink-dest" 0644
  [[ ! -L ${case_dir}/symlink-dest ]]
  cmp -s "${case_dir}/source" "${case_dir}/symlink-dest"
  grep -qx 'do-not-change' "${case_dir}/link-target"
)

test_put_file_failure() {
  local script=$1 case_dir=${TEST_ROOT}/failure-${1%.sh} rc=0
  install -d "${case_dir}"
  printf 'desired\n' >"${case_dir}/source"
  (
    load_helpers "${script}"
    install() { return 66; }
    if put_file "${case_dir}/source" "${case_dir}/target"; then
      exit 90
    fi
    exit 91
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]]
  [[ ! -e ${case_dir}/target ]]
}

test_root_put_file_failure() {
  local script=$1 case_dir=${TEST_ROOT}/root-failure-${1%.sh} rc=0
  install -d "${case_dir}"
  printf 'desired\n' >"${case_dir}/source"
  (
    load_helpers "${script}"
    sudo() { return 66; }
    if put_file -s "${case_dir}/source" "${case_dir}/target"; then
      exit 90
    fi
    exit 91
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]]
  [[ ! -e ${case_dir}/target ]]
}

test_pacman_statuses() (
  load_helpers setup-arch-workstation.sh
  pacman() {
    [[ $1 == -T ]]
    printf 'missing-one\nmissing-two\n'
    printf 'warning that must not become a package name\n' >&2
    return 127
  }
  find_missing_pkgs one two
  [[ ${MISSING_PKGS[*]} == 'missing-one missing-two' ]]
)

test_pacman_operational_failure() {
  local rc=0
  (
    load_helpers setup-arch-workstation.sh
    pacman() { printf 'database unavailable\n' >&2; return 42; }
    if find_missing_pkgs one; then exit 90; fi
    exit 91
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]]
}

test_repo_matching() (
  load_helpers setup-fedora-workstation.sh
  dnf() {
    printf 'repo id repo name\n'
    printf 'sing-box Sing Box\n'
    printf 'sing-box-testing Similar Prefix\n'
  }
  dnf_repo_enabled sing-box
  ! dnf_repo_enabled sing
)

test_fedora_flatpak_inventory_failure() {
  local rc=0
  (
    load_helpers setup-fedora-workstation.sh
    flatpak() { return 42; }
    if flatpak_install org.example.App; then exit 90; fi
    exit 91
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]]
}

for script in setup-arch-workstation.sh setup-fedora-workstation.sh; do
  test_put_file "${script}"
  printf 'PASS %s put_file convergence and symlink repair\n' "${script}"
  test_put_file_failure "${script}"
  printf 'PASS %s user put_file failure propagation\n' "${script}"
  test_root_put_file_failure "${script}"
  printf 'PASS %s root put_file failure propagation\n' "${script}"
done
test_pacman_statuses
printf 'PASS pacman missing-package status handling\n'
test_pacman_operational_failure
printf 'PASS pacman operational-error propagation\n'
test_repo_matching
printf 'PASS exact DNF repository matching\n'
test_fedora_flatpak_inventory_failure
printf 'PASS Flatpak inventory failure propagation\n'
