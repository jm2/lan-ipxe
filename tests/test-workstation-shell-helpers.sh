#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/workstation-helpers.XXXXXX)

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

test_fedora_inventory_failures() {
  local kind=$1 rc=0
  (
    load_helpers setup-fedora-workstation.sh
    case ${kind} in
      dnf)
        dnf() { return 42; }
        if dnf_install @development-tools; then exit 90; fi
        ;;
      flatpak)
        flatpak() { return 42; }
        if flatpak_install org.example.App; then exit 90; fi
        ;;
    esac
    exit 91
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]]
}

test_dkms_kernel_selection() (
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/dkms-kernels
  install -d "${case_dir}/modules/6.17.1/build" \
    "${case_dir}/modules/6.18.2/build" \
    "${case_dir}/modules/6.19.0-without-boot/build" "${case_dir}/boot"
  printf 'mock\n' >"${case_dir}/modules/6.17.1/build/Makefile"
  printf 'mock\n' >"${case_dir}/modules/6.18.2/build/Makefile"
  printf 'mock\n' >"${case_dir}/modules/6.19.0-without-boot/build/Makefile"
  printf 'mock\n' >"${case_dir}/boot/vmlinuz-6.17.1"
  printf 'mock\n' >"${case_dir}/boot/vmlinuz-6.18.2"
  select_dkms_kernel 6.17.1 "${case_dir}/modules" "${case_dir}/boot"
  [[ ${DKMS_KERNEL} == 6.17.1 ]]
  select_dkms_kernel 6.16.0 "${case_dir}/modules" "${case_dir}/boot"
  [[ ${DKMS_KERNEL} == 6.18.2 ]]
)

test_dkms_kernel_selection_failure() {
  local case_dir=${TEST_ROOT}/dkms-kernels-empty rc=0
  install -d "${case_dir}/modules" "${case_dir}/boot"
  (
    load_helpers setup-fedora-workstation.sh
    if select_dkms_kernel 6.16.0 "${case_dir}/modules" "${case_dir}/boot"; then
      exit 90
    fi
    exit 91
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]]
}

test_r8152_kernel_cutoff() (
  load_helpers "$1"
  ! kernel_version_at_least 7.1.99-1-test 7.2
  kernel_version_at_least 7.2.0-0.rc1-test 7.2
  kernel_version_at_least 7.12.3-1-test 7.2
  kernel_version_at_least 8.0.0-1-test 7.2
)

test_fedora_r8152_dispatch() (
  load_helpers setup-fedora-workstation.sh
  local sysfs_root=${TEST_ROOT}/fedora-r8152-dispatch-sys
  local lookups=0 installs=0 purges=0
  install -d "${sysfs_root}"
  resolve_r8152_release() {
    lookups=$((lookups + 1))
    # The sourced dispatcher consumes both assignments in its status note.
    # shellcheck disable=SC2034
    R8152_TAG=9.8.7-6 R8152_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  }
  install_r8152_dkms() {
    [[ $1 == 7.1.9-200.fc44.x86_64 ]]
    installs=$((installs + 1))
  }
  purge_r8152_dkms() {
    purges=$((purges + 1))
    R8152_PURGE_CHANGED=0
    R8152_PURGE_MODULE_CHANGED=0
  }
  reconcile_r8152_initramfs() { R8152_INITRAMFS_REBUILT=0; }

  manage_r8152_driver 7.2.0-200.fc44.x86_64 "${sysfs_root}"
  manage_r8152_driver 8.0.1-1.fc45.x86_64 "${sysfs_root}"
  [[ ${lookups} == 0 && ${installs} == 0 && ${purges} == 2 ]]

  purges=0
  manage_r8152_driver 7.1.9-200.fc44.x86_64
  [[ ${lookups} == 1 && ${installs} == 1 && ${purges} == 0 ]]
)

test_fedora_r8152_loaded_module_taint() (
  load_helpers setup-fedora-workstation.sh
  local sysfs_root=${TEST_ROOT}/fedora-r8152-loaded-sys
  local warning='' purges=0 reconciles=0
  install -d "${sysfs_root}/module/r8152"
  printf 'OE\n' >"${sysfs_root}/module/r8152/taint"
  purge_r8152_dkms() {
    purges=$((purges + 1))
    R8152_PURGE_CHANGED=0
    R8152_PURGE_MODULE_CHANGED=0
  }
  reconcile_r8152_initramfs() {
    reconciles=$((reconciles + 1))
    R8152_INITRAMFS_REBUILT=0
  }
  resolve_r8152_release() { fail '7.2+ loaded-module check queried releases'; }
  warn() { warning=$*; }

  manage_r8152_driver 7.2.1-200.fc44.x86_64 "${sysfs_root}"
  [[ ${purges} == 1 && ${reconciles} == 1 \
     && ${R8152_PURGE_MODULE_CHANGED} == 0 \
     && ${R8152_INITRAMFS_REBUILT} == 0 \
     && ${R8152_LOADED_OUT_OF_TREE} == 1 \
     && ${R8152_PURGE_REBOOT_REQUIRED} == 1 ]]
  [[ ${warning} == *'loaded r8152 module is marked out-of-tree'* ]]

  printf 'E\n' >"${sysfs_root}/module/r8152/taint"
  warning=''
  R8152_LOADED_OUT_OF_TREE=0
  R8152_PURGE_REBOOT_REQUIRED=0
  manage_r8152_driver 7.2.1-200.fc44.x86_64 "${sysfs_root}"
  [[ ${purges} == 2 && ${reconciles} == 2 \
     && ${R8152_LOADED_OUT_OF_TREE} == 0 \
     && ${R8152_PURGE_REBOOT_REQUIRED} == 0 && -z ${warning} ]]
)

test_fedora_r8152_purge() (
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-purge
  local source_root=${case_dir}/usr-src
  local source=${source_root}/realtek-r8152-2.22.1
  local source_stage=${source_root}/.realtek-r8152-2.22.1.lan-ipxe-stage
  local retired=${source_root}/.r8152-2.21.4.lan-ipxe-retirement-v1
  local retirement_guard=${retired}.guard
  local unmanaged=${source_root}/r8152-9.9.9
  local rule=${case_dir}/50-usb-realtek-net.rules
  local marker=${case_dir}/rule-marker
  local state=present dkms_removes=0 rule_reloads=0
  install -d "${source}/udev/rules.d" "${unmanaged}" "${source_stage}" \
    "${retired}" "${retirement_guard}"
  printf '%s\n' \
    'PACKAGE_NAME="realtek-r8152"' \
    'PACKAGE_VERSION="2.22.1"' >"${source}/dkms.conf"
  printf 'setup-owned rule\n' >"${source}/udev/rules.d/50-usb-realtek-net.rules"
  cp -- "${source}/udev/rules.d/50-usb-realtek-net.rules" "${rule}"
  printf '%s\n' \
    'PACKAGE_NAME="some-other-module"' \
    'PACKAGE_VERSION="9.9.9"' >"${unmanaged}/dkms.conf"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    'transaction=r8152-source-install-v1' \
    'dkms-module=realtek-r8152' \
    'version=2.22.1' \
    'release-tag=2.22.1-1' \
    'source-commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'source-tree-sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
    >"${source_stage}/.lan-ipxe-transaction"
  printf 'interrupted pre-cutoff copy\n' >"${source_stage}/driver.c"
  printf 'partly deleted pre-cutoff retirement\n' >"${retired}/remnant.c"

  stat() {
    local path=${!#}
    case ${path} in
      *.lan-ipxe-retirement-v1.guard) printf '0:0:700\n'; return 0 ;;
      */.lan-ipxe-retirement-authorized) printf '0:0:644\n'; return 0 ;;
    esac
    if [[ ${path} == "${source_stage}" ]]; then
      printf '0:0:755\n'
    elif [[ ${path} == "${source_stage}/.lan-ipxe-transaction" ]]; then
      printf '0:0:644\n'
    else
      command stat "$@"
    fi
  }

  dkms() {
    [[ $1 == status ]] || return 64
    if [[ ${state} == present ]]; then
      printf '%s\n' \
        'realtek-r8152/2.22.1, 7.1.9-200.fc44.x86_64, x86_64: installed' \
        'realtek-r8152/2.22.1, 7.0.12-100.fc43.x86_64, x86_64: installed' \
        'unrelated/1.0, 7.1.9-200.fc44.x86_64, x86_64: installed'
    fi
  }
  sudo() {
    local last_arg src src_index
    case $1 in
      dkms)
        [[ $* == 'dkms remove -m realtek-r8152 -v 2.22.1 --all' ]]
        state=absent
        dkms_removes=$((dkms_removes + 1))
        ;;
      rm)
        shift
        command rm "$@"
        ;;
      mkdir)
        last_arg=${!#}
        command mkdir -m 0700 -- "${last_arg}"
        ;;
      install)
        last_arg=${!#}
        src_index=$(( $# - 1 ))
        src=${!src_index}
        command install -m 0644 -- "${src}" "${last_arg}"
        ;;
      mv)
        shift
        command mv "$@"
        ;;
      rmdir)
        shift
        command rmdir "$@"
        ;;
      udevadm)
        [[ $* == 'udevadm control --reload-rules' ]]
        rule_reloads=$((rule_reloads + 1))
        ;;
      *) return 65 ;;
    esac
  }

  purge_r8152_dkms "${source_root}" "${rule}" "${marker}"
  [[ ${dkms_removes} == 1 && ${rule_reloads} == 1 ]]
  [[ ! -e ${source} && ! -e ${source_stage} && ! -e ${retired} \
     && ! -e ${retirement_guard} && ! -e ${rule} \
     && -d ${unmanaged} ]]
  [[ ${R8152_PURGE_CHANGED} == 1 && ${R8152_PURGE_MODULE_CHANGED} == 1 ]]
  [[ ${R8152_PURGED_KERNELS[*]} == \
     '7.1.9-200.fc44.x86_64 7.0.12-100.fc43.x86_64' ]]

  sudo() { return 66; }
  purge_r8152_dkms "${source_root}" "${rule}" "${marker}"
  [[ ${R8152_PURGE_CHANGED} == 0 && ${R8152_PURGE_MODULE_CHANGED} == 0 ]]
  [[ -d ${unmanaged} ]]
)

test_fedora_r8152_marked_rule_purge() (
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-marked-rule
  local source_root=${case_dir}/usr-src
  local rule=${case_dir}/50-usb-realtek-net.rules
  local marker=${case_dir}/rule-marker
  local rule_sha reloads=0
  install -d "${source_root}"
  printf 'future setup-managed rule\n' >"${rule}"
  rule_sha=$(sha256sum -- "${rule}")
  rule_sha=${rule_sha%% *}
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "rule-sha256=${rule_sha}" >"${marker}"
  dkms() { [[ $1 == status ]]; }
  sudo() {
    case $1 in
      rm) shift; command rm "$@" ;;
      udevadm) reloads=$((reloads + 1)) ;;
      *) return 67 ;;
    esac
  }
  purge_r8152_dkms "${source_root}" "${rule}" "${marker}"
  [[ ! -e ${rule} && ! -e ${marker} && ${reloads} == 1 ]]
  [[ ${R8152_PURGE_CHANGED} == 1 && ${R8152_PURGE_MODULE_CHANGED} == 0 ]]
)

test_fedora_r8152_modified_rule_preserved() (
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-modified-rule
  local source_root=${case_dir}/usr-src
  local rule=${case_dir}/50-usb-realtek-net.rules
  local marker=${case_dir}/rule-marker
  local original_sha
  install -d "${source_root}"
  printf 'original managed rule\n' >"${rule}"
  original_sha=$(sha256sum -- "${rule}")
  original_sha=${original_sha%% *}
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "rule-sha256=${original_sha}" >"${marker}"
  printf 'locally customized rule\n' >"${rule}"
  dkms() { [[ $1 == status ]]; }
  sudo() { return 78; }
  purge_r8152_dkms "${source_root}" "${rule}" "${marker}"
  grep -Fxq 'locally customized rule' "${rule}"
  [[ -f ${marker} && ${R8152_PURGE_CHANGED} == 0 ]]
)

test_fedora_r8152_superseded_migration() (
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-migration
  local source_root=${case_dir}/usr-src
  local legacy_source=${source_root}/r8152-2.22.1
  local retirement=${source_root}/.r8152-2.22.1.lan-ipxe-retirement-v1
  local guard=${retirement}.guard
  local authorization=${legacy_source}/.lan-ipxe-retirement-authorized
  local legacy_present=1 removes=0
  install -d "${legacy_source}"
  printf '%s\n' \
    'PACKAGE_NAME="realtek-r8152"' \
    'PACKAGE_VERSION="2.22.1"' >"${legacy_source}/dkms.conf"
  stat() {
    local path=${!#}
    if [[ ${path} == "${guard}" ]]; then
      printf '0:0:700\n'
    elif [[ ${path} == "${authorization}" ]]; then
      printf '0:0:644\n'
    else
      command stat "$@"
    fi
  }
  dkms() {
    [[ $1 == status ]] || return 75
    printf 'realtek-r8152/2.22.1, 7.1.9-200.fc44.x86_64, x86_64: installed\n'
    if (( legacy_present )); then
      printf 'r8152/2.22.1, 7.1.9-200.fc44.x86_64, x86_64: installed\n'
    fi
  }
  sudo() {
    local last_arg src src_index
    case $1 in
      dkms)
        [[ $* == 'dkms remove -m r8152 -v 2.22.1 --all' ]]
        legacy_present=0
        removes=$((removes + 1))
        ;;
      rm) shift; command rm "$@" ;;
      mkdir)
        last_arg=${!#}
        command mkdir -m 0700 -- "${last_arg}"
        ;;
      install)
        last_arg=${!#}
        src_index=$(( $# - 1 ))
        src=${!src_index}
        command install -m 0644 -- "${src}" "${last_arg}"
        ;;
      mv) shift; command mv "$@" ;;
      rmdir) shift; command rmdir "$@" ;;
      *) return 76 ;;
    esac
  }
  remove_superseded_r8152_dkms realtek-r8152 2.22.1 "${source_root}"
  [[ ${removes} == 1 && ${R8152_SUPERSEDED_CHANGED} == 1 \
     && ! -e ${legacy_source} ]]

  sudo() { return 77; }
  remove_superseded_r8152_dkms realtek-r8152 2.22.1 "${source_root}"
  [[ ${R8152_SUPERSEDED_CHANGED} == 0 ]]
)

test_fedora_r8152_same_version_rollover() (
  local scenario=$1
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-rollover-${scenario}
  local source_root=${case_dir}/usr-src
  local source=${source_root}/realtek-r8152-2.22.1
  local source_stage=${source_root}/.realtek-r8152-2.22.1.lan-ipxe-stage
  local retirement=${source_root}/.realtek-r8152-2.22.1.lan-ipxe-retirement-v1
  local retirement_guard=${retirement}.guard
  local retirement_authorization=${source}/.lan-ipxe-retirement-authorized
  local staged=${case_dir}/staged WORK_DIR=${case_dir}/work
  local old_digest expected_digest replaced_kernels
  local mock_registered=0 removes=0 adds=0 source_removes=0
  local old_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local new_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  [[ ${scenario} == registered ]] && mock_registered=1
  install -d "${source}" "${staged}" "${WORK_DIR}"
  printf '%s\n' \
    'PACKAGE_NAME="realtek-r8152"' \
    'PACKAGE_VERSION="2.22.1"' >"${source}/dkms.conf"
  cp -- "${source}/dkms.conf" "${staged}/dkms.conf"
  printf 'old release source\n' >"${source}/driver.c"
  printf 'new release source\n' >"${staged}/driver.c"
  old_digest=$(r8152_source_tree_sha256 "${source}")
  expected_digest=$(r8152_source_tree_sha256 "${staged}")
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    'dkms-module=realtek-r8152' \
    'version=2.22.1' \
    'release-tag=2.22.1-1' \
    "source-commit=${old_commit}" \
    "source-tree-sha256=${old_digest}" \
    >"${source}/.lan-ipxe-managed"

  stat() {
    local path=${!#}
    if [[ ${path} == "${source_stage}" ]]; then
      printf '0:0:755\n'
    elif [[ ${path} == "${source_stage}/.lan-ipxe-transaction" ]]; then
      printf '0:0:644\n'
    elif [[ ${path} == "${retirement_guard}" ]]; then
      printf '0:0:700\n'
    elif [[ ${path} == "${retirement_authorization}" ]]; then
      printf '0:0:644\n'
    else
      command stat "$@"
    fi
  }

  dkms() {
    [[ $1 == status ]] || return 79
    if (( mock_registered )); then
      printf '%s\n' \
        'realtek-r8152/2.22.1, 7.1.9-200.fc44.x86_64, x86_64: installed' \
        'realtek-r8152/2.22.1, 7.0.12-100.fc43.x86_64, x86_64: installed'
    fi
  }
  sudo() {
    local last_arg src src_index
    case $1 in
      dkms)
        case $2 in
          remove)
            [[ ${scenario} == registered \
               && $* == 'dkms remove -m realtek-r8152 -v 2.22.1 --all' ]]
            grep -Fxq 'new release source' "${source_stage}/driver.c"
            mock_registered=0
            removes=$((removes + 1))
            ;;
          add)
            [[ $* == 'dkms add -m realtek-r8152 -v 2.22.1' ]]
            mock_registered=1
            adds=$((adds + 1))
            ;;
          *) return 80 ;;
        esac
        ;;
      rm)
        last_arg=${!#}
        shift
        command rm "$@"
        [[ ${last_arg} != "${retirement}" ]] \
          || source_removes=$((source_removes + 1))
        ;;
      install)
        last_arg=${!#}
        if [[ " $* " == *' -d '* ]]; then
          command install -d -- "${last_arg}"
        else
          src_index=$(( $# - 1 ))
          src=${!src_index}
          command install -m 0644 -- "${src}" "${last_arg}"
        fi
        ;;
      cp)
        shift
        command cp "$@"
        ;;
      chown) ;;
      mkdir)
        last_arg=${!#}
        command mkdir -m 0700 -- "${last_arg}"
        ;;
      mv)
        shift
        command mv "$@"
        ;;
      rmdir)
        shift
        command rmdir "$@"
        ;;
      *) return 81 ;;
    esac
  }
  put_file() {
    [[ $1 == -s ]]
    local src=$2 dst=$3
    PUT_FILE_CHANGED=0
    if [[ -f ${dst} ]] && cmp -s -- "${src}" "${dst}"; then
      return 0
    fi
    command install -D -m 0644 -- "${src}" "${dst}"
    PUT_FILE_CHANGED=1
  }

  ensure_r8152_source_registration realtek-r8152 2.22.1 "${staged}" \
    "${expected_digest}" 2.22.1-2 "${new_commit}" "${source_root}"
  [[ ${mock_registered} == 1 && ${adds} == 1 && ${source_removes} == 1 \
     && ${R8152_SOURCE_CHANGED} == 1 && ${R8152_SOURCE_REPLACED} == 1 ]]
  if [[ ${scenario} == registered ]]; then
    [[ ${removes} == 1 ]]
    replaced_kernels=${R8152_SOURCE_REPLACED_KERNELS[*]}
    [[ ${replaced_kernels} == \
       '7.1.9-200.fc44.x86_64 7.0.12-100.fc43.x86_64' ]]
  else
    [[ ${removes} == 0 ]]
  fi
  grep -Fxq 'new release source' "${source}/driver.c"
  grep -Fxq 'release-tag=2.22.1-2' "${source}/.lan-ipxe-managed"
  grep -Fxq "source-commit=${new_commit}" "${source}/.lan-ipxe-managed"
  grep -Fxq "source-tree-sha256=${expected_digest}" \
    "${source}/.lan-ipxe-managed"

  sudo() { return 82; }
  ensure_r8152_source_registration realtek-r8152 2.22.1 "${staged}" \
    "${expected_digest}" 2.22.1-2 "${new_commit}" "${source_root}"
  [[ ${R8152_SOURCE_CHANGED} == 0 && ${R8152_SOURCE_REPLACED} == 0 \
     && ${adds} == 1 && ${source_removes} == 1 ]]
)

test_fedora_r8152_interrupted_copy_recovery() (
  local scenario=$1
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-copy-recovery-${scenario}
  local source_root=${case_dir}/usr-src
  local source=${source_root}/realtek-r8152-2.22.1
  local source_stage=${source_root}/.realtek-r8152-2.22.1.lan-ipxe-stage
  local transaction_marker=${source_stage}/.lan-ipxe-transaction
  local staged=${case_dir}/staged WORK_DIR=${case_dir}/work
  local expected_digest mock_registered=0 adds=0 stage_cleanups=0 moves=0
  local current_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  install -d "${source_root}" "${staged}" "${WORK_DIR}" "${source_stage}"
  printf '%s\n' \
    'PACKAGE_NAME="realtek-r8152"' \
    'PACKAGE_VERSION="2.22.1"' >"${staged}/dkms.conf"
  printf 'complete current source\n' >"${staged}/driver.c"
  expected_digest=$(r8152_source_tree_sha256 "${staged}")

  case ${scenario} in
    empty) ;;
    partial)
      printf '%s\n' \
        'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
        'transaction=r8152-source-install-v1' \
        'dkms-module=realtek-r8152' \
        'version=2.22.1' \
        'release-tag=2.22.1-2' \
        "source-commit=${current_commit}" \
        "source-tree-sha256=${expected_digest}" \
        >"${transaction_marker}"
      printf 'partial copy\n' >"${source_stage}/driver.c"
      ;;
    old-release)
      printf '%s\n' \
        'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
        'transaction=r8152-source-install-v1' \
        'dkms-module=realtek-r8152' \
        'version=2.22.1' \
        'release-tag=2.22.1-1' \
        'source-commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'source-tree-sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        >"${transaction_marker}"
      printf 'partial old-release copy\n' >"${source_stage}/driver.c"
      ;;
    *) fail "unknown interrupted-copy scenario: ${scenario}" ;;
  esac

  stat() {
    local path=${!#}
    if [[ ${path} == "${source_stage}" ]]; then
      printf '0:0:755\n'
    elif [[ ${path} == "${transaction_marker}" ]]; then
      printf '0:0:644\n'
    else
      command stat "$@"
    fi
  }
  dkms() {
    [[ $1 == status ]] || return 83
    (( mock_registered )) \
      && printf 'realtek-r8152/2.22.1: added\n'
    return 0
  }
  sudo() {
    local last_arg src src_index
    case $1 in
      dkms)
        [[ $* == 'dkms add -m realtek-r8152 -v 2.22.1' ]]
        mock_registered=1
        adds=$((adds + 1))
        ;;
      rm)
        last_arg=${!#}
        shift
        command rm "$@"
        [[ ${last_arg} != "${source_stage}" ]] \
          || stage_cleanups=$((stage_cleanups + 1))
        ;;
      rmdir)
        last_arg=${!#}
        shift
        command rmdir "$@"
        [[ ${last_arg} != "${source_stage}" ]] \
          || stage_cleanups=$((stage_cleanups + 1))
        ;;
      install)
        last_arg=${!#}
        if [[ " $* " == *' -d '* ]]; then
          command install -d -- "${last_arg}"
        else
          src_index=$(( $# - 1 ))
          src=${!src_index}
          command install -m 0644 -- "${src}" "${last_arg}"
        fi
        ;;
      cp)
        shift
        command cp "$@"
        ;;
      chown) ;;
      mv)
        shift
        command mv "$@"
        moves=$((moves + 1))
        ;;
      *) return 84 ;;
    esac
  }
  put_file() {
    [[ $1 == -s ]]
    local src=$2 dst=$3
    cmp -s -- "${src}" "${dst}" || command install -m 0644 -- "${src}" "${dst}"
  }

  ensure_r8152_source_registration realtek-r8152 2.22.1 "${staged}" \
    "${expected_digest}" 2.22.1-2 "${current_commit}" "${source_root}"
  [[ ${stage_cleanups} == 1 && ${moves} == 1 && ${adds} == 1 \
     && ${mock_registered} == 1 && -d ${source} && ! -e ${source_stage} ]]
  grep -Fxq 'complete current source' "${source}/driver.c"
  grep -Fxq "source-tree-sha256=${expected_digest}" \
    "${source}/.lan-ipxe-managed"
  [[ ! -e ${source}/.lan-ipxe-transaction \
     && ! -L ${source}/.lan-ipxe-transaction ]]

  sudo() { return 85; }
  ensure_r8152_source_registration realtek-r8152 2.22.1 "${staged}" \
    "${expected_digest}" 2.22.1-2 "${current_commit}" "${source_root}"
  [[ ${R8152_SOURCE_CHANGED} == 0 && ${adds} == 1 && ${moves} == 1 \
     && ${stage_cleanups} == 1 ]]
)

test_fedora_r8152_unverified_copy_stage_rejected() {
  local case_dir=${TEST_ROOT}/fedora-r8152-unverified-copy-stage rc=0
  (
    load_helpers setup-fedora-workstation.sh
    local source_root=${case_dir}/usr-src
    local source_stage=${source_root}/.realtek-r8152-2.22.1.lan-ipxe-stage
    local staged=${case_dir}/staged WORK_DIR=${case_dir}/work expected_digest
    install -d "${source_stage}" "${staged}" "${WORK_DIR}"
    printf '%s\n' \
      'PACKAGE_NAME="realtek-r8152"' \
      'PACKAGE_VERSION="2.22.1"' >"${staged}/dkms.conf"
    printf 'complete current source\n' >"${staged}/driver.c"
    printf 'unowned partial content\n' >"${source_stage}/driver.c"
    expected_digest=$(r8152_source_tree_sha256 "${staged}")
    stat() {
      local path=${!#}
      [[ ${path} == "${source_stage}" ]] \
        && { printf '0:0:755\n'; return 0; }
      command stat "$@"
    }
    sudo() { fail 'unverified r8152 copy stage authorized a mutation'; }
    ensure_r8152_source_registration realtek-r8152 2.22.1 "${staged}" \
      "${expected_digest}" 2.22.1-2 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      "${source_root}"
  ) >"${case_dir}.stdout" 2>"${case_dir}.stderr" || rc=$?
  [[ ${rc} == 1 ]] || fail 'unverified r8152 copy stage was accepted'
  grep -Fxq 'unowned partial content' \
    "${case_dir}/usr-src/.realtek-r8152-2.22.1.lan-ipxe-stage/driver.c" \
    || fail 'unverified r8152 copy stage was not preserved'
}

test_fedora_r8152_upstream_retirement_marker_rejected() {
  local case_dir=${TEST_ROOT}/fedora-r8152-upstream-retirement-marker rc=0
  (
    load_helpers setup-fedora-workstation.sh
    local source_root=${case_dir}/usr-src
    local staged=${case_dir}/staged WORK_DIR=${case_dir}/work expected_digest
    install -d "${source_root}" "${staged}" "${WORK_DIR}"
    printf '%s\n' \
      'PACKAGE_NAME="realtek-r8152"' \
      'PACKAGE_VERSION="2.22.1"' >"${staged}/dkms.conf"
    printf 'upstream collision\n' >"${staged}/.lan-ipxe-retirement-authorized"
    expected_digest=$(r8152_source_tree_sha256 "${staged}")
    dkms() { fail 'retirement-marker collision reached DKMS inspection'; }
    sudo() { fail 'retirement-marker collision authorized a mutation'; }
    ensure_r8152_source_registration realtek-r8152 2.22.1 "${staged}" \
      "${expected_digest}" 2.22.1-2 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      "${source_root}"
  ) >"${case_dir}.stdout" 2>"${case_dir}.stderr" || rc=$?
  [[ ${rc} == 1 ]] || fail 'upstream retirement marker was accepted'
}

test_fedora_r8152_interrupted_retirement_recovery() (
  local scenario=$1
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-retirement-${scenario}
  local source_root=${case_dir}/usr-src
  local source=${source_root}/realtek-r8152-2.22.1
  local retirement=${source_root}/.realtek-r8152-2.22.1.lan-ipxe-retirement-v1
  local guard=${retirement}.guard
  local authorization=${source}/.lan-ipxe-retirement-authorized
  local cleanup_calls=0 moves=0 source_digest
  install -d "${source_root}" "${guard}"
  case ${scenario} in
    pending-final)
      install -d "${source}"
      printf 'unregistered source awaiting retirement\n' >"${source}/partial.c"
      source_digest=$(r8152_source_tree_sha256 "${source}")
      printf '%s\n' \
        'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
        'transaction=r8152-source-retirement-v1' \
        'dkms-module=realtek-r8152' \
        'version=2.22.1' \
        "source-tree-sha256=${source_digest}" \
        >"${authorization}"
      ;;
    partial-retired)
      install -d "${retirement}"
      printf 'partly deleted retired source\n' >"${retirement}/remnant.c"
      ;;
    *) fail "unknown retirement recovery scenario: ${scenario}" ;;
  esac
  stat() {
    local path=${!#}
    [[ ${path} == "${guard}" ]] \
      && { printf '0:0:700\n'; return 0; }
    [[ ${path} == "${authorization}" ]] \
      && { printf '0:0:644\n'; return 0; }
    command stat "$@"
  }
  sudo() {
    case $1 in
      mv)
        shift
        command mv "$@"
        moves=$((moves + 1))
        ;;
      rm)
        shift
        command rm "$@"
        cleanup_calls=$((cleanup_calls + 1))
        ;;
      rmdir)
        shift
        command rmdir "$@"
        ;;
      *) return 86 ;;
    esac
  }

  recover_r8152_source_retirement "${source}" realtek-r8152 2.22.1 0
  [[ ${R8152_RETIREMENT_RECOVERED} == 1 && ${cleanup_calls} == 1 \
     && ! -e ${source} && ! -e ${retirement} && ! -e ${guard} ]]
  if [[ ${scenario} == pending-final ]]; then
    [[ ${moves} == 1 ]]
  else
    [[ ${moves} == 0 ]]
  fi

  sudo() { return 87; }
  recover_r8152_source_retirement "${source}" realtek-r8152 2.22.1 0
  [[ ${R8152_RETIREMENT_RECOVERED} == 0 && ${cleanup_calls} == 1 ]]
  grep -Fq 'if (( R8152_SOURCE_REPLACED )); then' \
    "${REPO_ROOT}/setup-fedora-workstation.sh"
  grep -Fq 'for kernel_tree in /usr/lib/modules/*; do' \
    "${REPO_ROOT}/setup-fedora-workstation.sh"
)

test_fedora_r8152_invalid_marker_rejected() {
  local case_dir=${TEST_ROOT}/fedora-r8152-invalid-marker rc=0
  (
    load_helpers setup-fedora-workstation.sh
    local source_root=${case_dir}/usr-src
    local source=${source_root}/realtek-r8152-2.22.1
    local staged=${case_dir}/staged WORK_DIR=${case_dir}/work expected_digest
    install -d "${source}" "${staged}" "${WORK_DIR}"
    printf '%s\n' \
      'PACKAGE_NAME="realtek-r8152"' \
      'PACKAGE_VERSION="2.22.1"' >"${source}/dkms.conf"
    cp -- "${source}/dkms.conf" "${staged}/dkms.conf"
    printf 'administrator source\n' >"${source}/driver.c"
    printf 'new release source\n' >"${staged}/driver.c"
    printf '%s\n' \
      'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
      'dkms-module=unexpected-module' >"${source}/.lan-ipxe-managed"
    expected_digest=$(r8152_source_tree_sha256 "${staged}")
    dkms() { [[ $1 == status ]]; }
    sudo() { fail 'invalid r8152 marker authorized a source-tree mutation'; }
    ensure_r8152_source_registration realtek-r8152 2.22.1 "${staged}" \
      "${expected_digest}" 2.22.1-2 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      "${source_root}"
  ) >"${case_dir}.stdout" 2>"${case_dir}.stderr" || rc=$?
  [[ ${rc} == 1 ]] || fail 'invalid r8152 ownership marker was accepted'
  grep -Fxq 'administrator source' \
    "${case_dir}/usr-src/realtek-r8152-2.22.1/driver.c" \
    || fail 'invalid r8152 ownership marker did not preserve the source tree'
}

test_fedora_r8152_regenerate_all() (
  load_helpers setup-fedora-workstation.sh
  local case_dir=${TEST_ROOT}/fedora-r8152-initramfs
  local modules_root=${case_dir}/modules boot_root=${case_dir}/boot
  local inspect_log=${case_dir}/inspect.log
  local dracut_calls=0 kernel inspected_kernel mode=clean
  R8152_PURGED_KERNELS=(7.1.9-200.fc44.x86_64 7.0.12-100.fc43.x86_64)
  install -d "${boot_root}"
  for kernel in "${R8152_PURGED_KERNELS[@]}"; do
    install -d "${modules_root}/${kernel}"
    printf 'image\n' >"${boot_root}/initramfs-${kernel}.img"
    printf 'kernel\n' >"${boot_root}/vmlinuz-${kernel}"
  done
  sudo() {
    case $1 in
      dracut)
        [[ $* == 'dracut --force --regenerate-all' ]]
        dracut_calls=$((dracut_calls + 1))
        ;;
      test)
        shift
        command test "$@"
        ;;
      lsinitrd)
        printf '%s\n' "$2" >>"${inspect_log}"
        inspected_kernel=${2#${boot_root}/initramfs-}
        inspected_kernel=${inspected_kernel%.img}
        if [[ ${mode} == external && ${dracut_calls} == 0 ]]; then
          printf 'usr/lib/modules/%s/weak-updates/r8152.ko.zst\n' \
            "${inspected_kernel}"
        else
          printf 'usr/lib/modules/%s/kernel/drivers/net/usb/r8152.ko.zst\n' \
            "${inspected_kernel}"
        fi
        ;;
      *) return 68 ;;
    esac
  }
  R8152_PURGE_MODULE_CHANGED=1
  reconcile_r8152_initramfs "${modules_root}" "${boot_root}"
  [[ ${dracut_calls} == 1 && ${R8152_INITRAMFS_REBUILT} == 1 \
     && $(wc -l <"${inspect_log}") == 4 ]]
  grep -Fqx "${boot_root}/initramfs-7.1.9-200.fc44.x86_64.img" "${inspect_log}"
  grep -Fqx "${boot_root}/initramfs-7.0.12-100.fc43.x86_64.img" "${inspect_log}"

  # A stale weak-updates copy must independently trigger regeneration even
  # when no DKMS registration remains to report the affected kernel.
  : >"${inspect_log}"
  dracut_calls=0
  mode=external
  R8152_PURGE_MODULE_CHANGED=0
  reconcile_r8152_initramfs "${modules_root}" "${boot_root}"
  [[ ${dracut_calls} == 1 && ${R8152_INITRAMFS_REBUILT} == 1 \
     && $(wc -l <"${inspect_log}") == 4 ]]
)

test_arch_r8152_catalog() (
  load_helpers setup-arch-workstation.sh
  local package count=0
  pacman() { return 69; }
  sudo() { return 70; }
  dkms() { return 71; }
  configure_r8152_arch 7.1.9-arch1-1
  configure_r8152_arch 7.1.9-arch1-1
  for package in "${PKGS_AUR[@]}"; do
    [[ ${package} == r8152-dkms ]] && count=$((count + 1))
  done
  [[ ${count} == 1 && ${R8152_USE_IN_TREE} == 0 ]]
)

test_arch_r8152_purge() (
  load_helpers setup-arch-workstation.sh
  local installed=1 registration=1 package_removes=0 dkms_removes=0 package
  pacman() {
    [[ $1 == -Q && $2 == r8152-dkms ]] || return 72
    (( installed ))
  }
  dkms() {
    [[ $1 == status ]] || return 73
    (( registration )) \
      && printf 'r8152/2.21.4, 7.2.1-arch1-1, x86_64: installed\n'
    return 0
  }
  sudo() {
    case $1 in
      pacman)
        [[ $* == 'pacman -Rns --noconfirm r8152-dkms' ]]
        installed=0
        package_removes=$((package_removes + 1))
        ;;
      dkms)
        [[ $* == 'dkms remove -m r8152 -v 2.21.4 --all' ]]
        registration=0
        dkms_removes=$((dkms_removes + 1))
        ;;
      *) return 74 ;;
    esac
  }

  configure_r8152_arch 7.2.1-arch1-1
  [[ ${package_removes} == 1 && ${dkms_removes} == 1 ]]
  [[ ${R8152_ARCH_PURGE_CHANGED} == 1 && ${R8152_USE_IN_TREE} == 1 \
     && ${R8152_ARCH_REBOOT_REQUIRED} == 1 ]]
  for package in "${PKGS_AUR[@]}"; do
    [[ ${package} != r8152-dkms ]]
  done

  configure_r8152_arch 8.0.0-arch1-1
  [[ ${package_removes} == 1 && ${dkms_removes} == 1 \
     && ${R8152_ARCH_PURGE_CHANGED} == 0 ]]
)

test_arch_r8152_initramfs_detection() (
  load_helpers setup-arch-workstation.sh
  local mode=external
  sudo() {
    [[ $1 == lsinitrd ]]
    if [[ ${mode} == external ]]; then
      printf 'usr/lib/modules/7.2.1-arch1-1/updates/dkms/r8152.ko.zst\n'
    else
      printf 'usr/lib/modules/7.2.1-arch1-1/kernel/drivers/net/usb/r8152.ko.zst\n'
    fi
  }
  initramfs_has_out_of_tree_r8152 /tmp/mock.img 7.2.1-arch1-1
  mode=in-tree
  ! initramfs_has_out_of_tree_r8152 /tmp/mock.img 7.2.1-arch1-1
  grep -Fq 'DRACUT_REBUILD=${R8152_ARCH_PURGE_CHANGED}' \
    "${REPO_ROOT}/setup-arch-workstation.sh"
)

test_arch_r8152_loaded_module_detection() (
  load_helpers setup-arch-workstation.sh
  local case_dir=${TEST_ROOT}/arch-r8152-loaded-module
  local taint_file=${case_dir}/taint
  install -d "${case_dir}"

  ! r8152_loaded_out_of_tree "${taint_file}"
  printf 'P\n' >"${taint_file}"
  ! r8152_loaded_out_of_tree "${taint_file}"
  printf 'OE\n' >"${taint_file}"
  r8152_loaded_out_of_tree "${taint_file}"

  # Package, DKMS, and initramfs state can already be clean on a second run
  # while the module loaded before the first run remains active until reboot.
  # The dynamically sourced helper consumes this override.
  # shellcheck disable=SC2034
  R8152_MODULE_TAINT_FILE=${taint_file}
  pacman() { return 72; }
  dkms() { [[ $1 == status ]]; }
  sudo() { return 73; }
  configure_r8152_arch 7.2.1-arch1-1
  [[ ${R8152_ARCH_PURGE_CHANGED} == 0 && ${R8152_USE_IN_TREE} == 1 \
     && ${R8152_ARCH_REBOOT_REQUIRED} == 1 ]]

  printf 'P\n' >"${taint_file}"
  R8152_ARCH_REBOOT_REQUIRED=0
  configure_r8152_arch 8.0.0-arch1-1
  [[ ${R8152_ARCH_PURGE_CHANGED} == 0 \
     && ${R8152_ARCH_REBOOT_REQUIRED} == 0 ]]
)

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
test_fedora_inventory_failures dnf
printf 'PASS DNF group-query failure propagation\n'
test_fedora_inventory_failures flatpak
printf 'PASS Flatpak inventory failure propagation\n'
test_dkms_kernel_selection
printf 'PASS Fedora DKMS running/newest kernel selection\n'
test_dkms_kernel_selection_failure
printf 'PASS Fedora DKMS missing-header failure propagation\n'
for script in setup-arch-workstation.sh setup-fedora-workstation.sh; do
  test_r8152_kernel_cutoff "${script}"
done
printf 'PASS Arch/Fedora r8152 numeric 7.2 kernel cutoff\n'
test_fedora_r8152_dispatch
printf 'PASS Fedora r8152 cutoff dispatch skips release lookup\n'
test_fedora_r8152_loaded_module_taint
printf 'PASS Fedora loaded out-of-tree r8152 reboot detection\n'
test_fedora_r8152_purge
printf 'PASS Fedora bounded r8152 DKMS/source/rule purge convergence\n'
test_fedora_r8152_marked_rule_purge
printf 'PASS Fedora marked r8152 udev-rule purge\n'
test_fedora_r8152_modified_rule_preserved
printf 'PASS Fedora modified/unmanaged r8152 udev-rule preservation\n'
test_fedora_r8152_superseded_migration
printf 'PASS Fedora superseded/legacy r8152 registration migration\n'
test_fedora_r8152_same_version_rollover registered
printf 'PASS Fedora same-version r8152 release-commit replacement convergence\n'
test_fedora_r8152_same_version_rollover interrupted
printf 'PASS Fedora interrupted marked-source r8152 recovery convergence\n'
for scenario in empty partial old-release; do
  test_fedora_r8152_interrupted_copy_recovery "${scenario}"
done
printf 'PASS Fedora interrupted r8152 source-copy transaction recovery\n'
test_fedora_r8152_unverified_copy_stage_rejected
printf 'PASS Fedora unverified r8152 source-copy staging preservation\n'
test_fedora_r8152_upstream_retirement_marker_rejected
printf 'PASS Fedora upstream r8152 retirement-marker collision rejection\n'
for scenario in pending-final partial-retired; do
  test_fedora_r8152_interrupted_retirement_recovery "${scenario}"
done
printf 'PASS Fedora interrupted r8152 source-retirement recovery\n'
test_fedora_r8152_invalid_marker_rejected
printf 'PASS Fedora invalid r8152 ownership-marker rejection\n'
test_fedora_r8152_regenerate_all
printf 'PASS Fedora all-kernel r8152 initramfs regeneration/validation\n'
test_arch_r8152_catalog
printf 'PASS Arch pre-7.2 r8152 desired-catalog convergence\n'
test_arch_r8152_purge
printf 'PASS Arch 7.2+ r8152 package/DKMS purge convergence\n'
test_arch_r8152_initramfs_detection
printf 'PASS Arch r8152 purge-driven initramfs regeneration/detection\n'
test_arch_r8152_loaded_module_detection
printf 'PASS Arch loaded out-of-tree r8152 reboot detection\n'
