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
      '--dry-run --check' '--bogus'; do
    rc=0
    # shellcheck disable=SC2086
    out=$(run_script x86_64 ${args} 2>&1 >/dev/null) || rc=$?
    [[ ${rc} == 1 ]] || fail "'${args}' exited ${rc}, expected 1"
    [[ ${out} == *Usage:* ]] || fail "'${args}' did not print usage on stderr"
  done
  out=$(run_script x86_64 --help) || fail '--help failed'
  [[ ${out} == *'--profile core|full'* && ${out} == *--no-upgrade* ]] \
    || fail '--help does not document the profile and upgrade flags'
  out=$(run_script x86_64 --dry-run)
  [[ ${out} == 'Profile: core; mode: dry-run'* ]] || fail 'default profile is not core'
  out=$(run_script x86_64 --dry-run --profile full --no-upgrade)
  [[ ${out} == 'Profile: full; mode: dry-run'* && ${out} == *'skipped (--no-upgrade)'* ]] \
    || fail 'full/--no-upgrade flags were not honored in any order'
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
          clang golang nodejs cockpit-machines cockpit-podman transmission-cli; do
        has_line "${item}" "${pkgs}" || fail "${arch}/${profile}: omits core package ${item}"
      done
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
        fi
      else
        for item in steam plexmediaserver powershell glibc-devel.i686; do
          ! has_line "${item}" "${pkgs}" || fail "aarch64/${profile}: requests x86_64-only ${item}"
        done
        has_line pwsh "${tools}" || fail "aarch64/${profile}: omits release-tarball PowerShell"
      fi
    done
  done
}

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

test_argument_parsing
printf 'PASS Fedora profile/mode argument parsing and core default\n'
test_profile_selection
printf 'PASS Fedora core/full package, Flatpak, service and repo selection (x86_64 + aarch64)\n'
test_dry_run_is_offline
printf 'PASS Fedora dry-run makes no sudo, package-manager, network, or HOME writes\n'
test_distro_rust_purge
printf 'PASS Fedora purges installed distro Rust packages before rustup\n'
