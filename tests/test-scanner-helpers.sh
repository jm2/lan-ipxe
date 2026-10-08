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
  # A raw C1 byte (invalid UTF-8) is a CSI for a terminal; the Unicode bidi
  # overrides can visually reorder a path. Both must be escaped too.
  raw=$'raw\x9bcsi'
  tsv_esc "${raw}"
  [[ ${REPLY} == 'raw\x9bcsi' ]] || fail "raw C1 byte not escaped: [${REPLY}]"
  [[ $(printf '%b' "${REPLY}") == "${raw}" ]] || fail 'C1-escaped cell does not round-trip'
  raw=$'bidi\xe2\x80\xaename'
  tsv_esc "${raw}"
  [[ ${REPLY} == 'bidi\u202ename' ]] || fail "bidi override not escaped: [${REPLY}]"
  [[ $(printf '%b' "${REPLY}") == "${raw}" ]] || fail 'bidi-escaped cell does not round-trip'
  # Valid printable UTF-8 stays visible as-is.
  tsv_esc $'caf\xc3\xa9.jpg'
  [[ ${REPLY} == $'caf\xc3\xa9.jpg' ]] || fail "valid UTF-8 mangled: [${REPLY}]"
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
  # A file name carrying its own forged FOUND line (control characters
  # included) must never become a finding with hostile detail text.
  printf 'x: \\e]8;;http://evil\\aEvil FOUND\ny: Eicar-Test-Signature FOUND\n' >"${dir}/clamscan.log"
  cat >>"${dir}/clamscan.log" <<EOF
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
  # The second forged line parses as a detection at path "y"; only the
  # inventory mapping (collect_results) can flag it, which parse_clam_log
  # cannot know about here.
  assert_lines "${dir}/findings.tsv" \
    $'DEFINITE\tclamav\tEicar-Test-Signature\ty' \
    $'DEFINITE\tclamav\tWin.Trojan.Agent-1234\tsub/trojan.exe' \
    $'DEFINITE\tclamav\tEicar-Test-Signature\tsub/weird: name' \
    $'REVIEW\tclamav\tPUA.Win.Packed.Upack\tpua.exe' \
    $'REVIEW\tclamav\tHeuristics.Safebrowsing.Suspected-phishing\tphish.html'
  assert_lines "${dir}/gaps.tsv" \
    "$(printf 'clamav\tsuspicious clamscan line (signature not recognized):\tx: \\\\e]8;;http://evil\\\\aEvil')" \
    $'clamav\tHeuristics.Encrypted.Zip\tenc.zip' \
    $'clamav\tHeuristics.Limits.Exceeded\thuge.rar' \
    $'clamav\tHeuristics.Broken.Media.mp3\tbroken.mp3' \
    $'clamav\tunrecognized clamscan output line (treated as unscanned):\tLibClamAV debug: a line without the FOUND suffix'
)

test_parse_yara_output() (
  load_scanner
  local dir=${TEST_ROOT}/yara-parse
  local root=${dir}/root
  mkdir -p "${root}/sub"
  {
    printf 'Macho_Installer [author = "forge", score = 80] %s/sub/installer.dmg\n' "${root}"
    printf 'Rule_Seventy_Five [score = 75] %s/boundary-high\n' "${root}"
    printf 'Rule_Seventy_Four [score = 74] %s/boundary-low\n' "${root}"
    printf 'No_Score_Rule [author = "nobody"] %s/no-score\n' "${root}"
    printf 'rule [score =80] %s/f\n' "${root}"
    printf 'score_not_first [note = "x", score=58] %s/compact\n' "${root}"
    # An invalid-UTF-8 byte in the name: the old regex dropped such lines
    # wholesale, hiding real detections.
    printf 'Latin_Rule [score = 90] %s/caf\xe9.exe\n' "${root}"
    # A rule name with hostile bytes must not become a finding detail.
    printf 'bad;rule [score = 90] %s/x\n' "${root}"
    printf 'skipped: not a rule line\n'
  } >"${dir}/yara.log"
  : >"${dir}/findings.tsv"
  : >"${dir}/gaps.tsv"
  parse_yara_output "${dir}/yara.log" "${dir}/findings.tsv" "${dir}/gaps.tsv" "${root}"
  assert_lines "${dir}/findings.tsv" \
    $'LIKELY\tyara\tMacho_Installer (score 80)\tsub/installer.dmg' \
    $'LIKELY\tyara\tRule_Seventy_Five (score 75)\tboundary-high' \
    $'REVIEW\tyara\tRule_Seventy_Four (score 74)\tboundary-low' \
    $'REVIEW\tyara\tNo_Score_Rule (score 0)\tno-score' \
    $'LIKELY\tyara\trule (score 80)\tf' \
    $'REVIEW\tyara\tscore_not_first (score 58)\tcompact' \
    $'LIKELY\tyara\tLatin_Rule (score 90)\tcaf\xe9.exe'
  assert_lines "${dir}/gaps.tsv" \
    $'yara\tunrecognized yara output line (rule name not valid):\tbad;rule [score = 90] '"${root}"'/x' \
    $'yara\tunrecognized yara output line (treated as unscanned):\tskipped: not a rule line'
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
  [[ $(clam_eta "${dir}" 3000 4) == '0% of data, ETA estimating' ]] || fail 'clam_eta did not wait for a finished batch'
  # Two finished 60 s batches of weight 100 each, total weight 3000, 4 jobs:
  # 2800 x (120 s / 200) / 4 = 420 s.
  for id in 00000 00001; do
    touch -d "@$(( now - 60 ))" "${dir}/clamscan.${id}.start"
    echo 0 >"${dir}/clamscan.${id}.rc"; touch -d "@${now}" "${dir}/clamscan.${id}.rc"
    echo 100 >"${dir}/clambatch.${id}.w"
  done
  : >"${dir}/clamscan.00002.start"; echo 900 >"${dir}/clambatch.00002.w"   # still running
  out=$(clam_eta "${dir}" 3000 4)
  [[ ${out} == '6% of data, ETA 0h07m' ]] || fail "clam_eta gave [${out}]"
)

# collect_results: findings whose path is not in the volume's inventory (a
# forged or malformed scanner line) keep their row but also become gaps, so
# neither the report nor --export can treat the volume as fully triaged.
test_collect_results() (
  load_scanner
  local dir=${TEST_ROOT}/collect
  # shellcheck disable=SC2034 # read by collect_results
  REPORT_DIR=${dir}
  mkdir -p "${dir}/volumes/vol1"
  printf 'a%.0s' {1..64} >"${dir}/shaA"
  local shaA; shaA=$(<"${dir}/shaA")
  {
    printf '%s\t5\t0\t644\ttext/plain\tgood.txt\n' "${shaA}"
    printf '%s\t6\t0\t644\ttext/plain\tdocs/evil.exe\n' "${shaA}"
  } >"${dir}/volumes/vol1/files.tsv"
  : >"${dir}/volumes/vol1/gaps.tsv"
  printf 'DEFINITE\tclamav\tWin.Trojan.X\tdocs/evil.exe\n' >>"${dir}/volumes/vol1/findings.tsv"
  printf 'DEFINITE\tclamav\tEicar-Test-Signature\ty\n' >>"${dir}/volumes/vol1/findings.tsv"
  printf 'REVIEW\tyara\tOdd (score 10)\tgood.txt\n' >>"${dir}/volumes/vol1/findings.tsv"
  : >"${dir}/gaps-global.tsv"
  collect_results
  assert_lines "${dir}/findings.tsv" \
    "$(printf 'DEFINITE\tclamav\tWin.Trojan.X\tvol1\t%s\tdocs/evil.exe' "${shaA}")" \
    $'DEFINITE\tclamav\tEicar-Test-Signature\tvol1\t-\ty' \
    "$(printf 'REVIEW\tyara\tOdd (score 10)\tvol1\t%s\tgood.txt' "${shaA}")"
  grep -q $'^vol1\tscan\tdetection not mapped to a scanned file (malformed or forged scanner output): y\t-$' "${dir}/gaps.tsv" \
    || fail 'unmapped detection did not become a coverage gap'
  (( $(grep -c 'not mapped to a scanned file' "${dir}/gaps.tsv") == 1 )) \
    || fail 'mapped detection also flagged as unmapped'
)

test_clam_split_batches() (
  load_scanner
  local dir f lines weights=() i long
  dir=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
  trap 'rm -rf -- "${dir}"' EXIT
  long=$(printf '/v/%.0s' {1..120}; printf 'x%.0s' {1..900})
  {
    for i in $(seq 1 100); do printf '50000 1700000000 644 /v/photo%s.jpg\0' "${i}"; done
    printf '%s\0' '200000000 1700000000 644 /v/big1.dmg' '200000000 1700000000 644 /v/big two.dmg'
    printf '10 1700000000 644 /v/new\nline.txt\0'
    # A trailing CR is stripped from --file-list lines and the file is then
    # "not found" silently; such names go to the argument batch.
    printf '20 1700000000 644 /v/carriage\rreturn.txt\0'
    # Paths at the 1023-byte list-line limit likewise.
    printf '30 1700000000 644 %s\0' "${long}"
  } >"${dir}/meta"
  # 4 batches of the total weight (bytes + 256 KiB per file).
  clam_split_batches "${dir}/meta" "${dir}" $(( (405000060 + 103 * 262144 + 3) / 4 ))
  for f in "${dir}"/clambatch.*.lst; do weights+=("$(<"${f%.lst}.w")"); done
  # Greedy packing: each 200 MB image alone exceeds a quarter of the weight.
  (( ${#weights[@]} >= 2 && ${#weights[@]} <= 4 )) || fail "clam_split_batches made ${#weights[@]} batches"
  # The two disk images land in different batches: weight, not file count.
  ! grep -lx '/v/big1.dmg' "${dir}"/clambatch.*.lst | xargs grep -qx '/v/big two.dmg' \
    || fail 'both large files ended up in one batch'
  lines=$(cat "${dir}"/clambatch.*.lst | wc -l)
  (( lines == 102 )) || fail "batches hold ${lines} paths, expected 102"
  [[ $(tr -d '\0' <"${dir}/clambatch.alias") == $'/v/new\nline.txt/v/carriage\rreturn.txt'"${long}" ]] \
    || fail 'newline/CR/long names not all in the NUL batch'
  [[ $(<"${dir}/clambatch.alias.w") == $(( 10 + 20 + 30 + 3 * 262144 )) ]] || fail 'NUL batch weight wrong'
)

test_hardening_regressions() (
  load_scanner
  local dir root out link
  # Raw C1 bytes (OSC 0x9d, APC 0x9f) and zero-width characters are escaped.
  tsv_esc $'a\x9db\x9fc'
  [[ ${REPLY} == 'a\x9db\x9fc' ]] || fail "raw C1 bytes not escaped: [${REPLY}]"
  tsv_esc $'zero\u200bwidth\ufeff'
  [[ ${REPLY} == 'zero\u200bwidth\ufeff' ]] || fail "zero-width characters not escaped: [${REPLY}]"
  dir=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
  trap 'rm -rf -- "${dir}"' EXIT
  root=${dir}/vol out=${dir}/out
  mkdir -p "${root}" "${out}"
  printf 'x' >"${root}/"$'evil\nname.exe'
  # A ClamAV detection reported through a symlink alias maps back to the file.
  printf '%s\0' "${root}/"$'evil\nname.exe' >"${out}/clambatch.alias"
  clam_alias_batch "${out}"
  link=$(head -n 1 "${out}/clambatch.alias.lst")
  [[ -L ${link} ]] || fail 'clam_alias_batch did not create the alias'
  printf '%s: Win.Test.Evil FOUND\n' "${link}" >"${out}/clamscan.log"
  : >"${out}/findings.tsv"; : >"${out}/gaps.tsv"
  parse_clam_log "${out}/clamscan.log" "${out}/findings.tsv" "${out}/gaps.tsv" "${root}" "${out}/clamlinks"
  [[ $(cut -f4 "${out}/findings.tsv") == 'evil\nname.exe' ]] || fail "alias did not map back: $(cat "${out}/findings.tsv")"
  [[ ! -s ${out}/gaps.tsv ]] || fail "alias mapping left a gap: $(cat "${out}/gaps.tsv")"
  # YARA prints the newline as the text \n; the decoded name is the file.
  printf 'Test_Rule [score=80] %s/evil\\nname.exe\n' "${root}" >"${out}/yara.log"
  : >"${out}/findings.tsv"
  parse_yara_output "${out}/yara.log" "${out}/findings.tsv" "${out}/gaps.tsv" "${root}"
  [[ $(cut -f4 "${out}/findings.tsv") == 'evil\nname.exe' ]] || fail "YARA name not decoded: $(cat "${out}/findings.tsv")"
  # A forged FOUND line with a signature outside the charset is a gap.
  printf '%s/a: \e]0;x\a FOUND\n' "${root}" >"${out}/clamscan.log"
  : >"${out}/findings.tsv"; : >"${out}/gaps.tsv"
  parse_clam_log "${out}/clamscan.log" "${out}/findings.tsv" "${out}/gaps.tsv" "${root}"
  [[ ! -s ${out}/findings.tsv && -s ${out}/gaps.tsv ]] || fail 'forged clamscan line became a finding'
  ! grep -q $'\e' "${out}/gaps.tsv" || fail 'raw ESC reached gaps.tsv'
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
printf 'PASS scanner YARA output parsing (score thresholds, invalid UTF-8 paths, gaps)\n'
test_collect_results
printf 'PASS scanner report merge (unmapped detections become coverage gaps)\n'
test_clam_jobs_bounds
printf 'PASS scanner clam_jobs memory/CPU bounds and 1..4 clamp\n'
test_clam_jobs_host_value
printf 'PASS scanner clam_jobs returns 1..4 on the local host\n'
test_suspect_regexes
printf 'PASS scanner suspect MIME/name regular expressions\n'
test_os_metadata_and_exec_mimes
printf 'PASS scanner OS-metadata, executable-MIME and expected-MIME tables\n'
test_clam_split_batches
printf 'PASS scanner ClamAV batches balanced by weight, newline names split out\n'
test_clam_eta
printf 'PASS scanner ClamAV ETA from finished-batch weights, durations and job count\n'
test_hardening_regressions
printf 'PASS scanner hardening: C1/zero-width escapes, ClamAV aliases, YARA names, forged lines\n'
test_internal_scan_guard
printf 'PASS scanner --internal-scan argument-count guard\n'
