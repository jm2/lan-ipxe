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
  # shellcheck disable=SC1090
  source <(sed -n '/^case ${ARCH} in$/,/^ZED_URL=/p' \
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

test_fedora_release_pins() (
  load_helpers setup-fedora-workstation.sh
  [[ ${ANTIGRAVITY_VERSION:-} =~ ^2\.[0-9]+\.[0-9]+$ ]] \
    || fail 'Fedora Antigravity desktop version is not pinned to a 2.x release'
  [[ ${ANTIGRAVITY_APP_ASAR_SHA256:-} =~ ^[[:xdigit:]]{64}$ ]] \
    || fail 'Fedora Antigravity application-bundle SHA-256 is invalid'

  local test_arch
  for test_arch in x86_64 aarch64; do
    select_fedora_artifacts "${test_arch}"
    [[ ${ANTIGRAVITY_DESKTOP_URL} == https://*"/${ANTIGRAVITY_VERSION}-${ANTIGRAVITY_BUILD}/"* ]] \
      || fail "${test_arch} desktop URL is not an immutable version/build asset"
    [[ ${ANTIGRAVITY_CLI_URL} == https://*"/${ANTIGRAVITY_CLI_VERSION}-${ANTIGRAVITY_CLI_BUILD}/"* ]] \
      || fail "${test_arch} CLI URL is not an immutable version/build asset"
    [[ ${ANTIGRAVITY_ARCHIVE_SHA256} =~ ^[[:xdigit:]]{64}$ ]] \
      || fail "${test_arch} desktop archive SHA-256 is invalid"
    [[ ${ANTIGRAVITY_BINARY_SHA256} =~ ^[[:xdigit:]]{64}$ ]] \
      || fail "${test_arch} desktop binary SHA-256 is invalid"
    [[ ${ANTIGRAVITY_CLI_ARCHIVE_SHA512} =~ ^[[:xdigit:]]{128}$ ]] \
      || fail "${test_arch} CLI archive SHA-512 is invalid"
    [[ ${ANTIGRAVITY_CLI_BINARY_SHA256} =~ ^[[:xdigit:]]{64}$ ]] \
      || fail "${test_arch} CLI binary SHA-256 is invalid"
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

test_fedora_opencode_pins() (
  load_helpers setup-fedora-workstation.sh
  local optimized_asset optimized_sha baseline_asset baseline_sha arm_asset arm_sha
  grep() { return 0; }
  select_fedora_artifacts x86_64
  optimized_asset=${OPENCODE_ASSET}
  optimized_sha=${OPENCODE_ARCHIVE_SHA256}
  [[ ${optimized_asset} == opencode-linux-x64.tar.gz ]] \
    || fail 'Fedora AVX2 OpenCode asset is not the optimized x64 build'

  grep() { return 1; }
  select_fedora_artifacts x86_64
  baseline_asset=${OPENCODE_ASSET}
  baseline_sha=${OPENCODE_ARCHIVE_SHA256}
  [[ ${baseline_asset} == opencode-linux-x64-baseline.tar.gz ]] \
    || fail 'Fedora non-AVX2 OpenCode asset is not the x64 baseline build'
  [[ ${baseline_sha} != "${optimized_sha}" ]] \
    || fail 'Fedora optimized and baseline OpenCode assets share a checksum'

  select_fedora_artifacts aarch64
  arm_asset=${OPENCODE_ASSET}
  arm_sha=${OPENCODE_ARCHIVE_SHA256}
  [[ ${arm_asset} == opencode-linux-arm64.tar.gz ]] \
    || fail 'Fedora aarch64 OpenCode asset is incorrect'

  local asset sha
  for asset in "${optimized_asset}" "${baseline_asset}" "${arm_asset}"; do
    [[ ${asset} == opencode-linux-*.tar.gz ]] || fail "unexpected OpenCode asset: ${asset}"
  done
  for sha in "${optimized_sha}" "${baseline_sha}" "${arm_sha}"; do
    [[ ${sha} =~ ^[[:xdigit:]]{64}$ ]] || fail 'an OpenCode archive SHA-256 is invalid'
  done
  [[ ${OPENCODE_URL} == "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${arm_asset}" ]] \
    || fail 'Fedora OpenCode URL is not pinned to the configured version and asset'
)

test_fedora_zed_pins() (
  load_helpers setup-fedora-workstation.sh
  [[ ${ZED_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail 'Fedora Zed version is not pinned to a release'
  local test_arch expected_zed_arch x86_sha=
  for test_arch in x86_64 aarch64; do
    select_fedora_artifacts "${test_arch}"
    expected_zed_arch=${test_arch}
    [[ ${ZED_ARCH} == "${expected_zed_arch}" ]] \
      || fail "${test_arch} selects unexpected Zed architecture ${ZED_ARCH}"
    [[ ${ZED_URL} == "https://github.com/zed-industries/zed/releases/download/v${ZED_VERSION}/zed-linux-${expected_zed_arch}.tar.gz" ]] \
      || fail "${test_arch} Zed URL is not the pinned official release asset"
    [[ ${ZED_ARCHIVE_SHA256} =~ ^[[:xdigit:]]{64}$ ]] \
      || fail "${test_arch} Zed archive SHA-256 is invalid"
    if [[ ${test_arch} == x86_64 ]]; then
      x86_sha=${ZED_ARCHIVE_SHA256}
    else
      [[ ${ZED_ARCHIVE_SHA256} != "${x86_sha}" ]] \
        || fail 'x86_64 and aarch64 Zed assets share a checksum'
    fi
  done
)

test_fedora_converged_native_installs() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/converged/work
  local install_dir=${TEST_ROOT}/converged/Antigravity
  local bin_dir=${TEST_ROOT}/converged/bin
  local link_calls=0 desktop_calls=0
  install -d "${WORK_DIR}" "${install_dir}/resources" "${bin_dir}"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${install_dir}/antigravity"
  chmod 0755 "${install_dir}/antigravity"
  printf 'verified application bundle fixture\n' >"${install_dir}/resources/app.asar"
  printf '%s\n' \
    'managed-by=lan-ipxe/setup-fedora-workstation.sh' \
    "version=${ANTIGRAVITY_VERSION}" \
    "archive-sha256=${ANTIGRAVITY_ARCHIVE_SHA256}" \
    "app-asar-sha256=${ANTIGRAVITY_APP_ASAR_SHA256}" \
    >"${install_dir}/.lan-ipxe-release"
  printf '#!/usr/bin/env sh\nprintf "%%s\\n" "%s"\n' \
    "${ANTIGRAVITY_CLI_VERSION}" >"${bin_dir}/agy"
  chmod 0755 "${bin_dir}/agy"
  sha256sum() {
    case ${*: -1} in
      "${install_dir}/antigravity") printf '%s  %s\n' "${ANTIGRAVITY_BINARY_SHA256}" "${*: -1}" ;;
      "${install_dir}/resources/app.asar") printf '%s  %s\n' "${ANTIGRAVITY_APP_ASAR_SHA256}" "${*: -1}" ;;
      "${bin_dir}/agy")             printf '%s  %s\n' "${ANTIGRAVITY_CLI_BINARY_SHA256}" "${*: -1}" ;;
      *)                             fail "unexpected converged-install hash target: ${*: -1}" ;;
    esac
  }
  curl() { fail 'a converged native Antigravity install attempted a download'; }
  ensure_symlink() {
    [[ $* == "-s ${install_dir}/antigravity ${ANTIGRAVITY_COMMAND_LINK}" ]] \
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

test_fedora_converged_opencode() (
  load_helpers setup-fedora-workstation.sh
  select_fedora_artifacts x86_64
  WORK_DIR=${TEST_ROOT}/converged-opencode/work
  local bin_dir=${TEST_ROOT}/converged-opencode/bin
  install -d "${WORK_DIR}" "${bin_dir}"
  printf '#!/usr/bin/env sh\nprintf "%%s\\n" "%s"\n' \
    "${OPENCODE_VERSION}" >"${bin_dir}/opencode"
  chmod 0755 "${bin_dir}/opencode"
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

test_fedora_zed_checksum_rejection() {
  local rc=0 install_dir=${TEST_ROOT}/bad-zed/home/.local/zed.app
  (
    load_helpers setup-fedora-workstation.sh
    select_fedora_artifacts x86_64
    WORK_DIR=${TEST_ROOT}/bad-zed/work
    HOME=${TEST_ROOT}/bad-zed/home
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
    [[ $* == '-q --quiet antigravity' ]] || return 97
    (( rpm_installed == 1 ))
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
  test_fedora_release_pins
  printf 'PASS Fedora Antigravity desktop/CLI release pins\n'
  test_fedora_developer_catalog
  printf 'PASS Fedora signed developer-package repositories and command postconditions\n'
  test_fedora_key_fingerprint_enforcement
  printf 'PASS Fedora signing-key fingerprint enforcement\n'
  test_fedora_opencode_pins
  printf 'PASS Fedora optimized/baseline/aarch64 OpenCode release pins\n'
  test_fedora_zed_pins
  printf 'PASS Fedora x86_64/aarch64 Zed release pins\n'
  test_fedora_converged_native_installs
  printf 'PASS Fedora verified native desktop/CLI convergence\n'
  test_fedora_converged_opencode
  printf 'PASS Fedora verified native OpenCode convergence\n'
  test_fedora_converged_zed
  printf 'PASS Fedora verified native Zed convergence\n'
  test_fedora_checksum_rejection desktop
  test_fedora_checksum_rejection cli
  test_fedora_checksum_rejection opencode
  printf 'PASS Fedora desktop/CLI/OpenCode corrupt-archive rejection\n'
  test_fedora_zed_checksum_rejection
  printf 'PASS Fedora Zed corrupt-archive rejection without installation mutation\n'
  test_fedora_known_repo_removal
  test_fedora_custom_repo_preservation
  printf 'PASS Fedora known/customized legacy repository handling\n'
  test_fedora_legacy_rpm_removal
  test_fedora_legacy_rpm_noop
  printf 'PASS Fedora legacy Antigravity RPM purge convergence\n'
  test_fedora_known_settings_removal
  test_fedora_custom_settings_preservation
  printf 'PASS Fedora known/customized legacy IDE settings handling\n'
  test_legacy_payloads_retired
  printf 'PASS Antigravity 1.x repository/settings payload retirement\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
