#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GENERATOR=${GENERATOR:-/usr/lib/systemd/system-generators/zram-generator}
[[ -x ${GENERATOR} ]] \
  || { printf 'zram-generator not installed at %s\n' "${GENERATOR}" >&2; exit 1; }

run_case() {
  local memory_kib=$1 expected_mib=$2 fixture output
  fixture=$(mktemp -d "/tmp/workstation-zram-${memory_kib}.XXXXXX")
  install -d "${fixture}/etc/systemd" "${fixture}/proc" "${fixture}/generated"
  install -m 0644 "${REPO_ROOT}/files/etc/systemd/zram-generator.conf" \
    "${fixture}/etc/systemd/zram-generator.conf"
  grep -Fxq 'compression-algorithm = zstd' \
    "${fixture}/etc/systemd/zram-generator.conf"
  printf 'MemTotal:       %s kB\n' "${memory_kib}" >"${fixture}/proc/meminfo"
  printf '\n' >"${fixture}/proc/cmdline"

  output=$(ZRAM_GENERATOR_ROOT="${fixture}" "${GENERATOR}" \
    "${fixture}/generated" "${fixture}/generated" "${fixture}/generated" 2>&1)
  [[ -f ${fixture}/generated/dev-zram0.swap ]]
  grep -Fq 'Priority=100' "${fixture}/generated/dev-zram0.swap"
  grep -Eq "(^|[^0-9])${expected_mib}([[:space:]]*M(B|iB)?|[^0-9])" <<<"${output}"
  printf 'PASS MemTotal=%sKiB produces zram0=%sMiB\n' "${memory_kib}" "${expected_mib}"
}

run_case 2097152 2048
run_case 33554432 8192
