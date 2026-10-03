#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/antigravity-migration.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'ASSERT: %s\n' "$*" >&2
  exit 1
}

load_helpers() {
  local script=$1
  set --
  # Permit loading Fedora's platform-independent declarations on Ubuntu CI.
  rpm() {
    [[ ${1:-} == -E && ${2:-} == %fedora ]] || return 1
    printf '44\n'
  }
  # Every helper is declared before this marker in both Linux setup scripts.
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${REPO_ROOT}/${script}")
}

array_contains() {
  local wanted=$1 item
  shift
  for item in "$@"; do
    [[ ${item} == "${wanted}" ]] && return 0
  done
  return 1
}

select_fedora_artifacts() {
  # ARCH is consumed by the dynamically sourced production case statement.
  # shellcheck disable=SC2034
  ARCH=$1
  # Evaluate only the architecture-to-artifact mapping, not preflight or any
  # workstation mutation. This makes both supported branches testable on CI.
  [[ $(command grep -Fxc 'case ${ARCH} in' \
      "${REPO_ROOT}/setup-fedora-workstation.sh") == 1 ]] \
    || fail 'Fedora architecture-to-artifact mapping marker is missing or ambiguous'
  # shellcheck disable=SC1090
  source <(sed -n '/^case ${ARCH} in$/,/^esac$/p' \
    "${REPO_ROOT}/setup-fedora-workstation.sh")
}

test_arch_catalog() (
  load_helpers setup-arch-workstation.sh
  local package
  # Antigravity, its CLI, Claude Code and Codex now come from self-updating
  # native installs, not root-owned pacman/AUR builds.
  for package in "${RETIRED_AI_PKGS[@]}" antigravity-ide; do
    ! array_contains "${package}" "${PKGS_OFFICIAL[@]}" "${PKGS_AUR[@]}" \
      || fail "Arch still requests ${package} as a package"
  done
  for package in antigravity antigravity-cli claude-code openai-codex; do
    array_contains "${package}" "${RETIRED_AI_PKGS[@]}" \
      || fail "Arch does not retire the ${package} package"
  done
  for package in fuse2 jq tmux; do
    array_contains "${package}" "${PKGS_OFFICIAL[@]}" \
      || fail "Arch official package set omits ${package}"
  done
  [[ ${ANTIGRAVITY_DESKTOP_MANIFEST_URL} == https://*/latest-x64-linux.yml \
     && ${ANTIGRAVITY_CLI_MANIFEST_URL} == https://*/linux_amd64.json ]] \
    || fail 'Arch Antigravity manifests are not the x86_64 Linux vendor feeds'
  [[ ${CLAUDE_INSTALLER_URL} == https://claude.ai/install.sh \
     && ${CODEX_INSTALLER_URL} == https://chatgpt.com/codex/install.sh ]] \
    || fail 'Arch Claude/Codex do not use the official native installers'
  grep -Fq 'managed-by=lan-ipxe/setup-arch-workstation.sh' \
    <(declare -f install_antigravity_desktop install_antigravity_cli | tr -d "'") \
    || fail 'Arch native installs do not write Arch-owned release markers'
)

test_arch_developer_catalog() (
  load_helpers setup-arch-workstation.sh
  local package
  for package in code opencode zed; do
    array_contains "${package}" "${PKGS_OFFICIAL[@]}" \
      || fail "Arch official package set omits ${package}"
  done
  ! array_contains vscodium-bin "${PKGS_OFFICIAL[@]}" \
    || fail 'Arch official package set still requests VSCodium'
  ! array_contains vscodium-bin "${PKGS_AUR[@]}" \
    || fail 'Arch AUR set still requests VSCodium'
  grep -Fq 'for command_name in claude code codex opencode zed' \
    "${REPO_ROOT}/setup-arch-workstation.sh" \
    || fail 'Arch does not enforce all requested developer-command postconditions'
)

test_arch_native_flow_order() (
  local script=${REPO_ROOT}/setup-arch-workstation.sh
  # The AUR antigravity package owns /opt/Antigravity, so it goes first; the
  # CLI packages go only once their native successors are installed; all of
  # it runs before the AUR phase drops cached sudo credentials.
  awk '
    $0 == "remove_retired_ai_pkgs_arch antigravity" { pkg = NR }
    $0 ~ /^ *install_antigravity_desktop$/ { desktop = NR }
    $0 ~ /^ *install_claude_cli$/ { claude = NR }
    $0 ~ /^ *install_codex_cli$/ { codex = NR }
    $0 == "remove_retired_ai_pkgs_arch antigravity-cli claude-code openai-codex" { cli = NR }
    $0 == "sudo -k" { aur = NR }
    END { exit !(pkg && pkg < desktop && desktop < cli && claude < cli && codex < cli && cli < aur) }
  ' "${script}" || fail 'Arch native-tool migration steps run in an unsafe order'
)

test_arch_retired_package_removal() (
  load_helpers setup-arch-workstation.sh
  local -A pkg_state=([claude-code]=1 [openai-codex]=1)
  local removals=0
  pacman() {
    [[ $1 == -Q ]] || return 97
    [[ -n ${pkg_state[$2]:-} ]]
  }
  sudo() {
    [[ $* == 'pacman -Rns --noconfirm claude-code openai-codex' ]] \
      || fail "unexpected retired-package removal: $*"
    (( removals += 1 ))
    pkg_state=()
  }
  remove_retired_ai_pkgs_arch antigravity-cli claude-code openai-codex
  remove_retired_ai_pkgs_arch antigravity-cli claude-code openai-codex
  (( removals == 1 )) || fail 'retired Arch packages were not removed exactly once'
)

test_arch_yay_devel_updates() (
  load_helpers setup-arch-workstation.sh
  local guard_line init_line update_line
  array_contains sit-git "${PKGS_AUR[@]}" \
    || fail 'Arch AUR set has no VCS/devel package exercising Yay tracking'
  guard_line=$(awk '$0 == "if [[ ! -f ${YAY_VCS_DB} ]]; then" { print NR }' \
    "${REPO_ROOT}/setup-arch-workstation.sh")
  init_line=$(awk '$0 == "  yay -Y --gendb" { print NR }' \
    "${REPO_ROOT}/setup-arch-workstation.sh")
  update_line=$(awk '$0 ~ /^ *yay -Sua --devel$/ { print NR }' \
    "${REPO_ROOT}/setup-arch-workstation.sh")
  [[ ${guard_line} =~ ^[0-9]+$ && ${init_line} =~ ^[0-9]+$ && ${update_line} =~ ^[0-9]+$ ]] \
    || fail 'Arch setup does not conditionally initialize Yay and request devel updates exactly once'
  (( guard_line < init_line && init_line < update_line )) \
    || fail 'Arch setup does not initialize the Yay development database before its devel update'
  ! grep -Fxq 'yay -Sua' "${REPO_ROOT}/setup-arch-workstation.sh" \
    || fail 'Arch setup still has an AUR update path that omits VCS/devel packages'
)

test_arch_openjdk_transition() (
  load_helpers setup-arch-workstation.sh
  local jre_installed=1 jdk_installed=0 remove_calls=0 install_calls=0
  local transition_line reconciliation_line
  array_contains jdk-openjdk "${PKGS_OFFICIAL[@]}" \
    || fail 'Arch official package set omits jdk-openjdk'
  pacman() {
    case "$*" in
      '-Q jre-openjdk') (( jre_installed == 1 )) ;;
      '-Q jdk-openjdk') (( jdk_installed == 1 )) ;;
      *) return 97 ;;
    esac
  }
  sudo() {
    [[ $1 == pacman ]] || fail 'OpenJDK transition did not invoke pacman through sudo'
    shift
    case "$*" in
      '-Rdd --noconfirm jre-openjdk')
        (( jre_installed == 1 )) || fail 'OpenJDK transition removed an absent JRE'
        (( remove_calls += 1 ))
        jre_installed=0
        ;;
      '-S --needed --noconfirm jdk-openjdk')
        (( jre_installed == 0 )) || fail 'OpenJDK transition installed the JDK before removing the conflicting JRE'
        (( install_calls += 1 ))
        jdk_installed=1
        ;;
      *) fail "unexpected OpenJDK transition arguments: $*" ;;
    esac
  }
  transition_openjdk_runtime_arch
  (( remove_calls == 1 && install_calls == 1 )) \
    || fail 'OpenJDK runtime-to-JDK migration did not perform one removal and one installation'
  (( jre_installed == 0 && jdk_installed == 1 )) \
    || fail 'OpenJDK runtime-to-JDK migration did not converge'
  transition_line=$(awk '$0 == "transition_openjdk_runtime_arch" { print NR }' \
    "${REPO_ROOT}/setup-arch-workstation.sh")
  reconciliation_line=$(awk '$0 == "find_missing_pkgs \"${WANTED_PKGS[@]}\"" { print NR }' \
    "${REPO_ROOT}/setup-arch-workstation.sh")
  [[ ${transition_line} =~ ^[0-9]+$ && ${reconciliation_line} =~ ^[0-9]+$ ]] \
    || fail 'Arch setup does not invoke the OpenJDK migration and package reconciliation exactly once'
  (( transition_line < reconciliation_line )) \
    || fail 'Arch setup invokes the OpenJDK migration after official-package reconciliation'
)

test_arch_openjdk_transition_noop() (
  load_helpers setup-arch-workstation.sh
  pacman() {
    [[ $* == '-Q jre-openjdk' ]] || return 97
    return 1
  }
  sudo() { fail 'OpenJDK transition mutated a host without the legacy JRE'; }
  transition_openjdk_runtime_arch
)

test_arch_legacy_purge() (
  load_helpers setup-arch-workstation.sh
  local ide_installed=1 remove_calls=0
  pacman() {
    [[ $1 == -Q && $2 == antigravity-ide ]] || return 97
    (( ide_installed == 1 ))
  }
  sudo() {
    [[ $1 == pacman ]] || fail 'legacy IDE purge did not invoke pacman through sudo'
    shift
    [[ $* == '-Rns --noconfirm antigravity-ide' ]] \
      || fail "unexpected legacy IDE removal arguments: $*"
    (( remove_calls += 1 ))
    ide_installed=0
  }
  purge_legacy_antigravity_arch
  (( remove_calls == 1 )) || fail 'legacy IDE was not removed exactly once'
  (( ide_installed == 0 )) || fail 'legacy IDE remained installed'
)

test_arch_legacy_purge_noop() (
  load_helpers setup-arch-workstation.sh
  pacman() { return 1; }
  sudo() { fail 'legacy IDE purge mutated an already-converged host'; }
  purge_legacy_antigravity_arch
)

test_arch_legacy_version_purge() (
  load_helpers setup-arch-workstation.sh
  local old_installed=1 remove_calls=0
  pacman() {
    case "$*" in
      '-Q antigravity-ide') return 1 ;;
      '-Q antigravity')
        (( old_installed == 1 )) || return 1
        printf 'antigravity 1.21.9-1\n'
        ;;
      *) return 97 ;;
    esac
  }
  vercmp() { printf '%s\n' -1; }
  sudo() {
    [[ $1 == pacman ]] || fail 'legacy 1.x purge did not invoke pacman through sudo'
    shift
    [[ $* == '-Rns --noconfirm antigravity' ]] \
      || fail "unexpected legacy 1.x removal arguments: $*"
    (( remove_calls += 1 ))
    old_installed=0
  }
  purge_legacy_antigravity_arch
  (( remove_calls == 1 )) || fail 'legacy Antigravity 1.x was not removed exactly once'
  (( old_installed == 0 )) || fail 'legacy Antigravity 1.x remained installed'
)

setup_arch_native_fixture() {
  HOME=${TEST_ROOT}/arch-native-$1/home
  ANTIGRAVITY_INSTALL_DIR=${TEST_ROOT}/arch-native-$1/Antigravity
  install -d "${HOME}/.local/bin" "${ANTIGRAVITY_INSTALL_DIR}"
  local tool
  printf '#!/bin/sh\nexit 0\n' >"${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage"
  chmod 0755 "${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage"
  for tool in agy claude codex; do
    printf '#!/bin/sh\nexit 0\n' >"${HOME}/.local/bin/${tool}"
    chmod 0755 "${HOME}/.local/bin/${tool}"
  done
}

test_arch_verify_good() (
  load_helpers setup-arch-workstation.sh
  setup_arch_native_fixture good
  pacman() { [[ $1 == -Q ]] || return 97; return 1; }
  command() { [[ $1 == -v && $2 == antigravity ]]; }
  verify_native_ai_tools_arch
)

test_arch_verify_rejection() {
  local scenario=$1 rc=0
  (
    load_helpers setup-arch-workstation.sh
    setup_arch_native_fixture "${scenario}"
    pacman() {
      [[ $1 == -Q ]] || return 97
      case ${scenario}:$2 in
        aur-package:antigravity|legacy-ide:antigravity-ide|rpm-claude:claude-code) return 0 ;;
      esac
      return 1
    }
    command() {
      [[ $1 == -v && $2 == antigravity && ${scenario} != missing-desktop-command ]]
    }
    case ${scenario} in
      missing-appimage) rm -f -- "${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage" ;;
      missing-cli) rm -f -- "${HOME}/.local/bin/agy" ;;
      missing-claude) rm -f -- "${HOME}/.local/bin/claude" ;;
      broken-cli) printf '#!/bin/sh\nexit 1\n' >"${HOME}/.local/bin/agy" ;;
    esac
    verify_native_ai_tools_arch
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail "Arch verification accepted ${scenario}"
}

test_fedora_release_sources() (
  load_helpers setup-fedora-workstation.sh
  [[ -z ${ANTIGRAVITY_VERSION} && -z ${ANTIGRAVITY_DESKTOP_URL} \
     && -z ${ANTIGRAVITY_DESKTOP_SHA512} && -z ${ANTIGRAVITY_CLI_VERSION} \
     && -z ${ANTIGRAVITY_CLI_URL} && -z ${ANTIGRAVITY_CLI_ARCHIVE_SHA512} ]] \
    || fail 'Fedora still hard-codes an Antigravity desktop or CLI release'
  [[ -z ${OPENCODE_VERSION} && -z ${OPENCODE_URL} \
     && -z ${OPENCODE_ARCHIVE_SHA256} && -z ${ZED_VERSION} \
     && -z ${ZED_URL} && -z ${ZED_ARCHIVE_SHA256} ]] \
    || fail 'Fedora still hard-codes an OpenCode or Zed release'
  [[ ${ANTIGRAVITY_DESKTOP_MANIFEST_BASE} == https://* \
     && ${ANTIGRAVITY_CLI_MANIFEST_BASE} == https://* \
     && ${OPENCODE_RELEASE_API} == https://api.github.com/repos/anomalyco/opencode/releases/latest \
     && ${ZED_RELEASE_API} == https://api.github.com/repos/zed-industries/zed/releases/latest ]] \
    || fail 'Fedora latest-release metadata sources are missing or non-HTTPS'
  [[ ${SPEEDTEST_VERSION} == 1.2.0 \
     && ${SPEEDTEST_ARCHIVE_SHA256_X86_64} =~ ^[[:xdigit:]]{64}$ \
     && ${SPEEDTEST_BINARY_SHA256_X86_64} =~ ^[[:xdigit:]]{64}$ \
     && ${SPEEDTEST_ARCHIVE_SHA256_AARCH64} =~ ^[[:xdigit:]]{64}$ \
     && ${SPEEDTEST_BINARY_SHA256_AARCH64} =~ ^[[:xdigit:]]{64}$ ]] \
    || fail 'the intentionally fixed low-churn Speedtest release lost its integrity pins'

  local test_arch expected_desktop_manifest expected_desktop_suffix
  local expected_cli_manifest expected_cli_suffix
  for test_arch in x86_64 aarch64; do
    case ${test_arch} in
      x86_64)
        expected_desktop_manifest=latest-x64-linux.yml
        expected_desktop_suffix=/linux-x64/Antigravity.AppImage
        expected_cli_manifest=linux_amd64.json
        expected_cli_suffix=/linux-x64/cli_linux_x64.tar.gz
        ;;
      aarch64)
        expected_desktop_manifest=latest-arm64-linux-arm64.yml
        expected_desktop_suffix=/linux-arm/Antigravity.AppImage
        expected_cli_manifest=linux_arm64.json
        expected_cli_suffix=/linux-arm/cli_linux_arm64.tar.gz
        ;;
    esac
    select_fedora_artifacts "${test_arch}"
    [[ ${ANTIGRAVITY_DESKTOP_MANIFEST_URL} == \
          "${ANTIGRAVITY_DESKTOP_MANIFEST_BASE}/${expected_desktop_manifest}" \
       && ${ANTIGRAVITY_DESKTOP_URL_SUFFIX} == "${expected_desktop_suffix}" \
       && ${ANTIGRAVITY_CLI_MANIFEST_URL} == \
          "${ANTIGRAVITY_CLI_MANIFEST_BASE}/${expected_cli_manifest}" \
       && ${ANTIGRAVITY_CLI_URL_SUFFIX} == "${expected_cli_suffix}" ]] \
      || fail "${test_arch} Antigravity manifest/artifact mapping is incorrect"
  done
)

test_fedora_developer_catalog() (
  load_helpers setup-fedora-workstation.sh
  array_contains code "${PKGS[@]}" || fail 'Fedora package set omits VS Code'
  ! array_contains claude-code "${PKGS[@]}" \
    || fail 'Fedora still installs Claude Code from the RPM repository'
  ! array_contains codium "${PKGS[@]}" || fail 'Fedora package set still requests VSCodium'
  [[ ! -e ${REPO_ROOT}/files/etc/yum.repos.d/vscodium.repo ]] \
    || fail 'Fedora still ships the VSCodium repository payload'
  [[ ${MICROSOFT_KEY_FINGERPRINT} =~ ^[[:xdigit:]]{40}$ ]] \
    || fail 'Fedora developer repository signing-key fingerprints are not pinned'
  [[ ! -e ${REPO_ROOT}/files/etc/yum.repos.d/claude-code.repo ]] \
    || fail 'Fedora still ships the retired Claude Code repository payload'
  [[ ${CLAUDE_INSTALLER_URL} == https://claude.ai/install.sh ]] \
    || fail 'Fedora Claude Code does not use the official native installer URL'
  declare -f install_claude_cli | grep -Fq 'claude" --version' \
    || fail 'Fedora Claude Code installer lacks a runnable-command postcondition'

  local repo=vscode.repo expected_key=${MICROSOFT_KEY_FILE}
  [[ -f ${REPO_ROOT}/files/etc/yum.repos.d/${repo} ]] \
    || fail "Fedora signed repository payload is missing: ${repo}"
  grep -qx 'enabled=1' "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
    || fail "${repo} is not enabled"
  grep -qx 'gpgcheck=1' "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
    || fail "${repo} does not require RPM signature validation"
  grep -Eq '^baseurl=https://[^[:space:]]+$' \
    "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
    || fail "${repo} does not use an HTTPS package source"
  [[ ${expected_key} == /etc/pki/rpm-gpg/* ]] \
    || fail "${repo} signing key is not installed under /etc/pki/rpm-gpg"
  grep -Fqx "gpgkey=file://${expected_key}" \
    "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
    || fail "${repo} does not use its fingerprint-verified local signing key"
  grep -qx 'sslverify=1' "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
    || fail "${repo} does not require TLS certificate validation"
  grep -Fqx "gpgkey=file://${MICROSOFT_KEY_FILE}" \
    "${REPO_ROOT}/files/etc/yum.repos.d/microsoft-prod.repo" \
    || fail 'Microsoft production repo bypasses the fingerprint-verified local key'

  [[ ${CODEX_INSTALLER_URL} == https://chatgpt.com/codex/install.sh ]] \
    || fail 'Fedora Codex CLI does not use the official native installer URL'
  declare -f install_codex_cli | grep -Fq 'codex" --version' \
    || fail 'Fedora Codex installer lacks a runnable-command postcondition'
  declare -f install_zed | grep -Fq 'zed" --version' \
    || fail 'Fedora Zed installer lacks a runnable-command postcondition'
  grep -Fq 'for command_name in agy antigravity claude code codex opencode zed' \
    "${REPO_ROOT}/setup-fedora-workstation.sh" \
    || fail 'Fedora does not enforce all requested developer-command postconditions'
)

test_fedora_key_fingerprint_enforcement() (
  load_helpers setup-fedora-workstation.sh
  WORK_DIR=${TEST_ROOT}/key-fingerprint
  local trusted_path=${WORK_DIR}/MICROSOFT-RPM-GPG-KEY
  local curl_calls=0 key_install_calls=0 import_calls=0 rc=0
  install -d "${WORK_DIR}"
  curl() {
    local output=''
    while (( $# )); do
      if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
    done
    [[ -n ${output} ]] || fail 'signing-key download did not specify an output file'
    printf 'mock signing key\n' >"${output}"
    (( curl_calls += 1 ))
  }
  gpg() {
    printf 'fpr:::::::::%s:\n' "${MICROSOFT_KEY_FINGERPRINT}"
  }
  put_file() {
    [[ $1 == -s && $3 == "${trusted_path}" && $4 == 0644 ]] \
      || fail "unexpected verified-key installation: $*"
    install -D -m 0644 -- "$2" "$3"
    (( key_install_calls += 1 ))
  }
  sudo() {
    [[ $1 == rpmkeys && $2 == --import && $3 == "${trusted_path}" && -f $3 ]] \
      || fail "unexpected verified-key import invocation: $*"
    (( import_calls += 1 ))
  }
  import_rpm_key "${MICROSOFT_KEY_URL}" gpgsecurity@microsoft.com \
    "${MICROSOFT_KEY_FINGERPRINT}" "${trusted_path}"
  (( curl_calls == 1 && key_install_calls == 1 && import_calls == 1 )) \
    || fail 'fingerprint-pinned key was not downloaded, verified, installed, and imported once'

  (
    gpg() { printf 'fpr:::::::::0000000000000000000000000000000000000000:\n'; }
    put_file() { fail 'fingerprint mismatch reached trusted key installation'; }
    sudo() { fail 'fingerprint mismatch reached RPM key import'; }
    import_rpm_key "${MICROSOFT_KEY_URL}" gpgsecurity@microsoft.com \
      "${MICROSOFT_KEY_FINGERPRINT}" "${trusted_path}"
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail 'Fedora accepted a signing key with the wrong fingerprint'
)

test_fedora_opencode_artifacts() (
  load_helpers setup-fedora-workstation.sh
  local optimized_asset baseline_asset arm_asset
  grep() { return 0; }
  select_fedora_artifacts x86_64
  optimized_asset=${OPENCODE_ASSET}
  unset -f grep
  [[ ${optimized_asset} == opencode-linux-x64.tar.gz ]] \
    || fail 'Fedora AVX2 OpenCode asset is not the optimized x64 build'

  grep() { return 1; }
  select_fedora_artifacts x86_64
  baseline_asset=${OPENCODE_ASSET}
  unset -f grep
  [[ ${baseline_asset} == opencode-linux-x64-baseline.tar.gz ]] \
    || fail 'Fedora non-AVX2 OpenCode asset is not the x64 baseline build'

  select_fedora_artifacts aarch64
  arm_asset=${OPENCODE_ASSET}
  [[ ${arm_asset} == opencode-linux-arm64.tar.gz ]] \
    || fail 'Fedora aarch64 OpenCode asset is incorrect'

  local asset
  for asset in "${optimized_asset}" "${baseline_asset}" "${arm_asset}"; do
    [[ ${asset} == opencode-linux-*.tar.gz ]] || fail "unexpected OpenCode asset: ${asset}"
  done
  [[ -z ${OPENCODE_VERSION} && -z ${OPENCODE_URL} \
     && -z ${OPENCODE_ARCHIVE_SHA256} ]] \
    || fail 'OpenCode architecture selection unexpectedly hard-codes a release'
)

test_fedora_zed_artifacts() (
  load_helpers setup-fedora-workstation.sh
  local test_arch expected_zed_arch
  for test_arch in x86_64 aarch64; do
    select_fedora_artifacts "${test_arch}"
    expected_zed_arch=${test_arch}
    [[ ${ZED_ARCH} == "${expected_zed_arch}" ]] \
      || fail "${test_arch} selects unexpected Zed architecture ${ZED_ARCH}"
    [[ -z ${ZED_VERSION} && -z ${ZED_URL} && -z ${ZED_ARCHIVE_SHA256} ]] \
      || fail "${test_arch} Zed selection unexpectedly hard-codes a release"
  done
)

test_fedora_dynamic_release_resolution() (
  load_helpers setup-fedora-workstation.sh
  local desktop_checksum_base64 desktop_checksum_hex
  desktop_checksum_base64=YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==
  desktop_checksum_hex=$(printf '61%.0s' {1..64})
  grep() { return 0; }
  select_fedora_artifacts x86_64
  unset -f grep
  fetch_release_document() {
    case $1 in
      "${ANTIGRAVITY_DESKTOP_MANIFEST_URL}")
        printf '%s\n' \
          'version: 3.90.1' \
          'files:' \
          '  - url: https://storage.googleapis.com/antigravity-public/releases/3.90.1-123/linux-x64/Antigravity.AppImage' \
          "    sha512: ${desktop_checksum_base64}" \
          '    size: 123456'
        ;;
      "${ANTIGRAVITY_CLI_MANIFEST_URL}")
        printf '%s\n' \
          '{"version":"3.4.5","url":"https://storage.googleapis.com/antigravity-public/antigravity-cli/3.4.5-456/linux-x64/cli_linux_x64.tar.gz","sha512":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","published":"additive fixture field"}'
        ;;
      "${OPENCODE_RELEASE_API}")
        printf '%s\n' \
          '{"draft":false,"prerelease":false,"immutable":false,"tag_name":"v9.8.7","assets":[{"name":"opencode-linux-x64.tar.gz","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v9.8.7/opencode-linux-x64.tar.gz","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]}'
        ;;
      "${ZED_RELEASE_API}")
        printf '%s\n' \
          '{"draft":false,"prerelease":false,"immutable":true,"tag_name":"v7.6.5","assets":[{"name":"zed-linux-x86_64.tar.gz","browser_download_url":"https://github.com/zed-industries/zed/releases/download/v7.6.5/zed-linux-x86_64.tar.gz","digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}]}'
        ;;
      *) fail "release resolver requested an unexpected URL: $1" ;;
    esac
  }

  resolve_native_tool_releases
  [[ ${ANTIGRAVITY_VERSION} == 3.90.1 \
     && ${ANTIGRAVITY_DESKTOP_SIZE} == 123456 \
     && ${ANTIGRAVITY_DESKTOP_ROLLOUT} == 100 \
     && ${ANTIGRAVITY_DESKTOP_SHA512} == "${desktop_checksum_hex}" ]] \
    || fail 'Fedora did not resolve the Antigravity desktop manifest and SHA-512 exactly'
  [[ ${ANTIGRAVITY_CLI_VERSION} == 3.4.5 \
     && ${ANTIGRAVITY_CLI_ARCHIVE_SHA512} == $(printf 'b%.0s' {1..128}) ]] \
    || fail 'Fedora did not resolve the Antigravity CLI manifest exactly'
  [[ ${OPENCODE_VERSION} == 9.8.7 \
     && ${OPENCODE_URL} == https://github.com/anomalyco/opencode/releases/download/v9.8.7/opencode-linux-x64.tar.gz \
     && ${OPENCODE_ARCHIVE_SHA256} == $(printf 'c%.0s' {1..64}) ]] \
    || fail 'Fedora did not bind OpenCode to one stable release asset and digest'
  [[ ${ZED_VERSION} == 7.6.5 \
     && ${ZED_URL} == https://github.com/zed-industries/zed/releases/download/v7.6.5/zed-linux-x86_64.tar.gz \
     && ${ZED_ARCHIVE_SHA256} == $(printf 'd%.0s' {1..64}) ]] \
    || fail 'Fedora did not bind Zed to one stable release asset and digest'
)

test_fedora_antigravity_rollout_parsing() (
  load_helpers setup-fedora-workstation.sh
  local manifest parsed
  manifest=$(printf '%s\n' \
    'version: 2.3.4' \
    'files:' \
    '  - url: https://storage.googleapis.com/antigravity-public/releases/2.3.4-5/linux-x64/Antigravity.AppImage' \
    '    sha512: YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==' \
    '    size: 42')
  parsed=$(parse_antigravity_desktop_manifest "${manifest}") \
    || fail 'Fedora rejected an Antigravity manifest with an omitted optional rollout'
  [[ ${parsed##*$'\t'} == 100 ]] \
    || fail 'Fedora did not default an omitted Antigravity rollout to 100'
  parsed=$(parse_antigravity_desktop_manifest \
    "${manifest}"$'\nstagingPercentage: 25') \
    || fail 'Fedora rejected an Antigravity manifest with an explicit rollout'
  [[ ${parsed##*$'\t'} == 25 ]] \
    || fail 'Fedora did not preserve an explicit Antigravity rollout'
)

test_fedora_github_metadata_rejection() {
  local scenario=$1 rc=0
  (
    load_helpers setup-fedora-workstation.sh
    grep() { return 0; }
    select_fedora_artifacts x86_64
    unset -f grep
    fetch_release_document() {
      local draft=false prerelease=false digest url assets tag=v1.2.3
      digest=sha256:$(printf 'e%.0s' {1..64})
      [[ ${scenario} != unprefixed-tag ]] || tag=1.2.3
      url=https://github.com/anomalyco/opencode/releases/download/${tag}/opencode-linux-x64.tar.gz
      assets="{\"name\":\"opencode-linux-x64.tar.gz\",\"browser_download_url\":\"${url}\",\"digest\":\"${digest}\"}"
      case ${scenario} in
        draft) draft=true ;;
        prerelease) prerelease=true ;;
        duplicate) assets="${assets},${assets}" ;;
        bad-digest) digest=sha512:$(printf 'e%.0s' {1..128}); assets="{\"name\":\"opencode-linux-x64.tar.gz\",\"browser_download_url\":\"${url}\",\"digest\":\"${digest}\"}" ;;
        off-origin) url=https://downloads.example.invalid/opencode-linux-x64.tar.gz; assets="{\"name\":\"opencode-linux-x64.tar.gz\",\"browser_download_url\":\"${url}\",\"digest\":\"${digest}\"}" ;;
        unprefixed-tag) ;;
        *) fail "unknown GitHub metadata scenario: ${scenario}" ;;
      esac
      printf '{"draft":%s,"prerelease":%s,"immutable":true,"tag_name":"%s","assets":[%s]}\n' \
        "${draft}" "${prerelease}" "${tag}" "${assets}"
    }
    resolve_github_release_asset anomalyco/opencode "${OPENCODE_RELEASE_API}" \
      "${OPENCODE_ASSET}"
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail "Fedora accepted unsafe GitHub release metadata: ${scenario}"
}

test_fedora_antigravity_metadata_rejection() {
  local scenario=$1 rc=0
  (
    load_helpers setup-fedora-workstation.sh
    select_fedora_artifacts x86_64
    fetch_release_document() {
      case ${scenario} in
        legacy-desktop-version)
          printf '%s\n' \
            'version: 1.99.0' \
            'files:' \
            '  - url: https://storage.googleapis.com/antigravity-public/releases/1.99.0-5/linux-x64/Antigravity.AppImage' \
            '    sha512: YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==' \
            '    size: 42' \
            'stagingPercentage: 100'
          ;;
        wrong-desktop-arch)
          printf '%s\n' \
            'version: 2.3.4' \
            'files:' \
            '  - url: https://storage.googleapis.com/antigravity-public/releases/2.3.4-5/linux-arm/Antigravity.AppImage' \
            '    sha512: YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==' \
            '    size: 42' \
            'stagingPercentage: 100'
          ;;
        malformed-desktop-checksum)
          printf '%s\n' \
            'version: 2.3.4' \
            'files:' \
            '  - url: https://storage.googleapis.com/antigravity-public/releases/2.3.4-5/linux-x64/Antigravity.AppImage' \
            '    sha512: not-base64!' \
            '    size: 42' \
            'stagingPercentage: 100'
          ;;
        cli-bad-digest)
          printf '%s\n' \
            '{"version":"1.2.3","url":"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.3-4/linux-x64/cli_linux_x64.tar.gz","sha512":"not-a-sha512"}'
          ;;
        *) fail "unknown Antigravity metadata scenario: ${scenario}" ;;
      esac
    }
    case ${scenario} in
      legacy-desktop-version|wrong-desktop-arch|malformed-desktop-checksum)
        resolve_antigravity_desktop_release
        ;;
      cli-bad-digest)
        resolve_antigravity_cli_release
        ;;
    esac
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] \
    || fail "Fedora accepted unsafe Antigravity release metadata: ${scenario}"
}

test_fedora_converged_native_installs() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/converged/work
  local install_dir=${TEST_ROOT}/converged/Antigravity
  local bin_dir=${TEST_ROOT}/converged/bin
  local installed_image=${install_dir}/Antigravity.AppImage
  local image_sha cli_sha
  local link_calls=0 desktop_calls=0 icon_calls=0
  ANTIGRAVITY_VERSION=2.90.1
  ANTIGRAVITY_DESKTOP_URL=https://storage.googleapis.com/antigravity-public/releases/2.90.1-123/linux-x64/Antigravity.AppImage
  ANTIGRAVITY_CLI_VERSION=3.4.5
  ANTIGRAVITY_CLI_URL=https://storage.googleapis.com/antigravity-public/antigravity-cli/3.4.5-456/linux-x64/cli_linux_x64.tar.gz
  ANTIGRAVITY_CLI_ARCHIVE_SHA512=$(printf 'b%.0s' {1..128})
  ANTIGRAVITY_COMMAND_LINK=${TEST_ROOT}/converged/antigravity-link
  ANTIGRAVITY_DESKTOP_FILE=${TEST_ROOT}/converged/antigravity.desktop
  install -d "${WORK_DIR}" "${install_dir}" "${bin_dir}"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${installed_image}"
  chmod 0755 "${installed_image}"
  image_sha=$(sha512sum -- "${installed_image}")
  ANTIGRAVITY_DESKTOP_SHA512=${image_sha%% *}
  ANTIGRAVITY_DESKTOP_SIZE=$(stat -c '%s' -- "${installed_image}")
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${ANTIGRAVITY_VERSION}" \
    "source-url=${ANTIGRAVITY_DESKTOP_URL}" \
    "image-size=${ANTIGRAVITY_DESKTOP_SIZE}" \
    "image-sha512=${ANTIGRAVITY_DESKTOP_SHA512}" \
    >"${install_dir}/.lan-ipxe-release"
  printf '#!/usr/bin/env sh\nprintf "%%s\\n" "%s"\n' \
    "${ANTIGRAVITY_CLI_VERSION}" >"${bin_dir}/agy"
  chmod 0755 "${bin_dir}/agy"
  cli_sha=$(sha256sum -- "${bin_dir}/agy")
  cli_sha=${cli_sha%% *}
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${ANTIGRAVITY_CLI_VERSION}" \
    "source-url=${ANTIGRAVITY_CLI_URL}" \
    "archive-sha512=${ANTIGRAVITY_CLI_ARCHIVE_SHA512}" \
    "binary-sha256=${cli_sha}" \
    >"${bin_dir}/agy.lan-ipxe-release"
  curl() { fail 'a converged native Antigravity install attempted a download'; }
  ensure_symlink() {
    [[ $* == "-s ${installed_image} ${ANTIGRAVITY_COMMAND_LINK}" ]] \
      || fail "unexpected Antigravity command-link arguments: $*"
    (( link_calls += 1 ))
  }
  put_file() {
    [[ $1 == -s && $2 == */usr/share/applications/antigravity.desktop \
       && $3 == "${ANTIGRAVITY_DESKTOP_FILE}" ]] \
      || fail "unexpected Antigravity desktop-file arguments: $*"
    (( desktop_calls += 1 ))
  }
  install_antigravity_icon() {
    [[ $* == "${installed_image}" ]] || fail "unexpected Antigravity icon arguments: $*"
    (( icon_calls += 1 ))
  }
  install_antigravity_desktop "${install_dir}"
  install_antigravity_cli "${bin_dir}"
  (( link_calls == 1 )) || fail 'converged desktop did not reconcile its command link'
  (( desktop_calls == 1 )) || fail 'converged desktop did not reconcile its launcher'
  (( icon_calls == 1 )) || fail 'converged desktop did not reconcile its icon'
)

test_fedora_future_major_downgrade_guard() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/future-major-downgrade/work
  local install_dir=${TEST_ROOT}/future-major-downgrade/Antigravity
  local installed_image=${install_dir}/Antigravity.AppImage
  local current_version=3.91.0 current_sha current_size log
  local link_calls=0 desktop_calls=0 icon_calls=0
  ANTIGRAVITY_VERSION=3.90.1
  ANTIGRAVITY_DESKTOP_URL=https://storage.googleapis.com/antigravity-public/releases/3.90.1-123/linux-x64/Antigravity.AppImage
  ANTIGRAVITY_DESKTOP_SHA512=$(printf 'a%.0s' {1..128})
  ANTIGRAVITY_DESKTOP_SIZE=123456
  ANTIGRAVITY_COMMAND_LINK=${TEST_ROOT}/future-major-downgrade/antigravity-link
  ANTIGRAVITY_DESKTOP_FILE=${TEST_ROOT}/future-major-downgrade/antigravity.desktop
  log=${TEST_ROOT}/future-major-downgrade/install.log
  install -d "${WORK_DIR}" "${install_dir}"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${installed_image}"
  chmod 0755 "${installed_image}"
  current_sha=$(sha512sum -- "${installed_image}")
  current_sha=${current_sha%% *}
  current_size=$(stat -c '%s' -- "${installed_image}")
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${current_version}" \
    'source-url=https://storage.googleapis.com/antigravity-public/releases/3.91.0-456/linux-x64/Antigravity.AppImage' \
    "image-size=${current_size}" \
    "image-sha512=${current_sha}" \
    >"${install_dir}/.lan-ipxe-release"
  curl() { fail 'future-major downgrade guard attempted a download'; }
  ensure_symlink() {
    [[ $* == "-s ${installed_image} ${ANTIGRAVITY_COMMAND_LINK}" ]] \
      || fail "unexpected future-major command-link arguments: $*"
    (( link_calls += 1 ))
  }
  put_file() {
    [[ $1 == -s && $2 == */usr/share/applications/antigravity.desktop \
       && $3 == "${ANTIGRAVITY_DESKTOP_FILE}" ]] \
      || fail "unexpected future-major desktop-file arguments: $*"
    (( desktop_calls += 1 ))
  }
  install_antigravity_icon() {
    [[ $* == "${installed_image}" ]] || fail "unexpected future-major icon arguments: $*"
    (( icon_calls += 1 ))
  }
  install_antigravity_desktop "${install_dir}" >"${log}"
  grep -Fq "Antigravity ${current_version} is newer than the current manifest ${ANTIGRAVITY_VERSION}; preserving it" \
    "${log}" || fail 'future-major downgrade preservation was not reported clearly'
  (( link_calls == 1 )) || fail 'future-major downgrade guard did not reconcile its command link'
  (( desktop_calls == 1 )) || fail 'future-major downgrade guard did not reconcile its launcher'
  (( icon_calls == 1 )) || fail 'future-major downgrade guard did not reconcile its icon'
)

# Writes a managed install whose marker records a different image than the one
# on disk, which is exactly what electron-updater leaves behind after it runs.
write_self_updated_antigravity() {
  local install_dir=$1 installed_image=$1/Antigravity.AppImage
  install -d "${install_dir}"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${installed_image}"
  chmod 0755 "${installed_image}"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    'version=2.12.2' \
    'source-url=https://storage.googleapis.com/antigravity-public/releases/2.12.2-1/linux-x64/Antigravity.AppImage' \
    'image-size=1' \
    "image-sha512=$(printf 'f%.0s' {1..128})" \
    >"${install_dir}/.lan-ipxe-release"
}

test_fedora_self_updated_desktop_preserved() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  local root=${TEST_ROOT}/self-updated
  local install_dir=${root}/Antigravity log=${root}/install.log
  local installed_image=${install_dir}/Antigravity.AppImage
  local finish_calls=0
  WORK_DIR=${root}/work
  ANTIGRAVITY_VERSION=2.19.1
  ANTIGRAVITY_DESKTOP_URL=https://storage.googleapis.com/antigravity-public/releases/2.19.1-123/linux-x64/Antigravity.AppImage
  ANTIGRAVITY_DESKTOP_SHA512=$(printf 'a%.0s' {1..128})
  ANTIGRAVITY_DESKTOP_SIZE=123456
  ANTIGRAVITY_COMMAND_LINK=${root}/antigravity-link
  install -d "${WORK_DIR}"
  write_self_updated_antigravity "${install_dir}"
  antigravity_appimage_version() {
    [[ $1 == "${installed_image}" ]] || fail "unexpected version-probe arguments: $*"
    printf '2.20.0\n'
  }
  curl() { fail 'a self-updated Antigravity newer than the manifest was re-downloaded'; }
  sudo() { fail "a self-updated Antigravity reconcile invoked sudo: $*"; }
  finish_antigravity_desktop() {
    [[ $* == "${install_dir}" ]] || fail "unexpected finish arguments: $*"
    (( finish_calls += 1 ))
  }
  install_antigravity_desktop "${install_dir}" >"${log}"
  grep -Fq 'Antigravity 2.20.0: updated in place by the app (manifest 2.19.1); preserving it' \
    "${log}" || fail 'self-updated Antigravity preservation was not reported'
  (( finish_calls == 1 )) || fail 'self-updated Antigravity did not reconcile its launcher'
)

test_fedora_stale_self_updated_desktop_replaced() {
  local root=${TEST_ROOT}/stale-self-updated rc=0
  (
    load_helpers setup-fedora-workstation.sh
    select_fedora_artifacts x86_64
    WORK_DIR=${root}/work
    ANTIGRAVITY_VERSION=2.19.1
    ANTIGRAVITY_DESKTOP_URL=https://storage.googleapis.com/antigravity-public/releases/2.19.1-123/linux-x64/Antigravity.AppImage
    ANTIGRAVITY_DESKTOP_SHA512=$(printf 'a%.0s' {1..128})
    ANTIGRAVITY_DESKTOP_SIZE=123456
    ANTIGRAVITY_COMMAND_LINK=${root}/antigravity-link
    install -d "${WORK_DIR}"
    write_self_updated_antigravity "${root}/Antigravity"
    antigravity_appimage_version() { printf '2.15.0\n'; }
    curl() { : >"${root}/downloaded"; return 1; }
    install_antigravity_desktop "${root}/Antigravity"
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 && -e ${root}/downloaded ]] \
    || fail 'a self-updated Antigravity older than the manifest was not replaced'
}

test_fedora_desktop_owner_handoff() (
  load_helpers setup-fedora-workstation.sh
  local install_dir=${TEST_ROOT}/owner-handoff/Antigravity chown_calls=0
  install -d "${install_dir}"
  : >"${install_dir}/Antigravity.AppImage"
  sudo() { fail "an already user-owned Antigravity install invoked sudo: $*"; }
  ensure_antigravity_owner "${install_dir}" >/dev/null
  id() {
    case $1 in
      -u|-g) printf '%s\n' "$(( $(command id "$1") + 4242 ))" ;;
      *) command id "$@" ;;
    esac
  }
  sudo() {
    [[ $* == "chown -R -- $(( $(command id -u) + 4242 )):$(( $(command id -g) + 4242 )) ${install_dir}" ]] \
      || fail "unexpected Antigravity ownership handoff: $*"
    (( chown_calls += 1 ))
  }
  ensure_antigravity_owner "${install_dir}" >/dev/null
  (( chown_calls == 1 )) || fail 'a foreign-owned Antigravity install was not handed to the user'
)

test_fedora_appimage_icon_and_version() (
  load_helpers setup-fedora-workstation.sh
  local root=${TEST_ROOT}/appimage-extract image icon_source='' icon_dest=''
  WORK_DIR=${root}/work
  ANTIGRAVITY_ICON_FILE=${root}/icons/hicolor/512x512/apps/antigravity.png
  image=${root}/Antigravity.AppImage
  install -d "${WORK_DIR}"
  # Minimal stand-in for the AppImage runtime's single-member extraction.
  cat >"${image}" <<'EOF'
#!/usr/bin/env sh
[ "$1" = --appimage-extract ] || exit 1
mkdir -p "squashfs-root/$(dirname "$2")"
case $2 in
  antigravity.desktop) printf '[Desktop Entry]\nX-AppImage-Version=2.19.1\n' >"squashfs-root/$2" ;;
  */antigravity.png) printf 'png' >"squashfs-root/$2" ;;
  *) exit 1 ;;
esac
EOF
  chmod 0755 "${image}"
  [[ $(antigravity_appimage_version "${image}") == 2.19.1 ]] \
    || fail 'the embedded Antigravity AppImage version was not read'
  sudo() { fail "an unchanged icon refreshed the icon cache: $*"; }
  put_file() {
    [[ $1 == -s ]] || fail "the Antigravity icon was not installed system-wide: $*"
    icon_source=$(cat -- "$2")
    icon_dest=$3
    # Read by the sourced install_antigravity_icon.
    # shellcheck disable=SC2034
    PUT_FILE_CHANGED=0
  }
  install_antigravity_icon "${image}" >/dev/null
  [[ ${icon_source} == png && ${icon_dest} == "${ANTIGRAVITY_ICON_FILE}" ]] \
    || fail 'the bundled Antigravity icon was not installed under the launcher icon name'
  [[ $(command grep -c '^Icon=antigravity$' \
      "${REPO_ROOT}/files/usr/share/applications/antigravity.desktop") == 1 ]] \
    || fail 'the Antigravity launcher does not reference the bundled icon'
)

test_fedora_converged_opencode() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/converged-opencode/work
  local bin_dir=${TEST_ROOT}/converged-opencode/bin
  local binary_sha
  OPENCODE_VERSION=9.8.7
  OPENCODE_URL=https://github.com/anomalyco/opencode/releases/download/v9.8.7/${OPENCODE_ASSET}
  OPENCODE_ARCHIVE_SHA256=$(printf 'c%.0s' {1..64})
  install -d "${WORK_DIR}" "${bin_dir}"
  printf '#!/usr/bin/env sh\nprintf "%%s\\n" "%s"\n' \
    "${OPENCODE_VERSION}" >"${bin_dir}/opencode"
  chmod 0755 "${bin_dir}/opencode"
  binary_sha=$(sha256sum -- "${bin_dir}/opencode")
  binary_sha=${binary_sha%% *}
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${OPENCODE_VERSION}" \
    "asset=${OPENCODE_ASSET}" \
    "source-url=${OPENCODE_URL}" \
    "archive-sha256=${OPENCODE_ARCHIVE_SHA256}" \
    "binary-sha256=${binary_sha}" \
    >"${bin_dir}/opencode.lan-ipxe-release"
  curl() { fail 'a converged OpenCode install attempted a download'; }
  put_file() { fail 'a converged OpenCode install attempted a replacement'; }
  install_opencode_cli "${bin_dir}"
)

test_fedora_converged_zed() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/converged-zed/work
  HOME=${TEST_ROOT}/converged-zed/home
  local install_dir=${HOME}/.local/zed.app link_calls=0 desktop_calls=0
  ZED_VERSION=7.6.5
  ZED_URL=https://github.com/zed-industries/zed/releases/download/v7.6.5/zed-linux-x86_64.tar.gz
  ZED_ARCHIVE_SHA256=$(printf 'd%.0s' {1..64})
  install -d "${WORK_DIR}" "${install_dir}/bin" \
    "${install_dir}/share/applications" \
    "${install_dir}/share/icons/hicolor/512x512/apps"
  printf '#!/usr/bin/env sh\nprintf "Zed %s\\n"\n' \
    "${ZED_VERSION}" >"${install_dir}/bin/zed"
  chmod 0755 "${install_dir}/bin/zed"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${ZED_VERSION}" \
    "archive-sha256=${ZED_ARCHIVE_SHA256}" \
    >"${install_dir}/.lan-ipxe-release"
  printf '%s\n' \
    '[Desktop Entry]' \
    'Exec=zed %U' \
    'Icon=zed' \
    >"${install_dir}/share/applications/dev.zed.Zed.desktop"
  printf 'mock icon\n' \
    >"${install_dir}/share/icons/hicolor/512x512/apps/zed.png"
  curl() { fail 'a converged Zed install attempted a download'; }
  ensure_symlink() {
    [[ $* == "${install_dir}/bin/zed ${HOME}/.local/bin/zed" ]] \
      || fail "unexpected converged Zed command-link arguments: $*"
    (( link_calls += 1 ))
  }
  put_file() {
    [[ $2 == "${HOME}/.local/share/applications/dev.zed.Zed.desktop" \
       && $3 == 0644 ]] || fail "unexpected converged Zed desktop arguments: $*"
    grep -Fqx "Exec=${install_dir}/bin/zed %U" "$1" \
      || fail 'converged Zed launcher did not receive the managed executable path'
    grep -Fqx "Icon=${install_dir}/share/icons/hicolor/512x512/apps/zed.png" "$1" \
      || fail 'converged Zed launcher did not receive the managed icon path'
    (( desktop_calls += 1 ))
  }
  install_zed "${install_dir}"
  (( link_calls == 1 )) || fail 'converged Zed did not reconcile its command link'
  (( desktop_calls == 1 )) || fail 'converged Zed did not reconcile its launcher'
)

test_fedora_media_servers() (
  load_helpers setup-fedora-workstation.sh
  array_contains plexmediaserver "${PKGS_FULL_X86_64[@]}" \
    || fail 'Fedora full x86_64 package set omits Plex Media Server'
  ! array_contains plexmediaserver "${PKGS[@]}" "${PKGS_FULL[@]}" \
    || fail 'Plex Media Server is requested on architectures Plex does not publish'
  array_contains plexmediaserver.service "${SERVICES_FULL_X86_64[@]}" \
    || fail 'Fedora full x86_64 service set omits Plex Media Server'
  array_contains navidrome.service "${SERVICES_FULL[@]}" \
    || fail 'Fedora full service set omits Navidrome'
  array_contains owntone.service "${SERVICES_FULL[@]}" \
    || fail 'Fedora full service set omits OwnTone'
  local spec=${REPO_ROOT}/files/rpm/owntone.spec
  [[ ${OWNTONE_RELEASE_API} == https://api.github.com/repos/owntone/owntone-server/releases/latest \
     && ${OWNTONE_SPEC} == "${FILES}/rpm/owntone.spec" && -f ${spec} ]] \
    || fail 'OwnTone release source or spec payload is missing'
  grep -Fqx 'Version: %{owntone_version}' "${spec}" \
    || fail 'OwnTone spec does not take its version from the resolved release'
  ! grep -Fq '%{name}.sysusers' "${spec}" \
    || fail 'OwnTone spec depends on a sysusers file the release tarball lacks'
  [[ ${PLEX_KEY_FINGERPRINT} =~ ^[[:xdigit:]]{40}$ \
     && ${PLEX_KEY_FILE} == /etc/pki/rpm-gpg/* ]] \
    || fail 'Plex repository signing key is not fingerprint-pinned'

  local repo=${REPO_ROOT}/files/etc/yum.repos.d/plex.repo line
  for line in '[PlexTv]' enabled=1 gpgcheck=1 repo_gpgcheck=1 sslverify=1 \
    "gpgkey=file://${PLEX_KEY_FILE}"; do
    grep -Fqx -- "${line}" "${repo}" || fail "plex.repo lacks ${line}"
  done
  grep -Eq '^baseurl=https://[^[:space:]]+$' "${repo}" \
    || fail 'plex.repo does not use an HTTPS package source'

  [[ ${NAVIDROME_RELEASE_API} == https://api.github.com/repos/navidrome/navidrome/releases/latest ]] \
    || fail 'Navidrome latest-release metadata source is incorrect'
  local test_arch expected_arch
  for test_arch in x86_64 aarch64; do
    case ${test_arch} in
      x86_64)  expected_arch=amd64 ;;
      aarch64) expected_arch=arm64 ;;
    esac
    select_fedora_artifacts "${test_arch}"
    [[ ${NAVIDROME_ARCH} == "${expected_arch}" ]] \
      || fail "${test_arch} selects unexpected Navidrome architecture ${NAVIDROME_ARCH}"
  done
)

# Mocks Navidrome release metadata, the RPM database, the download, and DNF.
# $1: installed version ('' when absent); $2: good or corrupt download.
NAVIDROME_FIXTURE_RPM=navidrome_0.70.1_linux_amd64.rpm
setup_navidrome_fixture() {
  local digest
  NAVIDROME_INSTALLED=$1
  NAVIDROME_DOWNLOAD=$2
  digest=$(printf 'navidrome fixture rpm\n' | sha256sum)
  NAVIDROME_DIGEST=${digest%% *}
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/navidrome-${1:-absent}-$2/work
  install -d "${WORK_DIR}"
  fetch_release_document() {
    [[ $1 == "${NAVIDROME_RELEASE_API}" ]] \
      || fail "Navidrome resolver requested an unexpected URL: $1"
    printf '{"draft":false,"prerelease":false,"immutable":true,"tag_name":"v0.70.1","assets":[{"name":"%s","browser_download_url":"https://github.com/navidrome/navidrome/releases/download/v0.70.1/%s","digest":"sha256:%s"}]}\n' \
      "${NAVIDROME_FIXTURE_RPM}" "${NAVIDROME_FIXTURE_RPM}" "${NAVIDROME_DIGEST}"
  }
  rpm() {
    case "$*" in
      '-q --quiet navidrome') [[ -n ${NAVIDROME_INSTALLED} ]] ;;
      '-q --qf %{VERSION} navidrome') printf '%s' "${NAVIDROME_INSTALLED}" ;;
      *) fail "unexpected rpm call: $*" ;;
    esac
  }
  curl() {
    local output=
    while (( $# )); do
      if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
    done
    [[ -n ${output} ]] || fail 'mock curl received no output path'
    if [[ ${NAVIDROME_DOWNLOAD} == good ]]; then
      printf 'navidrome fixture rpm\n' >"${output}"
    else
      printf 'deliberately corrupt rpm\n' >"${output}"
    fi
  }
  sudo() {
    [[ "$*" == "dnf -y install ${WORK_DIR}/${NAVIDROME_FIXTURE_RPM}" ]] \
      || fail "unexpected privileged Navidrome call: $*"
    NAVIDROME_INSTALLED=0.70.1
  }
}

test_fedora_navidrome_install() (
  load_helpers setup-fedora-workstation.sh
  local installed
  for installed in '' 0.63.2; do
    setup_navidrome_fixture "${installed}" good
    install_navidrome >/dev/null
    [[ ${NAVIDROME_INSTALLED} == 0.70.1 ]] \
      || fail "Navidrome ${installed:-absent} was not upgraded to the verified release"
  done

  for installed in 0.70.1 0.71.0; do
    setup_navidrome_fixture "${installed}" good
    curl() { fail "Navidrome ${installed} attempted a download"; }
    sudo() { fail "Navidrome ${installed} attempted a privileged mutation"; }
    install_navidrome >/dev/null
  done
)

test_fedora_navidrome_checksum_rejection() {
  local rc=0
  (
    load_helpers setup-fedora-workstation.sh
    setup_navidrome_fixture 0.63.2 corrupt
    # A distinct status keeps a reached DNF install from passing as die's 1.
    sudo() { exit 3; }
    install_navidrome
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail 'Fedora accepted a corrupt Navidrome RPM'
}

# Mocks OwnTone release metadata, the RPM database, the source download, DNF,
# and rpmbuild. $1: installed version ('' when absent); $2: good, corrupt, or
# broken (the build fails).
setup_owntone_fixture() {
  local digest
  OWNTONE_INSTALLED=$1
  OWNTONE_MODE=$2
  digest=$(printf 'owntone fixture source\n' | sha256sum)
  OWNTONE_DIGEST=${digest%% *}
  select_fedora_artifacts x86_64
  OWNTONE_SPEC=${REPO_ROOT}/files/rpm/owntone.spec
  WORK_DIR=${TEST_ROOT}/owntone-${1:-absent}-$2/work
  OWNTONE_CALLS=${WORK_DIR}/calls
  # install_owntone captures rpmbuild output; keep mock assertions visible.
  exec 9>&2
  install -d "${WORK_DIR}"
  : >"${OWNTONE_CALLS}"
  fetch_release_document() {
    [[ $1 == "${OWNTONE_RELEASE_API}" ]] \
      || fail "OwnTone resolver requested an unexpected URL: $1"
    printf '{"draft":false,"prerelease":false,"immutable":true,"tag_name":"29.4","assets":[{"name":"owntone-29.4.tar.xz","browser_download_url":"https://github.com/owntone/owntone-server/releases/download/29.4/owntone-29.4.tar.xz","digest":"sha256:%s"}]}\n' \
      "${OWNTONE_DIGEST}"
  }
  rpm() {
    case "$*" in
      '-q --quiet owntone') [[ -n ${OWNTONE_INSTALLED} ]] ;;
      '-q --qf %{VERSION} owntone') printf '%s' "${OWNTONE_INSTALLED}" ;;
      *) fail "unexpected rpm call: $*" ;;
    esac
  }
  curl() {
    local output=
    while (( $# )); do
      if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
    done
    [[ ${output} == "${WORK_DIR}/rpmbuild/SOURCES/owntone-29.4.tar.xz" ]] \
      || fail "OwnTone source downloaded to unexpected path: ${output}"
    if [[ ${OWNTONE_MODE} == corrupt ]]; then
      printf 'deliberately corrupt source\n' >"${output}"
    else
      printf 'owntone fixture source\n' >"${output}"
    fi
  }
  sudo() {
    local spec=${WORK_DIR}/rpmbuild/SPECS/owntone.spec
    case "$*" in
      "dnf -y builddep --define owntone_version 29.4 ${spec}")
        cmp -s -- "${OWNTONE_SPEC}" "${spec}" \
          || fail 'OwnTone build dependencies were not read from the repository spec'
        ;;
      "dnf -y install ${WORK_DIR}/rpmbuild/RPMS/x86_64/owntone-29.4-1.fc44.x86_64.rpm")
        OWNTONE_INSTALLED=29.4
        ;;
      *) fail "unexpected privileged OwnTone call: $*" ;;
    esac
    printf 'sudo %s\n' "$3" >>"${OWNTONE_CALLS}"
  }
  rpmbuild() {
    local topdir=${WORK_DIR}/rpmbuild
    [[ "$*" == "-bb --define _topdir ${topdir} --define owntone_version 29.4 --define debug_package %{nil} ${topdir}/SPECS/owntone.spec" ]] \
      || fail "unexpected rpmbuild call: $*" 2>&9
    [[ -f ${topdir}/SOURCES/owntone-29.4.tar.xz ]] \
      || fail 'rpmbuild ran without the verified source tarball' 2>&9
    printf 'rpmbuild\n' >>"${OWNTONE_CALLS}"
    [[ ${OWNTONE_MODE} != broken ]] || return 1
    install -d "${topdir}/RPMS/x86_64"
    : >"${topdir}/RPMS/x86_64/owntone-29.4-1.fc44.x86_64.rpm"
    : >"${topdir}/RPMS/x86_64/owntone-debugsource-29.4-1.fc44.x86_64.rpm"
  }
}

test_fedora_owntone_install() (
  load_helpers setup-fedora-workstation.sh
  local installed
  for installed in '' 29.3; do
    setup_owntone_fixture "${installed}" good
    install_owntone >/dev/null
    [[ ${OWNTONE_INSTALLED} == 29.4 ]] \
      || fail "OwnTone ${installed:-absent} was not upgraded to the verified release"
    [[ $(<"${OWNTONE_CALLS}") == $'sudo builddep\nrpmbuild\nsudo install' ]] \
      || fail "OwnTone ${installed:-absent} ran an unexpected build sequence"
  done

  for installed in 29.4 30.0; do
    setup_owntone_fixture "${installed}" good
    curl() { fail "OwnTone ${installed} attempted a download"; }
    sudo() { fail "OwnTone ${installed} attempted a privileged mutation"; }
    rpmbuild() { fail "OwnTone ${installed} attempted a rebuild"; }
    install_owntone >/dev/null
  done
)

test_fedora_owntone_rejection() {
  local mode=$1 rc=0
  (
    load_helpers setup-fedora-workstation.sh
    setup_owntone_fixture 29.3 "${mode}"
    # A distinct status keeps a reached mutation from passing as die's 1.
    case ${mode} in
      corrupt)
        sudo() { exit 3; }
        rpmbuild() { exit 3; }
        ;;
      broken) sudo() { [[ $3 == builddep ]] || exit 3; } ;;
    esac
    install_owntone
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail "Fedora installed OwnTone after a ${mode} source/build (rc=${rc})"
}

test_fedora_checksum_rejection() {
  local product=$1 rc=0
  (
    load_helpers setup-fedora-workstation.sh
    select_fedora_artifacts x86_64
    WORK_DIR=${TEST_ROOT}/bad-${product}/work
    ANTIGRAVITY_VERSION=2.90.1
    ANTIGRAVITY_DESKTOP_URL=https://storage.googleapis.com/antigravity-public/releases/2.90.1-123/linux-x64/Antigravity.AppImage
    ANTIGRAVITY_DESKTOP_SHA512=$(printf '0%.0s' {1..128})
    ANTIGRAVITY_DESKTOP_SIZE=29
    ANTIGRAVITY_COMMAND_LINK=${TEST_ROOT}/bad-${product}/antigravity-link
    ANTIGRAVITY_DESKTOP_FILE=${TEST_ROOT}/bad-${product}/antigravity.desktop
    ANTIGRAVITY_CLI_VERSION=3.4.5
    ANTIGRAVITY_CLI_URL=https://storage.googleapis.com/antigravity-public/antigravity-cli/3.4.5-456/linux-x64/cli_linux_x64.tar.gz
    ANTIGRAVITY_CLI_ARCHIVE_SHA512=$(printf '0%.0s' {1..128})
    OPENCODE_VERSION=9.8.7
    OPENCODE_URL=https://github.com/anomalyco/opencode/releases/download/v9.8.7/${OPENCODE_ASSET}
    OPENCODE_ARCHIVE_SHA256=$(printf '0%.0s' {1..64})
    install -d "${WORK_DIR}"
    curl() {
      local output=
      while (( $# )); do
        if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
      done
      [[ -n ${output} ]] || fail 'mock curl received no output path'
      printf 'deliberately corrupt archive\n' >"${output}"
    }
    sudo() { fail "${product} checksum mismatch reached a privileged mutation"; }
    case ${product} in
      desktop) install_antigravity_desktop "${TEST_ROOT}/bad-${product}/install" ;;
      cli)     install_antigravity_cli "${TEST_ROOT}/bad-${product}/bin" ;;
      opencode)
        put_file() { fail 'OpenCode checksum mismatch reached a file mutation'; }
        install_opencode_cli "${TEST_ROOT}/bad-${product}/bin"
        ;;
      *)       fail "unknown checksum-rejection product: ${product}" ;;
    esac
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail "Fedora accepted a corrupt Antigravity ${product} archive"
}

test_fedora_desktop_size_rejection() {
  local rc=0 install_dir=${TEST_ROOT}/bad-desktop-size/install
  (
    load_helpers setup-fedora-workstation.sh
    select_fedora_artifacts x86_64
    WORK_DIR=${TEST_ROOT}/bad-desktop-size/work
    ANTIGRAVITY_VERSION=2.90.1
    ANTIGRAVITY_DESKTOP_URL=https://storage.googleapis.com/antigravity-public/releases/2.90.1-123/linux-x64/Antigravity.AppImage
    ANTIGRAVITY_DESKTOP_SHA512=$(printf 'checksum-valid fixture' | sha512sum)
    ANTIGRAVITY_DESKTOP_SHA512=${ANTIGRAVITY_DESKTOP_SHA512%% *}
    ANTIGRAVITY_DESKTOP_SIZE=999999
    ANTIGRAVITY_COMMAND_LINK=${TEST_ROOT}/bad-desktop-size/antigravity-link
    ANTIGRAVITY_DESKTOP_FILE=${TEST_ROOT}/bad-desktop-size/antigravity.desktop
    install -d "${WORK_DIR}"
    curl() {
      local output=
      while (( $# )); do
        if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
      done
      [[ -n ${output} ]] || fail 'mock AppImage curl received no output path'
      printf 'checksum-valid fixture' >"${output}"
    }
    sudo() { fail 'AppImage size mismatch reached a privileged mutation'; }
    install_antigravity_desktop "${install_dir}"
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail 'Fedora accepted an AppImage with the wrong manifest size'
  [[ ! -e ${install_dir} && ! -L ${install_dir} ]] \
    || fail 'wrong-size AppImage mutated the installation directory'
}

test_fedora_zed_checksum_rejection() {
  local rc=0 install_dir=${TEST_ROOT}/bad-zed/home/.local/zed.app
  (
    load_helpers setup-fedora-workstation.sh
    select_fedora_artifacts x86_64
    WORK_DIR=${TEST_ROOT}/bad-zed/work
    HOME=${TEST_ROOT}/bad-zed/home
    ZED_VERSION=7.6.5
    ZED_URL=https://github.com/zed-industries/zed/releases/download/v7.6.5/zed-linux-x86_64.tar.gz
    ZED_ARCHIVE_SHA256=$(printf '0%.0s' {1..64})
    install -d "${WORK_DIR}"
    curl() {
      local output=
      while (( $# )); do
        if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
      done
      [[ -n ${output} ]] || fail 'mock Zed curl received no output path'
      printf 'deliberately corrupt Zed archive\n' >"${output}"
    }
    ensure_symlink() { fail 'Zed checksum mismatch reached command-link mutation'; }
    put_file() { fail 'Zed checksum mismatch reached desktop-file mutation'; }
    install_zed "${install_dir}"
  ) >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 1 ]] || fail 'Fedora accepted a corrupt Zed archive'
  [[ ! -e ${install_dir} && ! -L ${install_dir} ]] \
    || fail 'corrupt Zed archive mutated the installation directory'
  [[ ! -e ${TEST_ROOT}/bad-zed/home/.local/bin/zed ]] \
    || fail 'corrupt Zed archive mutated the command link'
}

test_fedora_self_updated_cli_preserved() (
  load_helpers setup-fedora-workstation.sh
  WORK_DIR=${TEST_ROOT}/cli-self-updated/work
  local bin_dir=${TEST_ROOT}/cli-self-updated/bin
  ANTIGRAVITY_CLI_VERSION=3.4.5
  ANTIGRAVITY_CLI_URL=https://storage.googleapis.com/antigravity-public/antigravity-cli/3.4.5-456/linux-x64/cli_linux_x64.tar.gz
  ANTIGRAVITY_CLI_ARCHIVE_SHA512=$(printf 'b%.0s' {1..128})
  install -d "${WORK_DIR}" "${bin_dir}"
  # The marker records an older install; agy has since replaced itself.
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    'version=3.4.0' \
    "binary-sha256=$(printf '0%.0s' {1..64})" \
    >"${bin_dir}/agy.lan-ipxe-release"
  printf '#!/usr/bin/env sh\nprintf "3.5.0\\n"\n' >"${bin_dir}/agy"
  chmod 0755 "${bin_dir}/agy"
  curl() { fail 'a self-updated Antigravity CLI was re-downloaded'; }
  put_file() { fail 'a self-updated Antigravity CLI was overwritten'; }
  install_antigravity_cli "${bin_dir}"
  [[ $("${bin_dir}/agy") == 3.5.0 ]] || fail 'self-updated Antigravity CLI was modified'
)

test_fedora_stale_cli_replaced() (
  load_helpers setup-fedora-workstation.sh
  WORK_DIR=${TEST_ROOT}/cli-stale/work
  local bin_dir=${TEST_ROOT}/cli-stale/bin
  ANTIGRAVITY_CLI_VERSION=3.4.5
  install -d "${WORK_DIR}" "${bin_dir}"
  printf '%s\n' 'managed-by=lan-ipxe/setup-fedora-workstation.sh' 'version=3.4.0' \
    >"${bin_dir}/agy.lan-ipxe-release"
  printf '#!/usr/bin/env sh\nprintf "3.4.0\\n"\n' >"${bin_dir}/agy"
  chmod 0755 "${bin_dir}/agy"
  curl() { printf 'download\n' >"${WORK_DIR}/downloaded"; return 1; }
  ( install_antigravity_cli "${bin_dir}" ) >/dev/null 2>&1 \
    && fail 'stale Antigravity CLI download failure was not fatal'
  [[ -f ${WORK_DIR}/downloaded ]] || fail 'an older Antigravity CLI was preserved'
)

write_known_claude_repo() {
  local path=$1
  install -d "$(dirname "${path}")"
  printf '%s\n' \
    '[claude-code]' \
    'name=Claude Code' \
    'baseurl=https://downloads.claude.ai/claude-code/rpm/stable' \
    'enabled=1' \
    'gpgcheck=1' \
    'gpgkey=file:///etc/pki/rpm-gpg/ANTHROPIC-CLAUDE-CODE-RPM-GPG-KEY' \
    'sslverify=1' \
    'metadata_expire=1h' \
    >"${path}"
}

test_fedora_claude_repo_retirement() (
  load_helpers setup-fedora-workstation.sh
  local dir=${TEST_ROOT}/claude-repo path key removed=() key_deleted=0
  path=${dir}/claude-code.repo key=${dir}/ANTHROPIC-CLAUDE-CODE-RPM-GPG-KEY
  write_known_claude_repo "${path}"
  printf 'key\n' >"${key}"
  [[ $(sha256sum -- "${path}" | awk '{print $1}') == "${LEGACY_CLAUDE_REPO_SHA256}" ]] \
    || fail 'Claude Code repository fixture drifted from the recognized checksum'
  dnf_repo_enabled() { fail 'the known Claude Code repository needed a DNF query'; }
  rpmkeys() {
    [[ $1 == --list ]] || fail "unexpected unprivileged rpmkeys call: $*"
    printf '%s Anthropic Claude Code Release Signing public key\n' \
      "${LEGACY_CLAUDE_KEY_FINGERPRINT,,}"
  }
  sudo() {
    case $* in
      "rm -f -- ${path}"|"rm -f -- ${key}") removed+=("${*: -1}"); command "$@" ;;
      "rpmkeys --delete ${LEGACY_CLAUDE_KEY_FINGERPRINT}") (( key_deleted += 1 )) ;;
      *) fail "unexpected Claude Code retirement command: $*" ;;
    esac
  }
  remove_legacy_claude_repo "${path}" "${key}"
  [[ ! -e ${path} && ! -e ${key} ]] || fail 'retired Claude Code repo or key was preserved'
  (( ${#removed[@]} == 2 && key_deleted == 1 )) \
    || fail 'Claude Code repo/key retirement did not run exactly once'
)

test_fedora_custom_claude_repo_preservation() (
  load_helpers setup-fedora-workstation.sh
  local path=${TEST_ROOT}/claude-custom/claude-code.repo repo_enabled=1 disable_calls=0
  install -d "$(dirname "${path}")"
  printf 'administrator customization\n' >"${path}"
  dnf_repo_enabled() {
    [[ $1 == claude-code ]] || return 97
    (( repo_enabled == 1 ))
  }
  rpmkeys() { fail 'the Claude Code key was considered while a repo may still need it'; }
  sudo() {
    [[ $* == 'dnf config-manager setopt claude-code.enabled=0' ]] \
      || fail "unexpected customized Claude Code repository action: $*"
    (( disable_calls += 1 ))
    repo_enabled=0
  }
  # The key is still referenced by a repository file, so it is preserved.
  grep() {
    [[ $1 == -rlsF ]] && return 0
    command grep "$@"
  }
  remove_legacy_claude_repo "${path}" /etc/pki/rpm-gpg/ANTHROPIC-CLAUDE-CODE-RPM-GPG-KEY \
    2>/dev/null
  command grep -qx 'administrator customization' "${path}" \
    || fail 'customized Claude Code repository was modified'
  (( disable_calls == 1 )) || fail 'customized Claude Code repository was not disabled exactly once'
)

test_fedora_claude_rpm_removed_after_native() (
  load_helpers setup-fedora-workstation.sh
  local installed=1 removals=0
  rpm() { [[ $* == '-q --quiet claude-code' ]] || return 97; (( installed == 1 )); }
  sudo() {
    [[ $* == 'dnf -y remove claude-code' ]] || fail "unexpected Claude RPM action: $*"
    (( removals += 1 )); installed=0
  }
  remove_legacy_claude_rpm
  remove_legacy_claude_rpm
  (( removals == 1 )) || fail 'Claude Code RPM removal did not converge'
  # Native install must precede RPM removal in the main flow.
  awk '/^ *install_claude_cli$/ { native = NR } /^remove_legacy_claude_rpm$/ { rpm = NR }
       END { exit !(native && rpm && native < rpm) }' \
    "${REPO_ROOT}/setup-fedora-workstation.sh" \
    || fail 'the Claude Code RPM is removed before the native install'
)

write_known_legacy_repo() {
  local path=$1
  install -d "$(dirname "${path}")"
  printf '%s\n' \
    '[antigravity-rpm]' \
    'name=Antigravity RPM Repository' \
    'baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm' \
    'enabled=0' \
    '# NOTE: gpgcheck is disabled because no published GPG signing-key URL is available' \
    '# for this Google Artifact Registry repo. Accepted risk: package signatures are not' \
    '# verified. Set gpgcheck=1 and add a gpgkey= line if/when a key URL is published.' \
    'gpgcheck=0' >"${path}"
}

write_known_legacy_settings() {
  local path=$1
  install -d "$(dirname "${path}")"
  printf '%s\n' \
    '{' \
    '    "git.confirmSync": false,' \
    '    "terminal.integrated.shellIntegration.enabled": false,' \
    '    "terminal.integrated.profiles.linux": {' \
    '        "Antigravity Agent (Clean)": {' \
    '            "path": "bash",' \
    '            "args": [' \
    '                "--noprofile",' \
    '                "--norc"' \
    '            ],' \
    '            "env": {' \
    '                "TERM": "dumb",' \
    '                "DEBIAN_FRONTEND": "noninteractive"' \
    '            }' \
    '        }' \
    '    },' \
    '    "terminal.integrated.defaultProfile.linux": "Antigravity Agent (Clean)"' \
    '}' >"${path}"
}

test_fedora_known_repo_removal() (
  load_helpers setup-fedora-workstation.sh
  local path=${TEST_ROOT}/known/antigravity.repo sudo_calls=0
  write_known_legacy_repo "${path}"
  [[ $(sha256sum -- "${path}" | awk '{print $1}') == "${LEGACY_ANTIGRAVITY_REPO_DISABLED_SHA256}" ]] \
    || fail 'legacy repository test fixture drifted from the recognized checksum'
  dnf_repo_enabled() { fail 'known legacy repository should be removed without a DNF query'; }
  sudo() {
    [[ $* == "rm -f -- ${path}" ]] || fail "unexpected repository removal command: $*"
    (( sudo_calls += 1 ))
    command "$@"
  }
  remove_legacy_antigravity_repo "${path}"
  [[ ! -e ${path} ]] || fail 'known legacy RPM repository was preserved'
  (( sudo_calls == 1 )) || fail 'known legacy RPM repository was not removed exactly once'
)

test_fedora_custom_repo_preservation() (
  load_helpers setup-fedora-workstation.sh
  local path=${TEST_ROOT}/custom/antigravity.repo repo_enabled=1 disable_calls=0
  install -D -m 0644 /dev/null "${path}"
  printf 'administrator customization\n' >"${path}"
  dnf_repo_enabled() {
    [[ $1 == antigravity-rpm ]] || return 97
    (( repo_enabled == 1 ))
  }
  sudo() {
    [[ $* == 'dnf config-manager setopt antigravity-rpm.enabled=0' ]] \
      || fail "unexpected customized-repository action: $*"
    (( disable_calls += 1 ))
    repo_enabled=0
  }
  remove_legacy_antigravity_repo "${path}"
  grep -qx 'administrator customization' "${path}" \
    || fail 'customized legacy repository was modified'
  (( disable_calls == 1 )) || fail 'customized legacy repository was not disabled exactly once'
)

test_fedora_legacy_rpm_removal() (
  load_helpers setup-fedora-workstation.sh
  local rpm_installed=1 remove_calls=0
  rpm() {
    if [[ $* == '-q --quiet antigravity' ]]; then
      (( rpm_installed == 1 ))
    elif [[ ${1:-} == -q && ${2:-} == --qf \
            && ${3:-} == '%{EPOCHNUM}\t%{VERSION}\n' \
            && ${4:-} == antigravity ]]; then
      printf '0\t1.21.9\n'
    else
      return 97
    fi
  }
  sudo() {
    [[ $* == 'dnf -y remove antigravity' ]] || fail "unexpected legacy RPM removal command: $*"
    (( remove_calls += 1 ))
    rpm_installed=0
  }
  remove_legacy_antigravity_rpm
  (( rpm_installed == 0 )) || fail 'legacy Antigravity RPM remained installed'
  (( remove_calls == 1 )) || fail 'legacy Antigravity RPM was not removed exactly once'
)

test_fedora_nonlegacy_rpm_preservation() (
  load_helpers setup-fedora-workstation.sh
  local rpm_epoch=0 rpm_version=2.11.0 log=${TEST_ROOT}/preserved-rpm.log
  rpm() {
    if [[ $* == '-q --quiet antigravity' ]]; then
      return 0
    elif [[ ${1:-} == -q && ${2:-} == --qf \
            && ${3:-} == '%{EPOCHNUM}\t%{VERSION}\n' \
            && ${4:-} == antigravity ]]; then
      printf '%s\t%s\n' "${rpm_epoch}" "${rpm_version}"
    else
      return 97
    fi
  }
  sudo() { fail "nonlegacy Antigravity RPM preservation invoked sudo: $*"; }

  remove_legacy_antigravity_rpm >"${log}"
  grep -Fq 'Antigravity 2.11.0 RPM: preserved (native 2.0.0-or-newer package)' \
    "${log}" || fail 'native Antigravity 2.x RPM preservation was not reported clearly'

  rpm_epoch=1
  rpm_version=1.21.9
  remove_legacy_antigravity_rpm >"${log}"
  grep -Fq "Preserving installed Antigravity RPM with unrecognized epoch/version '1:1.21.9'" \
    "${log}" || fail 'nonzero-epoch Antigravity RPM was not preserved safely'
)

test_fedora_legacy_rpm_noop() (
  load_helpers setup-fedora-workstation.sh
  rpm() { return 1; }
  sudo() { fail 'legacy RPM purge mutated an already-converged host'; }
  remove_legacy_antigravity_rpm
)

test_fedora_known_settings_removal() (
  load_helpers setup-fedora-workstation.sh
  local path=${TEST_ROOT}/known/settings.json
  write_known_legacy_settings "${path}"
  [[ $(sha256sum -- "${path}" | awk '{print $1}') == "${LEGACY_ANTIGRAVITY_SETTINGS_SHA256}" ]] \
    || fail 'legacy settings test fixture drifted from the recognized checksum'
  remove_legacy_antigravity_settings "${path}"
  [[ ! -e ${path} ]] || fail 'known legacy IDE settings were preserved'
)

test_fedora_custom_settings_preservation() (
  load_helpers setup-fedora-workstation.sh
  local path=${TEST_ROOT}/custom/settings.json
  install -D -m 0644 /dev/null "${path}"
  printf '{"administrator":true}\n' >"${path}"
  remove_legacy_antigravity_settings "${path}"
  grep -qx '{"administrator":true}' "${path}" \
    || fail 'customized legacy IDE settings were modified'
)

test_legacy_payloads_retired() {
  [[ ! -e ${REPO_ROOT}/files/etc/yum.repos.d/antigravity.repo ]] \
    || fail 'the abandoned Antigravity 1.x RPM repository payload remains'
  [[ ! -e ${REPO_ROOT}/files/config/Antigravity/User/settings.json ]] \
    || fail 'the script-owned Antigravity 1.x IDE settings payload remains'
}

main() {
  local scenario
  test_arch_catalog
  printf 'PASS Arch self-updating native AI tool set\n'
  test_arch_developer_catalog
  printf 'PASS Arch native developer-tool package/postcondition set\n'
  test_arch_yay_devel_updates
  printf 'PASS Arch Yay VCS/devel update convergence\n'
  test_arch_openjdk_transition
  test_arch_openjdk_transition_noop
  printf 'PASS Arch OpenJDK runtime-to-JDK migration convergence\n'
  test_arch_legacy_purge
  test_arch_legacy_version_purge
  test_arch_legacy_purge_noop
  printf 'PASS Arch legacy Antigravity 1.x/IDE purge convergence\n'
  test_arch_verify_good
  for scenario in aur-package legacy-ide rpm-claude missing-appimage missing-cli \
    missing-claude missing-desktop-command broken-cli; do
    test_arch_verify_rejection "${scenario}"
  done
  printf 'PASS Arch native Antigravity/CLI/Claude/Codex postconditions\n'
  test_arch_native_flow_order
  test_arch_retired_package_removal
  printf 'PASS Arch pacman/AUR AI package retirement and ordering\n'
  test_fedora_release_sources
  printf 'PASS Fedora dynamic release sources and intentional Speedtest pin\n'
  test_fedora_developer_catalog
  printf 'PASS Fedora signed developer-package repositories and command postconditions\n'
  test_fedora_key_fingerprint_enforcement
  printf 'PASS Fedora signing-key fingerprint enforcement\n'
  test_fedora_opencode_artifacts
  printf 'PASS Fedora optimized/baseline/aarch64 OpenCode artifact selection\n'
  test_fedora_zed_artifacts
  printf 'PASS Fedora x86_64/aarch64 Zed artifact selection\n'
  test_fedora_dynamic_release_resolution
  printf 'PASS Fedora offline latest-release resolution and digest binding\n'
  test_fedora_antigravity_rollout_parsing
  printf 'PASS Fedora optional/explicit Antigravity rollout parsing\n'
  for scenario in draft prerelease duplicate bad-digest off-origin unprefixed-tag; do
    test_fedora_github_metadata_rejection "${scenario}"
  done
  for scenario in legacy-desktop-version wrong-desktop-arch \
    malformed-desktop-checksum cli-bad-digest; do
    test_fedora_antigravity_metadata_rejection "${scenario}"
  done
  printf 'PASS Fedora unsafe/malformed release metadata rejection\n'
  test_fedora_converged_native_installs
  printf 'PASS Fedora verified native desktop/CLI convergence\n'
  test_fedora_future_major_downgrade_guard
  printf 'PASS Fedora future-major desktop downgrade preservation\n'
  test_fedora_self_updated_desktop_preserved
  test_fedora_stale_self_updated_desktop_replaced
  printf 'PASS Fedora self-updated desktop preservation/replacement\n'
  test_fedora_desktop_owner_handoff
  printf 'PASS Fedora user-owned desktop install for in-app updates\n'
  test_fedora_self_updated_cli_preserved
  test_fedora_stale_cli_replaced
  printf 'PASS Fedora self-updated Antigravity CLI preservation/replacement\n'
  test_fedora_appimage_icon_and_version
  printf 'PASS Fedora bundled launcher icon and embedded version extraction\n'
  test_fedora_converged_opencode
  printf 'PASS Fedora verified native OpenCode convergence\n'
  test_fedora_converged_zed
  printf 'PASS Fedora verified native Zed convergence\n'
  test_fedora_media_servers
  printf 'PASS Fedora Plex/Navidrome/OwnTone sources, services, spec, and artifact selection\n'
  test_fedora_navidrome_install
  printf 'PASS Fedora verified Navidrome RPM install/upgrade/convergence\n'
  test_fedora_navidrome_checksum_rejection
  printf 'PASS Fedora corrupt Navidrome RPM rejection\n'
  test_fedora_owntone_install
  printf 'PASS Fedora verified OwnTone build/install/convergence\n'
  test_fedora_owntone_rejection corrupt
  test_fedora_owntone_rejection broken
  printf 'PASS Fedora corrupt-source and failed-build OwnTone rejection\n'
  test_fedora_checksum_rejection desktop
  test_fedora_checksum_rejection cli
  test_fedora_checksum_rejection opencode
  printf 'PASS Fedora desktop/CLI/OpenCode corrupt-archive rejection\n'
  test_fedora_desktop_size_rejection
  printf 'PASS Fedora Antigravity AppImage manifest-size rejection\n'
  test_fedora_zed_checksum_rejection
  printf 'PASS Fedora Zed corrupt-archive rejection without installation mutation\n'
  test_fedora_known_repo_removal
  test_fedora_custom_repo_preservation
  printf 'PASS Fedora known/customized legacy repository handling\n'
  test_fedora_claude_repo_retirement
  test_fedora_custom_claude_repo_preservation
  test_fedora_claude_rpm_removed_after_native
  printf 'PASS Fedora Claude Code RPM repo/key/package retirement\n'
  test_fedora_legacy_rpm_removal
  test_fedora_nonlegacy_rpm_preservation
  test_fedora_legacy_rpm_noop
  printf 'PASS Fedora legacy-only Antigravity RPM purge convergence\n'
  test_fedora_known_settings_removal
  test_fedora_custom_settings_preservation
  printf 'PASS Fedora known/customized legacy IDE settings handling\n'
  test_legacy_payloads_retired
  printf 'PASS Antigravity 1.x repository/settings payload retirement\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
