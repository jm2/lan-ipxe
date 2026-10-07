#!/usr/bin/env bash
#
# Read-only malware triage of untrusted removable media (USB drives, disk
# images) on a Linux workstation. Written for drives that came from a
# compromised macOS host: it understands APFS, HFS+, exFAT/FAT, NTFS and ext*
# volumes, images block devices before touching them, and never mounts
# anything writable or executable.
#
# Run as your normal user; privileged steps go through sudo. Fedora 41+ is the
# primary target (missing tools are installed with dnf); Arch works when the
# tools are already installed (apfs-fuse is AUR-only there).
#
#   scan-untrusted-media.sh --image-dir /data/images /dev/sdb /dev/sdc
#   scan-untrusted-media.sh --no-image /dev/sdb            # scan the drive in place
#   scan-untrusted-media.sh /data/images/drive1.img        # rescan an existing image
#   scan-untrusted-media.sh --vt /mnt/already-mounted-dir  # any directory works
#
# What it does, per target:
#   1. hardens the GNOME session first (no automount, thumbnailers or
#      removable-media indexing: those parse untrusted files automatically)
#   2. block devices: refuses if anything on them is mounted, marks them
#      read-only, and (default) images them with ddrescue into --image-dir,
#      recording the image SHA-256 and any unreadable sectors
#   3. attaches images read-only, detects every partition and APFS volume,
#      and mounts each one ro,nosuid,nodev,noexec (APFS via apfs-fuse)
#   4. scans every mounted volume inside a transient systemd sandbox: the
#      invoking user plus CAP_DAC_READ_SEARCH only, no network, read-only
#      host, so a parser exploit in a scanner gains nothing useful
#        - full inventory and SHA-256 manifest of every file
#        - ClamAV (fresh definitions, all limits raised, archives/DMG/PKG
#          unpacked, PUA and macro alerts, encrypted/oversize files reported)
#        - YARA with the YARA Forge rule set (includes macOS malware rules)
#        - an inventory of executable content: Mach-O, scripts, app bundles,
#          installers, disk images, launch agents, macro documents, ...
#   5. optionally looks up hashes on VirusTotal (--vt; hashes only, never
#      file contents)
#   6. writes a report: DEFINITE / LIKELY / REVIEW findings plus the coverage
#      gaps that limit how much a clean result can be trusted
#
# No scan can prove media clean. Read the coverage-gap section of the report:
# a short gap list plus no findings is the strongest result this can give.

set -euo pipefail

#--- Config -----------------------------------------------------------------
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
YARA_FORGE_API=https://api.github.com/repos/YARAHQ/yara-forge/releases/latest
CACHE_DIR=${XDG_CACHE_HOME:-${HOME}/.cache}/scan-untrusted-media
VT_KEY_FILE=${XDG_CONFIG_HOME:-${HOME}/.config}/virustotal/api-key
VT_API=https://www.virustotal.com/api/v3/files
CLAMAV_DB_DIR=/var/lib/clamav
# Large enough for real-world installers and disk images; anything still over
# a limit is reported as a coverage gap instead of being silently "clean".
CLAM_LIMITS=(--max-filesize=4000M --max-scansize=4000M --max-files=200000
             --max-recursion=40 --max-scantime=900000 --max-partitions=200
             --max-embeddedpe=200M --max-htmlnormalize=200M
             --max-scriptnormalize=200M --max-ziptypercg=200M)
YARA_MAX_BYTES=$(( 1024 * 1024 * 1024 ))
YARA_TIMEOUT=120
# Executable or auto-run content that deserves a human look regardless of
# scanner verdicts (MIME types reported by file(1)).
SUSPECT_MIMES='^(application/(x-mach-binary|x-executable|x-pie-executable|x-sharedlib|x-object|x-dosexec|vnd\.microsoft\.portable-executable|x-msdownload|x-msi|java-archive|x-java-applet|x-apple-diskimage|x-xar|x-iso9660-image|x-ms-shortcut|x-bytecode\.python)|text/(x-shellscript|x-script\.python|x-python|x-perl|x-ruby|x-php|x-tcl|x-msdos-batch|x-applescript))$'
# File-name patterns (case-insensitive, matched against the relative path).
# Bundle types are directories, so they match anywhere in the path (every
# file inside Foo.app/ is app content); every other extension must end the
# path, or a folder such as "name@icloud.com/" would flag everything below it.
SUSPECT_NAMES='(\.(app|pkg|mpkg|scptd|workflow|action|bundle|plugin|kext|osax|qlgenerator|mdimporter|saver|prefpane)(/|$)|\.(dmg|command|tool|scpt|applescript|terminal|jar|dylib|so|webloc|inetloc|fileloc|lnk|url|desktop|exe|dll|scr|com|bat|cmd|ps1|psm1|py|pyw|pl|pm|rb|php|pht|vbs|vbe|jse|wsf|hta|msi|iso|docm|dotm|xlsm|xltm|xlam|pptm|potm|ppam|sldm)$|(^|/)(LaunchAgents|LaunchDaemons|StartupItems|Login ?Items|ScriptingAdditions|Extensions)/|(^|/)\.(zshrc|zprofile|zshenv|zlogin|bash_profile|bashrc|profile|login)$|(^|/)(authorized_keys|crontab)$)'

PKGS_FEDORA=(apfs-fuse clamav clamav-update curl ddrescue file jq kernel-modules-extra unzip yara)
PKGS_ARCH=(clamav curl ddrescue file jq unzip yara)

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ${0##*/} [options] TARGET...
       ${0##*/} --prepare-session | --restore-session
       ${0##*/} -h|--help

Read-only malware triage of untrusted media. TARGET is a block device
(/dev/sdX), a raw disk/partition image, or an already-mounted directory.

  --image-dir DIR     image block devices with ddrescue into DIR first and
                      scan the image (default when a block device is given)
  --no-image          scan block devices in place (still strictly read-only)
  --resume            continue an interrupted ddrescue image already in the
                      image dir (refused otherwise: a reader or stick without
                      a unique serial would reuse another drive's image)
  --report-dir DIR    where to write the report (default:
                      ./media-scan-YYYYmmdd-HHMMSS)
  --yara-set SET      YARA Forge rule set: core, extended (default) or full
  --yara-rules FILE   use this YARA rules file instead of YARA Forge
  --no-yara           skip YARA
  --clam-db PATH      ClamAV database file or directory (default: system DB)
  --no-update         do not refresh ClamAV definitions or YARA Forge rules
  --vt                look up SHA-256 hashes on VirusTotal (key from
                      \$VT_API_KEY or ${VT_KEY_FILE/#"${HOME}"/\~})
  --vt-all            with --vt, look up every file instead of only
                      detections and executable content (quota-hungry)
  --vt-rate N         VirusTotal requests per minute (default 4, the public
                      API limit)
  --keep-mounted      leave volumes mounted (read-only) for manual review
  --no-session-hardening
                      do not change GNOME automount/thumbnail/index settings
  --prepare-session   only harden the desktop session (automount, autorun,
                      thumbnails, removable-media indexing off) and exit; run
                      this BEFORE plugging in any untrusted drive
  --restore-session   undo --prepare-session and exit

Exit: 0 no findings, 3 findings in DEFINITE or LIKELY, 1 error.
USAGE
}

#--- Arguments ----------------------------------------------------------------
IMAGE_DIR=
IMAGE_MODE=auto
REPORT_DIR=
YARA_SET=extended
YARA_RULES=
USE_YARA=1
CLAM_DB=
UPDATE=1
USE_VT=0
VT_ALL=0
VT_RATE=4
KEEP_MOUNTED=0
RESUME=0
HARDEN_SESSION=1
SESSION_ACTION=
SESSION_RESTORE=${XDG_STATE_HOME:-${HOME}/.local/state}/scan-untrusted-media/restore-session-settings.sh
TARGETS=()

# --internal-scan is the sandboxed worker entry point; see scan_volume.
if [[ ${1:-} == --internal-scan ]]; then
  INTERNAL_SCAN=1
else
  INTERNAL_SCAN=0
  while (( $# )); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --image-dir)  (( $# >= 2 )) || die "--image-dir needs a directory"; IMAGE_DIR=$2; IMAGE_MODE=image; shift ;;
      --no-image)   IMAGE_MODE=direct ;;
      --report-dir) (( $# >= 2 )) || die "--report-dir needs a directory"; REPORT_DIR=$2; shift ;;
      --yara-set)
        (( $# >= 2 )) || die "--yara-set needs core, extended or full"
        case $2 in core|extended|full) YARA_SET=$2 ;; *) die "invalid --yara-set: $2" ;; esac
        shift ;;
      --yara-rules) (( $# >= 2 )) || die "--yara-rules needs a file"; YARA_RULES=$2; shift ;;
      --no-yara)    USE_YARA=0 ;;
      --clam-db)    (( $# >= 2 )) || die "--clam-db needs a path"; CLAM_DB=$2; shift ;;
      --no-update)  UPDATE=0 ;;
      --vt)         USE_VT=1 ;;
      --vt-all)     VT_ALL=1 ;;
      --vt-rate)
        (( $# >= 2 )) && [[ $2 =~ ^[1-9][0-9]*$ ]] || die "--vt-rate needs a positive integer"
        VT_RATE=$2; shift ;;
      --keep-mounted) KEEP_MOUNTED=1 ;;
      --resume)     RESUME=1 ;;
      --no-session-hardening) HARDEN_SESSION=0 ;;
      --prepare-session) SESSION_ACTION=prepare ;;
      --restore-session) SESSION_ACTION=restore ;;
      --) shift; TARGETS+=("$@"); break ;;
      -*) usage >&2; die "Unknown option: $1" ;;
      *)  TARGETS+=("$1") ;;
    esac
    shift
  done
fi

#--- Helpers: text and records ----------------------------------------------
# tsv_esc: make one NUL-free field safe for a TSV cell (backslash, tab and
# newline become \\, \t and \n) and leave it in REPLY. Odd names are kept
# visible, not dropped. No subshell: it runs once per file.
tsv_esc() {
  REPLY=$1
  REPLY=${REPLY//\\/\\\\}
  REPLY=${REPLY//$'\t'/\\t}
  REPLY=${REPLY//$'\n'/\\n}
}
tsv_escape() { tsv_esc "$1"; printf '%s' "${REPLY}"; }

human_bytes() {
  awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

# classify_clam_signature <name>: DEFINITE for real signatures, GAP for
# "could not fully scan" heuristics, REVIEW for PUA and other heuristics.
classify_clam_signature() {
  case $1 in
    Heuristics.Limits.Exceeded*|Heuristics.Encrypted*|Heuristics.Broken.Media*) printf 'GAP' ;;
    PUA.*|Heuristics.*) printf 'REVIEW' ;;
    *) printf 'DEFINITE' ;;
  esac
}

# parse_clam_log <clamscan stdout> <findings.tsv> <gaps.tsv> <root>: clamscan
# prints "<path>: <signature> FOUND". The path may itself contain ": ", so
# split on the last one. Paths are stored relative to <root>.
parse_clam_log() {
  local log_file=$1 findings=$2 gaps=$3 root=$4 line path sig cls
  while IFS= read -r line; do
    [[ ${line} == *' FOUND' ]] || continue
    line=${line% FOUND}
    sig=${line##*: }
    path=${line%: *}
    path=${path#"${root}"/}
    cls=$(classify_clam_signature "${sig}")
    tsv_esc "${path}"
    if [[ ${cls} == GAP ]]; then
      printf 'clamav\t%s\t%s\n' "${sig}" "${REPLY}" >>"${gaps}"
    else
      printf '%s\tclamav\t%s\t%s\n' "${cls}" "${sig}" "${REPLY}" >>"${findings}"
    fi
  done <"${log_file}"
}

# parse_yara_output <yara -m stdout> <findings.tsv> <root>: lines look like
# "RULE [meta...] /path". YARA Forge rules carry score=0..100 metadata; a
# score of 75+ is treated as LIKELY, anything lower as REVIEW.
parse_yara_output() {
  local out=$1 findings=$2 root=$3 line rule meta path score cls
  while IFS= read -r line; do
    [[ ${line} =~ ^([A-Za-z0-9_]+)\ \[(.*)\]\ (/.*)$ ]] || continue
    rule=${BASH_REMATCH[1]} meta=${BASH_REMATCH[2]} path=${BASH_REMATCH[3]}
    path=${path#"${root}"/}
    score=0
    # yara 4.5 prints "score =80"; tolerate optional spaces around the
    # list separator and the = of either spelling.
    local score_re='(^|,) *score *= *([0-9]+)'
    [[ ${meta} =~ ${score_re} ]] && score=${BASH_REMATCH[2]}
    if (( score >= 75 )); then cls=LIKELY; else cls=REVIEW; fi
    tsv_esc "${path}"
    printf '%s\tyara\t%s (score %s)\t%s\n' "${cls}" "${rule}" "${score}" "${REPLY}" >>"${findings}"
  done <"${out}"
}

# clam_jobs: parallel clamscan processes. Each loads the full signature set
# (~1.2 GiB RSS), so bound by available memory as well as CPUs.
clam_jobs() {
  local mem cpu j
  mem=$(awk '/^MemAvailable:/ { print int($2 / 1572864) }' /proc/meminfo)
  cpu=$(nproc)
  j=$(( cpu < mem ? cpu : mem ))
  (( j > 4 )) && j=4
  (( j < 1 )) && j=1
  printf '%s' "${j}"
}

#--- Sandboxed worker -------------------------------------------------------
# Runs inside the systemd sandbox (or directly in tests). Arguments:
#   <volume root> <output dir> <fs type> <compiled YARA rules or -> <ClamAV DB or ->
# Writes into the output dir:
#   files.tsv       sha256, size, mtime, mode, mime, path (every regular file)
#   findings.tsv    class, source, detail, path
#   gaps.tsv        source, reason, path (everything not fully examined)
#   suspect.tsv     sha256, mime, size, mtime, reason, path (executable content)
#   bundles.txt     macOS bundle directories (.app, .pkg, ...)
#   counts          key=value totals
#   clamscan.log, yara.log raw scanner output
# Paths are relative to the volume root and TSV-escaped (see tsv_esc).
# scan_progress <out> <text>: publish the worker's current phase for the host
# side to print (atomic replace; the host polls it while the sandbox runs).
scan_progress() {
  printf '%s\n' "$2" >"$1/progress.tmp" && mv -f -- "$1/progress.tmp" "$1/progress"
}

# count_existing <path>...: how many of the (glob-expanded) paths exist; an
# unmatched glob stays literal and counts as 0. Never fails, unlike a
# `compgen -G | wc -l` pipeline under pipefail.
count_existing() {
  local f c=0
  for f in "$@"; do [[ -e ${f} ]] && c=$(( c + 1 )); done
  printf '%s' "${c}"
}

# eta <done> <total> <start-epoch>: rough time left at the rate so far.
eta() {
  local done=$1 total=$2 start=$3 elapsed left
  elapsed=$(( EPOCHSECONDS - start ))
  (( done > 0 && elapsed > 0 && total > done )) || { printf '?'; return; }
  left=$(( (total - done) * elapsed / done ))
  printf '%dh%02dm' $(( left / 3600 )) $(( left % 3600 / 60 ))
}

internal_scan() {
  local root=${1%/} out=$2 fstype=$3 yara_rules=$4 clam_db=$5
  local meta=${out}/files.meta list=${out}/files.lst
  local rec rest path rel erel sum mime size mtime mode line reason f rc
  local files=0 bytes=0 suspects=0 zero_len=0 unix_fs=0 jobs batches per
  local total_files total_bytes n done_bytes started xpid
  local -a clam_opts=()
  local -A mime_of=() sum_of=() size_of=()
  [[ -d ${root} && -d ${out} ]] || { echo "internal-scan: bad paths" >&2; return 1; }
  : >"${out}/findings.tsv"; : >"${out}/gaps.tsv"; : >"${out}/suspect.tsv"
  [[ ${fstype} =~ ^(apfs|hfsplus|hfs|ext[234]|xfs|btrfs)$ ]] && unix_fs=1

  # Inventory: one find pass records size, mtime and mode next to each path
  # (no per-file stat forks). find errors (permission, I/O) are gaps.
  scan_progress "${out}" "inventory: listing files"
  find "${root}" -xdev -type f -printf '%s %Ts %m %p\0' >"${meta}" 2>"${out}/find.err" || true
  sed -z 's/^[0-9]* -\{0,1\}[0-9]* [0-7]* //' "${meta}" >"${list}"
  total_files=0 total_bytes=0
  while IFS=' ' read -r -d '' size mtime mode path; do
    size_of[${path}]=${size}
    total_files=$(( total_files + 1 )); total_bytes=$(( total_bytes + size ))
  done <"${meta}"
  scan_progress "${out}" "inventory: ${total_files} files, $(human_bytes "${total_bytes}") of data (each is read three times: hashing, ClamAV, YARA)"
  while IFS= read -r line; do
    printf 'find\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
  done <"${out}/find.err"
  find "${root}" -xdev -type d \( -iname '*.app' -o -iname '*.pkg' -o -iname '*.mpkg' \
      -o -iname '*.bundle' -o -iname '*.plugin' -o -iname '*.kext' -o -iname '*.framework' \
      -o -iname '*.workflow' -o -iname '*.scptd' -o -iname '*.prefpane' \) -prune \
      -printf '%P\n' >"${out}/bundles.txt" 2>/dev/null || true

  # Hashes and MIME types. sha256sum -z disables name escaping; file -r keeps
  # names raw (it would otherwise print a newline as \012).
  n=0 done_bytes=0 started=${EPOCHSECONDS}
  while IFS= read -r -d '' sum && IFS= read -r -d '' path; do
    sum_of[${path}]=${sum}
    n=$(( n + 1 )); done_bytes=$(( done_bytes + ${size_of[${path}]:-0} ))
    (( n % 500 )) || scan_progress "${out}" "hashing: ${n}/${total_files} files, $(human_bytes "${done_bytes}")/$(human_bytes "${total_bytes}"), ETA $(eta "${done_bytes}" "${total_bytes}" "${started}")"
  done < <(xargs -0 -r sha256sum -z -- <"${list}" 2>"${out}/sha256.err" \
             | sed -z 's/^\([0-9a-f]\{64\}\)  /\1\x00/')
  while IFS= read -r line; do
    printf 'sha256\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
  done <"${out}/sha256.err"
  n=0
  while IFS= read -r -d '' path && IFS= read -r rest; do
    mime_of[${path}]=${rest#: }
    n=$(( n + 1 ))
    (( n % 2000 )) || scan_progress "${out}" "file types: ${n}/${total_files} files"
  done < <(xargs -0 -r file -N -r -0 --mime-type -- <"${list}" 2>/dev/null)

  exec 3>"${out}/files.tsv" 4>>"${out}/gaps.tsv" 5>>"${out}/suspect.tsv"
  shopt -s nocasematch
  while IFS= read -r -d '' rec; do
    size=${rec%% *}; rest=${rec#* }
    mtime=${rest%% *}; rest=${rest#* }
    mode=${rest%% *}; path=${rest#* }
    rel=${path#"${root}"/}
    sum=${sum_of[${path}]:--}
    mime=${mime_of[${path}]:-unknown}
    tsv_esc "${rel}"; erel=${REPLY}
    files=$(( files + 1 )); bytes=$(( bytes + size ))
    (( files % 5000 )) || scan_progress "${out}" "classifying: ${files}/${total_files} files (CPU only, no disk reads)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${sum}" "${size}" "${mtime}" "${mode}" "${mime}" "${erel}" >&3
    [[ ${sum} == - ]] && printf 'sha256\tunreadable\t%s\n' "${erel}" >&4
    if (( size > YARA_MAX_BYTES )) && [[ ${yara_rules} != - ]]; then
      printf 'yara\tlarger than %s, not YARA-scanned\t%s\n' "$(human_bytes "${YARA_MAX_BYTES}")" "${erel}" >&4
    fi
    # Linux's hfsplus driver cannot read HFS+ transparent compression
    # (decmpfs): such files look empty. Count them as a coverage caveat.
    [[ ${fstype} == hfsplus ]] && (( size == 0 )) && zero_len=$(( zero_len + 1 ))

    reason=
    [[ ${mime} =~ ${SUSPECT_MIMES} ]] && reason="type ${mime}"
    [[ -z ${reason} && ${rel} =~ ${SUSPECT_NAMES} ]] && reason="name/location"
    # The execute bit only means something on Unix filesystems; FAT/exFAT/NTFS
    # report every file executable.
    if (( unix_fs )); then
      (( 8#${mode} & 8#6000 )) && reason="${reason:+${reason}; }setuid/setgid"
      [[ -z ${reason} ]] && (( 8#${mode} & 8#111 )) && reason="executable bit"
    fi
    [[ ${rel} == *$'\n'* ]] && reason="${reason:+${reason}; }newline in file name"
    if [[ -n ${reason} ]]; then
      suspects=$(( suspects + 1 ))
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${sum}" "${mime}" "${size}" "${mtime}" "${reason}" "${erel}" >&5
    fi
  done <"${meta}"
  shopt -u nocasematch
  exec 3>&- 4>&- 5>&-

  # ClamAV: everything unpacked as deeply as the engine allows; limits and
  # encryption raise alerts so they surface as gaps, never as silent passes.
  # The file list is split into batches read with --file-list, so each
  # clamscan loads its signature database once per batch (passing names as
  # arguments made xargs split at its 128 KiB command-line limit and relaunch
  # clamscan, reloading ~1 GB of signatures, far more often). --file-list is
  # line-based, so the rare names containing a newline go as arguments in a
  # batch of their own. Batches also give a progress measure.
  clam_opts=(--stdout --infected --no-summary --allmatch=yes --detect-pua=yes
             --heuristic-alerts=yes --alert-encrypted=yes --alert-exceeds-max=yes
             --alert-macros=yes --alert-partition-intersection=yes "${CLAM_LIMITS[@]}")
  [[ ${clam_db} != - ]] && clam_opts+=(--database="${clam_db}")
  if (( files > 0 )); then
    jobs=$(clam_jobs)
    # About 20 batches per job: fine-grained progress, few database loads.
    per=$(( (files + jobs * 20 - 1) / (jobs * 20) ))
    (( per >= 200 )) || per=200
    awk -v RS='\0' -v per="${per}" -v dir="${out}" '
      index($0, "\n") { printf "%s%c", $0, 0 > (dir "/clambatch.nl"); next }
      { b = int(n++ / per); f = sprintf("%s/clambatch.%05d.lst", dir, b)
        if (f != cur) { if (cur != "") close(cur); cur = f }
        print > f }' "${list}"
    batches=$(count_existing "${out}"/clambatch.*.lst)
    [[ -s ${out}/clambatch.nl ]] && batches=$(( batches + 1 ))
    started=${EPOCHSECONDS}
    # shellcheck disable=SC2016 # expanded by the inner bash
    {
      if [[ -e ${out}/clambatch.00000.lst ]]; then
        printf '%s\0' "${out}"/clambatch.*.lst | xargs -0 -r -P "${jobs}" -I{} bash -c '
          out=$1 batch=$2 n=$3; shift 3; id=${batch##*/clambatch.}; id=${id%.lst}
          rc=0; clamscan "${@:1:n}" --file-list="${batch}" >"${out}/clamscan.${id}.part" 2>"${out}/clamscan.${id}.err" || rc=$?
          echo "${rc}" >"${out}/clamscan.${id}.rc"' _ "${out}" {} "${#clam_opts[@]}" "${clam_opts[@]}"
      fi
      if [[ -s ${out}/clambatch.nl ]]; then
        rc=0
        xargs -0 -r clamscan "${clam_opts[@]}" -- <"${out}/clambatch.nl" \
          >"${out}/clamscan.nl.part" 2>"${out}/clamscan.nl.err" || rc=$?
        echo "${rc}" >"${out}/clamscan.nl.rc"
      fi
    } &
    xpid=$!
    while kill -0 "${xpid}" 2>/dev/null; do
      n=$(count_existing "${out}"/clamscan.*.rc)
      scan_progress "${out}" "clamav: ${n}/${batches} batches done, ETA $(eta "${n}" "${batches}" "${started}")"
      sleep 10
    done
    wait "${xpid}" || true
    rm -f -- "${out}"/clambatch.*
  fi
  cat "${out}"/clamscan.*.part >"${out}/clamscan.log" 2>/dev/null || : >"${out}/clamscan.log"
  cat "${out}"/clamscan.*.err >"${out}/clamscan.err" 2>/dev/null || : >"${out}/clamscan.err"
  for f in "${out}"/clamscan.*.rc; do
    [[ -e ${f} ]] || continue
    rc=$(<"${f}")
    (( rc <= 1 )) || printf 'clamav\tclamscan exited %s (see clamscan.err)\t-\n' "${rc}" >>"${out}/gaps.tsv"
  done
  # A worker killed before it could write its .rc (e.g. OOM) leaves its .part
  # orphaned; that chunk was only partially examined - record it, never hide it.
  for f in "${out}"/clamscan.*.part; do
    [[ -e ${f} ]] || continue
    [[ -e ${f%.part}.rc ]] \
      || printf 'clamav\tclamscan worker died before finishing (chunk not fully scanned; see clamscan.log)\t-\n' >>"${out}/gaps.tsv"
  done
  rm -f -- "${out}"/clamscan.*.part "${out}"/clamscan.[0-9n]*.err "${out}"/clamscan.*.rc
  parse_clam_log "${out}/clamscan.log" "${out}/findings.tsv" "${out}/gaps.tsv" "${root}"
  while IFS= read -r line; do
    [[ ${line} == *ERROR:* || ${line} == *'Access denied'* || ${line} == *"Can't"* ]] || continue
    printf 'clamav\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
  done <"${out}/clamscan.err"

  if [[ ${yara_rules} != - ]]; then
    scan_progress "${out}" "yara: scanning $(human_bytes "${total_bytes}") since $(date +%H:%M) (no per-file progress)"
    rc=0
    yara --compiled-rules --recursive --no-follow-symlinks --print-meta --no-warnings \
      --threads="$(nproc)" --timeout="${YARA_TIMEOUT}" --skip-larger="${YARA_MAX_BYTES}" \
      "${yara_rules}" "${root}" >"${out}/yara.log" 2>"${out}/yara.err" || rc=$?
    (( rc == 0 )) || printf 'yara\tyara exited %s (see yara.err)\t-\n' "${rc}" >>"${out}/gaps.tsv"
    parse_yara_output "${out}/yara.log" "${out}/findings.tsv" "${root}"
    while IFS= read -r line; do
      printf 'yara\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
    done <"${out}/yara.err"
  fi

  scan_progress "${out}" "done"
  printf 'files=%s\nbytes=%s\nsuspects=%s\nbundles=%s\nzero_len_hfsplus=%s\n' "${files}" \
    "${bytes}" "${suspects}" "$(wc -l <"${out}/bundles.txt")" "${zero_len}" >"${out}/counts"
  rm -f -- "${list}" "${meta}"
}

if (( INTERNAL_SCAN )); then
  shift
  (( $# == 5 )) || die "--internal-scan needs 5 arguments"
  internal_scan "$@"
  exit
fi

# Sourced by tests: stop before doing anything.
[[ ${SCAN_UNTRUSTED_MEDIA_LIB:-0} == 1 ]] && return 0

#--- Preflight --------------------------------------------------------------
(( EUID != 0 )) || die "Run as your normal user; privileged steps use sudo."
if [[ -n ${SESSION_ACTION} ]]; then
  (( ${#TARGETS[@]} == 0 )) || die "--${SESSION_ACTION}-session takes no TARGET"
else
  (( ${#TARGETS[@]} )) || { usage >&2; die "No TARGET given."; }
fi
(( VT_ALL == 0 || USE_VT == 1 )) || die "--vt-all needs --vt"
[[ -z ${YARA_RULES} || -r ${YARA_RULES} ]] || die "Cannot read --yara-rules ${YARA_RULES}"
[[ -z ${CLAM_DB} || -e ${CLAM_DB} ]] || die "No such --clam-db ${CLAM_DB}"
[[ -z ${CLAM_DB} ]] || CLAM_DB=$(readlink -f -- "${CLAM_DB}")
[[ -z ${YARA_RULES} ]] || YARA_RULES=$(readlink -f -- "${YARA_RULES}")
USER_NAME=$(id -un)
USER_GID=$(id -g)
MNT_BASE=/run/scan-untrusted-media.$$
MOUNTS=()
LOOPS=()
RO_DEVS=()
FRESHCLAM_WAS_ACTIVE=0
KEEPALIVE_PID=
UNIT_SEQ=0
COMPILED_YARA=-
YARA_DESC=disabled
DISTRO=unknown

for t in "${TARGETS[@]}"; do
  [[ -b ${t} || -f ${t} || -d ${t} ]] || die "Not a block device, image file or directory: ${t}"
done

# shellcheck source=/dev/null
[[ -r /etc/os-release ]] && . /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *' fedora '*) DISTRO=fedora ;;
  *' arch '*)   DISTRO=arch ;;
esac

install_tools() {
  local p missing=() kver
  kver=$(uname -r)
  case ${DISTRO} in
    fedora)
      for p in "${PKGS_FEDORA[@]}"; do
        [[ ${p} == kernel-modules-extra || ${p} == apfs-fuse ]] && continue
        rpm -q --whatprovides "${p}" >/dev/null 2>&1 || missing+=("${p}")
      done
      if (( ${#missing[@]} )); then
        log "Installing scanner tools: ${missing[*]}"
        sudo dnf -y install "${missing[@]}" || die "dnf install failed"
      fi
      # apfs-fuse exists only in newer Fedora repos (F43+); a missing package
      # must not abort the whole scan - APFS degrades to a coverage gap.
      if ! rpm -q --whatprovides apfs-fuse >/dev/null 2>&1; then
        sudo dnf -y install apfs-fuse \
          || warn "apfs-fuse is not installable on this release; APFS volumes will be reported as coverage gaps."
      fi
      # hfsplus.ko lives in kernel-modules-extra and must match the running
      # kernel; after a kernel update that means installing it and rebooting.
      if ! rpm -q "kernel-modules-extra-${kver}" >/dev/null 2>&1; then
        log "Installing kernel-modules-extra for the running kernel (HFS+ support)"
        sudo dnf -y install "kernel-modules-extra-${kver}" \
          || warn "kernel-modules-extra-${kver} is not installable; HFS+ volumes will not mount until you install kernel-modules-extra and reboot into the matching kernel."
      fi
      ;;
    arch)
      for p in "${PKGS_ARCH[@]}"; do
        pacman -Q "${p}" >/dev/null 2>&1 || missing+=("${p}")
      done
      if (( ${#missing[@]} )); then
        log "Installing scanner tools: ${missing[*]}"
        sudo pacman -S --needed --noconfirm "${missing[@]}" || die "pacman install failed"
      fi
      command -v apfs-fuse >/dev/null || warn "apfs-fuse is missing (AUR: apfs-fuse-git); APFS volumes will be reported as coverage gaps."
      ;;
    *) warn "Unrecognised distribution; tools must already be installed." ;;
  esac
  for p in clamscan yara yarac ddrescue file jq curl unzip sha256sum systemd-run losetup blkid lsblk; do
    command -v "${p}" >/dev/null || die "Required tool missing: ${p}"
  done
  command -v apfs-fuse >/dev/null && command -v apfsutil >/dev/null \
    || warn "apfs-fuse/apfsutil missing: APFS volumes cannot be mounted."
}

cleanup() {
  local i
  set +e
  if (( KEEP_MOUNTED )) && (( ${#MOUNTS[@]} )); then
    log "Volumes left mounted read-only (--keep-mounted):"
    for i in "${MOUNTS[@]}"; do note "${i}"; done
    note "Unmount later with: sudo umount ${MNT_BASE}/*; then: sudo losetup -d ${LOOPS[*]:-<none>}"
  else
    for (( i = ${#MOUNTS[@]} - 1; i >= 0; i-- )); do
      sudo umount -- "${MOUNTS[i]}" 2>/dev/null || sudo umount -l -- "${MOUNTS[i]}" 2>/dev/null
      sudo rmdir -- "${MOUNTS[i]}" 2>/dev/null
    done
    for i in "${LOOPS[@]}"; do sudo losetup -d "${i}" 2>/dev/null; done
    [[ -d ${MNT_BASE} ]] && sudo rmdir -- "${MNT_BASE}" 2>/dev/null
  fi
  # A paused freshclam daemon must not stay down just because the scan ended
  # on an error path (die/INT during prepare_clamav skips its restart).
  (( FRESHCLAM_WAS_ACTIVE )) && sudo systemctl start clamav-freshclam.service 2>/dev/null
  if (( ${#RO_DEVS[@]} )); then
    note "Scanned devices were left read-only for safety; restore with:"
    for i in "${RO_DEVS[@]}"; do note "  sudo blockdev --setrw ${i}"; done
  fi
  [[ -n ${KEEPALIVE_PID} ]] && kill "${KEEPALIVE_PID}" 2>/dev/null
}

start_sudo() {
  sudo -v || die "sudo is required for imaging and mounting."
  # One failed refresh (ticket invalidated) must not end caching for good.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 50; done ) &
  KEEPALIVE_PID=$!
}

#--- Session hardening --------------------------------------------------------
# GNOME automounts new media, renders thumbnails (image/video/PDF parsers) and
# lets Tracker index removable devices: all parse untrusted files before any
# scan runs. Turn them off for this user and leave them off; the report dir
# gets a script that restores the previous values.
# harden_session <restore-script>: turn off everything in the desktop session
# that would open or parse untrusted media on its own, and write a script that
# restores the previous values. Settings already hardened (for example by an
# earlier --prepare-session) are left alone and not added to the restore list.
harden_session() {
  local restore=$1 spec schema key want cur schemas revert=()
  if ! command -v gsettings >/dev/null || [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && ! -S /run/user/${UID}/bus ]]; then
    warn "No desktop session found; make sure nothing automounts or previews the media."
    return 0
  fi
  schemas=$(gsettings list-schemas 2>/dev/null) || return 0
  for spec in 'org.gnome.desktop.media-handling automount false' \
              'org.gnome.desktop.media-handling automount-open false' \
              'org.gnome.desktop.media-handling autorun-never true' \
              'org.gnome.desktop.thumbnailers disable-all true' \
              'org.freedesktop.Tracker3.Miner.Files index-removable-devices false' \
              'org.freedesktop.Tracker3.Miner.Files index-optical-discs false'; do
    read -r schema key want <<<"${spec}"
    grep -qxF "${schema}" <<<"${schemas}" || continue
    cur=$(gsettings get "${schema}" "${key}" 2>/dev/null) || continue
    [[ ${cur} == "${want}" ]] && continue
    if gsettings set "${schema}" "${key}" "${want}"; then
      revert+=("gsettings set ${schema} ${key} ${cur}")
      note "set ${schema} ${key} ${want} (was ${cur})"
    fi
  done
  if (( ${#revert[@]} )); then
    mkdir -p -- "$(dirname -- "${restore}")"
    printf '#!/bin/sh\n# Restore desktop settings changed by scan-untrusted-media.sh\n%s\n' \
      "$(printf '%s\n' "${revert[@]}")" >>"${restore}"
    chmod 0700 "${restore}"
    note "Restore later with: ${restore}"
  else
    note "Desktop session: automount, autorun, thumbnails and removable-media indexing already off"
  fi
  case ${XDG_CURRENT_DESKTOP:-} in
    *GNOME*|'') ;;
    *) warn "Desktop ${XDG_CURRENT_DESKTOP} is not GNOME: disable its automount/thumbnailing yourself." ;;
  esac
}

#--- Signatures ---------------------------------------------------------------
clam_db_present() {
  compgen -G "${CLAMAV_DB_DIR}/main.c[vl]d" >/dev/null && compgen -G "${CLAMAV_DB_DIR}/daily.c[vl]d" >/dev/null
}

# Age of the newest daily database in hours (huge when absent).
clam_db_age_hours() {
  local f newest=0 m
  for f in "${CLAMAV_DB_DIR}"/daily.c[vl]d; do
    [[ -e ${f} ]] || continue
    m=$(stat -c %Y -- "${f}")
    (( m > newest )) && newest=${m}
  done
  (( newest )) || { printf '999999'; return; }
  printf '%s' $(( ($(date +%s) - newest) / 3600 ))
}

prepare_clamav() {
  local age=0
  if [[ -n ${CLAM_DB} ]]; then
    log "ClamAV database: ${CLAM_DB} (--clam-db)"
    return 0
  fi
  age=$(clam_db_age_hours)
  if clam_db_present && { (( ! UPDATE )) || (( age < 24 )); }; then
    log "ClamAV definitions are ${age}h old"
    return 0
  fi
  clam_db_present || (( UPDATE )) || die "No ClamAV database in ${CLAMAV_DB_DIR} and --no-update given."
  log "Updating ClamAV definitions"
  # The freshclam daemon holds the update lock; pause it for a one-shot run.
  if systemctl -q is-active clamav-freshclam.service 2>/dev/null; then
    FRESHCLAM_WAS_ACTIVE=1
    sudo systemctl stop clamav-freshclam.service
  fi
  if ! sudo freshclam; then
    clam_db_present || die "freshclam failed and no ClamAV database exists (check /etc/freshclam.conf and network)."
    warn "freshclam failed; scanning with definitions ${age}h old."
  fi
  command -v restorecon >/dev/null && sudo restorecon -R "${CLAMAV_DB_DIR}" 2>/dev/null
  (( FRESHCLAM_WAS_ACTIVE )) && { sudo systemctl start clamav-freshclam.service; FRESHCLAM_WAS_ACTIVE=0; }
  clam_db_present || die "No ClamAV database after update."
}

# fetch_yara_forge: download the latest YARA Forge release asset for
# YARA_SET, verify it against the SHA-256 digest GitHub records for the
# asset, and compile it into the cache. Unverifiable rules are refused.
fetch_yara_forge() {
  local json tag url digest want got dest tmp yar
  json=$(curl -fsSL --proto '=https' --max-time 60 -H 'Accept: application/vnd.github+json' \
           "${YARA_FORGE_API}") || return 1
  tag=$(jq -r '.tag_name // empty' <<<"${json}")
  [[ ${tag} =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  dest=${CACHE_DIR}/yara-forge/${tag}
  [[ -s ${dest}/rules-${YARA_SET}.yarc ]] && return 0
  IFS=' ' read -r url digest < <(jq -r --arg n "yara-forge-rules-${YARA_SET}.zip" \
    '.assets[] | select(.name == $n) | "\(.browser_download_url) \(.digest // "")"' <<<"${json}")
  [[ ${url:-} == https://github.com/* ]] || { warn "YARA Forge ${tag} has no ${YARA_SET} asset"; return 1; }
  want=${digest#sha256:}
  if [[ ${digest:-} != sha256:* || ! ${want} =~ ^[0-9a-f]{64}$ ]]; then
    warn "YARA Forge asset has no SHA-256 digest; refusing unverified rules."
    return 1
  fi
  log "Downloading YARA Forge ${tag} (${YARA_SET})"
  tmp=$(mktemp -d)
  if ! curl -fsSL --proto '=https' --max-time 900 -o "${tmp}/rules.zip" "${url}"; then
    rm -rf -- "${tmp}"; return 1
  fi
  got=$(sha256sum <"${tmp}/rules.zip"); got=${got%% *}
  if [[ ${got} != "${want}" ]]; then
    warn "YARA Forge digest mismatch (got ${got}, want ${want})"
    rm -rf -- "${tmp}"; return 1
  fi
  unzip -q -o "${tmp}/rules.zip" -d "${tmp}/x" || { rm -rf -- "${tmp}"; return 1; }
  yar=$(find "${tmp}/x" -type f -name '*.yar' -print -quit)
  [[ -n ${yar} ]] || { rm -rf -- "${tmp}"; return 1; }
  if ! yarac -w "${yar}" "${tmp}/rules.yarc"; then
    warn "yarac could not compile YARA Forge ${tag}"
    rm -rf -- "${tmp}"; return 1
  fi
  mkdir -p -- "${dest}"
  chmod 0700 -- "${dest}"
  mv -- "${yar}" "${dest}/rules-${YARA_SET}.yar"
  mv -- "${tmp}/rules.yarc" "${dest}/rules-${YARA_SET}.yarc"
  printf '%s\n' "${got}" >"${dest}/rules-${YARA_SET}.zip.sha256"
  rm -rf -- "${tmp}"
}

prepare_yara() {
  local d best=
  (( USE_YARA )) || return 0
  if [[ -n ${YARA_RULES} ]]; then
    COMPILED_YARA=${REPORT_DIR}/custom-rules.yarc
    yarac -w "${YARA_RULES}" "${COMPILED_YARA}" || die "yarac failed on ${YARA_RULES}"
    YARA_DESC="custom rules ${YARA_RULES}"
    return 0
  fi
  mkdir -p -- "${CACHE_DIR}/yara-forge"
  chmod 0700 -- "${CACHE_DIR}/yara-forge"
  (( UPDATE )) && { fetch_yara_forge || warn "Could not update YARA Forge rules; using the cache if any."; }
  for d in "${CACHE_DIR}"/yara-forge/*/; do
    [[ -s ${d}rules-${YARA_SET}.yarc ]] && best=${d}
  done
  if [[ -z ${best} ]]; then
    warn "No YARA rules available: YARA is skipped (reported as a coverage gap)."
    printf -- '-\tyara\tno YARA rules available, YARA not run\t-\n' >>"${REPORT_DIR}/gaps-global.tsv"
    return 0
  fi
  COMPILED_YARA=${best}rules-${YARA_SET}.yarc
  best=${best%/}
  YARA_DESC="YARA Forge ${best##*/} (${YARA_SET})"
  log "YARA rules: ${YARA_DESC}"
}

#--- Acquisition --------------------------------------------------------------
# map_unrecovered_bytes <ddrescue mapfile>: bytes not marked finished ('+').
map_unrecovered_bytes() {
  local pos size status rest total=0
  while read -r pos size status rest; do
    [[ ${pos} == '#'* || -z ${status} ]] && continue
    [[ ${status} == [-?*/] ]] && total=$(( total + size ))
  done <"$1"
  printf '%s' "${total}"
}

# acquire_device <dev>: refuse mounted devices, set them read-only, image them
# (unless --no-image). Sets ACQUIRED to the image path or the device.
acquire_device() {
  local dev=$1 node mp mounted=() dir size avail have serial model name img map bad sum
  while read -r node mp; do
    [[ -n ${mp} ]] && mounted+=("${node} on ${mp}")
  done < <(lsblk -nrpo NAME,MOUNTPOINT -- "${dev}")
  if (( ${#mounted[@]} )); then
    printf '    %s\n' "${mounted[@]}" >&2
    die "${dev} has mounted filesystems. Unmount them first (udisksctl unmount -b <partition>), then rerun."
  fi
  swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "${dev}" && die "${dev} is in use as swap"
  # lsblk lists the disk itself first, then its partitions.
  RO_DEVS=()
  while read -r node; do
    sudo blockdev --setro "${node}" || die "blockdev --setro ${node} failed"
    RO_DEVS+=("${node}")
  done < <(lsblk -nrpo NAME -- "${dev}")
  model=$(lsblk -dno MODEL -- "${dev}" | xargs)
  serial=$(lsblk -dno SERIAL -- "${dev}" | xargs)
  size=$(sudo blockdev --getsize64 "${dev}")
  if [[ ${IMAGE_MODE} == direct ]]; then
    printf '%s\t%s\t%s\t%s\t(scanned in place)\t-\t-\n' "${dev}" "${model:--}" "${serial:--}" \
      "${size}" >>"${REPORT_DIR}/acquisition.tsv"
    ACQUIRED=${dev}
    return 0
  fi
  if [[ -n ${IMAGE_DIR} ]]; then
    # ddrescue runs as root writing here; a group/world-writable directory
    # would let another local user plant a symlink for root to truncate.
    dir=$(readlink -f -- "${IMAGE_DIR}")
    (( 8#$(stat -c %a -- "${dir}") & 8#077 )) \
      && die "Image dir ${dir} is group- or world-writable; refusing to write images as root into it."
  else
    dir=${REPORT_DIR}/images
    mkdir -p -- "${dir}"
    chmod 0700 -- "${dir}"
    dir=$(readlink -f -- "${dir}")
  fi
  name=${dev##*/}${serial:+-${serial}}
  name=${name//[^A-Za-z0-9._-]/_}
  img=${dir}/${name}.img map=${dir}/${name}.map
  # The name is only device + serial; card readers report the reader's serial
  # and cheap sticks none, so an existing map may belong to another drive and
  # ddrescue would "resume" it without copying anything from this one.
  if [[ -e ${img} || -e ${map} ]] && (( ! RESUME )); then
    die "${img} or its map already exists (possibly another drive's image). Pass --resume to continue an interrupted image of this same drive, or use a fresh --image-dir."
  fi
  have=0
  [[ -f ${img} ]] && have=$(stat -c %s -- "${img}")
  avail=$(df -B1 --output=avail -- "${dir}" | tail -n 1)
  (( avail + have >= size + 1073741824 )) \
    || die "Not enough space in ${dir} for ${dev}: need $(human_bytes "${size}"), have $(human_bytes "${avail}")"
  log "Imaging ${dev} (${model:-?} ${serial:-}, $(human_bytes "${size}")) -> ${img}"
  # Pass 1 copies everything readable fast and skips bad areas; pass 2
  # retries them. The mapfile makes reruns resume instead of starting over.
  sudo ddrescue -d -n "${dev}" "${img}" "${map}" || sudo ddrescue -n "${dev}" "${img}" "${map}" \
    || die "ddrescue failed on ${dev}"
  sudo ddrescue -d -r3 "${dev}" "${img}" "${map}" || sudo ddrescue -r3 "${dev}" "${img}" "${map}" \
    || warn "ddrescue retry pass failed on ${dev}"
  sudo chown "${UID}:${USER_GID}" -- "${img}" "${map}"
  chmod 0440 -- "${img}"
  bad=$(map_unrecovered_bytes "${map}")
  (( bad == 0 )) || {
    warn "${dev}: $(human_bytes "${bad}") could not be read; those areas are zero in the image."
    printf -- '%s\tacquisition\t%s unreadable on the source device\t-\n' "${name}" "$(human_bytes "${bad}")" \
      >>"${REPORT_DIR}/gaps-global.tsv"
  }
  log "Hashing image"
  sum=$(sha256sum <"${img}"); sum=${sum%% *}
  printf '%s  %s\n' "${sum}" "${img##*/}" >"${img}.sha256"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${dev}" "${model:--}" "${serial:--}" "${size}" "${img}" \
    "${sum}" "${bad}" >>"${REPORT_DIR}/acquisition.tsv"
  ACQUIRED=${img}
}

attach_image() {
  local loop
  loop=$(sudo losetup --find --show --read-only --partscan -- "$1") || die "losetup failed on $1"
  LOOPS+=("${loop}")
  udevadm settle --timeout=15 2>/dev/null || sleep 2
  ATTACHED=${loop}
}

#--- Mounting -----------------------------------------------------------------
gap() { # <volume> <source> <reason>
  printf '%s\t%s\t%s\t-\n' "$1" "$2" "$3" >>"${REPORT_DIR}/gaps-global.tsv"
  warn "$1: $3"
}

# try_mount <node> <mountpoint> <type> <options>
try_mount() {
  sudo mkdir -p -- "$2" || return 1
  if sudo mount -t "$3" -o "$4" -- "$1" "$2" 2>"${REPORT_DIR}/mount.err"; then
    MOUNTS+=("$2")
    return 0
  fi
  sudo rmdir -- "$2" 2>/dev/null
  return 1
}

mount_apfs() { # <node> <tag>
  local node=$1 tag=$2 line v mp vols=() listing
  local -A enc=() vname=()
  command -v apfs-fuse >/dev/null || { gap "${tag}" mount "APFS container not mounted: apfs-fuse missing"; return 0; }
  listing=$(sudo apfsutil "${node}" 2>&1) || true
  printf '%s\n' "${listing}" >"${REPORT_DIR}/apfs-${tag}.txt"
  while IFS= read -r line; do
    if [[ ${line} =~ ^[[:space:]]*Volume[[:space:]]+([0-9]+) ]]; then
      v=${BASH_REMATCH[1]}; vols+=("${v}")
    elif [[ -n ${v:-} && ${line} =~ FileVault:[[:space:]]*Yes ]]; then
      enc[${v}]=1
    elif [[ -n ${v:-} && ${line} =~ Name:[[:space:]]*(.*)$ ]]; then
      vname[${v}]=${BASH_REMATCH[1]}
    fi
  done <<<"${listing}"
  (( ${#vols[@]} )) || vols=(0)
  for v in "${vols[@]}"; do
    mp=${MNT_BASE}/${tag}-v${v}
    if [[ -n ${enc[${v}]:-} ]]; then
      log "APFS volume ${v} '${vname[${v}]:-}' is encrypted: apfs-fuse will ask for its password or recovery key."
    fi
    sudo mkdir -p -- "${mp}"
    if sudo apfs-fuse -o "allow_other,nosuid,nodev,noexec,uid=${UID},gid=${USER_GID},vol=${v}" "${node}" "${mp}" </dev/tty; then
      MOUNTS+=("${mp}")
      scan_volume "${mp}" apfs "${tag}-v${v}"
    else
      sudo rmdir -- "${mp}" 2>/dev/null
      gap "${tag}-v${v}" mount "APFS volume ${v} '${vname[${v}]:-}' not mounted${enc[${v}]:+ (encrypted, not unlocked)}"
    fi
  done
}

# mount_and_scan <node> <fstype> <tag>
mount_and_scan() {
  local node=$1 fstype=$2 tag=$3 mp=${MNT_BASE}/$3
  local base="ro,nosuid,nodev,noexec" own="uid=${UID},gid=${USER_GID}"
  case ${fstype} in
    apfs) mount_apfs "${node}" "${tag}"; return 0 ;;
    swap) note "${tag}: swap, skipped"; return 0 ;;
    crypto_LUKS|BitLocker|LVM2_member|linux_raid_member|zfs_member|VMFS*|ceph*)
      gap "${tag}" mount "${fstype} not opened (encrypted or container volume)"; return 0 ;;
  esac
  case ${fstype} in
    vfat|exfat) try_mount "${node}" "${mp}" "${fstype}" "${base},${own},fmask=0333,dmask=0222" ;;
    ntfs) try_mount "${node}" "${mp}" ntfs3 "${base},${own}" \
            || try_mount "${node}" "${mp}" ntfs-3g "${base},${own}" ;;
    hfsplus|hfs)
      sudo modprobe "${fstype}" 2>/dev/null \
        || { gap "${tag}" mount "${fstype} kernel module unavailable (install kernel-modules-extra for $(uname -r), or reboot into the kernel it matches)"; return 0; }
      try_mount "${node}" "${mp}" "${fstype}" "${base},${own}" ;;
    ext2|ext3|ext4) try_mount "${node}" "${mp}" "${fstype}" "${base},noload" ;;
    xfs)   try_mount "${node}" "${mp}" xfs "${base},norecovery" ;;
    btrfs) try_mount "${node}" "${mp}" btrfs "${base},rescue=nologreplay" ;;
    iso9660|udf) try_mount "${node}" "${mp}" "${fstype}" "${base},${own}" ;;
    *) try_mount "${node}" "${mp}" "${fstype}" "${base}" ;;
  esac || { gap "${tag}" mount "${fstype} mount failed: $(tr '\n' ' ' <"${REPORT_DIR}/mount.err")"; return 0; }
  scan_volume "${mp}" "${fstype}" "${tag}"
}

# scan_block <top node> <tag>: every partition / filesystem on a device or
# attached image.
scan_block() {
  local top=$1 tag=$2 node nodes info fstype pttype vtag
  # Read the node list up front: the loop body runs apfs-fuse, whose password
  # prompt must read the terminal, not the rest of this list.
  mapfile -t nodes < <(lsblk -nrpo NAME -- "${top}")
  for node in "${nodes[@]}"; do
    info=$(sudo blkid -p -o export -- "${node}" 2>/dev/null) || info=
    fstype=$(sed -n 's/^TYPE=//p' <<<"${info}")
    pttype=$(sed -n 's/^PTTYPE=//p' <<<"${info}")
    vtag=${tag}
    [[ ${node} != "${top}" ]] && vtag=${tag}-${node##*/}
    vtag=${vtag//[^A-Za-z0-9._-]/_}
    if [[ -z ${fstype} ]]; then
      # A container whose partitions the kernel exposed is scanned through
      # them; a partition table with no partitions (damaged GPT, a table type
      # the kernel does not parse) would otherwise vanish from the report.
      (( $(lsblk -nrpo NAME -- "${node}" | wc -l) > 1 )) && continue
      if [[ -n ${pttype} ]]; then
        gap "${vtag}" mount "${pttype} partition table on ${node} but no partitions were exposed; nothing on it was scanned"
      else
        gap "${vtag}" mount "no recognised filesystem on ${node}"
      fi
      continue
    fi
    mount_and_scan "${node}" "${fstype}" "${vtag}"
  done
}

#--- Scanning -----------------------------------------------------------------
# scan_volume <root> <fstype> <tag>: run the worker in a transient sandbox as
# the invoking user. CAP_DAC_READ_SEARCH lets it read files owned by the Mac
# account (uid 501, mode 0700) without root; no network, read-only host.
scan_volume() {
  local root=$1 fstype=$2 tag=$3 out rc=0 poller
  out=${REPORT_DIR}/volumes/${tag}
  mkdir -p -- "${out}"
  printf '%s\t%s\t%s\n' "${tag}" "${fstype}" "${root}" >>"${REPORT_DIR}/volumes.tsv"
  UNIT_SEQ=$(( UNIT_SEQ + 1 ))
  log "Scanning ${tag} (${fstype}) at ${root}"
  # The worker runs as "bash <script>", never by exec'ing the script itself:
  # under SELinux, systemd (init_t) may not execute a file labeled
  # user_home_t (a checkout in ~), which fails every scan with 203/EXEC.
  # bash is bin_t and transitions to unconfined_service_t, which may read it.
  # Print the worker's progress file once a minute while the sandbox runs.
  ( last=
    while sleep 60; do
      [[ -r ${out}/progress ]] || continue
      cur=$(<"${out}/progress")
      [[ ${cur} == "${last}" ]] || note "[${tag} $(date +%H:%M)] ${cur}"
      last=${cur}
    done ) &
  poller=$!
  sudo systemd-run --quiet --wait --pipe --collect --expand-environment=no \
    --unit="scan-utm-${EPOCHSECONDS}-$$-${UNIT_SEQ}" \
    -p User="${USER_NAME}" -p WorkingDirectory=/ -p UMask=0077 \
    -p AmbientCapabilities=CAP_DAC_READ_SEARCH -p CapabilityBoundingSet=CAP_DAC_READ_SEARCH \
    -p NoNewPrivileges=yes -p PrivateNetwork=yes -p PrivateTmp=yes -p PrivateDevices=yes \
    -p ProtectSystem=strict -p ProtectHome=read-only -p ReadWritePaths="${REPORT_DIR}" \
    -p ProtectKernelTunables=yes -p ProtectKernelModules=yes -p ProtectKernelLogs=yes \
    -p ProtectControlGroups=yes -p ProtectClock=yes -p ProtectHostname=yes \
    -p RestrictAddressFamilies=AF_UNIX -p RestrictNamespaces=yes -p RestrictSUIDSGID=yes \
    -p RestrictRealtime=yes -p LockPersonality=yes -p SystemCallArchitectures=native \
    -p Nice=5 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=6 \
    -- "${BASH}" "${SCRIPT_PATH}" --internal-scan "${root}" "${out}" "${fstype}" "${COMPILED_YARA}" "${CLAM_DB:--}" \
    </dev/null || rc=$?
  kill "${poller}" 2>/dev/null || true
  wait "${poller}" 2>/dev/null || true
  (( rc == 0 )) || gap "${tag}" scan "sandboxed scan exited ${rc}; results for this volume are incomplete"
  [[ -f ${out}/counts ]] && note "$(tr '\n' ' ' <"${out}/counts")"
}

#--- VirusTotal ---------------------------------------------------------------
vt_lookup_all() {
  local key='' mode hashes=() sha tmp code n=0 total delay cache now age stop=0 tries row
  (( USE_VT )) || return 0
  if [[ -n ${VT_API_KEY:-} ]]; then
    key=${VT_API_KEY}
  elif [[ -r ${VT_KEY_FILE} ]]; then
    mode=$(stat -c %a -- "${VT_KEY_FILE}")
    [[ ${mode} == [46]00 ]] || die "${VT_KEY_FILE} must be mode 0600 (chmod 600 ${VT_KEY_FILE})"
    key=$(tr -d '[:space:]' <"${VT_KEY_FILE}")
  fi
  if [[ ! ${key} =~ ^[0-9a-fA-F]{64}$ ]]; then
    gap - virustotal "no valid VirusTotal API key (set VT_API_KEY or ${VT_KEY_FILE}); lookups skipped"
    return 0
  fi
  if (( VT_ALL )); then
    mapfile -t hashes < <(cut -f1 "${REPORT_DIR}"/volumes/*/files.tsv 2>/dev/null | grep -E '^[0-9a-f]{64}$' | sort -u)
  else
    mapfile -t hashes < <({ cut -f5 "${REPORT_DIR}/findings.tsv"; cut -f1 "${REPORT_DIR}"/volumes/*/suspect.tsv; } \
                           2>/dev/null | grep -E '^[0-9a-f]{64}$' | sort -u)
  fi
  total=${#hashes[@]}
  : >"${REPORT_DIR}/virustotal.tsv"
  (( total )) || { log "VirusTotal: nothing to look up"; return 0; }
  delay=$(( (60 + VT_RATE - 1) / VT_RATE ))
  log "VirusTotal: ${total} hash(es), about $(( total * delay / 60 )) min at ${VT_RATE}/min"
  (( total <= 500 )) || warn "More than 500 lookups exceeds the public API daily quota; the rest will be reported as gaps."
  cache=${CACHE_DIR}/vt
  mkdir -p -- "${cache}"
  chmod 0700 -- "${cache}"
  tmp=$(mktemp)
  now=$(date +%s)
  for sha in "${hashes[@]}"; do
    n=$(( n + 1 ))
    if (( stop )); then
      printf '%s\tnot-checked\t-\t-\t-\t-\t-\n' "${sha}" >>"${REPORT_DIR}/virustotal.tsv"
      continue
    fi
    # Cache: known results for 7 days, "unknown" for 1 day.
    if [[ -s ${cache}/${sha} ]]; then
      age=$(( now - $(stat -c %Y -- "${cache}/${sha}") ))
      row=$(<"${cache}/${sha}")
      if (( age < 604800 )) && [[ ${row} != *$'\tunknown\t'* || ${age} -lt 86400 ]]; then
        printf '%s\n' "${row}" >>"${REPORT_DIR}/virustotal.tsv"
        continue
      fi
    fi
    tries=0
    while :; do
      code=$(curl -sS --proto '=https' --max-time 60 -o "${tmp}" -w '%{http_code}' \
               -H @<(printf 'x-apikey: %s\n' "${key}") "${VT_API}/${sha}") || code=000
      [[ ${code} == 429 && ${tries} -lt 3 ]] || break
      tries=$(( tries + 1 ))
      grep -q QuotaExceeded "${tmp}" && [[ ${tries} -ge 2 ]] && break
      note "VirusTotal rate limit; waiting 60s"
      sleep 60
    done
    case ${code} in
      200) row=$(jq -r --arg s "${sha}" '.data.attributes as $a | [$s, "known",
             ($a.last_analysis_stats.malicious // 0), ($a.last_analysis_stats.suspicious // 0),
             ($a.last_analysis_stats.undetected // 0),
             ($a.popular_threat_classification.suggested_threat_label // "-"),
             ($a.meaningful_name // "-")] | map(tostring | gsub("[\t\n]"; " ")) | join("\t")' "${tmp}") \
             || row="${sha}"$'\terror\t-\t-\t-\t-\tbad JSON'
           printf '%s\n' "${row}" >"${cache}/${sha}" ;;
      404) row="${sha}"$'\tunknown\t-\t-\t-\t-\t-'
           printf '%s\n' "${row}" >"${cache}/${sha}" ;;
      401|403) warn "VirusTotal rejected the API key (HTTP ${code}); stopping lookups."
           row="${sha}"$'\tnot-checked\t-\t-\t-\t-\t-'; stop=1 ;;
      429) warn "VirusTotal quota exhausted; remaining hashes are not checked."
           row="${sha}"$'\tnot-checked\t-\t-\t-\t-\t-'; stop=1 ;;
      *)   row="${sha}"$'\terror\t-\t-\t-\t-\tHTTP '"${code}" ;;
    esac
    printf '%s\n' "${row}" >>"${REPORT_DIR}/virustotal.tsv"
    (( n % 20 == 0 )) && note "VirusTotal: ${n}/${total}"
    (( stop )) || (( n == total )) || sleep "${delay}"
  done
  rm -f -- "${tmp}"
  n=$(grep -c $'\tnot-checked\t' "${REPORT_DIR}/virustotal.tsv" || true)
  (( n == 0 )) || gap - virustotal "${n} hash(es) not looked up on VirusTotal (quota or key)"
  # Engine detections become findings for every file with that hash.
  awk -F'\t' -v OFS='\t' '
    FNR == 1 { vf = (FILENAME ~ /virustotal\.tsv$/) }
    vf { if ($2 == "known" && $3 + 0 >= 1) { m[$1] = $3; l[$1] = $6 } ; next }
    ($1 in m) { n = split(FILENAME, p, "/"); vol = p[n - 1]
      cls = (m[$1] >= 5 ? "DEFINITE" : (m[$1] >= 2 ? "LIKELY" : "REVIEW"))
      print cls, "virustotal", m[$1] " engines: " l[$1], vol, $1, $6 }' \
    "${REPORT_DIR}/virustotal.tsv" "${REPORT_DIR}"/volumes/*/files.tsv >>"${REPORT_DIR}/findings.tsv"
}

#--- Report -------------------------------------------------------------------
# collect_results: merge per-volume findings and gaps (adding the volume tag
# and each file's SHA-256) into findings.tsv and gaps.tsv at the top level.
collect_results() {
  local d tag
  : >"${REPORT_DIR}/findings.tsv"
  cp -- "${REPORT_DIR}/gaps-global.tsv" "${REPORT_DIR}/gaps.tsv"
  for d in "${REPORT_DIR}"/volumes/*/; do
    [[ -f ${d}files.tsv ]] || continue
    tag=${d%/}; tag=${tag##*/}
    awk -F'\t' -v OFS='\t' -v vol="${tag}" 'NR == FNR { sha[$6] = $1; next }
      { print $1, $2, $3, vol, (($4 in sha) ? sha[$4] : "-"), $4 }' \
      "${d}files.tsv" "${d}findings.tsv" >>"${REPORT_DIR}/findings.tsv"
    awk -F'\t' -v OFS='\t' -v vol="${tag}" '{ print vol, $1, $2, $3 }' "${d}gaps.tsv" >>"${REPORT_DIR}/gaps.tsv"
  done
}

count_class() { awk -F'\t' -v c="$1" '$1 == c { k[$4 "\t" $6] = 1 } END { print length(k) }' "${REPORT_DIR}/findings.tsv"; }

write_report() {
  local s=${REPORT_DIR}/summary.txt definite likely review gaps files=0 bytes=0 suspects=0 d k v
  local vt_known=0 vt_mal=0 vt_unknown=0 vt_unk_exec=0 zero=0
  definite=$(count_class DEFINITE); likely=$(count_class LIKELY); review=$(count_class REVIEW)
  gaps=$(wc -l <"${REPORT_DIR}/gaps.tsv")
  for d in "${REPORT_DIR}"/volumes/*/counts; do
    [[ -f ${d} ]] || continue
    while IFS='=' read -r k v; do
      case ${k} in
        files) files=$(( files + v )) ;; bytes) bytes=$(( bytes + v )) ;;
        suspects) suspects=$(( suspects + v )) ;; zero_len_hfsplus) zero=$(( zero + v )) ;;
      esac
    done <"${d}"
  done
  # No file examined anywhere (every volume failed to mount, or the media is
  # empty) must never read as the "no coverage gaps" result.
  if (( files == 0 )); then
    printf -- '-\tscan\tno files were scanned on any volume\t-\n' >>"${REPORT_DIR}/gaps.tsv"
    gaps=$(( gaps + 1 ))
  fi
  if [[ -s ${REPORT_DIR}/virustotal.tsv ]]; then
    vt_known=$(awk -F'\t' '$2 == "known"' "${REPORT_DIR}/virustotal.tsv" | wc -l)
    vt_mal=$(awk -F'\t' '$2 == "known" && $3 + 0 >= 1' "${REPORT_DIR}/virustotal.tsv" | wc -l)
    vt_unknown=$(awk -F'\t' '$2 == "unknown"' "${REPORT_DIR}/virustotal.tsv" | wc -l)
    vt_unk_exec=$(awk -F'\t' 'FNR == 1 { vf = (FILENAME ~ /virustotal\.tsv$/) }
      vf { if ($2 == "unknown") u[$1] = 1; next } ($1 in u) { e[$1] = 1 } END { print length(e) }' \
      "${REPORT_DIR}/virustotal.tsv" "${REPORT_DIR}"/volumes/*/suspect.tsv)
  fi
  {
    printf 'Untrusted media scan report\n===========================\n'
    printf 'Date:      %s\nHost:      %s\nTargets:   %s\n' "$(date -R)" "$(uname -n)" "${TARGETS[*]}"
    printf 'ClamAV:    %s\nYARA:      %s (%s)\n' "$(clamscan --version "${ver_opts[@]}" 2>/dev/null)" \
      "${YARA_DESC}" "$(yara --version 2>/dev/null)"
    printf 'VirusTotal: %s\n\n' "$( (( USE_VT )) && echo "hash lookups$( (( VT_ALL )) && echo ', all files')" || echo 'not used')"
    if [[ -s ${REPORT_DIR}/acquisition.tsv ]]; then
      printf 'Acquisition (device, model, serial, bytes, image, sha256, unreadable bytes):\n'
      sed 's/^/  /' "${REPORT_DIR}/acquisition.tsv"; echo
    fi
    printf 'Volumes scanned (tag, filesystem, mountpoint):\n'
    sed 's/^/  /' "${REPORT_DIR}/volumes.tsv" 2>/dev/null || echo '  none'
    printf '\nFiles: %s (%s); executable/auto-run items for review: %s\n\n' "${files}" \
      "$(human_bytes "${bytes}")" "${suspects}"
    printf 'Findings (unique files): DEFINITE %s   LIKELY %s   REVIEW %s\n' "${definite}" "${likely}" "${review}"
    if (( definite + likely )); then
      printf '\nDEFINITE / LIKELY detections (class, source, detail, volume, sha256, path):\n'
      awk -F'\t' '$1 == "DEFINITE" || $1 == "LIKELY"' "${REPORT_DIR}/findings.tsv" | sort -u | head -n 200 | sed 's/^/  /'
    fi
    if (( review )); then
      printf '\nREVIEW (PUA, heuristics, low-score YARA, single-engine VT; first 50):\n'
      awk -F'\t' '$1 == "REVIEW"' "${REPORT_DIR}/findings.tsv" | sort -u | head -n 50 | sed 's/^/  /'
    fi
    if (( USE_VT )); then
      printf '\nVirusTotal: %s known (%s flagged by >=1 engine), %s unknown' "${vt_known}" "${vt_mal}" "${vt_unknown}"
      printf ' (%s of them executable/auto-run content)\n' "${vt_unk_exec}"
    fi
    printf '\nCoverage gaps: %s (full list: gaps.tsv)\n' "${gaps}"
    awk -F'\t' -v lsq="$(printf '\342\200\210')" -v rsq="$(printf '\342\200\211')" \
      '{ r = $3; gsub(/\/[^ :]*/, "...", r); gsub(/'\''[^'\'']*'\''/, "...", r)
         gsub(lsq "[^" rsq "]*" rsq, "...", r)
         if (length(r) > 90) r = substr(r, 1, 90) "..."; c[$2 ": " r]++ }
       END { for (k in c) printf "  %6d  %s\n", c[k], k }' "${REPORT_DIR}/gaps.tsv" | sort -rn | head -n 25
    (( zero )) && printf '  %6d  HFS+ zero-length files: may be macOS-compressed (decmpfs) data Linux cannot read\n' "${zero}"
    printf '\nRESULT: '
    if (( definite + likely )); then
      printf 'MALWARE DETECTED in %s file(s). Treat the media and anything copied from it\n' $(( definite + likely ))
      printf 'as compromised. Do not open these files on any machine.\n'
    elif (( review + gaps + zero + vt_unk_exec )); then
      printf 'no definite or likely detections, but %s item(s) need review and\n' "${review}"
      printf '%s coverage gap(s) (plus %s possibly compressed HFS+ file(s)) limit confidence.\n' "${gaps}" "${zero}"
      printf 'A clean scan is not proof of clean media:\n'
      printf 'review the gaps and the executable inventory (volumes/*/suspect.tsv).\n'
    else
      printf 'no detections and no coverage gaps. This is the strongest result this\n'
      printf 'scan can give; it is still not proof that the media is clean (new or targeted\n'
      printf 'malware has no signatures). Prefer copying only the documents you need.\n'
    fi
    printf '\nReport files: summary.txt, findings.tsv, gaps.tsv, volumes/<tag>/{files,suspect,findings,gaps}.tsv,\n'
    printf 'bundles.txt, clamscan.log, yara.log%s\n' "$( (( USE_VT )) && echo ', virustotal.tsv')"
  } >"${s}"
  echo
  cat -- "${s}"
  echo
  log "Report: ${REPORT_DIR}"
  (( definite + likely == 0 ))
}

#--- Main ---------------------------------------------------------------------
# unique_tag <base>: a target tag no earlier target used. Tags come from
# basenames, so /a/disk.img and /b/disk.img would otherwise share mount points
# and volumes/<tag>/ output, and the second scan would erase the first.
unique_tag() {
  local base=${1//[^A-Za-z0-9._-]/_} tag n=1
  tag=${base}
  while compgen -G "${REPORT_DIR}/volumes/${tag}" >/dev/null \
        || compgen -G "${REPORT_DIR}/volumes/${tag}-*" >/dev/null \
        || awk -F'\t' -v t="${tag}" '$1 == t || index($1, t "-") == 1 { f = 1 } END { exit !f }' \
             "${REPORT_DIR}/gaps-global.tsv"; do
    n=$(( n + 1 ))
    tag=${base}-${n}
  done
  printf '%s' "${tag}"
}

main() {
  local t img global_gaps ver_opts=()
  # Session-only modes: no report dir, tools, sudo or scanning.
  case ${SESSION_ACTION} in
    prepare)
      log "Hardening the desktop session before any untrusted drive is attached"
      harden_session "${SESSION_RESTORE}"
      log "Ready. Plug the drives in now; nothing will mount or open them. Scan with: ${0##*/} /dev/sdX"
      return 0 ;;
    restore)
      [[ -f ${SESSION_RESTORE} ]] || die "Nothing to restore: ${SESSION_RESTORE} does not exist"
      sh -- "${SESSION_RESTORE}" || die "restoring the desktop settings failed; see ${SESSION_RESTORE}"
      rm -f -- "${SESSION_RESTORE}"
      log "Desktop session settings restored"
      return 0 ;;
  esac
  [[ -n ${CLAM_DB} ]] && ver_opts+=(--database="${CLAM_DB}")
  REPORT_DIR=${REPORT_DIR:-${PWD}/media-scan-$(date +%Y%m%d-%H%M%S)}
  mkdir -p -- "${REPORT_DIR}"
  chmod 0700 -- "${REPORT_DIR}"
  REPORT_DIR=$(readlink -f -- "${REPORT_DIR}")
  [[ ${REPORT_DIR} != *[[:space:]]* ]] || die "--report-dir must not contain whitespace (systemd sandbox path)"
  # The sandbox uses PrivateTmp: a report dir under /tmp or /var/tmp would be
  # masked inside it and every volume scan would fail (status=226/NAMESPACE).
  case ${REPORT_DIR} in
    /tmp|/tmp/*|/var/tmp|/var/tmp/*)
      die "Report dir must not be under /tmp or /var/tmp (PrivateTmp hides it from the scan sandbox)." ;;
  esac
  [[ -z $(ls -A -- "${REPORT_DIR}") ]] || die "Report dir ${REPORT_DIR} is not empty"
  : >"${REPORT_DIR}/gaps-global.tsv"
  log "Report directory: ${REPORT_DIR}"

  (( HARDEN_SESSION )) && harden_session "${REPORT_DIR}/restore-session-settings.sh"
  install_tools
  start_sudo
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  sudo mkdir -p -m 0755 -- "${MNT_BASE}"
  prepare_clamav
  prepare_yara

  for t in "${TARGETS[@]}"; do
    if [[ -b ${t} ]]; then
      acquire_device "${t}"
      if [[ -b ${ACQUIRED} ]]; then
        scan_block "${ACQUIRED}" "$(unique_tag "${t##*/}")"
      else
        attach_image "${ACQUIRED}"
        img=${ACQUIRED##*/}
        scan_block "${ATTACHED}" "$(unique_tag "${img%.img}")"
      fi
    elif [[ -f ${t} ]]; then
      attach_image "$(readlink -f -- "${t}")"
      img=${t##*/}
      scan_block "${ATTACHED}" "$(unique_tag "${img%.*}")"
    else
      img=$(readlink -f -- "${t}")
      scan_volume "${img}" "$(findmnt -no FSTYPE -T "${img}" 2>/dev/null || echo unknown)" \
        "$(unique_tag "dir-${img##*/}")"
    fi
  done

  collect_results
  # vt_lookup_all reads the merged findings, so it runs after the merge; any
  # gaps it records (bad key, quota) are carried into gaps.tsv afterwards.
  global_gaps=$(wc -l <"${REPORT_DIR}/gaps-global.tsv")
  vt_lookup_all
  tail -n "+$(( global_gaps + 1 ))" -- "${REPORT_DIR}/gaps-global.tsv" >>"${REPORT_DIR}/gaps.tsv"
  rc=0
  write_report || rc=3
  return "${rc}"
}

main
exit $?
