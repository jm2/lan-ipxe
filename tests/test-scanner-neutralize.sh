#!/usr/bin/env bash
# Mocked, CI-safe checks for scan-untrusted-media.sh's --export/--quarantine
# helpers: quarantine.tsv generation and parsing, volume matching, the OS
# clutter matcher, the export worker on a plain directory tree, in-place
# quarantine of one file (7-Zip mocked), and option validation. Nothing here
# needs root, mounts anything or touches a block device: sudo, systemd-run,
# mount, losetup, blockdev and package managers are shims that fail loudly.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${REPO_ROOT}/scan-untrusted-media.sh
TEST_ROOT=$(mktemp -d -p "${TMPDIR:-/var/tmp}" scanner-neutralize.XXXXXX)
# The scanner refuses report and DEST directories under /tmp and /var/tmp
# (its sandbox uses PrivateTmp), so the option-validation fixtures that must
# get past that check live in a private directory under the user cache.
CACHE_ROOT=${XDG_CACHE_HOME:-${HOME}/.cache}
mkdir -p -- "${CACHE_ROOT}"
FIXTURE_ROOT=$(mktemp -d -p "${CACHE_ROOT}" scanner-neutralize-test.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT}" "${FIXTURE_ROOT}"' EXIT

fail() { printf 'ASSERT: %s\n' "$*" >&2; exit 1; }

# Shims: anything privileged must never run from these tests.
SHIM_DIR=${TEST_ROOT}/shims
mkdir -p "${SHIM_DIR}"
for tool in sudo systemd-run mount umount losetup blockdev dnf pacman yay gsettings; do
  printf '#!/bin/sh\necho "SHIM %s called: $*" >&2\nexit 97\n' "${tool}" >"${SHIM_DIR}/${tool}"
  chmod +x "${SHIM_DIR}/${tool}"
done
# A 7z stand-in with the subset quarantine_file uses: "a ... -si<name> -- ARCHIVE"
# stores stdin, "t ... -- ARCHIVE" checks it exists, "x -so ... -- ARCHIVE"
# prints it. It also records the password and header-encryption flags.
cat >"${SHIM_DIR}/7z" <<'EOF'
#!/bin/bash
set -euo pipefail
cmd=$1; shift
archive=${*: -1}
printf '%s\n' "${cmd} $*" >>"${SEVENZIP_LOG:?}"
case ${cmd} in
  a) [[ " $* " == *' -pinfected '* && " $* " == *' -mhe=on '* ]] || exit 7
     cat >"${archive}" ;;
  t) [[ " $* " == *' -pinfected '* && -s ${archive} ]] ;;
  x) [[ " $* " == *' -pinfected '* ]] || exit 2; cat -- "${archive}" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "${SHIM_DIR}/7z"
export PATH="${SHIM_DIR}:${PATH}"
export SEVENZIP_LOG="${TEST_ROOT}/7z.log"

# Load the scanner's helper definitions without side effects (see
# tests/test-scanner-helpers.sh).
load_scanner() {
  set --
# shellcheck disable=SC2034  # read by the sourced scanner
  SCAN_UNTRUSTED_MEDIA_LIB=1
  # shellcheck disable=SC1090
  source "${SCRIPT}"
}

sha_of() { local s; s=$(sha256sum <"$1"); printf '%s' "${s%% *}"; }

assert_lines() {
  local file=$1 idx
  shift
  local -a expected got
  expected=("$@")
  mapfile -t got <"${file}"
  (( ${#got[@]} == ${#expected[@]} )) \
    || fail "${file##*/}: expected ${#expected[@]} line(s), got ${#got[@]}: [$(tr '\n' '|' <"${file}")]"
  for idx in "${!expected[@]}"; do
    [[ ${got[idx]} == "${expected[idx]}" ]] \
      || fail "${file##*/} line $(( idx + 1 )): [${got[idx]}] != [${expected[idx]}]"
  done
}

S1=$(printf 'a%.0s' {1..64})
S2=$(printf 'b%.0s' {1..64})
S3=$(printf 'c%.0s' {1..64})
S4=$(printf 'd%.0s' {1..64})
T=$'\t'

test_quarantine_template() (
  load_scanner
  local dir=${TEST_ROOT}/template
  mkdir -p "${dir}"
  {
    printf 'DEFINITE\tclamav\tWin.Trojan.X\tvolB\t%s\tz/evil.exe\n' "${S1}"
    printf 'LIKELY\tyara\tMacho_Rule (score 80)\tvolB\t%s\tz/evil.exe\n' "${S1}"
    printf 'DEFINITE\tclamav\tWin.Trojan.X\tvolB\t%s\tz/evil.exe\n' "${S1}"
    printf 'REVIEW\tclamav\tPUA.Win.Packed\tvolA\t%s\tb/pua.exe\n' "${S2}"
    printf 'REVIEW\tyara\tLow (score 10)\tvolA\t%s\ta/odd\\tname\\nx\n' "${S3}"
    printf 'LIKELY\tvirustotal\t3 engines: trojan\tvolA\t%s\ta/odd\\tname\\nx\n' "${S3}"
    printf 'LIKELY\tyara\tRule (score 90)\tvolA\t%s\tc/x.sh\n' "${S4}"
  } >"${dir}/findings.tsv"
  write_quarantine_template "${dir}"
  awk '!/^#/' "${dir}/quarantine.tsv" >"${dir}/active"
  awk '/^# / && /\t/ && !/^# volume_tag/' "${dir}/quarantine.tsv" >"${dir}/commented"
  assert_lines "${dir}/active" \
    "volA${T}${S3}${T}LIKELY${T}yara: Low (score 10); virustotal: 3 engines: trojan${T}a/odd\\tname\\nx" \
    "volA${T}${S4}${T}LIKELY${T}yara: Rule (score 90)${T}c/x.sh" \
    "volB${T}${S1}${T}DEFINITE${T}clamav: Win.Trojan.X; yara: Macho_Rule (score 80)${T}z/evil.exe"
  assert_lines "${dir}/commented" \
    "# volA${T}${S2}${T}REVIEW${T}clamav: PUA.Win.Packed${T}b/pua.exe"
  grep -q '^# Only active (uncommented) lines are acted on' "${dir}/quarantine.tsv" \
    || fail 'quarantine.tsv header does not explain active lines'
  # The generated file must parse back exactly into the active selection.
  load_quarantine_selection "${dir}/quarantine.tsv" || fail 'generated quarantine.tsv does not parse'
  (( ${#Q_KEYS[@]} == 3 )) || fail "expected 3 active selections, got ${#Q_KEYS[@]}"
  [[ ${Q_REL[volB$'\t'z/evil.exe]} == "${S1}" ]] || fail 'volB evil.exe not selected'
  [[ -z ${Q_REL[volA$'\t'b/pua.exe]+x} ]] || fail 'commented REVIEW line was selected'
  # No findings file: nothing is written.
  local empty=${TEST_ROOT}/template-empty
  mkdir -p "${empty}"
  write_quarantine_template "${empty}"
  [[ ! -e ${empty}/quarantine.tsv ]] || fail 'quarantine.tsv written without findings.tsv'
)

test_selection_parsing() (
  load_scanner
  local q=${TEST_ROOT}/sel.tsv raw esc
  raw=$'dir/tab\there\nand newline.bin'
  tsv_esc "${raw}"; esc=${REPLY}
  {
    printf '# a comment line\n\n   \n'
    printf '   # indented comment\tvol\t%s\tX\tY\tz\n' "${S1}"
    printf 'vol1\t%s\tDEFINITE\tclamav: X\t%s\n' "${S1}" "${esc}"
    printf 'vol1\t%s\tLIKELY\tyara: R\t-leading dash.txt\r\n' "${S2}"
    printf '# vol1\t%s\tREVIEW\tpua\tcommented.exe\n' "${S3}"
    printf 'vol2\t-\tDEFINITE\tclamav: unreadable\tno/hash'
  } >"${q}"
  load_quarantine_selection "${q}" || fail 'valid selection rejected'
  (( ${#Q_KEYS[@]} == 3 )) || fail "expected 3 active lines, got ${#Q_KEYS[@]}"
  [[ ${Q_KEYS[0]} == "vol1"$'\t'"${esc}" ]] || fail "escaped tab/newline name not kept verbatim: [${Q_KEYS[0]}]"
  [[ ${Q_REL[vol1$'\t'-leading dash.txt]} == "${S2}" ]] || fail 'CRLF line or leading-dash path mis-parsed'
  [[ ${Q_INFO[vol1$'\t'-leading dash.txt]} == $'LIKELY\tyara: R' ]] || fail 'class/detail mis-parsed'
  [[ -n ${Q_SHA[${S1}]+x} && -n ${Q_SHA[${S2}]+x} && -z ${Q_SHA[${S3}]+x} ]] || fail 'Q_SHA wrong'
  [[ -z ${Q_SHA[-]+x} ]] || fail 'a missing sha256 (-) became a sha selector'
  [[ ${Q_REL[vol2$'\t'no/hash]} == - ]] || fail 'unhashed line not kept'
  # A path found on disk matches only through tsv_esc, never by unescaping.
  tsv_esc "${raw}"
  [[ -n ${Q_REL[vol1$'\t'${REPLY}]+x} ]] || fail 'raw name does not match its escaped selection'
  local bad
  for bad in $'vol\tshort\tline' \
             $'vol\tnot-a-sha\tDEFINITE\td\tp' \
             "vol${T}${S1}${T}DEFINITE${T}d${T}p${T}extra" \
             "${T}${S1}${T}DEFINITE${T}d${T}p" \
             "vol${T}${S1}${T}DEFINITE${T}d${T}" \
             "vol  ${S1}  DEFINITE  d  spaces-instead-of-tabs"; do
    printf '# ok\n%s\n' "${bad}" >"${q}"
    if load_quarantine_selection "${q}" 2>/dev/null; then fail "malformed line accepted: [${bad}]"; fi
  done
  if load_quarantine_selection "${TEST_ROOT}/does-not-exist" 2>/dev/null; then
    fail 'missing quarantine.tsv accepted'
  fi
)

test_os_clutter() (
  load_scanner
  local p
  for p in .DS_Store a/b/.DS_Store A/.ds_store ._photo.jpg 'dir/._Report 1.pdf' \
           .Spotlight-V100/Store-V2/x .fseventsd/0001 .Trashes/501/x.doc .TemporaryItems/f \
           .DocumentRevisions-V100/PerUID/1 'System Volume Information/IndexerVolumeGuid' \
           '$RECYCLE.BIN/S-1-5-21/desktop.ini' '$Recycle.Bin/S-1/x' .Trash-1000/files/old.txt \
           'sub/.Trash-1000/info/x' $'odd\nname/.DS_Store'; do
    is_os_clutter "${p}" || fail "not treated as OS clutter: [${p}]"
  done
  for p in DS_Store notes.txt a._b x/.DS_Store.bak '.Trashes' 'my.Spotlight-V100/x' \
           'System Volume Information.txt' 'docs/._/real.txt' '$RECYCLE.BINX/a' \
           .Trash/x 'x/.fseventsd' report.pdf; do
    ! is_os_clutter "${p}" || fail "wrongly treated as OS clutter: [${p}]"
  done
  shopt -q nocasematch && fail 'is_os_clutter leaked nocasematch'
  shopt -s nocasematch
  is_os_clutter .ds_store || fail 'clutter match failed under caller nocasematch'
  shopt -q nocasematch || fail 'is_os_clutter cleared the caller nocasematch'
)

test_match_volume_tag() (
  load_scanner
  local v=${TEST_ROOT}/volumes.tsv got rc
  {
    printf 'img\text4\t/m/img\t/i/d.img\tU-1\t-\t0\n'
    printf 'img-loop0p1\tvfat\t/m/p1\t/i/d.img\tAB12-CD34\t-\t1\n'
    printf 'img-loop0p2\tvfat\t/m/p2\t/i/d.img\t-\t-\t2\n'
    printf 'img-loop0p3\tapfs\t/m/v0\t/i/d.img\tAPFS-U\t0\t3\n'
    printf 'img-loop0p3-v1\tapfs\t/m/v1\t/i/d.img\tAPFS-U\t1\t3\n'
    printf 'twin-a\txfs\t/m/a\t/dev/sdz1\tSAME\t-\t1\n'
    printf 'twin-b\txfs\t/m/b\t/dev/sdz2\tSAME\t-\t2\n'
    printf 'nouuid-a\texfat\t/m/c\t/dev/sdy1\t-\t-\t4\n'
    printf 'nouuid-b\texfat\t/m/d\t/dev/sdx1\t-\t-\t4\n'
    printf 'dir-x\tunknown\t/home/u/x\t-\t-\t-\t-\n'
  } >"${v}"
  [[ $(match_volume_tag "${v}" vfat AB12-CD34 7 -) == img-loop0p1 ]] || fail 'UUID match must win over the partition number'
  [[ $(match_volume_tag "${v}" vfat - 2 -) == img-loop0p2 ]] || fail 'fallback by fstype+partition failed'
  [[ $(match_volume_tag "${v}" vfat - 1 -) == img-loop0p1 ]] || fail 'fallback when the live volume has no UUID failed'
  [[ $(match_volume_tag "${v}" apfs APFS-U 3 1) == img-loop0p3-v1 ]] || fail 'APFS volume index not honoured'
  [[ $(match_volume_tag "${v}" xfs SAME 2 -) == twin-b ]] || fail 'partition number did not break a UUID tie'
  rc=0; got=$(match_volume_tag "${v}" xfs SAME 3 - 2>/dev/null) || rc=$?
  [[ ${rc} == 2 && -z ${got} ]] || fail "UUID clones without a tie-break: rc ${rc} [${got}]"
  rc=0; got=$(match_volume_tag "${v}" exfat - 4 - 2>/dev/null) || rc=$?
  [[ ${rc} == 2 && -z ${got} ]] || fail "ambiguous fallback not refused: rc ${rc} [${got}]"
  rc=0; got=$(match_volume_tag "${v}" ext4 U-OTHER 0 - 2>/dev/null) || rc=$?
  [[ ${rc} == 1 && -z ${got} ]] || fail "a different UUID must not fall back to the partition: rc ${rc} [${got}]"
  rc=0; got=$(match_volume_tag "${v}" ntfs - 1 - 2>/dev/null) || rc=$?
  [[ ${rc} == 1 ]] || fail "fstype mismatch matched: rc ${rc} [${got}]"
  printf 'old\tvfat\t/m/old\n' >"${v}.old"
  rc=0; match_volume_tag "${v}.old" vfat - 1 - >/dev/null 2>&1 || rc=$?
  [[ ${rc} == 3 ]] || fail "pre-identity volumes.tsv not reported: rc ${rc}"
)

test_quarantine_fs_types() (
  load_scanner
  local fs
  [[ $(quarantine_fs_types ntfs) == 'ntfs3 ntfs-3g' ]] || fail 'ntfs must try ntfs3 then ntfs-3g'
  for fs in vfat exfat ext2 ext3 ext4 btrfs xfs; do
    [[ $(quarantine_fs_types "${fs}") == "${fs}" ]] || fail "${fs} should be writable in place"
  done
  for fs in apfs hfs hfsplus; do
    if quarantine_fs_types "${fs}" >/dev/null 2>"${TEST_ROOT}/fs.err"; then fail "${fs} accepted"; fi
    grep -q 'Mac' "${TEST_ROOT}/fs.err" || fail "${fs} refusal does not point to a Mac/VM"
    grep -q -- '--export' "${TEST_ROOT}/fs.err" || fail "${fs} refusal does not suggest --export"
  done
  for fs in iso9660 udf ntfs-3g zfs_member crypto_LUKS f2fs ''; do
    if quarantine_fs_types "${fs}" >/dev/null 2>&1; then fail "[${fs}] accepted"; fi
  done
)

test_check_export_dest() (
  load_scanner
  local d
  for d in /tmp /tmp/x /var/tmp /var/tmp/a/b /run/scan-untrusted-media.123/x / '' "${TEST_ROOT}/new"; do
    if check_export_dest "${d}" >/dev/null 2>&1; then fail "DEST [${d}] accepted"; fi
  done
  mkdir -p "${FIXTURE_ROOT}/dest-full" "${FIXTURE_ROOT}/dest-empty"
  : >"${FIXTURE_ROOT}/dest-full/.hidden"
  : >"${FIXTURE_ROOT}/dest-file"
  if check_export_dest "${FIXTURE_ROOT}/dest-full" >/dev/null 2>&1; then fail 'non-empty DEST accepted'; fi
  if check_export_dest "${FIXTURE_ROOT}/dest-file" >/dev/null 2>&1; then fail 'file DEST accepted'; fi
  if check_export_dest "${FIXTURE_ROOT}/with space" >/dev/null 2>&1; then fail 'DEST with whitespace accepted'; fi
  [[ $(check_export_dest "${FIXTURE_ROOT}/dest-empty") == "${FIXTURE_ROOT}/dest-empty" ]] || fail 'empty DEST refused'
  [[ $(check_export_dest "${FIXTURE_ROOT}/x/../dest-new") == "${FIXTURE_ROOT}/dest-new" ]] || fail 'new DEST not normalised'
)

# make_export_fixture <root> <report dir>: a volume tree plus its files.tsv
# and quarantine.tsv, as a scan would have recorded them.
make_export_fixture() {
  local root=$1 rep=$2 rel sum
  local -a names
  mkdir -p "${root}/docs" "${root}/copies" "${root}/.Spotlight-V100/Store-V2" \
           "${root}/\$RECYCLE.BIN/S-1-5" "${root}/System Volume Information" \
           "${root}/.Trash-1000/files" "${root}/.fseventsd" "${root}/photos" "${rep}/volumes/vol1"
  printf 'report\n' >"${root}/docs/report.pdf"
  printf 'EVIL\n' >"${root}/docs/evil.exe"
  printf 'EVIL\n' >"${root}/copies/evil-copy.bin"
  printf 'dash\n' >"${root}/-leading dash.txt"
  printf 'weird\n' >"${root}/"$'tab\there\nnewline.txt'
  printf 'select me\n' >"${root}/"$'q\tsel\nname.bin'
  printf '#!/bin/sh\necho hi\n' >"${root}/run.sh"
  chmod 4755 "${root}/run.sh"
  printf 'never scanned\n' >"${root}/unscanned.txt"
  printf 'v2\n' >"${root}/changed.txt"
  printf 'x\n' >"${root}/unreadable-at-scan.txt"
  printf 'ds\n' >"${root}/.DS_Store"
  printf 'ad\n' >"${root}/docs/._report.pdf"
  printf 'sp\n' >"${root}/.Spotlight-V100/Store-V2/store.db"
  printf 'rb\n' >"${root}/\$RECYCLE.BIN/S-1-5/desktop.ini"
  printf 'sv\n' >"${root}/System Volume Information/IndexerVolumeGuid"
  printf 'tr\n' >"${root}/.Trash-1000/files/old.txt"
  printf 'fe\n' >"${root}/.fseventsd/0000"
  printf 'img\n' >"${root}/photos/IMG_0001.JPG"
  ln -s /etc/passwd "${root}/link-to-passwd"
  mkfifo "${root}/pipe"
  : >"${rep}/volumes/vol1/files.tsv"
  mapfile -d '' -t names < <(cd "${root}" && find . -type f -printf '%P\0' | sort -z)
  for rel in "${names[@]}"; do
    [[ ${rel} == unscanned.txt ]] && continue
    sum=$(sha256sum <"${root}/${rel}"); sum=${sum%% *}
    [[ ${rel} == changed.txt ]] && sum=$(printf 'v1\n' | sha256sum | cut -d' ' -f1)
    [[ ${rel} == unreadable-at-scan.txt ]] && sum=-
    tsv_esc "${rel}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${sum}" 5 0 644 text/plain "${REPLY}" >>"${rep}/volumes/vol1/files.tsv"
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(printf 'gone\n' | sha256sum | cut -d' ' -f1)" 5 0 644 text/plain gone.txt \
    >>"${rep}/volumes/vol1/files.tsv"
  tsv_esc $'q\tsel\nname.bin'
  {
    printf '# header\n\n'
    printf 'vol1\t%s\tDEFINITE\tclamav: X\tdocs/evil.exe\n' "$(sha_of "${root}/docs/evil.exe")"
    printf 'vol1\t%s\tLIKELY\tyara: Y\t%s\n' "$(sha_of "${root}/"$'q\tsel\nname.bin')" "${REPLY}"
    printf '# vol1\t%s\tREVIEW\tpua\tdocs/report.pdf\n' "$(sha_of "${root}/docs/report.pdf")"
    # Another volume's selection by path must not reach vol1's photo.
    printf 'vol2\t%s\tDEFINITE\tclamav: Z\tphotos/IMG_0001.JPG\n' "${S4}"
  } >"${rep}/quarantine.tsv"
}

# read_export_log <log>: STATUS[escaped relpath]="status|reason".
read_export_log() {
  local st reason tag sum erel
  STATUS=()
  while IFS=$'\t' read -r st reason tag sum erel; do
    [[ ${st} == '#'* ]] && continue
    [[ ${tag} == vol1 ]] || fail "log line for unexpected tag [${tag}]"
    STATUS[${erel}]="${st}|${reason}"
  done <"$1"
}

expect_status() { # <escaped relpath> <status> [reason substring]
  local got=${STATUS[$1]-}
  [[ ${got%%|*} == "$2" ]] || fail "[$1]: status [${got}] want [$2]"
  [[ -z ${3:-} || ${got#*|} == *"$3"* ]] || fail "[$1]: reason [${got#*|}] lacks [$3]"
}

test_export_tree() (
  load_scanner
  local root=${TEST_ROOT}/vol rep=${TEST_ROOT}/report dest=${TEST_ROOT}/dest prog=${TEST_ROOT}/prog
  local log=${TEST_ROOT}/export.log weird sel f
  declare -A STATUS=()
  make_export_fixture "${root}" "${rep}"
  mkdir -p "${dest}" "${prog}"
  : >"${log}"
  export_tree "${root}/" "${dest}" "${rep}/volumes/vol1/files.tsv" "${rep}/quarantine.tsv" vol1 "${log}" 0 "${prog}" \
    || fail 'export_tree failed'
  read_export_log "${log}"
  tsv_esc $'tab\there\nnewline.txt'; weird=${REPLY}
  tsv_esc $'q\tsel\nname.bin'; sel=${REPLY}
  expect_status docs/report.pdf copied
  expect_status photos/IMG_0001.JPG copied
  expect_status '-leading dash.txt' copied
  expect_status "${weird}" copied
  expect_status run.sh copied
  expect_status docs/evil.exe skipped 'selected in quarantine.tsv'
  expect_status "${sel}" skipped 'selected in quarantine.tsv'
  expect_status copies/evil-copy.bin skipped 'same sha256'
  expect_status unscanned.txt skipped 'not in the scan inventory'
  expect_status unreadable-at-scan.txt skipped 'no sha256 recorded'
  expect_status changed.txt mismatch 'changed since the scan'
  expect_status gone.txt missing
  expect_status link-to-passwd skipped 'not a regular file'
  expect_status pipe skipped 'not a regular file'
  for f in .DS_Store docs/._report.pdf .Spotlight-V100/Store-V2/store.db '$RECYCLE.BIN/S-1-5/desktop.ini' \
           'System Volume Information/IndexerVolumeGuid' .Trash-1000/files/old.txt .fseventsd/0000; do
    expect_status "${f}" skipped 'OS metadata'
    [[ ! -e ${dest}/${f} ]] || fail "OS clutter copied: ${f}"
  done
  # Destination contents: exactly the copied files, byte-identical, 0644
  # files in 0755 directories, nothing but regular files and directories.
  cmp -s "${root}/docs/report.pdf" "${dest}/docs/report.pdf" || fail 'report.pdf differs'
  cmp -s "${root}/"$'tab\there\nnewline.txt' "${dest}/"$'tab\there\nnewline.txt' || fail 'weird name differs'
  [[ -f ${dest}/-leading\ dash.txt ]] || fail 'leading-dash file missing'
  [[ ! -e ${dest}/docs/evil.exe && ! -e ${dest}/copies/evil-copy.bin ]] || fail 'quarantined content exported'
  [[ ! -e ${dest}/changed.txt ]] || fail 'mismatched copy left in DEST'
  [[ ! -e ${dest}/unscanned.txt && ! -e ${dest}/link-to-passwd && ! -e ${dest}/pipe ]] || fail 'unscanned/special file exported'
  [[ $(stat -c %a "${dest}/run.sh") == 644 ]] || fail "run.sh mode $(stat -c %a "${dest}/run.sh"), want 644 (no setuid/exec)"
  [[ -z $(find "${dest}" -type f ! -perm 0644) ]] || fail 'a copied file is not mode 0644'
  [[ -z $(find "${dest}" -mindepth 1 -type d ! -perm 0755) ]] || fail 'a created directory is not mode 0755'
  [[ -z $(find "${dest}" ! -type f ! -type d) ]] || fail 'DEST holds something other than files and directories'
  (( $(find "${dest}" -type f -printf . | wc -c) == 5 )) || fail "expected 5 files in DEST, got $(find "${dest}" -type f -printf . | wc -c)"
  [[ $(<"${prog}/progress") == 'done: 5 files copied'* ]] || fail "progress not finalised: $(<"${prog}/progress")"

  # --keep-metadata: clutter that was scanned is copied too.
  rm -rf "${dest}"; mkdir -p "${dest}"; : >"${log}"
  export_tree "${root}" "${dest}" "${rep}/volumes/vol1/files.tsv" "${rep}/quarantine.tsv" vol1 "${log}" 1 "${prog}" \
    || fail 'export_tree --keep-metadata failed'
  read_export_log "${log}"
  expect_status .DS_Store copied
  expect_status '$RECYCLE.BIN/S-1-5/desktop.ini' copied
  [[ -f ${dest}/System\ Volume\ Information/IndexerVolumeGuid ]] || fail 'metadata not kept with --keep-metadata'
  expect_status docs/evil.exe skipped 'selected in quarantine.tsv'

  # A malformed selection stops the export before anything is copied.
  rm -rf "${dest}"; mkdir -p "${dest}"; : >"${log}"
  printf 'vol1 broken line\n' >"${rep}/bad-quarantine.tsv"
  if export_tree "${root}" "${dest}" "${rep}/volumes/vol1/files.tsv" "${rep}/bad-quarantine.tsv" vol1 "${log}" 0 "${prog}" 2>/dev/null; then
    fail 'export_tree accepted a malformed quarantine.tsv'
  fi
  [[ -z $(ls -A "${dest}") ]] || fail 'files copied despite a malformed selection'
)

test_quarantine_file() (
  load_scanner
  local vol=${TEST_ROOT}/qvol good bad name stub sum
  # shellcheck disable=SC2034 # read by quarantine_file through dynamic scope
  local -a run=()
  NZ_REPORT=${TEST_ROOT}/qreport
  QDIR=${NZ_REPORT}/quarantine
  NZ_LOG=${NZ_REPORT}/quarantine-test.log
  mkdir -p "${vol}/d" "${QDIR}"
  : >"${NZ_LOG}" ; : >"${SEVENZIP_LOG}"
  name=$'-evil\tname.exe'
  printf 'MALWARE\n' >"${vol}/d/${name}"
  printf 'other\n' >"${vol}/d/changed.exe"
  printf 'MAL2\n' >"${vol}/d/planted.exe"
  ln -s "${TEST_ROOT}/host-target" "${vol}/d/planted.exe.QUARANTINED.txt"
  good=$(sha_of "${vol}/d/${name}")
  bad=$(sha_of "${vol}/d/planted.exe")
  tsv_esc "d/${name}"
  Q_REL=([vol1$'\t'${REPLY}]=${good} [vol1$'\t'd/changed.exe]=${S1} [vol1$'\t'd/planted.exe]=${bad})
  Q_INFO=([vol1$'\t'${REPLY}]=$'DEFINITE\tclamav: Win.Trojan.X'
          [vol1$'\t'd/changed.exe]=$'LIKELY\tyara: R' [vol1$'\t'd/planted.exe]=$'DEFINITE\tclamav: Y')
  quarantine_file "${vol}/d/${name}" "vol1"$'\t'"${REPLY}"
  [[ ! -e ${vol}/d/${name} ]] || fail 'original not deleted'
  stub=${vol}/d/${name}.QUARANTINED.txt
  [[ -f ${stub} ]] || fail 'stub not written next to the original'
  grep -q "SHA-256:       ${good}" "${stub}" || fail 'stub lacks the sha256'
  grep -q 'clamav: Win.Trojan.X' "${stub}" || fail 'stub lacks the detection'
  grep -q "${good}.7z" "${stub}" || fail 'stub lacks the archive name'
  grep -q 'Original name: -evil\\tname.exe' "${stub}" || fail 'stub does not show the escaped original name'
  [[ -s ${QDIR}/${good}.7z ]] || fail 'archive missing'
  [[ $(stat -c %a "${QDIR}/${good}.7z") == 600 ]] || fail 'archive is not 0600'
  [[ ! -e ${QDIR}/.${good}.partial.7z ]] || fail 'partial archive left behind'
  grep -q -- "^a .*-mhe=on .*-pinfected .*-si${good} -- " "${SEVENZIP_LOG}" || fail "7z add not called with -mhe=on -pinfected -si<sha>: $(cat "${SEVENZIP_LOG}")"
  grep -q '^t ' "${SEVENZIP_LOG}" || fail 'archive not tested with 7z t'
  grep -q $'^quarantined\t' "${NZ_LOG}" || fail 'quarantine not logged'
  grep -q "${good}" "${QDIR}/index.tsv" || fail 'index.tsv not written'

  # sha256 no longer matches the selection: left in place, no archive.
  quarantine_file "${vol}/d/changed.exe" "vol1"$'\t'"d/changed.exe"
  [[ -f ${vol}/d/changed.exe && ! -e ${vol}/d/changed.exe.QUARANTINED.txt ]] || fail 'mismatched file touched'
  [[ ! -e ${QDIR}/${S1}.7z ]] || fail 'mismatched file archived'
  grep -q $'^mismatch\t.*left in place\tvol1\t'"${S1}"$'\td/changed.exe$' "${NZ_LOG}" || fail 'mismatch not logged'

  # A planted symlink where the stub goes is never followed.
  quarantine_file "${vol}/d/planted.exe" "vol1"$'\t'"d/planted.exe"
  [[ ! -e ${TEST_ROOT}/host-target ]] || fail 'stub write followed a planted symlink'
  [[ -L ${vol}/d/planted.exe.QUARANTINED.txt ]] || fail 'planted symlink replaced'
  [[ -f ${vol}/d/QUARANTINED-${bad}.txt && ! -e ${vol}/d/planted.exe ]] || fail 'fallback stub not used'

  # An archive that fails verification leaves the original in place.
  printf 'MAL3\n' >"${vol}/d/third.exe"
  sum=$(sha_of "${vol}/d/third.exe")
  Q_REL[vol1$'\t'd/third.exe]=${sum}; Q_INFO[vol1$'\t'd/third.exe]=$'DEFINITE\tx'
  # shellcheck disable=SC2329 # invoked by quarantine_file
  nz_verify_archive() { return 1; }
  quarantine_file "${vol}/d/third.exe" "vol1"$'\t'"d/third.exe"
  [[ -f ${vol}/d/third.exe && ! -e ${QDIR}/${sum}.7z && ! -e ${QDIR}/.${sum}.partial.7z ]] \
    || fail 'unverified archive still removed the original'
  grep -q $'^error\tarchive failed verification' "${NZ_LOG}" || fail 'verification failure not logged'
)

# run_script <args...>: run the scanner with the shims, capture rc + stderr.
run_script() {
  RC=0
  ERR=$(HOME="${TEST_ROOT}/home" "${SCRIPT}" --no-session-hardening "$@" 2>&1 >/dev/null) || RC=$?
}

expect_die() { # <message substring> <args...>
  local want=$1
  shift
  run_script "$@"
  [[ ${RC} == 1 ]] || fail "'$*' exited ${RC}, expected 1 (stderr: ${ERR})"
  [[ ${ERR} == *"${want}"* ]] || fail "'$*' stderr lacks [${want}]: ${ERR}"
  [[ ${ERR} != *'SHIM '* ]] || fail "'$*' reached a privileged tool: ${ERR}"
}

test_option_validation() {
  local rep=${FIXTURE_ROOT}/report old=${FIXTURE_ROOT}/old-report img=${FIXTURE_ROOT}/disk.img
  mkdir -p "${TEST_ROOT}/home" "${rep}/volumes/v" "${old}" "${FIXTURE_ROOT}/full"
  : >"${img}"
  : >"${FIXTURE_ROOT}/full/x"
  printf 'v\tapfs\t/m\t/i/disk.img\tU\t0\t2\n' >"${rep}/volumes.tsv"
  : >"${rep}/findings.tsv"
  printf 'v\t%s\tDEFINITE\tclamav: X\tevil.app/x\n' "${S1}" >"${rep}/quarantine.tsv"
  printf 'v\tvfat\t/m\n' >"${old}/volumes.tsv"
  : >"${old}/findings.tsv"

  expect_die '--export needs REPORT_DIR and DEST' --export
  expect_die '--export needs REPORT_DIR and DEST' --export "${rep}"
  expect_die '--quarantine needs REPORT_DIR' --quarantine
  expect_die 'No TARGET given' --export "${rep}" "${FIXTURE_ROOT}/d1"
  expect_die 'takes exactly one TARGET' --export "${rep}" "${FIXTURE_ROOT}/d1" "${img}" "${img}"
  expect_die 'separate runs' --export "${rep}" "${FIXTURE_ROOT}/d1" --quarantine "${rep}" "${img}"
  expect_die '--keep-metadata needs --export' --keep-metadata "${img}"
  expect_die '--yes needs --quarantine' --yes --export "${rep}" "${FIXTURE_ROOT}/d1" "${img}"
  expect_die 'do not apply to --export' --export "${rep}" "${FIXTURE_ROOT}/d1" --image-dir "${FIXTURE_ROOT}" "${img}"
  expect_die '--keep-mounted does not apply' --quarantine "${rep}" --keep-mounted "${img}"
  expect_die 'under /tmp or /var/tmp' --export "${rep}" /tmp/scanner-neutralize-dest "${img}"
  expect_die 'under /tmp or /var/tmp' --export "${rep}" "${TEST_ROOT}/dest" "${img}"
  expect_die 'is not empty' --export "${rep}" "${FIXTURE_ROOT}/full" "${img}"
  expect_die 'No such report directory' --export "${FIXTURE_ROOT}/nope" "${FIXTURE_ROOT}/d1" "${img}"
  expect_die 'under /tmp or /var/tmp' --export "${TEST_ROOT}" "${FIXTURE_ROOT}/d1" "${img}"
  expect_die 'no volume identity columns' --export "${old}" "${FIXTURE_ROOT}/d1" "${img}"
  expect_die 'DEST and TARGET must not contain each other' --export "${rep}" "${FIXTURE_ROOT}/d1/sub" "${FIXTURE_ROOT}"
  expect_die 'works on the drive itself' --quarantine "${rep}" "${img}"
  [[ ! -e ${FIXTURE_ROOT}/d1 ]] || fail 'a refused export created DEST'

  # A report without quarantine.tsv gets one generated, and the run stops
  # so it can be reviewed.
  rm -f "${rep}/quarantine.tsv"
  printf 'DEFINITE\tclamav\tX\tv\t%s\tevil.app/x\n' "${S1}" >"${rep}/findings.tsv"
  expect_die 'Review it' --export "${rep}" "${FIXTURE_ROOT}/d1" "${img}"
  grep -q $'^v\t'"${S1}" "${rep}/quarantine.tsv" || fail 'quarantine.tsv not generated from findings.tsv'

  local rc=0 out
  for args in '--internal-export' '--internal-export a b c'; do
    rc=0
    # shellcheck disable=SC2086 # deliberate word splitting of the case
    out=$("${SCRIPT}" ${args} 2>&1 >/dev/null) || rc=$?
    [[ ${rc} == 1 && ${out} == *'--internal-export needs 8 arguments'* ]] \
      || fail "'${args}' guard: rc ${rc}: ${out}"
  done
}

# End to end --export of a directory TARGET through the real host flow
# (report/DEST checks, work dir, log, the sandbox call with its argument list,
# summary, exit code). sudo is a shim that allows only what this flow needs
# without privilege: "systemd-run ... -- CMD" runs CMD directly as the user,
# package installs and /run mkdir/rmdir are no-ops; anything else fails.
test_export_end_to_end() {
  local shims=${TEST_ROOT}/e2e-shims rep=${FIXTURE_ROOT}/e2e-report dest=${FIXTURE_ROOT}/e2e-dest
  local target=${TEST_ROOT}/e2e-target rc=0 out tag=dir-e2e-target f sum
  mkdir -p "${target}/docs" "${shims}" "${rep}/volumes/${tag}"
  if [[ $(stat -c %d "${target}") == "$(stat -c %d "${FIXTURE_ROOT}")" ]]; then
    target=$(mktemp -d -p /dev/shm scanner-neutralize-target.XXXXXX 2>/dev/null) || target=
    if [[ -z ${target} || $(stat -c %d "${target}") == "$(stat -c %d "${FIXTURE_ROOT}")" ]]; then
      [[ -n ${target} ]] && rm -rf -- "${target}"
      printf 'SKIP neutralize --export end to end: no scratch filesystem apart from %s\n' "${FIXTURE_ROOT}"
      return 0
    fi
    # shellcheck disable=SC2064 # expand now: the path is fixed
    trap "rm -rf -- '${TEST_ROOT}' '${FIXTURE_ROOT}' '${target}'" EXIT
    mkdir -p "${target}/docs"
  fi
  cat >"${shims}/sudo" <<'EOF'
#!/bin/bash
case $1 in
  -v|-n) exit 0 ;;
  systemd-run) while (( $# )) && [[ $1 != -- ]]; do shift; done; shift; exec "$@" ;;
  mkdir|rmdir|dnf|pacman) exit 0 ;;
  *) echo "SHIM sudo refused: $*" >&2; exit 97 ;;
esac
EOF
  chmod +x "${shims}/sudo"
  printf 'good\n' >"${target}/docs/good.txt"
  printf 'EVIL\n' >"${target}/docs/evil.bin"
  printf 'ad\n' >"${target}/docs/._good.txt"
  printf '%s\tunknown\t%s\t-\t-\t-\t-\n' "${tag}" "$(readlink -f "${target}")" >"${rep}/volumes.tsv"
  : >"${rep}/findings.tsv"
  for f in docs/good.txt docs/evil.bin docs/._good.txt; do
    sum=$(sha_of "${target}/${f}")
    printf '%s\t5\t0\t644\ttext/plain\t%s\n' "${sum}" "${f}" >>"${rep}/volumes/${tag}/files.tsv"
  done
  printf '# header\n%s\t%s\tDEFINITE\tclamav: X\tdocs/evil.bin\n' "${tag}" "$(sha_of "${target}/docs/evil.bin")" \
    >"${rep}/quarantine.tsv"
  out=$(PATH="${shims}:${PATH}" HOME="${TEST_ROOT}/home" \
        "${SCRIPT}" --no-session-hardening --export "${rep}" "${dest}" "${target}" 2>&1) || rc=$?
  [[ ${rc} == 0 ]] || fail "end-to-end export exited ${rc}: ${out}"
  [[ ${out} != *'SHIM '* ]] || fail "end-to-end export reached a refused privileged call: ${out}"
  cmp -s "${target}/docs/good.txt" "${dest}/${tag}/docs/good.txt" || fail 'good.txt not exported'
  [[ ! -e ${dest}/${tag}/docs/evil.bin && ! -e ${dest}/${tag}/docs/._good.txt ]] || fail 'evil.bin or clutter exported'
  [[ -f ${target}/docs/evil.bin ]] || fail 'export modified the target'
  compgen -G "${rep}/export-*.log" >/dev/null || fail 'no export log written'
  grep -hq $'^copied\t-\t'"${tag}"$'\t.*\tdocs/good.txt$' "${rep}"/export-*.log || fail 'copy not logged'
  grep -hq $'^skipped\tselected in quarantine.tsv\t' "${rep}"/export-*.log || fail 'quarantined skip not logged'
  [[ ${out} == *'copied:'*1* && ${out} == *'Export complete'* ]] || fail "summary missing: ${out}"
  # The same DEST is now non-empty: a second export is refused.
  rc=0
  out=$(PATH="${shims}:${PATH}" HOME="${TEST_ROOT}/home" \
        "${SCRIPT}" --no-session-hardening --export "${rep}" "${dest}" "${target}" 2>&1) || rc=$?
  [[ ${rc} == 1 && ${out} == *'is not empty'* ]] || fail "re-export into a used DEST: rc ${rc}: ${out}"
}

# --quarantine refuses APFS/HFS+ volumes before asking or touching anything;
# a stand-in block device is not available unprivileged, so the refusal is
# checked through the same function quarantine_main uses, on the report.
test_quarantine_refuses_mac_fs_in_report() (
  load_scanner
  local why
  why=$(quarantine_fs_types apfs 2>&1 >/dev/null) && fail 'apfs accepted'
  [[ ${why} == *'no safe read-write Linux driver'* ]] || fail "apfs refusal text: ${why}"
)

test_quarantine_template
printf 'PASS neutralize quarantine.tsv generation (active/commented, dedupe, strongest class)\n'
test_selection_parsing
printf 'PASS neutralize quarantine.tsv parsing (comments, CRLF, escaped tab/newline, malformed lines)\n'
test_os_clutter
printf 'PASS neutralize OS metadata clutter matcher\n'
test_match_volume_tag
printf 'PASS neutralize volume matching (UUID first, fallback, ambiguity, old reports)\n'
test_quarantine_fs_types
printf 'PASS neutralize in-place filesystem allow/refuse list\n'
test_check_export_dest
printf 'PASS neutralize DEST validation\n'
test_export_tree
printf 'PASS neutralize export selection, copy modes, sha re-verification and mismatch handling\n'
test_quarantine_file
printf 'PASS neutralize in-place quarantine of one file (mocked 7z, symlinked stub, mismatch)\n'
test_quarantine_refuses_mac_fs_in_report
printf 'PASS neutralize APFS/HFS+ in-place refusal\n'
test_option_validation
printf 'PASS neutralize option and report/DEST validation\n'
test_export_end_to_end
printf 'PASS neutralize --export end to end on a directory TARGET (sandbox and sudo shimmed)\n'
