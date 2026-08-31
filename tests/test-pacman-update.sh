#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UPDATE_SCRIPT=${REPO_ROOT}/files/etc/cron.daily/pacman-update

run_case() {
  local name=$1 remove_running=$2 running_kver=$3 running_pkgbase=$4
  local replacements=$5 image_kver=$6 expected_reboot_kver=$7
  local fixture spec kver pkgbase has_dep rc=0 transformed
  fixture=$(mktemp -d "/tmp/pacman-update-${name}.XXXXXX")
  install -d "${fixture}/modules/${running_kver}" "${fixture}/boot" \
    "${fixture}/log"
  printf '%s\n' "${running_pkgbase}" >"${fixture}/modules/${running_kver}/pkgbase"
  printf 'mock\n' >"${fixture}/modules/${running_kver}/modules.dep"
  for spec in ${replacements}; do
    IFS=: read -r kver pkgbase has_dep <<<"${spec}"
    install -d "${fixture}/modules/${kver}"
    printf '%s\n' "${pkgbase}" >"${fixture}/modules/${kver}/pkgbase"
    if [[ ${has_dep} == yes ]]; then
      printf 'mock\n' >"${fixture}/modules/${kver}/modules.dep"
    fi
  done
  printf 'mock initramfs\n' >"${fixture}/boot/initramfs-${running_pkgbase}.img"
  : >"${fixture}/events"

  # Redirect only the three absolute state paths into the fixture. The update
  # and reboot-selection logic itself is sourced unchanged.
  transformed=$(sed \
    -e "s|/usr/lib/modules|${fixture}/modules|g" \
    -e "s|/boot|${fixture}/boot|g" \
    -e "s|/var/log/pacman-update.log|${fixture}/log/pacman-update.log|g" \
    "${UPDATE_SCRIPT}")

  (
    export MOCK_RUNNING_KVER=${running_kver}
    export MOCK_RUNNING_PKGBASE=${running_pkgbase}
    export MOCK_REMOVE_RUNNING=${remove_running}
    export MOCK_IMAGE_KVER=${image_kver}
    export MOCK_EVENTS=${fixture}/events
    export MOCK_MODULES_DIR=${fixture}/modules
    uname() {
      [[ ${1:-} == -r ]] || return 2
      printf '%s\n' "${MOCK_RUNNING_KVER}"
    }
    pacman() {
      case ${1:-} in
        -Syu)
          if [[ ${MOCK_REMOVE_RUNNING} == 1 ]]; then
            mv "${MOCK_MODULES_DIR}/${MOCK_RUNNING_KVER}" \
              "${MOCK_MODULES_DIR}/.removed-${MOCK_RUNNING_KVER}"
          elif [[ ${MOCK_REMOVE_RUNNING} == 2 ]]; then
            mv "${MOCK_MODULES_DIR}/${MOCK_RUNNING_KVER}/pkgbase" \
              "${MOCK_MODULES_DIR}/${MOCK_RUNNING_KVER}/.removed-pkgbase"
          fi
          ;;
        -Qoq)
          [[ -r ${2:-} ]] || return 1
          printf '%s\n' "${MOCK_RUNNING_PKGBASE}"
          ;;
        *) return 2 ;;
      esac
    }
    paccache() { [[ ${1:-} == -r ]]; }
    logger() { :; }
    hostname() { printf 'mock-host\n'; }
    date() { printf '2026-08-31T15:30:00-0400\n'; }
    lsinitrd() {
      printf 'usr/lib/modules/%s/kernel/mock.ko\n' "${MOCK_IMAGE_KVER}"
    }
    wall() { printf 'wall|%s\n' "$*" >>"${MOCK_EVENTS}"; }
    systemd-run() { printf 'systemd-run|%s\n' "$*" >>"${MOCK_EVENTS}"; }
    eval "${transformed}"
  ) || rc=$?
  [[ ${rc} == 0 ]]

  if [[ -n ${expected_reboot_kver} ]]; then
    grep -Fq 'systemd-run|--on-active=30m systemctl reboot -i' "${fixture}/events"
    grep -Fq "${expected_reboot_kver}" "${fixture}/events"
  else
    [[ ! -s ${fixture}/events ]]
  fi
  printf 'PASS %-16s reboot=%s\n' "${name}" "${expected_reboot_kver:-no}"
}

run_case unchanged 0 6.17.1-arch1-1 linux '' 6.17.1-arch1-1 ''
run_case upgraded 1 6.17.1-arch1-1 linux \
  '6.18.2-arch1-1:linux:yes' 6.18.2-arch1-1 6.18.2-arch1-1
run_case leftover_dir 2 6.17.1-arch1-1 linux \
  '6.18.2-arch1-1:linux:yes' 6.18.2-arch1-1 6.18.2-arch1-1
run_case same_flavor 1 6.12.40-1-lts linux-lts \
  '6.19.1-arch1-1:linux:yes 6.12.41-1-lts:linux-lts:yes' \
  6.12.41-1-lts 6.12.41-1-lts
run_case wrong_image 1 6.17.1-arch1-1 linux \
  '6.18.2-arch1-1:linux:yes' 6.17.1-arch1-1 ''
run_case missing_modules 1 6.17.1-arch1-1 linux \
  '6.18.2-arch1-1:linux:no' 6.18.2-arch1-1 ''
run_case wrong_flavor_only 1 6.12.40-1-lts linux-lts \
  '6.19.1-arch1-1:linux:yes' 6.19.1-arch1-1 ''
