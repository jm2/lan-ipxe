#!/usr/bin/env bash
# Mocked, CI-safe checks for scan-untrusted-media.sh's pure helper functions.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${REPO_ROOT}/scan-untrusted-media.sh
TEST_ROOT=$(mktemp -d -p "${TMPDIR:-/var/tmp}" scanner-helpers.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() { printf 'ASSERT: %s\n' "$*" >&2; exit 1; }

# Load the scanner's helper definitions without side effects: with no
# positional arguments its argument parser is a no-op, and the
# SCAN_UNTRUSTED_MEDIA_LIB hook stops it before the preflight (root checks,
# tool installation, network, mounts).
load_scanner() {
  set --
# shellcheck disable=SC2034  # read by the sourced scanner
  SCAN_UNTRUSTED_MEDIA_LIB=1
  # shellcheck disable=SC1090
  source "${SCRIPT}"
}

# assert_lines <file> <expected line>...: the file must hold exactly these
# lines, in this order.
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

test_tsv_esc() (
  load_scanner
  local raw=$'a\\b\tc\nd'
  tsv_esc "${raw}"
  [[ ${REPLY} == 'a\\b\tc\nd' ]] || fail "tsv_esc produced [${REPLY}]"
  [[ $(tsv_escape "${raw}") == 'a\\b\tc\nd' ]] || fail 'tsv_escape stdout differs from tsv_esc REPLY'
  [[ ${REPLY} != *$'\t'* && ${REPLY} != *$'\n'* ]] \
    || fail 'escaped cell still contains a raw separator'
  # Every backslash in the escaped cell is part of \\, \t or \n, so %b reads
  # the original field back exactly.
  [[ $(printf '%b' "${REPLY}") == "${raw}" ]] || fail 'escaped cell does not round-trip through printf %b'
  # Other control characters (terminal escapes from hostile names) are
  # escaped too and still round-trip.
  raw=$'evil\e]8;;http://x\a\x7fname'
  tsv_esc "${raw}"
  [[ ${REPLY} != *[[:cntrl:]]* ]] || fail "tsv_esc left a control character in [${REPLY}]"
  [[ ${REPLY} == 'evil\x1b]8;;http://x\x07\x7fname' ]] || fail "tsv_esc control escapes: [${REPLY}]"
  [[ $(printf '%b' "${REPLY}") == "${raw}" ]] || fail 'control-escaped cell does not round-trip'
  tsv_esc ''
  [[ -z ${REPLY} ]] || fail 'tsv_esc changed an empty field'
  tsv_esc 'plain-name.txt'
  [[ ${REPLY} == 'plain-name.txt' ]] || fail 'tsv_esc changed a plain name'
)

test_human_bytes() (
  load_scanner
  local in got
  local -A want=(
    [512]='512 B'
    [1023]='1023 B'
    [1024]='1.0 KiB'
    [1536]='1.5 KiB'
    [2048]='2.0 KiB'
    [1048576]='1.0 MiB'
    [1073741824]='1.0 GiB'
    [1099511627776]='1.0 TiB'
  )
  for in in "${!want[@]}"; do
    got=$(human_bytes "${in}")
    [[ ${got} == "${want[${in}]}" ]] || fail "human_bytes(${in}) = [${got}], want [${want[${in}]}]"
  done
)

test_classify_clam_signature() (
  load_scanner
  local sig got
  local -a gap_sigs=(
    Heuristics.Limits.Exceeded
    Heuristics.Limits.Exceeded.MaxFiles
    Heuristics.Encrypted.Zip
    Heuristics.Encrypted.RAR
    Heuristics.Broken.Media.mp3
  )
  local -a review_sigs=(
    PUA.Win.Packed.Upack
    PUA.Doc.Packed
    Heuristics.Broken.Executable
    Heuristics.Safebrowsing.Suspected-phishing
  )
  local -a definite_sigs=(Eicar-Test-Signature Win.Trojan.Agent-1234 Unix.Malware.Linux-7)
  for sig in "${gap_sigs[@]}"; do
    got=$(classify_clam_signature "${sig}")
    [[ ${got} == GAP ]] || fail "classify_clam_signature(${sig}) = ${got}, want GAP"
  done
  for sig in "${review_sigs[@]}"; do
    got=$(classify_clam_signature "${sig}")
    [[ ${got} == REVIEW ]] || fail "classify_clam_signature(${sig}) = ${got}, want REVIEW"
  done
  for sig in "${definite_sigs[@]}"; do
    got=$(classify_clam_signature "${sig}")
    [[ ${got} == DEFINITE ]] || fail "classify_clam_signature(${sig}) = ${got}, want DEFINITE"
  done
)

test_parse_clam_log() (
  load_scanner
  local dir=${TEST_ROOT}/clam-parse
  local root=${dir}/root
  mkdir -p "${root}/sub"
  cat >"${dir}/clamscan.log" <<EOF
${root}/sub/trojan.exe: Win.Trojan.Agent-1234 FOUND
${root}/sub/weird: name: Eicar-Test-Signature FOUND
${root}/enc.zip: Heuristics.Encrypted.Zip FOUND
${root}/pua.exe: PUA.Win.Packed.Upack FOUND
${root}/huge.rar: Heuristics.Limits.Exceeded FOUND
${root}/broken.mp3: Heuristics.Broken.Media.mp3 FOUND
${root}/phish.html: Heuristics.Safebrowsing.Suspected-phishing FOUND
LibClamAV debug: a line without the FOUND suffix
EOF
  : >"${dir}/findings.tsv"
  : >"${dir}/gaps.tsv"
  parse_clam_log "${dir}/clamscan.log" "${dir}/findings.tsv" "${dir}/gaps.tsv" "${root}"
  assert_lines "${dir}/findings.tsv" \
    $'DEFINITE\tclamav\tWin.Trojan.Agent-1234\tsub/trojan.exe' \
    $'DEFINITE\tclamav\tEicar-Test-Signature\tsub/weird: name' \
    $'REVIEW\tclamav\tPUA.Win.Packed.Upack\tpua.exe' \
    $'REVIEW\tclamav\tHeuristics.Safebrowsing.Suspected-phishing\tphish.html'
  assert_lines "${dir}/gaps.tsv" \
    $'clamav\tHeuristics.Encrypted.Zip\tenc.zip' \
    $'clamav\tHeuristics.Limits.Exceeded\thuge.rar' \
    $'clamav\tHeuristics.Broken.Media.mp3\tbroken.mp3'
)

test_parse_yara_output() (
  load_scanner
  local dir=${TEST_ROOT}/yara-parse
  local root=${dir}/root
  mkdir -p "${root}/sub"
  cat >"${dir}/yara.log" <<EOF
Macho_Installer [author = "forge", score = 80] ${root}/sub/installer.dmg
Rule_Seventy_Five [score = 75] ${root}/boundary-high
Rule_Seventy_Four [score = 74] ${root}/boundary-low
No_Score_Rule [author = "nobody"] ${root}/no-score
rule [score =80] ${root}/f
score_not_first [note = "x", score=58] ${root}/compact
skipped: not a rule line
EOF
  : >"${dir}/findings.tsv"
  parse_yara_output "${dir}/yara.log" "${dir}/findings.tsv" "${root}"
  assert_lines "${dir}/findings.tsv" \
    $'LIKELY\tyara\tMacho_Installer (score 80)\tsub/installer.dmg' \
    $'LIKELY\tyara\tRule_Seventy_Five (score 75)\tboundary-high' \
    $'REVIEW\tyara\tRule_Seventy_Four (score 74)\tboundary-low' \
    $'REVIEW\tyara\tNo_Score_Rule (score 0)\tno-score' \
    $'LIKELY\tyara\trule (score 80)\tf' \
    $'REVIEW\tyara\tscore_not_first (score 58)\tcompact'
)

# /proc/meminfo and nproc are stubbed so the min(cpu, mem)/cap/floor
# arithmetic is checked hermetically, independent of the host.
test_clam_jobs_bounds() (
  load_scanner
  local fake_mem fake_cpu
  awk() {
    [[ ${2:-} == /proc/meminfo ]] || fail "clam_jobs ran awk on unexpected args: $*"
    printf '%s\n' "${fake_mem}"
  }
  nproc() { printf '%s\n' "${fake_cpu}"; }
  fake_cpu=2 fake_mem=10
  [[ $(clam_jobs) == 2 ]] || fail 'clam_jobs ignored the CPU bound'
  fake_cpu=8 fake_mem=1
  [[ $(clam_jobs) == 1 ]] || fail 'clam_jobs ignored the memory bound'
  fake_cpu=99 fake_mem=99
  [[ $(clam_jobs) == 4 ]] || fail 'clam_jobs exceeded the cap of 4'
  fake_cpu=0 fake_mem=0
  [[ $(clam_jobs) == 1 ]] || fail 'clam_jobs dropped below the floor of 1'
)

test_clam_jobs_host_value() (
  load_scanner
  local got
  got=$(clam_jobs)
  [[ ${got} =~ ^[1-4]$ ]] || fail "clam_jobs returned [${got}] on this host, want an integer 1..4"
)

# internal_scan applies these regexes under nocasematch; mirror that here.
test_suspect_regexes() (
  load_scanner
  local value
  shopt -s nocasematch
  for value in application/x-mach-binary application/x-executable \
               application/x-apple-diskimage text/x-shellscript text/x-python \
               Text/X-Shellscript application/vnd.android.package-archive \
               application/vnd.ms-htmlhelp application/x-ms-shortcut text/x-ms-regedit \
               application/x-rpm application/vnd.debian.binary-package application/msonenote; do
    [[ ${value} =~ ${SUSPECT_MIMES} ]] || fail "SUSPECT_MIMES does not match ${value}"
  done
  for value in text/plain application/pdf image/jpeg application/octet-stream; do
    ! [[ ${value} =~ ${SUSPECT_MIMES} ]] || fail "SUSPECT_MIMES unexpectedly matches ${value}"
  done
  for value in 'Foo.app/' 'note.docm' 'Library/LaunchAgents/com.example.plist' \
               '/home/u/Downloads/notes.txt.py' 'home/u/.bashrc' 'ssh/authorized_keys' \
               'EVIL.APP/install' 'x/setup.com' 'Kit.kext/Contents/Info.plist' \
               'Payload/Game.ipa' 'profile.mobileconfig' 'Share.appex/Info.plist' \
               'update.apk' 'classes.dex' 'invoice.pdf.lnk' 'run.ps1' 'help.chm' \
               'Microsoft/Windows/Start Menu/Programs/Startup/a.txt' 'Windows/System32/Tasks/Updater' \
               'autorun.inf' 'home/u/.config/autostart/x.desktop' 'etc/ld.so.preload' \
               'tool.AppImage' 'fix.sh' 'pkg.deb' 'notes.one' 'conn.rdp' 'disk.vhdx'; do
    [[ ${value} =~ ${SUSPECT_NAMES} ]] || fail "SUSPECT_NAMES does not match ${value}"
  done
  for value in photo.jpg report.pdf notes.txt Resume.docx fake.appendix \
               'someone@icloud.com/Old Downloads/notes.txt' 'backup.exe/readme.txt' \
               'shell.sh.d/readme.md' 'site.js'; do
    ! [[ ${value} =~ ${SUSPECT_NAMES} ]] || fail "SUSPECT_NAMES unexpectedly matches ${value}"
  done
)

test_os_metadata_and_exec_mimes() (
  load_scanner
  local value
  shopt -s nocasematch
  for value in '._report.pdf' 'a/b/._x.dmg' '.DS_Store' 'Thumbs.db' '.Spotlight-V100/Store-V2/x' \
               '$RECYCLE.BIN/S-1-5/x.exe' 'System Volume Information/x' '.Trash-1000/files/a' '.fseventsd/x'; do
    [[ ${value} =~ ${OS_METADATA} ]] || fail "OS_METADATA does not match ${value}"
  done
  for value in 'report.pdf' 'a._b.pdf' 'My.DS_Store.txt' 'Spotlight/x'; do
    ! [[ ${value} =~ ${OS_METADATA} ]] || fail "OS_METADATA unexpectedly matches ${value}"
  done
  for value in application/x-dosexec application/vnd.microsoft.portable-executable \
               application/x-mach-binary application/x-pie-executable application/vnd.android.package-archive; do
    [[ ${value} =~ ^(${EXEC_MIMES})$ ]] || fail "EXEC_MIMES does not match ${value}"
  done
  for value in application/pdf image/jpeg application/zip; do
    ! [[ ${value} =~ ^(${EXEC_MIMES})$ ]] || fail "EXEC_MIMES unexpectedly matches ${value}"
  done
  [[ application/pdf =~ ${EXPECTED_MIME[pdf]} ]] || fail 'EXPECTED_MIME[pdf] rejects a PDF'
  ! [[ application/octet-stream =~ ${EXPECTED_MIME[pdf]} ]] || fail 'EXPECTED_MIME[pdf] accepts octet-stream'
  [[ image/heic =~ ${EXPECTED_MIME[jpg]} ]] || fail 'EXPECTED_MIME[jpg] rejects another image type'
)

test_clam_eta() (
  load_scanner
  local dir out now
  dir=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
  trap 'rm -rf -- "${dir}"' EXIT
  now=$(date +%s)
  [[ $(clam_eta "${dir}" 30 4) == estimating ]] || fail 'clam_eta did not wait for a finished batch'
  # Two finished 60 s batches, 4 jobs, 30 batches: 28 x 60 / 4 = 420 s.
  for id in 00000 00001; do
    touch -d "@$(( now - 60 ))" "${dir}/clamscan.${id}.start"
    echo 0 >"${dir}/clamscan.${id}.rc"; touch -d "@${now}" "${dir}/clamscan.${id}.rc"
  done
  : >"${dir}/clamscan.00002.start"   # still running: ignored
  out=$(clam_eta "${dir}" 30 4)
  [[ ${out} == 0h07m ]] || fail "clam_eta gave ${out}, expected 0h07m"
)

test_internal_scan_guard() {
  local out rc args
  for args in '--internal-scan' '--internal-scan one two'; do
    rc=0
    # shellcheck disable=SC2086 # deliberate word splitting of the case
    out=$("${SCRIPT}" ${args} 2>&1 >/dev/null) || rc=$?
    [[ ${rc} == 1 ]] || fail "'${args}' exited ${rc}, expected 1"
    [[ ${out} == *'--internal-scan needs 5 arguments'* ]] \
      || fail "'${args}' did not print the argument-count error on stderr"
  done
}

test_tsv_esc
printf 'PASS scanner tsv_esc/tsv_escape escaping and round-trip\n'
test_human_bytes
printf 'PASS scanner human_bytes formatting and unit boundaries\n'
test_classify_clam_signature
printf 'PASS scanner ClamAV signature classification (GAP/REVIEW/DEFINITE)\n'
test_parse_clam_log
printf 'PASS scanner clamscan log parsing (last-colon split, relative paths, gaps)\n'
test_parse_yara_output
printf 'PASS scanner YARA output parsing (score thresholds, meta spellings)\n'
test_clam_jobs_bounds
printf 'PASS scanner clam_jobs memory/CPU bounds and 1..4 clamp\n'
test_clam_jobs_host_value
printf 'PASS scanner clam_jobs returns 1..4 on the local host\n'
test_suspect_regexes
printf 'PASS scanner suspect MIME/name regular expressions\n'
test_os_metadata_and_exec_mimes
printf 'PASS scanner OS-metadata, executable-MIME and expected-MIME tables\n'
test_clam_eta
printf 'PASS scanner ClamAV ETA from finished-batch durations and job count\n'
test_internal_scan_guard
printf 'PASS scanner --internal-scan argument-count guard\n'
