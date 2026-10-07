#!/usr/bin/env bash
# Mocked, CI-safe checks for setup-fedora-workstation.sh profiles and modes.
# Every external command the script could mutate through is shimmed to log and
# fail, so a passing run proves --dry-run stayed offline and read-only.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${REPO_ROOT}/setup-fedora-workstation.sh
TEST_ROOT=$(mktemp -d -p "${TMPDIR:-/var/tmp}" fedora-profiles.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() { printf 'ASSERT: %s\n' "$*" >&2; exit 1; }

SHIMS=${TEST_ROOT}/bin
CALLS=${TEST_ROOT}/calls
FAKE_HOME=${TEST_ROOT}/home
mkdir -p "${SHIMS}"
for command_name in sudo curl wget dnf flatpak rpm git systemctl rustup-init; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "${command_name}" "${CALLS}" \
    >"${SHIMS}/${command_name}"
  chmod +x "${SHIMS}/${command_name}"
done
printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_ARCH:?}"\n' >"${SHIMS}/uname"
chmod +x "${SHIMS}/uname"

run_script() {
  local arch=$1
  shift
  HOME=${FAKE_HOME} FAKE_ARCH=${arch} PATH="${SHIMS}:${PATH}" \
    bash "${SCRIPT}" "$@"
}

# Print the indented entries of one PLAN section from dry-run output.
plan_section() {
  awk -v header="$1" '
    index($0, "PLAN: ") == 1 { on = (index($0, header) > 0); next }
    on && /^  / { sub(/^  /, ""); print }
  ' <<<"$2"
}

has_line() { grep -Fxq -- "$1" <<<"$2"; }

test_argument_parsing() {
  local rc out
  for args in '--profile' '--profile other' '--check --dry-run' \
      '--dry-run --check' '--bogus' '--wazuh-manager'; do
    rc=0
    # shellcheck disable=SC2086
    out=$(run_script x86_64 ${args} 2>&1 >/dev/null) || rc=$?
    [[ ${rc} == 1 ]] || fail "'${args}' exited ${rc}, expected 1"
    [[ ${out} == *Usage:* ]] || fail "'${args}' did not print usage on stderr"
  done
  out=$(run_script x86_64 --help) || fail '--help failed'
  [[ ${out} == *'--profile core|full'* && ${out} == *--no-upgrade* \
     && ${out} == *--wazuh-manager* ]] \
    || fail '--help does not document the profile, upgrade and wazuh flags'
  out=$(run_script x86_64 --dry-run)
  [[ ${out} == 'Profile: core; mode: dry-run'* ]] || fail 'default profile is not core'
  out=$(run_script x86_64 --dry-run --profile full --no-upgrade)
  [[ ${out} == 'Profile: full; mode: dry-run'* && ${out} == *'skipped (--no-upgrade)'* ]] \
    || fail 'full/--no-upgrade flags were not honored in any order'
  out=$(run_script x86_64 --dry-run --wazuh-manager wazuh.lan)
  [[ ${out} == *'configured for wazuh.lan and enabled'* ]] \
    || fail '--wazuh-manager did not change the Wazuh plan'
  if run_script x86_64 --dry-run --wazuh-manager 'not a host' >/dev/null 2>&1; then
    fail 'an invalid --wazuh-manager value was accepted'
  fi
}

test_profile_selection() {
  local arch profile out pkgs flatpaks services repos tools item
  for arch in x86_64 aarch64; do
    for profile in core full; do
      out=$(run_script "${arch}" --profile "${profile}" --dry-run)
      pkgs=$(plan_section 'dnf install' "${out}")
      flatpaks=$(plan_section 'flatpaks' "${out}")
      services=$(plan_section 'enable' "${out}" | grep -E '\.(service|socket|timer)$' || true)
      repos=$(plan_section 'repositories' "${out}")
      tools=$(plan_section 'native vendor tools' "${out}")
      [[ -n ${pkgs} && -n ${flatpaks} && -n ${services} ]] \
        || fail "${arch}/${profile}: dry-run plan sections are empty"

      # Rust comes from rustup only, in every profile.
      for item in rust cargo clippy rustfmt rust-analyzer; do
        ! has_line "${item}" "${pkgs}" || fail "${arch}/${profile}: requests distro ${item}"
      done
      has_line rustup "${pkgs}" || fail "${arch}/${profile}: omits the rustup package"
      # r8152 support is gone; dkms/mokutil existed only for it.
      for item in dkms mokutil; do
        ! has_line "${item}" "${pkgs}" || fail "${arch}/${profile}: still requests ${item}"
      done
      [[ ${out} != *r8152* ]] || fail "${arch}/${profile}: plan still mentions r8152"

      # Core developer surface, present in both profiles.
      for item in balun tributary chromium google-chrome-stable code \
          clang golang nodejs cockpit-machines cockpit-podman transmission-cli \
          aide audit clamav clamav-update clamd firewalld; do
        has_line "${item}" "${pkgs}" || fail "${arch}/${profile}: omits core package ${item}"
      done
      # Security layer: rendered configs and static payloads in every profile.
      for item in etc/audit/rules.d/50-workstation.rules etc/aide.conf \
          etc/firewalld/zones/workstation.xml \
          etc/systemd/system/clamav-media-scan.service \
          etc/systemd/system/aide-check.timer; do
        grep -Fq "files/${item} -> /${item}" <<<"${out}" \
          || fail "${arch}/${profile}: managed-file plan omits ${item}"
      done
      [[ ${out} == *'workstation-lan source zone'* ]] \
        || fail "${arch}/${profile}: plan omits the LAN zone"
      grep -A1 'workstation-lan source zone' <<<"${out}" \
        | grep -Fq 'cockpit rdp ipp-client mdns iperf3' \
        || fail "${arch}/${profile}: core LAN services are wrong"
      ! grep -Fq 'wazuh-agent' <<<"${pkgs}" \
        || fail "${arch}/${profile}: wazuh-agent must install from its own (pinned) repo step"
      for item in copr:copr.fedorainfracloud.org:jmsqrd:balun \
          copr:copr.fedorainfracloud.org:jmsqrd:tributary; do
        has_line "${item}" "${repos}" || fail "${arch}/${profile}: omits core repo ${item}"
      done
      for item in antigravity agy opencode claude codex zed speedtest; do
        has_line "${item}" "${tools}" || fail "${arch}/${profile}: omits tool ${item}"
      done
      # Claude Code self-updates natively; its RPM repo and the unused NVIDIA repo are retired.
      for item in claude-code rpmfusion-nonfree-nvidia-driver; do
        ! has_line "${item}" "${pkgs}" || fail "${arch}/${profile}: still requests package ${item}"
        ! has_line "${item}" "${repos}" || fail "${arch}/${profile}: still enables repo ${item}"
      done
      has_line net.nokyan.Resources "${flatpaks}" \
        || fail "${arch}/${profile}: omits the core Resources Flatpak"

      if [[ ${profile} == core ]]; then
        for item in lutris steam rhythmbox brasero transmission transmission-gtk \
            transmission-daemon transmission-remote-gtk plexmediaserver glibc-devel.i686; do
          ! has_line "${item}" "${pkgs}" || fail "${arch}/core: requests ${item}"
        done
        ! grep -q '^io\.jor\.' <<<"${flatpaks}" || fail "${arch}/core: requests game Flatpaks"
        for item in navidrome owntone; do
          ! has_line "${item}" "${tools}" || fail "${arch}/core: installs ${item}"
          ! has_line "${item}.service" "${services}" || fail "${arch}/core: enables ${item}"
        done
        ! has_line rpmfusion-nonfree-steam "${repos}" || fail "${arch}/core: enables the Steam repo"
      else
        for item in lutris rhythmbox brasero transmission-gtk transmission-daemon; do
          has_line "${item}" "${pkgs}" || fail "${arch}/full: omits ${item}"
        done
        has_line io.jor.bugdom "${flatpaks}" || fail "${arch}/full: omits game Flatpaks"
        for item in navidrome owntone; do
          has_line "${item}" "${tools}" || fail "${arch}/full: omits ${item}"
          has_line "${item}.service" "${services}" || fail "${arch}/full: omits ${item}.service"
        done
      fi

      if [[ ${arch} == x86_64 ]]; then
        has_line powershell "${pkgs}" || fail "x86_64/${profile}: omits the PowerShell RPM"
        if [[ ${profile} == full ]]; then
          for item in steam plexmediaserver glibc-devel.i686; do
            has_line "${item}" "${pkgs}" || fail "x86_64/full: omits ${item}"
          done
          has_line rpmfusion-nonfree-steam "${repos}" || fail 'x86_64/full: omits the Steam repo'
          # Full-only LAN services are gated on the services their profile
          # actually installs.
          lan_services=$(grep -A1 'workstation-lan source zone' <<<"${out}" | tail -1)
          for item in navidrome owntone transmission plexmediaserver steam-streaming; do
            grep -Fqw "${item}" <<<"${lan_services}" \
              || fail "x86_64/full: LAN zone omits ${item}"
          done
        fi
      else
        for item in steam plexmediaserver powershell glibc-devel.i686; do
          ! has_line "${item}" "${pkgs}" || fail "aarch64/${profile}: requests x86_64-only ${item}"
        done
        has_line pwsh "${tools}" || fail "aarch64/${profile}: omits release-tarball PowerShell"
        if [[ ${profile} == full ]]; then
          lan_services=$(grep -A1 'workstation-lan source zone' <<<"${out}" | tail -1)
          for item in navidrome owntone transmission; do
            grep -Fqw "${item}" <<<"${lan_services}" \
              || fail "aarch64/full: LAN zone omits ${item}"
          done
          for item in plexmediaserver steam-streaming; do
            ! grep -Fqw "${item}" <<<"${lan_services}" \
              || fail "aarch64/full: LAN zone opens x86_64-only ${item}"
          done
        fi
      fi
    done
  done
}

# Every MANAGED_FILES entry (across both profiles and architectures) must
# have a matching apply-time put_file call. Fedora's entries carry no mode
# field, so the libexec helper's explicit 0755 is accepted alongside the
# default; line continuations are joined and runs of spaces collapsed first.
test_managed_files_are_applied() (
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
  local seen='' entry src dst flag profile arch
  for arch in x86_64 aarch64; do
    for profile in core full; do
# shellcheck disable=SC2034  # consumed by the sourced select_profile
      PROFILE=${profile} ARCH=${arch}
# shellcheck disable=SC2034  # consumed by the sourced select_profile
      [[ ${arch} == x86_64 ]] && IS_X86_64=1 || IS_X86_64=0
      select_profile
      for entry in "${MANAGED_FILES[@]}"; do
        grep -Fxq -- "${entry}" <<<"${seen}" && continue
        seen+="${entry}"$'\n'
        src=${entry%%|*}
        dst=${entry#*|}
        flag='-s '
        [[ ${dst} == "${HOME}"/* ]] && flag=''
        dst=${dst/#"${HOME}"/'"${HOME}'}
        [[ ${dst} == '"${HOME}'* ]] && dst+='"'
        awk -v want="put_file ${flag}\"\${FILES}/${src}\" ${dst}" '
          {
            if (sub(/\\$/, "")) { joined = joined $0; next }
            line = joined $0; joined = ""
            sub(/^ +/, "", line)
            gsub(/  +/, " ", line)
            if (line == want || line == (want " 0755")) found = 1
          }
          END { exit !found }
        ' "${SCRIPT}" || fail "managed file ${src} has no matching apply-time put_file"
      done
    done
  done
)

test_dry_run_is_offline() {
  : >"${CALLS}"
  run_script aarch64 --profile full --dry-run >/dev/null
  run_script x86_64 --dry-run --no-upgrade >/dev/null
  [[ ! -s ${CALLS} ]] || fail "dry-run invoked external commands: $(tr '\n' ';' <"${CALLS}")"
  [[ ! -e ${FAKE_HOME} ]] || fail 'dry-run wrote under HOME'
}

test_distro_rust_purge() (
  local rust_db=${TEST_ROOT}/installed-rust log=${TEST_ROOT}/rust-calls
  printf '%s\n' rust cargo rust-std-static >"${rust_db}"
  : >"${log}"
  # Only the helper definitions: everything before the preflight marker.
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
  rpm() { [[ $1 == -q && $2 == --quiet ]] && grep -Fxq -- "$4" "${rust_db}"; }
  sudo() {
    printf '%s\n' "$*" >>"${log}"
    [[ $1 == dnf && $3 == remove ]] && : >"${rust_db}"
  }
  purge_distro_rust >/dev/null
  [[ $(cat "${log}") == 'dnf -y remove rust cargo rust-std-static' ]] \
    || fail "unexpected purge transaction: $(cat "${log}")"
  : >"${log}"
  purge_distro_rust >/dev/null
  [[ ! -s ${log} ]] || fail 'purge ran again with no distro Rust installed'
)

# Fedora 45: protobuf3-c obsoletes protobuf-c; the repair must bypass both the
# obsolete and the persistent exclude, and do nothing once converged.
test_protobuf_c_restore() (
  local db=${TEST_ROOT}/installed-protobuf log=${TEST_ROOT}/protobuf-calls
  printf '%s\n' protobuf3-c >"${db}"
  : >"${log}"
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
  rpm() { [[ $1 == -q && $2 == --quiet ]] && grep -Fxq -- "$3" "${db}"; }
  sudo() {
    printf '%s\n' "$*" >>"${log}"
    [[ $* == *' swap protobuf3-c protobuf-c' ]] && printf 'protobuf-c\n' >"${db}"
  }
  restore_protobuf_c >/dev/null
  [[ $(cat "${log}") == "dnf -y --setopt=obsoletes=0 --setopt=disable_excludes=* swap protobuf3-c protobuf-c" ]] \
    || fail "unexpected protobuf-c repair: $(cat "${log}")"
  : >"${log}"
  restore_protobuf_c >/dev/null
  [[ ! -s ${log} ]] || fail 'protobuf-c repair ran again with protobuf3-c absent'
  grep -Fxq 'excludepkgs=protobuf3-c*' \
    "${REPO_ROOT}/files/etc/dnf/libdnf5.conf.d/80-protobuf3-c.conf" \
    || fail 'libdnf5 drop-in does not exclude protobuf3-c*'
)

# The rendered security configs must be deterministic: apply installs them and
# --check compares against the same rendering.
test_security_renders() (
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
  local base=${REPO_ROOT}/files/etc/clamd.d/scan.conf
  local out1 out2 out_core out_full
  out1=$(render_clamd_config "${base}" /home/alice/Downloads)
  out2=$(render_clamd_config "${base}" /home/alice/Downloads)
  [[ ${out1} == "${out2}" ]] || fail 'render_clamd_config is not deterministic'
  cmp -s <(cat -- "${base}") <(printf '%s\n' "${out1}" | head -n "$(wc -l <"${base}")") \
    || fail 'render_clamd_config does not start with the checked-in base'
  grep -Fxq 'OnAccessIncludePath /home/alice/Downloads' <<<"${out1}" \
    || fail 'render_clamd_config omits the Downloads include'
  # The base itself must not pre-watch /home (Downloads-only design).
  ! grep -q '^OnAccessIncludePath' "${base}" \
    || fail 'the checked-in clamd base config carries its own include paths'

# shellcheck disable=SC2034  # read by the sourced helpers
  PROFILE=core
  select_profile
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
  grep -Fq '<service name="cockpit"/>' <<<"${out_core}" \
    || fail 'core LAN zone omits cockpit'
  grep -Fq '<service name="iperf3"/>' <<<"${out_core}" \
    || fail 'core LAN zone omits iperf3 (shipped in the core package set)'
  ! grep -Fq '<service name="transmission"/>' <<<"${out_core}" \
    || fail 'core LAN zone opens transmission (full-profile only)'
  grep -Fq '<source address="192.168.2.0/23"/>' <<<"${out_core}" \
    || fail 'LAN zone omits the SD-WAN source'
# shellcheck disable=SC2034  # read by the sourced helpers
  PROFILE=full
  select_profile
  out_full=$(render_lan_zone "${FIREWALL_LAN_SERVICES[@]}")
  for item in navidrome owntone transmission; do
    grep -Fq "<service name=\"${item}\"/>" <<<"${out_full}" \
      || fail "full LAN zone omits ${item}"
  done
  if [[ $(uname -m) == x86_64 ]]; then
    for item in plexmediaserver steam-streaming; do
      grep -Fq "<service name=\"${item}\"/>" <<<"${out_full}" \
        || fail "x86_64 full LAN zone omits ${item}"
    done
  else
    for item in plexmediaserver steam-streaming; do
      ! grep -Fq "<service name=\"${item}\"/>" <<<"${out_full}" \
        || fail "aarch64 full LAN zone opens x86_64-only ${item}"
    done
  fi
)

test_clamav_db_bootstrap() (
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
  local db=${TEST_ROOT}/clamav-db calls=${TEST_ROOT}/clamav-calls
  mkdir -p "${db}"
  : >"${calls}"
  systemctl() { return 1; }
  sudo() {
    printf 'sudo %s\n' "$*" >>"${calls}"
    case $1 in
      freshclam) touch "${db}/main.cvd" "${db}/daily.cvd" ;;
      restorecon) : ;;
    esac
    return 0
  }
  command() { [[ $1 == -v && $2 == restorecon ]] && return 0; return 1; }
  bootstrap_clamav_db "${db}" >/dev/null
  grep -qx 'sudo freshclam' "${calls}" || fail 'bootstrap did not run freshclam'
  grep -qx 'sudo restorecon -R '"${db}" "${calls}" \
    || fail 'Fedora bootstrap did not restorecon the database directory'
  : >"${calls}"
  bootstrap_clamav_db "${db}" >/dev/null
  [[ ! -s ${calls} ]] || fail 'bootstrap re-ran with the database present'
  # The running freshclam daemon holds the update lock and must be stopped.
  rm -f "${db}"/main.cvd "${db}"/daily.cvd
  : >"${calls}"
  systemctl() { [[ $1 == is-active && $3 == clamav-freshclam.service ]] && return 0; return 1; }
  bootstrap_clamav_db "${db}" >/dev/null
  grep -qx 'sudo systemctl stop clamav-freshclam.service' "${calls}" \
    || fail 'bootstrap did not stop the running freshclam daemon'
)

test_ensure_started_unit() (
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
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
    systemctl $2
    return 0
  }
  ensure_started_unit 'clamd@scan.service' 0 >/dev/null
  [[ $(<"${calls}") == 'systemctl start clamd@scan.service' ]] \
    || fail 'an inactive unit was not started'
  : >"${calls}"
  active=0
  ensure_started_unit 'clamd@scan.service' 0 >/dev/null
  [[ ! -s ${calls} ]] || fail 'an unchanged active unit was touched'
  ensure_started_unit 'clamd@scan.service' 1 >/dev/null
  [[ $(<"${calls}") == 'systemctl restart clamd@scan.service' ]] \
    || fail 'a changed active unit was not restarted'
)

test_wazuh_manager_gating() (
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${SCRIPT}")
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
printf 'PASS Fedora profile/mode argument parsing and core default\n'
test_profile_selection
printf 'PASS Fedora core/full package, Flatpak, service and repo selection (x86_64 + aarch64)\n'
test_managed_files_are_applied
printf 'PASS Fedora managed-file list matches apply-time put_file calls\n'
test_dry_run_is_offline
printf 'PASS Fedora dry-run makes no sudo, package-manager, network, or HOME writes\n'
test_distro_rust_purge
printf 'PASS Fedora purges installed distro Rust packages before rustup\n'
test_protobuf_c_restore
printf 'PASS Fedora swaps an obsoleting protobuf3-c back to protobuf-c once\n'
test_security_renders
printf 'PASS Fedora deterministic clamd/LAN-zone rendering with profile gating\n'
test_clamav_db_bootstrap
printf 'PASS Fedora ClamAV database bootstrap (lock handling, restorecon, one-time)\n'
test_ensure_started_unit
printf 'PASS Fedora start-now/restart-on-change unit reconciliation\n'
test_wazuh_manager_gating
printf 'PASS Fedora manager-gated Wazuh configuration and enablement\n'