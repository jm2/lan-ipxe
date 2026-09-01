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
  array_contains antigravity "${PKGS_AUR[@]}" \
    || fail 'Arch AUR set omits Antigravity 2.x'
  array_contains antigravity-cli "${PKGS_AUR[@]}" \
    || fail 'Arch AUR set omits Antigravity CLI'
  ! array_contains antigravity-ide "${PKGS_AUR[@]}" \
    || fail 'Arch AUR set still requests the legacy Antigravity IDE'
)

test_arch_developer_catalog() (
  load_helpers setup-arch-workstation.sh
  local package
  for package in code opencode openai-codex zed; do
    array_contains "${package}" "${PKGS_OFFICIAL[@]}" \
      || fail "Arch official package set omits ${package}"
  done
  array_contains claude-code "${PKGS_AUR[@]}" \
    || fail 'Arch AUR set omits Claude Code'
  ! array_contains vscodium-bin "${PKGS_OFFICIAL[@]}" \
    || fail 'Arch official package set still requests VSCodium'
  ! array_contains vscodium-bin "${PKGS_AUR[@]}" \
    || fail 'Arch AUR set still requests VSCodium'
  grep -Fq 'for command_name in claude code codex opencode zed' \
    "${REPO_ROOT}/setup-arch-workstation.sh" \
    || fail 'Arch does not enforce all requested developer-command postconditions'
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
  update_line=$(awk '$0 == "yay -Sua --devel" { print NR }' \
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

test_arch_verify_good() (
  load_helpers setup-arch-workstation.sh
  pacman() {
    case "$*" in
      '-Q antigravity')     printf 'antigravity 2.11.0-1\n' ;;
      '-Q antigravity-cli') return 0 ;;
      '-Q antigravity-ide') return 1 ;;
      *)                    return 97 ;;
    esac
  }
  vercmp() { printf '1\n'; }
  command() {
    [[ $1 == -v && ( $2 == antigravity || $2 == agy ) ]]
  }
  agy() { [[ $1 == --version ]]; }
  verify_antigravity_arch
)

test_arch_verify_rejection() {
  local scenario=$1 rc=0
  (
    load_helpers setup-arch-workstation.sh
    pacman() {
      case "$*" in
        '-Q antigravity')
          if [[ ${scenario} == old-version ]]; then
            printf 'antigravity 1.21.9-1\n'
          else
            printf 'antigravity 2.11.0-1\n'
          fi
          ;;
        '-Q antigravity-cli')
          [[ ${scenario} != missing-cli ]]
          ;;
        '-Q antigravity-ide')
          [[ ${scenario} == legacy-ide ]]
          ;;
        *) return 97 ;;
      esac
    }
    vercmp() {
      if [[ $1 == 1.* ]]; then printf '%s\n' -1; else printf '1\n'; fi
    }
    command() {
      [[ $1 == -v ]] || return 1
      case $2 in
        antigravity) [[ ${scenario} != missing-desktop-command ]] ;;
        agy)         [[ ${scenario} != missing-cli-command ]] ;;
        *)           return 1 ;;
      esac
    }
    agy() { [[ $1 == --version && ${scenario} != broken-cli ]]; }
    verify_antigravity_arch
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
     && ${ZED_RELEASE_API} == https://api.github.com/repos/zed-industries/zed/releases/latest \
     && ${R8152_RELEASE_API} == https://api.github.com/repos/awesometic/realtek-r8152-dkms/releases/latest \
     && -z ${R8152_TAG} && -z ${R8152_COMMIT} ]] \
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
  array_contains claude-code "${PKGS[@]}" || fail 'Fedora package set omits Claude Code'
  ! array_contains codium "${PKGS[@]}" || fail 'Fedora package set still requests VSCodium'
  [[ ! -e ${REPO_ROOT}/files/etc/yum.repos.d/vscodium.repo ]] \
    || fail 'Fedora still ships the VSCodium repository payload'
  [[ ${MICROSOFT_KEY_FINGERPRINT} =~ ^[[:xdigit:]]{40}$ \
     && ${CLAUDE_KEY_FINGERPRINT} =~ ^[[:xdigit:]]{40}$ ]] \
    || fail 'Fedora developer repository signing-key fingerprints are not pinned'

  local repo expected_key
  for repo in vscode.repo claude-code.repo; do
    [[ -f ${REPO_ROOT}/files/etc/yum.repos.d/${repo} ]] \
      || fail "Fedora signed repository payload is missing: ${repo}"
    grep -qx 'enabled=1' "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
      || fail "${repo} is not enabled"
    grep -qx 'gpgcheck=1' "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
      || fail "${repo} does not require RPM signature validation"
    grep -Eq '^baseurl=https://[^[:space:]]+$' \
      "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
      || fail "${repo} does not use an HTTPS package source"
    case ${repo} in
      vscode.repo)     expected_key=${MICROSOFT_KEY_FILE} ;;
      claude-code.repo) expected_key=${CLAUDE_KEY_FILE} ;;
    esac
    [[ ${expected_key} == /etc/pki/rpm-gpg/* ]] \
      || fail "${repo} signing key is not installed under /etc/pki/rpm-gpg"
    grep -Fqx "gpgkey=file://${expected_key}" \
      "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
      || fail "${repo} does not use its fingerprint-verified local signing key"
    grep -qx 'sslverify=1' "${REPO_ROOT}/files/etc/yum.repos.d/${repo}" \
      || fail "${repo} does not require TLS certificate validation"
  done
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

test_fedora_r8152_release_resolution() (
  load_helpers setup-fedora-workstation.sh
  fetch_release_document() {
    [[ $1 == "${R8152_RELEASE_API}" ]] \
      || fail "r8152 resolver requested an unexpected URL: $1"
    printf '%s\n' \
      '{"draft":false,"prerelease":false,"tag_name":"9.8.7-6"}'
  }
  git() {
    [[ $* == "ls-remote --exit-code --tags ${R8152_REPO} refs/tags/9.8.7-6 refs/tags/9.8.7-6^{}" ]] \
      || fail "unexpected r8152 tag-resolution command: $*"
    printf '%s\t%s\n' \
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/tags/9.8.7-6 \
      bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 'refs/tags/9.8.7-6^{}'
  }
  resolve_r8152_release
  [[ ${R8152_TAG} == 9.8.7-6 \
     && ${R8152_COMMIT} == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] \
    || fail 'Fedora did not bind the latest r8152 release to its peeled commit'
)

test_fedora_github_metadata_rejection() {
  local scenario=$1 rc=0
  (
    load_helpers setup-fedora-workstation.sh
    grep() { return 0; }
    select_fedora_artifacts x86_64
    unset -f grep
    fetch_release_document() {
      local draft=false prerelease=false digest url assets
      digest=sha256:$(printf 'e%.0s' {1..64})
      url=https://github.com/anomalyco/opencode/releases/download/v1.2.3/opencode-linux-x64.tar.gz
      assets="{\"name\":\"opencode-linux-x64.tar.gz\",\"browser_download_url\":\"${url}\",\"digest\":\"${digest}\"}"
      case ${scenario} in
        draft) draft=true ;;
        prerelease) prerelease=true ;;
        duplicate) assets="${assets},${assets}" ;;
        bad-digest) digest=sha512:$(printf 'e%.0s' {1..128}); assets="{\"name\":\"opencode-linux-x64.tar.gz\",\"browser_download_url\":\"${url}\",\"digest\":\"${digest}\"}" ;;
        off-origin) url=https://downloads.example.invalid/opencode-linux-x64.tar.gz; assets="{\"name\":\"opencode-linux-x64.tar.gz\",\"browser_download_url\":\"${url}\",\"digest\":\"${digest}\"}" ;;
        *) fail "unknown GitHub metadata scenario: ${scenario}" ;;
      esac
      printf '{"draft":%s,"prerelease":%s,"immutable":true,"tag_name":"v1.2.3","assets":[%s]}\n' \
        "${draft}" "${prerelease}" "${assets}"
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
  local link_calls=0 desktop_calls=0
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
  install_antigravity_desktop "${install_dir}"
  install_antigravity_cli "${bin_dir}"
  (( link_calls == 1 )) || fail 'converged desktop did not reconcile its command link'
  (( desktop_calls == 1 )) || fail 'converged desktop did not reconcile its launcher'
)

test_fedora_future_major_downgrade_guard() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/future-major-downgrade/work
  local install_dir=${TEST_ROOT}/future-major-downgrade/Antigravity
  local installed_image=${install_dir}/Antigravity.AppImage
  local current_version=3.91.0 current_sha current_size log
  local link_calls=0 desktop_calls=0
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
  install_antigravity_desktop "${install_dir}" >"${log}"
  grep -Fq "Antigravity ${current_version} is newer than the current manifest ${ANTIGRAVITY_VERSION}; preserving it" \
    "${log}" || fail 'future-major downgrade preservation was not reported clearly'
  (( link_calls == 1 )) || fail 'future-major downgrade guard did not reconcile its command link'
  (( desktop_calls == 1 )) || fail 'future-major downgrade guard did not reconcile its launcher'
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
  printf 'PASS Arch Antigravity 2.x/CLI desired package set\n'
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
  for scenario in old-version missing-cli missing-desktop-command \
    missing-cli-command broken-cli legacy-ide; do
    test_arch_verify_rejection "${scenario}"
  done
  printf 'PASS Arch Antigravity 2.x/desktop/CLI runtime/legacy-absence postconditions\n'
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
  test_fedora_r8152_release_resolution
  printf 'PASS Fedora latest r8152 release-to-commit binding\n'
  for scenario in draft prerelease duplicate bad-digest off-origin; do
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
  test_fedora_converged_opencode
  printf 'PASS Fedora verified native OpenCode convergence\n'
  test_fedora_converged_zed
  printf 'PASS Fedora verified native Zed convergence\n'
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
