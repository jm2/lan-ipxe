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

test_freon_sensors() (
  load_helpers "$1"
  local dir=${TEST_ROOT}/freon-${1%.sh} out
  install -d "${dir}"
  freon() { render_freon_sensors "$1" "${dir}/$2.json" "${@:3}"; }
  hot() { freon "$@" | sed -n 's/^hot-sensors=//p'; }

  printf '%s' '{"coretemp-isa-0000":{"Core 0":{"temp2_input":39},"Package id 0":{"temp1_input":40}},
    "acpitz-acpi-0":{"temp1":{"temp1_input":30}},"nvme-pci-0100":{"Composite":{"temp1_input":33}}}' \
    >"${dir}/intel.json"
  [[ $(hot intel intel) == "['Package id 0']" ]]
  # NVIDIA's proprietary driver: the nvidia-smi name, and Freon must read it.
  out=$(freon intel intel "NVIDIA GeForce RTX 4070")
  grep -Fxq "hot-sensors=['Package id 0', 'NVIDIA GeForce RTX 4070']" <<<"${out}"
  grep -Fxq 'use-gpu-nvidia=true' <<<"${out}"
  [[ $(hot intel intel "O'Neil \\ GPU") == "['Package id 0', 'O\\'Neil \\\\ GPU']" ]]

  # AMD: Tctl, and the dGPU's edge even when the APU's amdgpu chip lists
  # first (Freon then names the second "edge" "edge-1").
  printf '%s' '{"amdgpu-pci-0500":{"edge":{"temp1_input":42}},
    "k10temp-pci-00c3":{"Tctl":{"temp1_input":45},"Tccd1":{"temp3_input":40}},
    "amdgpu-pci-0300":{"vddgfx":{"in0_input":0.8},"edge":{"temp1_input":50},"junction":{"temp2_input":55}}}' \
    >"${dir}/amd-dgpu.json"
  [[ $(hot amd amd-dgpu) == "['Tctl', 'edge-1']" ]]
  # An AMD APU alone: its iGPU has a dedicated sensor.
  printf '%s' '{"k10temp-pci-00c3":{"Tctl":{"temp1_input":45}},"amdgpu-pci-0500":{"edge":{"temp1_input":42}}}' \
    >"${dir}/amd-apu.json"
  [[ $(hot amd amd-apu) == "['Tctl', 'edge']" ]]
  # Intel Arc on xe.
  printf '%s' '{"coretemp-isa-0000":{"Package id 0":{"temp1_input":40}},"xe-pci-0300":{"pkg":{"temp2_input":48},"vram":{"temp3_input":50}}}' \
    >"${dir}/intel-arc.json"
  [[ $(hot intel intel-arc) == "['Package id 0', 'pkg']" ]]

  # Arm thermal zones: unlabeled temp1s, numbered in listing order.
  printf '%s' '{"gpuss0_thermal-virtual-0":{"temp1":{"temp1_input":30}},
    "cpu0_top_thermal-virtual-0":{"temp1":{"temp1_input":40}}}' >"${dir}/qcom.json"
  [[ $(hot qualcomm qcom) == "['temp1-1']" ]]
  [[ $(hot nvidia qcom) == "['temp1-1']" ]]
  printf '%s' '{"macsmc_hwmon-isa-0000":{"NAND Flash":{"temp1_input":35},"CPU P-core 1":{"temp2_input":44}}}' \
    >"${dir}/apple.json"
  [[ $(hot apple apple) == "['CPU P-core 1']" ]]

  # Nothing recognized: no keyfile, so Freon keeps average/maximum.
  [[ -z $(freon unknown qcom) ]]
  [[ -z $(freon intel apple) ]]
)

test_cpu_platform() (
  load_helpers "$1"
  local root=${TEST_ROOT}/cpu-${1%.sh}
  install -d "${root}"/{intel,amd,arm,qcom,apple,nv}/proc \
    "${root}/qcom/sys/firmware/devicetree/base" "${root}/apple/sys/firmware/devicetree/base" \
    "${root}/nv/sys/devices/soc0"
  printf 'vendor_id\t: GenuineIntel\n' >"${root}/intel/proc/cpuinfo"
  printf 'vendor_id\t: AuthenticAMD\n' >"${root}/amd/proc/cpuinfo"
  printf 'CPU implementer\t: 0x41\n' | tee "${root}"/{arm,qcom,apple,nv}/proc/cpuinfo >/dev/null
  printf 'qcom,x1e80100-crd\0qcom,x1e80100\0' >"${root}/qcom/sys/firmware/devicetree/base/compatible"
  printf 'apple,j414c\0apple,t6000\0' >"${root}/apple/sys/firmware/devicetree/base/compatible"
  printf 'jep106:036b:0241\n' >"${root}/nv/sys/devices/soc0/soc_id"
  [[ $(detect_cpu_platform "${root}/intel") == intel ]]
  [[ $(detect_cpu_platform "${root}/amd") == amd ]]
  [[ $(detect_cpu_platform "${root}/qcom") == qualcomm ]]
  [[ $(detect_cpu_platform "${root}/apple") == apple ]]
  [[ $(detect_cpu_platform "${root}/nv") == nvidia ]]
  [[ $(detect_cpu_platform "${root}/arm") == unknown ]]
)

test_dock_aliases() (
  load_helpers "$1"
  local root=${TEST_ROOT}/dock-${1%.sh}
  install -d "${root}/rpm/applications" "${root}/flatpak/applications"
  : >"${root}/rpm/applications/bugdom.desktop"
  : >"${root}/rpm/applications/chrome.desktop"
  : >"${root}/flatpak/applications/io.jor.mightymike.desktop"
  # shellcheck disable=SC2034  # read by the sourced desktop_id_present
  APP_DATA_DIRS=("${root}/rpm" "${root}/flatpak")
  # Flatpak -> package and package -> Flatpak, in place; unknown and
  # not-installed entries are left for the dock to skip.
  [[ $(swap_dock_aliases "['chrome.desktop', 'io.jor.bugdom.desktop', 'mightymike.desktop', 'gone.desktop']") \
     == "['chrome.desktop', 'bugdom.desktop', 'io.jor.mightymike.desktop', 'gone.desktop']" ]]
  # Both forms listed (the shipped default) collapse to the installed one.
  [[ $(swap_dock_aliases "['bugdom.desktop', 'io.jor.bugdom.desktop']") == "['bugdom.desktop']" ]]
  [[ $(swap_dock_aliases "['chrome.desktop']") == "['chrome.desktop']" ]]
)

test_strv_merge() (
  load_helpers "$1"
  [[ $(strv_merge "['a', 'old@x', 'b']" "old@x,gone@y" "['c']" a c d) == "['a', 'b', 'd']" ]]
  [[ $(strv_merge "@as []" "" "@as []" x y) == "['x', 'y']" ]]
  [[ $(strv_merge "['a']" "a" "@as []") == "@as []" ]]
  [[ $(strv_merge "['a', 'b']" "" "@as []" b a) == "['a', 'b']" ]]
)

for script in setup-arch-workstation.sh setup-fedora-workstation.sh; do
  test_put_file "${script}"
  printf 'PASS %s put_file convergence and symlink repair\n' "${script}"
  test_put_file_failure "${script}"
  printf 'PASS %s user put_file failure propagation\n' "${script}"
  test_root_put_file_failure "${script}"
  printf 'PASS %s root put_file failure propagation\n' "${script}"
  test_freon_sensors "${script}"
  printf 'PASS %s Freon panel sensors per CPU/GPU platform\n' "${script}"
  test_cpu_platform "${script}"
  printf 'PASS %s CPU platform detection\n' "${script}"
  test_dock_aliases "${script}"
  printf 'PASS %s dock launcher aliases\n' "${script}"
  test_strv_merge "${script}"
  printf 'PASS %s enabled-extensions merge\n' "${script}"
done
test_pacman_statuses
printf 'PASS pacman missing-package status handling\n'
test_pacman_operational_failure
printf 'PASS pacman operational-error propagation\n'
test_repo_matching
printf 'PASS exact DNF repository matching\n'
test_fedora_flatpak_inventory_failure
printf 'PASS Flatpak inventory failure propagation\n'
