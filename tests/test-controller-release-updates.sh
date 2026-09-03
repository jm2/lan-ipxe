#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTROLLER=${REPO_ROOT}/setup-fedora-controllers.sh
TEST_ROOT=$(mktemp -d /tmp/controller-release-updates.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'ASSERT: %s\n' "$*" >&2
  exit 1
}

[[ $(grep -c '^#--- Release-update helpers ' "${CONTROLLER}") == 1 ]] \
  || fail 'controller release helper start marker is missing or ambiguous'
[[ $(grep -c '^#--- End release-update helpers ' "${CONTROLLER}") == 1 ]] \
  || fail 'controller release helper end marker is missing or ambiguous'

# Globals and dependencies consumed by the dynamically extracted helpers.
# shellcheck disable=SC2034
MINIMUM_SAFE_UOS_VERSION=5.1.37
UOS_DOWNLOAD_PREFIX=https://fw-download.ubnt.com/data/unifi-os-server/
UOS_RELEASE_API_URL='https://fw-update.ui.com/api/firmware-latest?filter=eq~~product~~unifi-os-server&filter=eq~~platform~~linux-x64&filter=eq~~channel~~release'
log() { :; }
warn() { :; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
atomic_write_file() { # <target> <mode>; content on stdin
  local target=$1
  command cat >"${target}"
  chmod "$2" "${target}"
}
# shellcheck disable=SC1090
source <(sed -n '/^#--- Release-update helpers /,/^#--- End release-update helpers /p' \
  "${CONTROLLER}")

for helper in validate_uos_release_values configure_uos_release_mode \
  load_uos_release_metadata resolve_uos_bootstrap_release \
  check_os_update_reboot_requirement image_identity refresh_mutable_image \
  prune_dangling_images; do
  declare -F "${helper}" >/dev/null || fail "missing production helper ${helper}"
done

test_reboot_hint_statuses() (
  local expected_required expected_failed
  dnf() {
    [[ $* == 'needs-restarting -r' ]] \
      || fail "unexpected reboot-check command: dnf $*"
    return "${MOCK_DNF_STATUS}"
  }
  for MOCK_DNF_STATUS in 0 1 2; do
    case ${MOCK_DNF_STATUS} in
      0) expected_required=0; expected_failed=0 ;;
      1) expected_required=1; expected_failed=0 ;;
      2) expected_required=0; expected_failed=1 ;;
    esac
    check_os_update_reboot_requirement
    [[ ${OS_UPDATE_REBOOT_REQUIRED} == "${expected_required}" \
       && ${OS_UPDATE_REBOOT_CHECK_FAILED} == "${expected_failed}" ]] \
      || fail "reboot hint status ${MOCK_DNF_STATUS} was classified incorrectly"
  done
)

VALID_VERSION=9.8.7
VALID_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
VALID_SHA_UPPER=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
VALID_URL=${UOS_DOWNLOAD_PREFIX}abcd-linux-x64-9.8.7-01234567.7-x64
VALID_FIXTURE=${TEST_ROOT}/valid-release.json
cat >"${VALID_FIXTURE}" <<EOF
{
  "_embedded": {
    "firmware": [{
      "product": "unifi-os-server",
      "platform": "linux-x64",
      "channel": "release",
      "version": "v${VALID_VERSION}",
      "version_major": 9,
      "version_minor": 8,
      "version_patch": 7,
      "file_size": 123456789,
      "sha256_checksum": "${VALID_SHA_UPPER}",
      "_links": {"data": {"href": "${VALID_URL}"}}
    }]
  }
}
EOF

reset_release_state() {
  UOS_VERSION=
  UOS_INSTALLER_URL=
  UOS_INSTALLER_SHA256=
  # These flags are consumed by configure_uos_release_mode from the dynamic
  # source block above.
  # shellcheck disable=SC2034
  UOS_VERSION_OVERRIDE_SET=0
  # shellcheck disable=SC2034
  UOS_URL_OVERRIDE_SET=0
  # shellcheck disable=SC2034
  UOS_SHA256_OVERRIDE_SET=0
  UOS_RELEASE_MODE=
  UOS_RELEASE_METADATA_TMP=
}

expect_failure() {
  local description=$1
  shift
  if ( "$@" ) >"${TEST_ROOT}/unexpected.stdout" 2>"${TEST_ROOT}/expected.stderr"; then
    fail "${description} unexpectedly succeeded"
  fi
}

load_metadata_for_failure() {
  reset_release_state
  load_uos_release_metadata "$1"
}

BAD_INDEX=0
reject_metadata_mutation() {
  local description=$1 filter=$2 bad_fixture
  (( BAD_INDEX += 1 ))
  bad_fixture=${TEST_ROOT}/bad-${BAD_INDEX}.json
  jq "${filter}" "${VALID_FIXTURE}" >"${bad_fixture}"
  expect_failure "${description}" load_metadata_for_failure "${bad_fixture}"
}

test_valid_metadata() (
  reset_release_state
  load_uos_release_metadata "${VALID_FIXTURE}"
  [[ ${UOS_VERSION} == "${VALID_VERSION}" ]] \
    || fail 'valid metadata did not select the exact version'
  [[ ${UOS_INSTALLER_URL} == "${VALID_URL}" ]] \
    || fail 'valid metadata did not select the exact URL'
  [[ ${UOS_INSTALLER_SHA256} == "${VALID_SHA}" ]] \
    || fail 'valid metadata SHA-256 was not selected and normalized'
)

test_invalid_metadata() {
  local malformed=${TEST_ROOT}/malformed.json
  printf '{"_embedded":' >"${malformed}"
  expect_failure 'malformed JSON' load_metadata_for_failure "${malformed}"

  reject_metadata_mutation 'zero firmware results' '._embedded.firmware = []'
  reject_metadata_mutation 'duplicate firmware results' \
    '._embedded.firmware += [._embedded.firmware[0]]'
  reject_metadata_mutation 'wrong product' \
    '._embedded.firmware[0].product = "unifi-network-application"'
  reject_metadata_mutation 'wrong platform' \
    '._embedded.firmware[0].platform = "linux-arm64"'
  reject_metadata_mutation 'wrong release channel' \
    '._embedded.firmware[0].channel = "beta"'
  reject_metadata_mutation 'missing version' \
    'del(._embedded.firmware[0].version)'
  reject_metadata_mutation 'non-numeric version component' \
    '._embedded.firmware[0].version_patch = "7"'
  reject_metadata_mutation 'version/component mismatch' \
    '._embedded.firmware[0].version_patch = 8'
  reject_metadata_mutation 'release below security floor' \
    '._embedded.firmware[0].version = "v5.1.36"
     | ._embedded.firmware[0].version_major = 5
     | ._embedded.firmware[0].version_minor = 1
     | ._embedded.firmware[0].version_patch = 36
     | ._embedded.firmware[0]._links.data.href |= sub("9.8.7"; "5.1.36")'
  reject_metadata_mutation 'short checksum' \
    '._embedded.firmware[0].sha256_checksum = "abcd"'
  reject_metadata_mutation 'non-HTTPS download' \
    '._embedded.firmware[0]._links.data.href |= sub("https:"; "http:")'
  reject_metadata_mutation 'wrong download host' \
    '._embedded.firmware[0]._links.data.href |= sub("fw-download.ubnt.com"; "example.invalid")'
  reject_metadata_mutation 'URL/version mismatch' \
    '._embedded.firmware[0]._links.data.href |= sub("9.8.7"; "9.8.8")'
  reject_metadata_mutation 'missing download link' \
    'del(._embedded.firmware[0]._links.data.href)'
  reject_metadata_mutation 'zero file size' \
    '._embedded.firmware[0].file_size = 0'
}

capture_override_mask() {
  local mask=$1
  unset UOS_VERSION UOS_INSTALLER_URL UOS_INSTALLER_SHA256
  if (( mask & 1 )); then UOS_VERSION=${VALID_VERSION}; fi
  if (( mask & 2 )); then UOS_INSTALLER_URL=${VALID_URL}; fi
  if (( mask & 4 )); then UOS_INSTALLER_SHA256=${VALID_SHA_UPPER}; fi
  # The prefix is declaration-only and ends before the focused helper block.
  # Loading it exercises production's [[ -v ... ]] presence capture.
  # shellcheck disable=SC1090
  source <(sed '/^#--- Release-update helpers /,$d' "${CONTROLLER}")
}

test_override_coherence() {
  local mask
  for mask in {0..7}; do
    if (( mask == 0 )); then
      (
        capture_override_mask "${mask}"
        configure_uos_release_mode
        [[ ${UOS_RELEASE_MODE} == official-latest ]] \
          || fail 'no overrides did not select official-latest mode'
      )
    elif (( mask == 7 )); then
      (
        capture_override_mask "${mask}"
        configure_uos_release_mode
        [[ ${UOS_RELEASE_MODE} == emergency-pin ]] \
          || fail 'complete override triplet did not select emergency-pin mode'
        [[ ${UOS_INSTALLER_SHA256} == "${VALID_SHA}" ]] \
          || fail 'emergency-pin checksum was not normalized'
        curl() { fail 'emergency pin unexpectedly queried release metadata'; }
        resolve_uos_bootstrap_release
      )
    else
      expect_failure "partial override mask ${mask}" configure_mask_for_failure "${mask}"
    fi
  done
  expect_failure 'explicit but empty override' configure_empty_override_for_failure
}

configure_mask_for_failure() {
  capture_override_mask "$1"
  configure_uos_release_mode
}

configure_empty_override_for_failure() {
  unset UOS_VERSION UOS_INSTALLER_URL UOS_INSTALLER_SHA256
  UOS_VERSION=
  UOS_INSTALLER_URL=${VALID_URL}
  UOS_INSTALLER_SHA256=${VALID_SHA}
  # shellcheck disable=SC1090
  source <(sed '/^#--- Release-update helpers /,$d' "${CONTROLLER}")
  configure_uos_release_mode
}

test_default_api_resolution() (
  local call_log=${TEST_ROOT}/api-curl.args output='' final=''
  reset_release_state
  configure_uos_release_mode
  STATE_DIR=${TEST_ROOT}/api-state
  install -d "${STATE_DIR}"
  curl() {
    printf '%s\n' "$*" >"${call_log}"
    while (( $# )); do
      case $1 in
        -o) output=$2; shift 2 ;;
        *)  final=$1; shift ;;
      esac
    done
    [[ ${final} == "${UOS_RELEASE_API_URL}" ]] \
      || fail 'default resolver queried an unexpected API URL'
    [[ -n ${output} ]] || fail 'default resolver did not provide a metadata output file'
    cp "${VALID_FIXTURE}" "${output}"
  }
  resolve_uos_bootstrap_release
  [[ -s ${call_log} ]] || fail 'default resolver did not query release metadata'
  [[ ${UOS_VERSION} == "${VALID_VERSION}" \
     && ${UOS_INSTALLER_URL} == "${VALID_URL}"
     && ${UOS_INSTALLER_SHA256} == "${VALID_SHA}" ]] \
    || fail 'default API resolution did not converge on the fixture release'
  [[ -z ${UOS_RELEASE_METADATA_TMP} ]] \
    || fail 'successful API resolution retained its temporary metadata path'
  [[ -z $(find "${STATE_DIR}" -name 'uos-release.*.json' -print -quit) ]] \
    || fail 'successful API resolution retained a temporary metadata file'
)

MOCK_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MOCK_IMAGE_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
MOCK_REPO_DIGESTS='["example.invalid/unrelated@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"]'
MOCK_PULL_FAIL=0
MOCK_INSPECT_FAIL=0
MOCK_PRUNE_FAIL=0
IMAGE_PRUNE_CALLS=0
IMAGE_CALL_LOG=${TEST_ROOT}/image-calls.log

podman() {
  printf '%s\n' "$*" >>"${IMAGE_CALL_LOG}"
  if [[ $1 == pull ]]; then
    (( MOCK_PULL_FAIL == 0 ))
    return
  fi
  if [[ $1 == image && ${2:-} == inspect ]]; then
    (( MOCK_INSPECT_FAIL == 0 )) || return 42
    printf '[{"Id":"%s","Digest":"%s","RepoDigests":%s}]\n' \
      "${MOCK_IMAGE_ID}" "${MOCK_IMAGE_DIGEST}" "${MOCK_REPO_DIGESTS}"
    return
  fi
  if [[ $1 == image && ${2:-} == prune ]]; then
    (( IMAGE_PRUNE_CALLS += 1 ))
    [[ $* == 'image prune --force' ]] || return 96
    (( MOCK_PRUNE_FAIL == 0 ))
    return
  fi
  return 97
}

test_mutable_image_refresh() {
  local state_file=${TEST_ROOT}/omada-image.identity first_hash
  : >"${IMAGE_CALL_LOG}"
  refresh_mutable_image docker.io/mbentley/omada-controller:6 "${state_file}"
  first_hash=$(sha256sum "${state_file}" | awk '{print $1}')
  grep -qx "id=${MOCK_IMAGE_ID}" "${state_file}" \
    || fail 'image state omitted the content ID'
  grep -qx "digest=${MOCK_IMAGE_DIGEST}" "${state_file}" \
    || fail 'image state omitted the manifest digest'

  # A rerun must still pull, but unrelated local RepoDigest associations must
  # not change the service input when the actual ID/digest is unchanged.
  MOCK_REPO_DIGESTS='["example.invalid/new@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]'
  refresh_mutable_image docker.io/mbentley/omada-controller:6 "${state_file}"
  [[ $(sha256sum "${state_file}" | awk '{print $1}') == "${first_hash}" ]] \
    || fail 'unchanged image content produced a changed service input'
  [[ $(grep -c '^pull -q docker.io/mbentley/omada-controller:6$' "${IMAGE_CALL_LOG}") == 2 ]] \
    || fail 'mutable image channel was not pulled on every refresh'

  MOCK_IMAGE_ID=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  MOCK_IMAGE_DIGEST=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  refresh_mutable_image docker.io/mbentley/omada-controller:6 "${state_file}"
  [[ $(sha256sum "${state_file}" | awk '{print $1}') != "${first_hash}" ]] \
    || fail 'new image content did not change the service input'
}

test_image_failure_no_mutation() {
  local state_file=${TEST_ROOT}/failure-image.identity
  printf 'known-good\n' >"${state_file}"
  if ( MOCK_PULL_FAIL=1; refresh_mutable_image example.invalid/image:latest "${state_file}" ) \
      >/dev/null 2>&1; then
    fail 'failed image pull unexpectedly succeeded'
  fi
  grep -qx 'known-good' "${state_file}" \
    || fail 'failed image pull mutated the recorded identity'

  MOCK_IMAGE_ID=not-a-valid-id
  if ( refresh_mutable_image example.invalid/image:latest "${state_file}" ) \
      >/dev/null 2>&1; then
    fail 'invalid inspected image identity unexpectedly succeeded'
  fi
  grep -qx 'known-good' "${state_file}" \
    || fail 'invalid image inspection mutated the recorded identity'
}

test_small_storage_image_prune() (
  IMAGE_PRUNE_CALLS=0
  MOCK_PRUNE_FAIL=0
  prune_dangling_images
  (( IMAGE_PRUNE_CALLS == 1 )) \
    || fail 'small-storage cleanup did not invoke one dangling-image prune'

  MOCK_PRUNE_FAIL=1
  if ( prune_dangling_images ) >/dev/null 2>&1; then
    fail 'failed dangling-image prune was silently accepted'
  fi
)

array_contains() {
  local wanted=$1 item
  shift
  for item in "$@"; do
    [[ ${item} == "${wanted}" ]] && return 0
  done
  return 1
}

test_service_input_catalog() (
  STATE_DIR=/test/state
  # These paths are expanded by the dynamically sourced production catalog.
  # shellcheck disable=SC2034
  QUADLET_DIR=/test/quadlets
  # shellcheck disable=SC2034
  OMADA_DIR=/test/omada
  # shellcheck disable=SC2034
  SS_DIR=/test/shadowsocks
  [[ $(grep -c '^#--- Service input catalog ' "${CONTROLLER}") == 1 ]] \
    || fail 'service input catalog start marker is missing or ambiguous'
  [[ $(grep -c '^#--- End service input catalog ' "${CONTROLLER}") == 1 ]] \
    || fail 'service input catalog end marker is missing or ambiguous'
  # shellcheck disable=SC1090
  source <(sed -n '/^#--- Service input catalog /,/^#--- End service input catalog /p' \
    "${CONTROLLER}")
  array_contains "${OMADA_DB_IMAGE_STATE}" "${OMADA_DB_FILES[@]}" \
    || fail 'Mongo image identity is not an omada-db restart input'
  array_contains "${OMADA_IMAGE_STATE}" "${OMADA_FILES[@]}" \
    || fail 'Omada image identity is not an omada restart input'
  array_contains "${SS_IMAGE_STATE}" "${SS_FILES[@]}" \
    || fail 'Shadowsocks image identity is not a shadowsocks restart input'
  ! array_contains "${OMADA_DB_IMAGE_STATE}" "${OMADA_FILES[@]}" \
    || fail 'Mongo identity is incorrectly wired directly to Omada inputs'
  ! array_contains "${SS_IMAGE_STATE}" "${OMADA_DB_FILES[@]}" \
    || fail 'Shadowsocks identity leaked into Mongo inputs'
)

line_of() {
  awk -v needle="$1" 'index($0, needle) { print NR; exit }' "${CONTROLLER}"
}

test_static_wiring() {
  local fresh_guard resolve_call pull_call quiesce_line
  local mongo_ready mongo_record omada_ready omada_record runtime_ready prune_call
  local zram_package_install reboot_check
  grep -Fq "UOS_RELEASE_API_URL='${UOS_RELEASE_API_URL}'" "${CONTROLLER}" \
    || fail 'official UniFi OS latest-release API query changed unexpectedly'
  ! grep -Eq 'DEFAULT_UOS_(VERSION|INSTALLER_URL|INSTALLER_SHA256)=' "${CONTROLLER}" \
    || fail 'controller retains a hardcoded default UniFi OS release'
  grep -Fq 'if [[ -v UOS_VERSION ]]' "${CONTROLLER}" \
    || fail 'UOS override mode does not capture explicit variable presence'
  sed -n '/^BASE_PACKAGES=(/,/^)/p' "${CONTROLLER}" | grep -Eq '(^|[[:space:]])jq([[:space:]]|$)' \
    || fail 'jq is not a controller prerequisite'
  grep -Fxq 'dnf -y upgrade --refresh' "${CONTROLLER}" \
    || fail 'controller setup does not apply available Rocky package updates'
  sed -n '/^BASE_PACKAGES=(/,/^)/p' "${CONTROLLER}" | grep -Eq '(^|[[:space:]])dnf-plugins-core([[:space:]]|$)' \
    || fail 'controller cannot evaluate the post-update reboot requirement'
  grep -Fq 'if dnf needs-restarting -r; then' "${CONTROLLER}" \
    && grep -Fq 'OS update state  : reboot required/recommended after this setup run' "${CONTROLLER}" \
    || fail 'controller does not report a post-update reboot requirement'
  grep -Fq 'OMADA_STANDARD_IMAGE=${OMADA_STANDARD_IMAGE:-docker.io/mbentley/omada-controller:6}' "${CONTROLLER}" \
    || fail 'standard Omada image does not track supported major 6'
  grep -Fq 'OMADA_LOW_RAM_IMAGE=${OMADA_LOW_RAM_IMAGE:-docker.io/mbentley/omada-controller:6-openj9}' "${CONTROLLER}" \
    || fail 'low-RAM Omada image does not track supported major 6-openj9'
  grep -Fq 'SS_IMAGE=${SS_IMAGE:-ghcr.io/shadowsocks/ssserver-rust:latest}' "${CONTROLLER}" \
    || fail 'Shadowsocks no longer tracks latest with an incident override'
  grep -Fq 'MONGO_TAG=8.0' "${CONTROLLER}" \
    && grep -Fq 'MONGO_TAG=4.4' "${CONTROLLER}" \
    || fail 'Mongo compatibility-major channels are not retained'
  ! grep -Fq 'podman image exists' "${CONTROLLER}" \
    || fail 'pull-once image gate remains in controller setup'
  grep -Fq 'refresh_mutable_image "docker.io/mongo:${MONGO_TAG}" "${OMADA_DB_IMAGE_STATE}"' "${CONTROLLER}" \
    || fail 'Mongo mutable channel is not mapped to its identity input'
  grep -Fq 'refresh_mutable_image "${OMADA_IMAGE}" "${OMADA_IMAGE_STATE}"' "${CONTROLLER}" \
    || fail 'Omada mutable channel is not mapped to its identity input'
  grep -Fq 'refresh_mutable_image "${SS_IMAGE}" "${SS_IMAGE_STATE}"' "${CONTROLLER}" \
    || fail 'Shadowsocks mutable channel is not mapped to its identity input'
  grep -Fq '(( RESTART_DB )) && RESTART_OMADA=${ENABLE_OMADA}' "${CONTROLLER}" \
    || fail 'Mongo image/config changes no longer propagate to Omada restart'

  fresh_guard=$(line_of 'if (( ENABLE_UNIFI_OS )) && ! uos_unit_exists; then')
  resolve_call=$(line_of '  resolve_uos_bootstrap_release')
  pull_call=$(line_of '  refresh_mutable_image "docker.io/mongo:${MONGO_TAG}"')
  quiesce_line=$(line_of '#--- Quiesce legacy and disabled components')
  mongo_ready=$(line_of '  log "Omada MongoDB ready"')
  mongo_record=$(line_of '  record_applied omada-db "${OMADA_DB_FILES[@]}"')
  omada_ready=$(line_of '  wait_for_https "Omada" https://localhost:8043 900 omada.service')
  omada_record=$(line_of '    record_applied omada "${OMADA_FILES[@]}"')
  runtime_ready=$(line_of 'log "All enabled services passed runtime checks"')
  prune_call=$(line_of '  prune_dangling_images')
  zram_package_install=$(line_of '    if ! dnf -y install zram-generator-defaults')
  reboot_check=$(line_of 'check_os_update_reboot_requirement # all DNF transactions are complete')
  [[ ${fresh_guard} =~ ^[0-9]+$ && ${resolve_call} =~ ^[0-9]+$ \
     && ${pull_call} =~ ^[0-9]+$ && ${quiesce_line} =~ ^[0-9]+$ \
     && ${mongo_ready} =~ ^[0-9]+$ && ${mongo_record} =~ ^[0-9]+$ \
     && ${omada_ready} =~ ^[0-9]+$ && ${omada_record} =~ ^[0-9]+$ \
     && ${runtime_ready} =~ ^[0-9]+$ && ${prune_call} =~ ^[0-9]+$ ]] \
    || fail 'could not locate release, image-refresh, or readiness-commit wiring'
  [[ ${zram_package_install} =~ ^[0-9]+$ && ${reboot_check} =~ ^[0-9]+$ ]] \
    && (( zram_package_install < reboot_check )) \
    || fail 'reboot detection does not follow the final possible DNF transaction'
  (( fresh_guard < resolve_call && pull_call < quiesce_line \
     && mongo_ready < mongo_record && omada_ready < omada_record \
     && runtime_ready < prune_call )) \
    || fail 'release/image refresh or readiness-gated applied-state ordering is unsafe'
  grep -Fq 'if (( SMALL_STORAGE_ACTIVE )); then' "${CONTROLLER}" \
    || fail 'dangling-image cleanup is not gated by the small-storage profile'
}

test_quadlet_generator_dryrun() (
  local quadlet_dir=${TEST_ROOT}/quadlets
  local mock_generator=${TEST_ROOT}/mock-quadlet-generator
  install -d "${quadlet_dir}"
  touch "${quadlet_dir}/omada.container"

  # Case A: Dryrun Success
  cat >"${mock_generator}" <<'EOF'
#!/usr/bin/env bash
[[ "${QUADLET_UNIT_DIRS}" == *"/quadlets"* && "$1" == "--dryrun" ]] || exit 99
exit 0
EOF
  chmod +x "${mock_generator}"

  QUADLET_GENERATOR="${mock_generator}"
  QUADLET_DIAGNOSTICS=$(QUADLET_UNIT_DIRS="${quadlet_dir}" "${QUADLET_GENERATOR}" --dryrun 2>&1) \
    || fail "valid Quadlet dryrun unexpectedly failed"

  # Case B: Dryrun Validation Failure (Fail-Closed)
  cat >"${mock_generator}" <<'EOF'
#!/usr/bin/env bash
echo "Error: invalid Quadlet key 'InvalidKey' in omada.container" >&2
exit 1
EOF
  chmod +x "${mock_generator}"

  if QUADLET_DIAGNOSTICS=$(QUADLET_UNIT_DIRS="${quadlet_dir}" "${QUADLET_GENERATOR}" --dryrun 2>&1); then
    fail "invalid Quadlet dryrun unexpectedly passed"
  fi
  grep -Fq "Error: invalid Quadlet key" <<<"${QUADLET_DIAGNOSTICS}" \
    || fail "Quadlet generator diagnostics were not captured"
)

test_diagnostic_dump_resilience() (
  local journal_log=${TEST_ROOT}/journal.log
  local podman_log=${TEST_ROOT}/podman.log

  journalctl() {
    echo called >> "${journal_log}"
    return 1
  }

  podman() {
    if [[ "$1" == "container" && "$2" == "exists" ]]; then
      return 0
    fi
    if [[ "$1" == "logs" ]]; then
      echo called >> "${podman_log}"
      return 1
    fi
    return 0
  }

  (
    set -e
    eval "$(sed -n '/^dump_omada_diagnostics() {/,/^}/p' "${CONTROLLER}")"
    eval "$(sed -n '/^dump_uos_diagnostics() {/,/^}/p' "${CONTROLLER}")"
    dump_omada_diagnostics >/dev/null 2>&1
    dump_uos_diagnostics >/dev/null 2>&1
  ) || fail "diagnostic dump crashed when underlying tools failed"
  [[ -s ${journal_log} ]] || fail "journalctl was not invoked during diagnostics"
  [[ -s ${podman_log} ]] || fail "podman logs was not invoked during diagnostics"
)

test_new_behaviors_static_wiring() {
  local dryrun_call diag_omada_def diag_uos_def db_diag_call omada_diag_call
  dryrun_call=$(line_of 'QUADLET_UNIT_DIRS="${QUADLET_DIR}"')
  diag_omada_def=$(line_of 'dump_omada_diagnostics() {')
  diag_uos_def=$(line_of 'dump_uos_diagnostics() {')
  db_diag_call=$(line_of '|| { dump_omada_diagnostics; die "omada-db.service/container failed to start"; }')
  omada_diag_call=$(line_of '|| { dump_omada_diagnostics; die "omada.service failed to start"; }')

  [[ ${dryrun_call} =~ ^[0-9]+$ ]] \
    || fail "could not locate Quadlet generator dryrun check"
  [[ ${diag_omada_def} =~ ^[0-9]+$ && ${diag_uos_def} =~ ^[0-9]+$ \
     && ${db_diag_call} =~ ^[0-9]+$ && ${omada_diag_call} =~ ^[0-9]+$ ]] \
    || fail "could not locate diagnostic dump definitions or call sites"

  # Verify Quadlet validation occurs before service start
  local omada_start=$(line_of 'start_unit_and_verify_active omada-db')
  (( dryrun_call < omada_start )) \
    || fail "fresh Quadlet dryrun does not precede service activation"
}

test_error_handling_and_pipeline_safety() {
  local err_trap_line cleanup_err_line lan_iface_line
  err_trap_line=$(line_of "trap 'report_script_error \"\$LINENO\" \"\$BASH_COMMAND\"' ERR")
  cleanup_err_line=$(line_of 'trap - EXIT INT TERM ERR')
  lan_iface_line=$(line_of 'LAN_IFACE=$(ip -4 route show default 2>/dev/null | awk '\''NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}'\'' || true)')

  [[ ${err_trap_line} =~ ^[0-9]+$ ]] \
    || fail "could not locate ERR trap registration"
  [[ ${cleanup_err_line} =~ ^[0-9]+$ ]] \
    || fail "could not locate ERR trap deregistration in cleanup_controller_setup"
  [[ ${lan_iface_line} =~ ^[0-9]+$ ]] \
    || fail "could not locate SIGPIPE-safe LAN_IFACE resolution"

  # Ensure no awk exit in route resolution that could trigger SIGPIPE
  if grep -E 'ip -4 route show default.*awk.*exit' "${REPO_ROOT}/setup-fedora-controllers.sh" >/dev/null; then
    fail "found hazardous awk exit in default route resolution"
  fi
}

test_valid_metadata
printf 'PASS official UniFi OS metadata selection\n'
test_invalid_metadata
printf 'PASS fail-closed UniFi OS metadata validation\n'
test_override_coherence
printf 'PASS explicit all-or-none UniFi OS emergency overrides\n'
test_default_api_resolution
printf 'PASS default UniFi OS API resolution and cleanup\n'
test_reboot_hint_statuses
printf 'PASS Rocky post-transaction reboot-hint classification\n'
test_mutable_image_refresh
printf 'PASS mutable image refresh identity convergence\n'
test_image_failure_no_mutation
printf 'PASS failed image refresh preserves prior identity\n'
test_small_storage_image_prune
printf 'PASS small-storage dangling-image cleanup and failure handling\n'
test_service_input_catalog
printf 'PASS image identities mapped to service restart inputs\n'
test_static_wiring
printf 'PASS controller dynamic release/update static wiring\n'
test_quadlet_generator_dryrun
printf 'PASS Quadlet generator dryrun validation\n'
test_diagnostic_dump_resilience
printf 'PASS diagnostic dump resilience under failures\n'
test_new_behaviors_static_wiring
printf 'PASS new behavior static wiring and ordering\n'
test_error_handling_and_pipeline_safety
printf 'PASS error reporting trap and pipeline safety\n'

