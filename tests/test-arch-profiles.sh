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
  for package in google-chrome balun-bin tributary-bin powershell-bin android-studio; do
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
  # The security checks render files under ${FILES}, which resolves to a
  # /dev/fd path inside load_helpers; they are covered by their own tests.
  check_security_state() { report CURRENT 'security state'; }
  RUSTUP_HOME=${TEST_ROOT}/rustup
  mkdir -p "${RUSTUP_HOME}/toolchains/${RUST_TOOLCHAIN}/lib/rustlib"
  printf 'default_toolchain = "stable-x86_64-unknown-linux-gnu"\n' >"${RUSTUP_HOME}/settings.toml"
  printf 'rustc-x86_64\nrustfmt-preview-x86_64\nclippy-preview-x86_64\nrust-analyzer-preview-x86_64\n' \
    >"${RUSTUP_HOME}/toolchains/${RUST_TOOLCHAIN}/lib/rustlib/components"
  # Native self-updating AI tools live under a fixture home and install root.
  HOME=${TEST_ROOT}/check-home
  ANTIGRAVITY_INSTALL_DIR=${TEST_ROOT}/check-Antigravity
  mkdir -p "${HOME}/.local/bin" "${ANTIGRAVITY_INSTALL_DIR}"
  local tool
  for tool in "${ANTIGRAVITY_INSTALL_DIR}/Antigravity.AppImage" \
      "${HOME}/.local/bin/agy" "${HOME}/.local/bin/claude" "${HOME}/.local/bin/codex"; do
    printf '#!/bin/sh\n' >"${tool}"
    chmod 0755 "${tool}"
  done
  installed=' '
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
  installed=' rust mkinitcpio '
  rc=0; output=$(run_check) || rc=$?
  [[ ${rc} == 2 && ${output} == *'distro Rust: rust installed'* && ${output} == *mkinitcpio* ]] \
    || fail 'check did not flag distro Rust / mkinitcpio'
  installed=' claude-code '
  rc=0; output=$(run_check) || rc=$?
  [[ ${rc} == 2 && ${output} == *'claude-code: installed (replaced by a self-updating native install)'* ]] \
    || fail 'check did not flag the retired claude-code package'
  rm -f -- "${HOME}/.local/bin/claude"
  installed=' '
  rc=0; output=$(run_check) || rc=$?
  [[ ${rc} == 2 && ${output} == *'native claude: missing'* ]] \
    || fail 'check did not flag a missing native claude'
  printf '#!/bin/sh\n' >"${HOME}/.local/bin/claude"
  chmod 0755 "${HOME}/.local/bin/claude"
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

# The rendered security configs must be deterministic: apply installs them and
# --check compares against the same rendering.
test_security_renders() (
  load_helpers
  local base=${REPO_ROOT}/files/etc/clamav/clamd.conf
  local out_core out_full
  local out1 out2
  out1=$(render_clamd_config "${base}" /home/alice/Downloads /home/bob/Downloads)
  out2=$(render_clamd_config "${base}" /home/alice/Downloads /home/bob/Downloads)
  [[ ${out1} == "${out2}" ]] || fail 'render_clamd_config is not deterministic'
  cmp -s <(cat -- "${base}") <(printf '%s\n' "${out1}" | head -n "$(wc -l <"${base}")") \
    || fail 'render_clamd_config does not start with the checked-in base'
  grep -Fxq 'OnAccessIncludePath /home/alice/Downloads' <<<"${out1}" \
    || fail 'render_clamd_config omits the first Downloads include'
  grep -Fxq 'OnAccessIncludePath /home/bob/Downloads' <<<"${out1}" \
    || fail 'render_clamd_config omits the second Downloads include'

  select_profile core
  out_core=$(render_lan_zone "${FIREWALL_LAN_SERVICES[@]}")
  # firewalld puts each packet in exactly one zone: without ssh here, LAN
  # peers would be rejected instead of falling through to the default zone.
  grep -Fq '<service name="ssh"/>' <<<"${out_core}" \
    || fail 'core LAN zone omits ssh (LAN peers would be rejected)'
  # Hand-run servers on these hosts open in every profile.
  for item in lancache nfs mountd rpc-bind samba; do
    grep -Fq "<service name=\"${item}\"/>" <<<"${out_core}" \
      || fail "core LAN zone omits ${item}"
  done
  # Arch hosts run the media servers by hand, so every profile opens them.
  for item in plexmediaserver navidrome owntone transmission iperf3; do
    grep -Fq "<service name=\"${item}\"/>" <<<"${out_core}" \
      || fail "Arch core LAN zone omits ${item}"
  done
  grep -Fq '<service name="cockpit"/>' <<<"${out_core}" \
    || fail 'core LAN zone omits cockpit'
  grep -Fq '<service name="rdp"/>' <<<"${out_core}" \
    || fail 'core LAN zone omits rdp (GNOME Remote Desktop)'
  grep -Fq '<service name="ipp-client"/>' <<<"${out_core}" \
    || fail 'core LAN zone omits printer discovery'
  grep -Fq '<service name="mdns"/>' <<<"${out_core}" \
    || fail 'core LAN zone omits mdns'
  ! grep -Fq '<service name="steam-streaming"/>' <<<"${out_core}" \
    || fail 'core LAN zone opens Steam streaming'
  grep -Fq '<source address="192.168.1.0/24"/>' <<<"${out_core}" \
    || fail 'LAN zone omits the LAN source'
  grep -Fq '<source address="192.168.2.0/23"/>' <<<"${out_core}" \
    || fail 'LAN zone omits the SD-WAN source'
  select_profile full
  out_full=$(render_lan_zone "${FIREWALL_LAN_SERVICES[@]}")
  grep -Fq '<service name="steam-streaming"/>' <<<"${out_full}" \
    || fail 'full LAN zone omits Steam streaming'
)

test_clamav_db_bootstrap() (
  load_helpers
  local db=${TEST_ROOT}/clamav-db calls=${TEST_ROOT}/clamav-calls
  mkdir -p "${db}"
  : >"${calls}"
  systemctl() { return 1; }
  sudo() {
    printf 'sudo %s\n' "$*" >>"${calls}"
    [[ $1 == freshclam ]] && touch "${db}/main.cld" "${db}/daily.cld"
    return 0
  }
  bootstrap_clamav_db "${db}" >/dev/null
  [[ $(<"${calls}") == 'sudo freshclam' ]] \
    || fail "unexpected Arch bootstrap calls: $(<"${calls}")"
  : >"${calls}"
  bootstrap_clamav_db "${db}" >/dev/null
  [[ ! -s ${calls} ]] || fail 'bootstrap re-ran with the database present'
  # The freshclam daemon holds the update lock and must be stopped first.
  rm -f "${db}"/main.cld "${db}"/daily.cld
  : >"${calls}"
  systemctl() { [[ $1 == is-active && $3 == clamav-freshclam.service ]] && return 0; return 1; }
  bootstrap_clamav_db "${db}" >/dev/null
  grep -qx 'sudo systemctl stop clamav-freshclam.service' "${calls}" \
    || fail 'bootstrap did not stop the running freshclam daemon'
  grep -qx 'sudo freshclam' "${calls}" \
    || fail 'bootstrap did not run freshclam after stopping the daemon'
)

test_ensure_started_unit() (
  load_helpers
  local calls=${TEST_ROOT}/ensure-calls active=1
  : >"${calls}"
  systemctl() {
    case $1 in
      is-active) return "${active}" ;;
      start|restart) active=0; return 0 ;;
    esac
    return 0
  }
  sudo() {
    printf '%s\n' "$*" >>"${calls}"
    # Run the (mocked) privileged command so start/restart flips the state.
    systemctl $2
    return 0
  }
  ensure_started_unit clamav-daemon.service 0 >/dev/null
  [[ $(<"${calls}") == 'systemctl start clamav-daemon.service' ]] \
    || fail 'an inactive unit was not started'
  : >"${calls}"
  active=0
  ensure_started_unit clamav-daemon.service 0 >/dev/null
  [[ ! -s ${calls} ]] || fail 'an unchanged active unit was touched'
  ensure_started_unit clamav-daemon.service 1 >/dev/null
  [[ $(<"${calls}") == 'systemctl restart clamav-daemon.service' ]] \
    || fail 'a changed active unit was not restarted'
)

test_wazuh_manager_gating() (
  load_helpers
  local conf=${TEST_ROOT}/wazuh-ossec.conf calls=${TEST_ROOT}/wazuh-calls
  cat >"${conf}" <<'EOF'
<ossec_conf>
  <client>
    <server>
      <address>0.0.0.0</address>
      <port>1514</port>
    </server>
  </client>
</ossec_conf>
EOF
# shellcheck disable=SC2034  # read by the sourced helpers
  WAZUH_MANAGER=wazuh.lan
# shellcheck disable=SC2034  # read by the sourced helpers
  WORK_DIR=${TEST_ROOT}
  put_file() {
    [[ $1 == -s ]] && shift
    cp -- "$1" "$2"
    # shellcheck disable=SC2034
    PUT_FILE_CHANGED=1
  }
  configure_wazuh_agent "${conf}" >/dev/null
  grep -Fq '<address>wazuh.lan</address>' "${conf}" \
    || fail 'the manager address did not land in ossec.conf'
  grep -Fq '<location>/var/log/audit/audit.log</location>' "${conf}" \
    || fail 'audit log collection was not appended'
  grep -Fq '<log_format>journald</log_format>' "${conf}" \
    || fail 'ClamAV journald collection was not appended'
  grep -Fq '<location>clamav-media-scan.service</location>' "${conf}" \
    || fail 'the media-scan unit was not collected'
  [[ $(tail -n 1 "${conf}") == '</ossec_conf>' ]] \
    || fail 'the appended stanzas broke the ossec.conf structure'
  cp -- "${conf}" "${conf}.first"
  configure_wazuh_agent "${conf}" >/dev/null
  cmp -s "${conf}" "${conf}.first" \
    || fail 'configure_wazuh_agent is not idempotent'

  : >"${calls}"
  systemctl() { return 0; }
  sudo() { printf '%s\n' "$*" >>"${calls}"; }
  wazuh_service_action >/dev/null
  [[ $(<"${calls}") == 'systemctl enable --now wazuh-agent' ]] \
    || fail 'a configured manager did not enable+start wazuh-agent'
  : >"${calls}"
# shellcheck disable=SC2034  # read by the sourced helpers
  WAZUH_MANAGER=
  systemctl() {
    [[ $1 == is-active ]] && return 1
    [[ $1 == is-enabled ]] && return 0
    return 0
  }
  wazuh_service_action >/dev/null
  [[ $(<"${calls}") == 'systemctl disable --now wazuh-agent' ]] \
    || fail 'a missing manager did not disable an enabled wazuh-agent'
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
test_security_renders
printf 'PASS Arch deterministic clamd/LAN-zone rendering with profile gating\n'
test_clamav_db_bootstrap
printf 'PASS Arch ClamAV database bootstrap (lock handling, one-time)\n'
test_ensure_started_unit
printf 'PASS Arch start-now/restart-on-change unit reconciliation\n'
test_wazuh_manager_gating
printf 'PASS Arch manager-gated Wazuh configuration and enablement\n'
