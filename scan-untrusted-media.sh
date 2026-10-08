#!/usr/bin/env bash
#
# Read-only malware triage of untrusted removable media (USB drives, disk
# images) on a Linux workstation, for media from any platform: Windows,
# macOS, iOS/iPadOS/tvOS/watchOS/visionOS, Linux and Android. It understands
# APFS, HFS+, exFAT/FAT, NTFS, ext2/3/4, XFS, Btrfs, F2FS, SquashFS/EROFS
# and optical/ISO volumes, opens LVM and (with your passphrase) LUKS and
# BitLocker read-only, images block devices before touching them, and never
# mounts anything writable or executable. Other filesystem types are reported
# as coverage gaps instead of exposing rarely audited kernel drivers.
#
# Run as your normal user; privileged steps go through sudo. Fedora 41+ is the
# primary target (missing tools are installed with dnf); Arch works when the
# tools are already installed (apfs-fuse is AUR-only there).
#
#   scan-untrusted-media.sh /dev/sdb                       # scan the drive in place, read-only
#   scan-untrusted-media.sh --image-dir /data/images /dev/sdb /dev/sdc   # image first
#   scan-untrusted-media.sh /data/images/drive1.img        # rescan an existing image
#   scan-untrusted-media.sh --vt /mnt/already-mounted-dir  # any directory works
#
# What it does, per target:
#   1. hardens the GNOME session first (no automount, thumbnailers or
#      removable-media indexing: those parse untrusted files automatically)
#   2. block devices: refuses if anything on them is mounted, marks them
#      read-only, and scans them in place - or, only with --image-dir, images
#      them with ddrescue first, recording the image SHA-256 and any
#      unreadable sectors
#   3. attaches images read-only, detects every partition and APFS volume,
#      and mounts each one ro,nosuid,nodev,noexec (APFS via apfs-fuse)
#   4. scans every mounted volume inside a transient systemd sandbox: the
#      invoking user plus CAP_DAC_READ_SEARCH only, no network, no sockets,
#      a system-service syscall allowlist (no ptrace), and its only writable
#      path is the per-volume output directory - a parser exploit in a
#      scanner cannot rewrite the report, reach the session bus or trace the
#      host script (it still runs as your user: treat a scanner compromise
#      as a user-account compromise)
#        - full inventory and SHA-256 manifest of every file
#        - ClamAV (fresh definitions, all limits raised, archives/DMG/PKG
#          unpacked, PUA and macro alerts, encrypted/oversize files reported)
#        - YARA with the YARA Forge rule set (Windows, Linux, macOS, Android
#          and cross-platform malware, webshells, hack tools)
#        - an inventory of executable and auto-run content for every
#          platform: PE/ELF/Mach-O/DEX binaries, APK/IPA/MSI/DMG/deb/rpm
#          packages, scripts, app bundles, iOS/macOS configuration profiles,
#          shortcuts, disk images, macro documents, and persistence locations
#          (launch agents, Startup folders, scheduled tasks, autostart,
#          systemd/cron, shell start-up files)
#        - content-vs-extension checks: an executable named like a document
#          is a LIKELY finding, any other mismatch (a ".pdf" that is not a
#          PDF) a REVIEW finding; OS metadata (AppleDouble ._*, Spotlight,
#          Recycle Bin) is counted separately
#   5. optionally looks up hashes on VirusTotal (--vt; hashes only, never
#      file contents)
#   6. writes a report: DEFINITE / LIKELY / REVIEW findings plus the coverage
#      gaps that limit how much a clean result can be trusted
#
# No scan can prove media clean. Read the coverage-gap section of the report:
# a short gap list plus no findings is the strongest result this can give.

set -euo pipefail
# Report paths are escaped (tsv_esc) in the scan sandbox, the export sandbox
# and this shell, and --export/--quarantine match files by that escaped form:
# the character classes must not depend on the caller's locale.
unset LC_ALL
export LC_CTYPE=C.UTF-8

#--- Config -----------------------------------------------------------------
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
YARA_FORGE_API=https://api.github.com/repos/YARAHQ/yara-forge/releases/latest
CACHE_DIR=${XDG_CACHE_HOME:-${HOME}/.cache}/scan-untrusted-media
VT_KEY_FILE=${XDG_CONFIG_HOME:-${HOME}/.config}/virustotal/api-key
VT_API=https://www.virustotal.com/api/v3/files
CLAMAV_DB_DIR=/var/lib/clamav
# Large enough for real-world installers and disk images; anything still over
# a limit is reported as a coverage gap instead of being silently "clean".
# ClamAV cannot scan files of 2 GiB or more whatever the limit says; larger
# files are recorded as coverage gaps by the worker instead.
CLAMAV_MAX_BYTES=$(( 2 * 1024 * 1024 * 1024 - 1 ))
CLAM_LIMITS=(--max-filesize=2047M --max-scansize=4000M --max-files=200000
             --max-recursion=40 --max-scantime=900000 --max-partitions=200
             --max-embeddedpe=200M --max-htmlnormalize=200M
             --max-scriptnormalize=200M --max-ziptypercg=200M)
YARA_MAX_BYTES=$(( 1024 * 1024 * 1024 ))
YARA_TIMEOUT=120
# Executable or auto-run content that deserves a human look regardless of
# scanner verdicts, for every platform the media may have touched: Windows,
# macOS, iOS/iPadOS/tvOS/watchOS/visionOS, Linux, Android and cross-platform
# runtimes. MIME types are the ones file(1) reports.
EXEC_MIMES='application/(x-mach-binary|x-executable|x-pie-executable|x-sharedlib|x-object|x-coff|x-coff-executable|x-dosexec|vnd\.microsoft\.portable-executable|x-msdownload|x-ms-ne-executable|x-lx-executable|x-ms-w[34]-executable|vnd\.android\.package-archive|java-archive|x-java-applet|x-bytecode\.python)'
SUSPECT_MIMES='^('"${EXEC_MIMES}"'|application/(x-msi|x-ms-mst|vnd\.ms-cab-compressed|vnd\.ms-htmlhelp|x-ms-shortcut|x-mswinurl|x-setupscript|msonenote|onenote|x-apple-diskimage|x-xar|x-iso9660-image|x-virtualbox-vhd|vnd\.debian\.binary-package|x-rpm|vnd\.flatpak\.ref|x-shockwave-flash)|text/(x-shellscript|x-script\.python|x-python|x-perl|x-ruby|x-php|x-tcl|x-msdos-batch|x-applescript|x-ms-regedit|x-wine-extension-reg|x-ms-scf|x-ms-rdp))$'
# File-name patterns (case-insensitive, matched against the relative path).
# Bundle types are directories, so they match anywhere in the path (every
# file inside Foo.app/ is app content); every other extension must end the
# path, or a folder such as "name@icloud.com/" would flag everything below it.
#   Apple bundles: app, pkg, framework, kext, xpc, appex (iOS/macOS app
#     extensions), systemextension, driverext, plugins, prefpanes, ...
#   Apple files: dmg, command, scripts, dylib, ipa (iOS/tvOS/watchOS apps),
#     mobileconfig (configuration/MDM profiles), mobileprovision, web shortcuts
#   Windows: PE/DOS executables and libraries, control-panel and console
#     snap-ins, installers (msi/msix/appx/appinstaller), drivers, scripts
#     (PowerShell, WSH, batch), HTA/CHM, registry/inf/shortcut/search/library
#     files, RDP connections, mountable disk images, OneNote, Excel add-ins
#     and the macro-enabled Office formats
#   Linux: shell scripts, .run/AppImage, deb/rpm/snap/flatpak refs, desktop
#     entries, kernel modules, shared objects
#   Android: apk and split/bundle variants, dex/odex bytecode
#   Cross-platform: jar/class, Python/Perl/Ruby/PHP scripts, Flash
# Locations: macOS launch agents/daemons and login items, Windows Startup
# folders and scheduled tasks, Linux autostart/systemd/cron/init/profile
# directories and preload hooks, shell start-up files and SSH authorized keys.
SUSPECT_NAMES='(\.(app|pkg|mpkg|framework|kext|xpc|appex|systemextension|driverext|scptd|workflow|action|bundle|plugin|osax|qlgenerator|mdimporter|saver|prefpane|wdgt)(/|$)'\
'|\.(dmg|sparseimage|command|tool|scpt|applescript|terminal|dylib|ipa|mobileconfig|mobileprovision|webloc|inetloc|fileloc'\
'|exe|dll|scr|com|pif|cpl|msc|msi|msp|mst|msix|msixbundle|appx|appxbundle|appinstaller|application|appref-ms|gadget|sys|drv|ocx'\
'|bat|cmd|ps1|psm1|psd1|ps1xml|vbs|vbe|jse|wsf|wsh|wsc|sct|hta|chm|hlp|reg|inf|lnk|url|scf|library-ms|search-ms|searchconnector-ms|settingcontent-ms|rdp'\
'|iso|img|vhd|vhdx|one|xll|iqy|slk|docm|dotm|xlsm|xltm|xlam|xlsb|pptm|potm|ppam|ppsm|sldm'\
'|sh|bash|zsh|ksh|csh|run|appimage|deb|rpm|snap|flatpakref|flatpakrepo|desktop|ko|so'\
'|apk|apks|xapk|apkm|aab|dex|odex'\
'|jar|class|py|pyw|pl|pm|rb|php|pht|phtml|swf)$'\
'|(^|/)(LaunchAgents|LaunchDaemons|StartupItems|Login ?Items|ScriptingAdditions|PrivilegedHelperTools)/'\
'|(^|/)(Programs/Startup|System32/Tasks|SysWOW64/Tasks)/'\
'|(^|/)(\.config/autostart|\.config/systemd/user|\.local/share/applications|xdg/autostart|systemd/system|init\.d|rc\.d|profile\.d|cron\.(d|hourly|daily|weekly|monthly))/'\
'|(^|/)(ld\.so\.preload|rc\.local|autorun\.inf|crontab|authorized_keys)$'\
'|(^|/)\.ssh/rc$|(^|/)\.(zshrc|zprofile|zshenv|zlogin|zlogout|bash_profile|bash_login|bash_logout|bashrc|profile|login|xprofile|xinitrc|xsessionrc)$)'
# OS-generated metadata that every platform sprinkles over removable media:
# AppleDouble "._" companions and macOS volume databases, Windows recycle bin
# and volume information, freedesktop trash. Still scanned by ClamAV and YARA
# and still flagged by content type, but kept out of the name-based inventory
# and the extension checks (a "._report.pdf" is metadata, not a fake PDF).
OS_METADATA='(^|/)(\._[^/]*|\.DS_Store|Thumbs\.db|desktop\.ini|\.localized)$|(^|/)(\.Spotlight-V100|\.fseventsd|\.Trashes|\.TemporaryItems|\.DocumentRevisions-V100|\.MobileBackups|System Volume Information|\$RECYCLE\.BIN|RECYCLER|\.Trash-[0-9]+)/'
# Extension -> MIME types its content must have. A mismatch is reported for
# review; executable content behind a document/media extension (a PE renamed
# invoice.pdf) is a LIKELY finding. Empty files match anything.
declare -gA EXPECTED_MIME=(
  [pdf]='^application/pdf$'
  [jpg]='^image/' [jpeg]='^image/' [png]='^image/' [gif]='^image/' [heic]='^image/' [webp]='^image/' [tif]='^image/' [tiff]='^image/' [bmp]='^image/'
  [doc]='^application/(msword|vnd\.ms-|x-ole-storage|CDFV2)' [xls]='^application/(vnd\.ms-|x-ole-storage|CDFV2|msword)' [ppt]='^application/(vnd\.ms-|x-ole-storage|CDFV2|msword)'
  [docx]='^application/(vnd\.openxmlformats|zip|octet-stream)' [xlsx]='^application/(vnd\.openxmlformats|zip|octet-stream)' [pptx]='^application/(vnd\.openxmlformats|zip|octet-stream)'
  [txt]='^text/' [csv]='^(text/|application/csv)' [rtf]='^text/rtf$'
  [mp3]='^audio/' [m4a]='^(audio/|video/mp4)' [wav]='^audio/' [mp4]='^video/' [mov]='^video/' [avi]='^video/' [mkv]='^video/'
  [zip]='^application/zip$'
)

PKGS_FEDORA=(apfs-fuse clamav clamav-update cryptsetup curl ddrescue file jq kernel-modules-extra lvm2 unzip yara)
PKGS_ARCH=(clamav cryptsetup curl ddrescue file jq lvm2 unzip yara)

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ${0##*/} [options] TARGET...
       ${0##*/} --export REPORT_DIR DEST [--keep-metadata] TARGET
       ${0##*/} --quarantine REPORT_DIR [--yes] TARGET
       ${0##*/} --prepare-session | --restore-session
       ${0##*/} -h|--help

Read-only malware triage of untrusted media. TARGET is a block device
(/dev/sdX), a raw disk/partition image, or an already-mounted directory.

  --image-dir DIR     image block devices with ddrescue into DIR first and
                      scan the image (default: scan block devices in place,
                      strictly read-only)
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
                      thumbnails, removable-media indexing off) and install a
                      runtime udev rule that stops md/btrfs/LVM from
                      auto-processing untrusted drives, then exit; run this
                      BEFORE plugging in any untrusted drive (needs sudo)
  --restore-session   undo --prepare-session (desktop settings and the udev
                      rule) and exit

Neutralizing reviewed threats (after a scan; review REPORT_DIR/quarantine.tsv
first: only its active, uncommented lines are acted on):
  --export REPORT_DIR DEST TARGET
                      copy every scanned file except the selected ones (and
                      anything not in the scan inventory) from TARGET, mounted
                      read-only, into the new or empty directory DEST; each
                      copy is mode 0644 and re-verified against the scan's
                      SHA-256. Never writes to TARGET.
  --keep-metadata     with --export, also copy OS clutter (._*, .DS_Store,
                      .Spotlight-V100, .Trashes, \$RECYCLE.BIN, ...)
  --quarantine REPORT_DIR TARGET
                      on the block device TARGET itself, move each selected
                      file into REPORT_DIR/quarantine/<sha256>.7z (password
                      "infected", encrypted names) and leave a
                      <name>.QUARANTINED.txt stub. Mounts read-write (replays
                      journals); vfat, exfat, ntfs (ntfs3), ext2/3/4, btrfs,
                      xfs only.
  --yes               with --quarantine, do not ask for confirmation

Exit: 0 no DEFINITE or LIKELY findings (REVIEW-only findings exit 0 too),
      3 findings in DEFINITE or LIKELY, 1 error.
      --export/--quarantine: 0 done, 3 incomplete (see the log), 1 error.
USAGE
}

#--- Arguments ----------------------------------------------------------------
IMAGE_DIR=
IMAGE_MODE=direct
REPORT_DIR=
YARA_SET=extended
YARA_RULES=
USE_YARA=1
CLAM_DB=
UPDATE=1
USE_VT=0
VT_ALL=0
VT_RATE=4
VT_RATE_SET=0
KEEP_MOUNTED=0
RESUME=0
HARDEN_SESSION=1
SESSION_ACTION=
SESSION_RESTORE=${XDG_STATE_HOME:-${HOME}/.local/state}/scan-untrusted-media/restore-session-settings.sh
TARGETS=()
NZ_MODE=
NZ_REPORT=
NZ_DEST=
KEEP_METADATA=0
ASSUME_YES=0

# --internal-scan and --internal-export are the sandboxed worker entry points;
# see scan_volume and export_volume.
INTERNAL_SCAN=0
INTERNAL_EXPORT=0
if [[ ${1:-} == --internal-scan ]]; then
  INTERNAL_SCAN=1
elif [[ ${1:-} == --internal-export ]]; then
  INTERNAL_EXPORT=1
else
  while (( $# )); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --image-dir)  (( $# >= 2 )) || die "--image-dir needs a directory"; IMAGE_DIR=$2; IMAGE_MODE=image; shift ;;
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
        VT_RATE=$2; VT_RATE_SET=1; shift ;;
      --keep-mounted) KEEP_MOUNTED=1 ;;
      --resume)     RESUME=1 ;;
      --no-session-hardening) HARDEN_SESSION=0 ;;
      --prepare-session) SESSION_ACTION=prepare ;;
      --restore-session) SESSION_ACTION=restore ;;
      --export)
        (( $# >= 3 )) || die "--export needs REPORT_DIR and DEST (then TARGET)"
        [[ -z ${NZ_MODE} ]] || die "--export and --quarantine are separate runs"
        NZ_MODE=export NZ_REPORT=$2 NZ_DEST=$3; shift 2 ;;
      --quarantine)
        (( $# >= 2 )) || die "--quarantine needs REPORT_DIR (then TARGET)"
        [[ -z ${NZ_MODE} ]] || die "--export and --quarantine are separate runs"
        NZ_MODE=quarantine NZ_REPORT=$2; shift ;;
      --keep-metadata) KEEP_METADATA=1 ;;
      --yes)        ASSUME_YES=1 ;;
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
  local s c h i code
  REPLY=$1
  REPLY=${REPLY//\\/\\\\}
  REPLY=${REPLY//$'\t'/\\t}
  REPLY=${REPLY//$'\n'/\\n}
  # Every other control character (C0, DEL and, in UTF-8 names, C1) becomes
  # \xHH or \uHHHH: names come from hostile media, and raw ESC/CSI bytes in a
  # report would be interpreted by whatever terminal later displays it.
  # [[:cntrl:]] alone misses a raw C1 byte such as 0x9b (invalid UTF-8, but a
  # terminal executes it as CSI) and the Unicode bidi overrides, which can
  # visually reorder a path to disguise it - both are escaped as well.
  # The bracket below is a set of literal characters, not a range, so it works
  # the same under any collation.
  if [[ ${REPLY} != *[[:cntrl:]]* && ${REPLY} != *[$'\x80'-$'\x9f']* \
        && ${REPLY} != *[$'\u200b'$'\u200c'$'\u200d'$'\u200e'$'\u200f'$'\u2028'$'\u2029'$'\u202a'$'\u202b'$'\u202c'$'\u202d'$'\u202e'$'\u2060'$'\u2066'$'\u2067'$'\u2068'$'\u2069'$'\ufeff']* ]]; then
    return 0
  fi
  s=${REPLY} REPLY=
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    printf -v h '%x' "'${c}"
    code=$(( 16#${h} ))
    if [[ ${c} == [[:cntrl:]] ]] \
       || (( code >= 128 && code <= 159 )) \
       || { (( code >= 0x200b && code <= 0x200f )); } \
       || { (( code >= 0x2028 && code <= 0x2029 )); } \
       || (( code == 0x2060 || code == 0xfeff )) \
       || { (( code >= 0x202a && code <= 0x202e )); } \
       || { (( code >= 0x2066 && code <= 0x2069 )); }; then
      if (( code < 256 )); then printf -v c '\\x%02x' "${code}"; else printf -v c '\\u%04x' "${code}"; fi
    fi
    REPLY+=${c}
  done
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
# split on the last one. Paths are stored relative to <root>. The signature
# must match a restricted charset: it comes from the same line as the hostile
# file name, and a file named "x: <CSI junk>Evil FOUND\ny" would otherwise
# forge a finding with raw escape sequences in it. Anything that does not
# parse is recorded as a gap - never silently dropped.
parse_clam_log() {
  local log_file=$1 findings=$2 gaps=$3 root=$4 links=${5:-} line path sig cls k v
  local -A alias_of=()
  if [[ -n ${links} && -s ${links}.idx ]]; then
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do alias_of[${k}]=${v}; done <"${links}.idx"
  fi
  while IFS= read -r line; do
    if [[ ${line} != *' FOUND' ]]; then
      [[ -n ${line} ]] || continue
      tsv_esc "${line}"
      printf 'clamav\tunrecognized clamscan output line (treated as unscanned):\t%s\n' "${REPLY}" >>"${gaps}"
      continue
    fi
    line=${line% FOUND}
    sig=${line##*: }
    path=${line%: *}
    if [[ ! ${sig} =~ ^[A-Za-z0-9._:@-]+$ ]]; then
      tsv_esc "${line}"
      printf 'clamav\tsuspicious clamscan line (signature not recognized):\t%s\n' "${REPLY}" >>"${gaps}"
      continue
    fi
    # A symlink alias (awkward original name) maps back to its file.
    [[ -n ${alias_of[${path}]+x} ]] && path=${alias_of[${path}]}
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

# parse_yara_output <yara -m stdout> <findings.tsv> <gaps.tsv> <root>: lines
# look like "RULE [meta...] /path". YARA Forge rules carry score=0..100
# metadata; a score of 75+ is treated as LIKELY, anything lower as REVIEW.
# YARA prints CR and LF in names as the two-byte text "\r"/"\n", so a line
# holds at most one name, but the name may contain any other bytes (including
# invalid UTF-8): a $'.' regex under C.UTF-8 would drop such lines wholesale,
# so the line is split with globs on the trusted "] ${root}/" boundary, which
# no scanner output can silently mangle. Anything unparsable becomes a gap.
parse_yara_output() {
  local out=$1 findings=$2 gaps=$3 root=$4 line rule meta path score cls rest
  while IFS= read -r line; do
    if [[ ${line} != *"] ${root}/"* || ${line} != *\ [* ]]; then
      [[ -n ${line} ]] || continue
      tsv_esc "${line}"
      printf 'yara\tunrecognized yara output line (treated as unscanned):\t%s\n' "${REPLY}" >>"${gaps}"
      continue
    fi
    rest=${line%%"] ${root}/"*}
    path=${line#*"] ${root}/"}
    # YARA prints CR and LF in names as the text \r and \n (and backslashes
    # as they are): when the printed name is not a file but its decoded form
    # is, the decoded form is the file. Both existing is ambiguous: keep the
    # printed one and say so.
    if [[ ${path} == *\\* ]]; then
      local decoded=${path//\\n/$'\n'}
      decoded=${decoded//\\r/$'\r'}
      if [[ ${decoded} != "${path}" && ( -e ${root}/${decoded} || -L ${root}/${decoded} ) ]]; then
        if [[ -e ${root}/${path} || -L ${root}/${path} ]]; then
          tsv_esc "${path}"
          printf 'yara\tdetection name is ambiguous (a file with literal \\n/\\r and one with a real line break both exist); attributed to the literal one:\t%s\n' "${REPLY}" >>"${gaps}"
        else
          path=${decoded}
        fi
      fi
    fi
    rule=${rest%% \[*}
    meta=${rest#*\[}
    if [[ ! ${rule} =~ ^[A-Za-z0-9_]+$ ]]; then
      tsv_esc "${line}"
      printf 'yara\tunrecognized yara output line (rule name not valid):\t%s\n' "${REPLY}" >>"${gaps}"
      continue
    fi
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
#   bundles.txt     Apple bundle directories (.app, .pkg, .framework, .appex, ...)
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
  (( done > 0 && elapsed > 0 && total > done )) || { printf 'estimating'; return; }
  left=$(( (total - done) * elapsed / done ))
  printf '%dh%02dm' $(( left / 3600 )) $(( left % 3600 / 60 ))
}

# clam_split_batches <files.meta> <dir> <weight per batch>: split the
# inventory ("size mtime mode path" NUL records) into newline-separated
# --file-list batches dir/clambatch.NNNNN.lst of about <weight per batch>
# each (bytes plus CLAM_FILE_WEIGHT per file), writing each batch's weight to
# clambatch.NNNNN.w. Names that cannot ride a --file-list line - a newline,
# a carriage return (clamscan strips a trailing CR from list lines) or a
# path of CLAM_LIST_MAX bytes or more (it splits list lines at 1023) - go
# NUL-separated to clambatch.alias (weight in clambatch.alias.w); the worker
# scans them through short symlink aliases (see clam_alias_batch).
clam_split_batches() {
  LC_ALL=C awk -v RS='\0' -v per="$3" -v fw="${CLAM_FILE_WEIGHT}" -v lmax="${CLAM_LIST_MAX}" -v dir="$2" '
    function close_batch() { if (cur != "") { close(cur); printf "%.0f\n", w > (base ".w"); close(base ".w") } }
    { p = $0; sub(/^[0-9]+ -?[0-9]+ [0-7]+ /, "", p)
      if (index(p, "\n") || index(p, "\r") || length(p) >= lmax) { printf "%s%c", p, 0 > (dir "/clambatch.alias"); nlw += $1 + fw; next }
      if (cur == "" || w >= per) { close_batch(); base = sprintf("%s/clambatch.%05d", dir, b++); cur = base ".lst"; w = 0 }
      print p > cur; w += $1 + fw }
    END { close_batch(); if (nlw) printf "%.0f\n", nlw > (dir "/clambatch.alias.w") }' "$1"
}

# clam_alias_batch <dir>: turn clambatch.alias (NUL-separated awkward names)
# into the list batch clambatch.alias.lst of symlinks dir/clamlinks/NNNNNNN.
# clamscan follows a symlink named in its file list and reports the link's
# own (safe) name, so every detection maps back to exactly one file through
# dir/clamlinks.idx - scanning the names as arguments instead let a newline in
# a name split, and forge, clamscan's line-based output.
clam_alias_batch() {
  local dir=$1 p i=0 link
  [[ -s ${dir}/clambatch.alias ]] || return 0
  mkdir -p -- "${dir}/clamlinks"
  : >"${dir}/clamlinks.idx"
  while IFS= read -r -d '' p; do
    i=$(( i + 1 ))
    printf -v link '%s/clamlinks/%07d' "${dir}" "${i}"
    ln -s -- "${p}" "${link}"
    printf '%s\0%s\0' "${link}" "${p}" >>"${dir}/clamlinks.idx"
    printf '%s\n' "${link}" >>"${dir}/clambatch.alias.lst"
  done <"${dir}/clambatch.alias"
}

# clam_eta <out> <total weight> <jobs>: "NN% of data, ETA XhYYm" for the
# ClamAV batches. Work is measured in batch weights (bytes plus a per-file
# cost, see the batch split); the time per unit of weight comes from the
# batches that finished, and <jobs> batches run at once.
CLAM_FILE_WEIGHT=$(( 256 * 1024 ))
# clamscan reads --file-list lines with a 1023-byte limit and strips a
# trailing CR; names at or above this length (or containing CR) are passed as
# arguments instead of through a list.
CLAM_LIST_MAX=1000
clam_eta() {
  local out=$1 total=$2 jobs=$3 rc id start wfile secs=0 wdone=0 left pct
  for rc in "${out}"/clamscan.*.rc; do
    [[ -e ${rc} ]] || continue
    id=${rc%.rc}; id=${id##*/clamscan.}
    start=${out}/clamscan.${id}.start wfile=${out}/clambatch.${id}.w
    [[ -e ${start} && -r ${wfile} ]] || continue
    secs=$(( secs + $(stat -c %Y -- "${rc}") - $(stat -c %Y -- "${start}") ))
    wdone=$(( wdone + $(<"${wfile}") ))
  done
  (( total > 0 )) || total=1
  pct=$(( wdone * 100 / total ))
  if (( wdone == 0 || wdone >= total )); then
    printf '%d%% of data, ETA estimating' "${pct}"
    return
  fi
  left=$(( (total - wdone) * secs / wdone / jobs ))
  (( left >= 60 )) || left=60
  printf '%d%% of data, ETA %dh%02dm' "${pct}" $(( left / 3600 )) $(( left % 3600 / 60 ))
}

internal_scan() {
  local root=${1%/} out=$2 fstype=$3 yara_rules=$4 clam_db=$5 walk=${6:-strict}
  local meta=${out}/files.meta list=${out}/files.lst
  local rec rest path rel erel sum mime size mtime mode line reason f rc
  local files=0 bytes=0 suspects=0 zero_len=0 unix_fs=0 jobs batches per
  local os_meta=0 mismatches=0 is_meta base ext want clam_weight dev0 dev
  local total_files total_bytes n done_bytes started xpid
  local -a xdev=(-xdev) clam_opts=()
  local -A mime_of=() sum_of=() size_of=()
  [[ -d ${root} && -d ${out} ]] || { echo "internal-scan: bad paths" >&2; return 1; }
  # walk mode: "strict" never crosses a subvolume/mount boundary (find -xdev);
  # "cross" scans btrfs subvolumes of the volume this tool mounted itself
  # (each has its own st_dev, but they are media content, not foreign mounts);
  # "dir" is strict for a caller-supplied directory, whose nested mounts are
  # not media and become coverage gaps.
  [[ ${walk} == cross ]] && xdev=()
  : >"${out}/findings.tsv"; : >"${out}/gaps.tsv"; : >"${out}/suspect.tsv"
  [[ ${fstype} =~ ^(apfs|hfsplus|ext[234]|xfs|btrfs|f2fs)$ ]] && unix_fs=1

  # Inventory: one find pass records size, mtime and mode next to each path
  # (no per-file stat forks). find errors (permission, I/O) are gaps.
  scan_progress "${out}" "inventory: listing files"
  find "${root}" "${xdev[@]}" -type f -printf '%s %Ts %m %p\0' >"${meta}" 2>"${out}/find.err" || true
  if [[ ${walk} == dir ]]; then
    # Anything with a different st_dev below the target was skipped by the
    # -xdev walk (a nested mount, or a btrfs subvolume): an honest gap, never
    # a silent hole in the inventory.
    dev0=$(stat -c %d -- "${root}" || printf 0)
    while IFS= read -r line; do
      [[ -n ${line} ]] || continue
      dev=${line%% *}; path=${line#* }
      [[ ${dev} == "${dev0}" ]] && continue
      tsv_esc "${path#"${root}"/}"
      printf 'find\tnested filesystem (mount or subvolume) not scanned:\t%s\n' "${REPLY}" >>"${out}/gaps.tsv"
    done < <(find "${root}" -type d -printf '%D %p\n' 2>/dev/null || true)
  fi
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
  find "${root}" "${xdev[@]}" -type d \( -iname '*.app' -o -iname '*.pkg' -o -iname '*.mpkg' \
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
  done < <(xargs -0 -r file -N -r -0 --mime-type -- <"${list}" 2>"${out}/file.err"; echo $? >"${out}/file.rc")
  # file(1) killed by a signal (its seccomp SIGSYS, or a parser crash on
  # hostile content) leaves the rest of the inventory untyped and the
  # content-vs-extension checks silently skipped: stderr is kept and a short
  # count is a gap, never a quiet pass.
  while IFS= read -r line; do
    printf 'file\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
  done <"${out}/file.err"
  if (( n < total_files )); then
    printf 'file\tfile(1) reported a type for %s of %s files (crashed or stopped early; content checks incomplete)\t-\n' \
      "${n}" "${total_files}" >>"${out}/gaps.tsv"
    rc=$(<"${out}/file.rc")
    (( rc == 0 )) || printf 'file\tfile type detection exited %s\t-\n' "${rc}" >>"${out}/gaps.tsv"
  fi
  rm -f -- "${out}/file.rc"

  exec 3>"${out}/files.tsv" 4>>"${out}/gaps.tsv" 5>>"${out}/suspect.tsv" 6>>"${out}/findings.tsv"
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
    (( size > CLAMAV_MAX_BYTES )) \
      && printf 'clamav\tlarger than 2 GiB, which ClamAV cannot scan\t%s\n' "${erel}" >&4
    if (( size > YARA_MAX_BYTES )) && [[ ${yara_rules} != - ]]; then
      printf 'yara\tlarger than %s, not YARA-scanned\t%s\n' "$(human_bytes "${YARA_MAX_BYTES}")" "${erel}" >&4
    fi
    # Linux's hfsplus driver cannot read HFS+ transparent compression
    # (decmpfs): such files look empty. Count them as a coverage caveat.
    [[ ${fstype} == hfsplus ]] && (( size == 0 )) && zero_len=$(( zero_len + 1 ))

    is_meta=0
    [[ ${rel} =~ ${OS_METADATA} ]] && is_meta=1 && os_meta=$(( os_meta + 1 ))
    reason=
    [[ ${mime} =~ ${SUSPECT_MIMES} ]] && reason="type ${mime}"
    # Metadata names are skipped here but not their content type: an
    # executable hiding as "._x" is still flagged above.
    (( is_meta )) || { [[ -z ${reason} && ${rel} =~ ${SUSPECT_NAMES} ]] && reason="name/location"; }
    # Content that does not match the extension: an executable behind a
    # document/media extension is a classic lure (LIKELY); anything else
    # (a ".pdf" that is not a PDF) needs a look (REVIEW).
    base=${rel##*/}
    if (( ! is_meta )) && [[ ${base} == ?*.?* && ${mime} != inode/x-empty ]]; then
      ext=${base##*.}; ext=${ext,,}
      want=${EXPECTED_MIME[${ext}]:-}
      if [[ -n ${want} && ! ${mime} =~ ${want} ]]; then
        mismatches=$(( mismatches + 1 ))
        reason="${reason:+${reason}; }content ${mime} does not match .${ext}"
        if [[ ${mime} =~ ^(${EXEC_MIMES})$ ]]; then
          printf 'LIKELY\theuristic\texecutable (%s) disguised as .%s\t%s\n' "${mime}" "${ext}" "${erel}" >&6
        else
          printf 'REVIEW\theuristic\tcontent is %s, not what .%s implies\t%s\n' "${mime}" "${ext}" "${erel}" >&6
        fi
      fi
    fi
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
  exec 3>&- 4>&- 5>&- 6>&-

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
    # Every batch starts by loading the ~1 GB signature database (15-30 s),
    # so batches hold at least ~1000 files; very large volumes are capped at
    # 20 batches per job, which still gives fine-grained progress.
    batches=$(( (files + 999) / 1000 ))
    (( batches >= jobs )) || batches=${jobs}
    (( batches <= jobs * 20 )) || batches=$(( jobs * 20 ))
    # Batches are balanced by work, not file count: a file weighs its size
    # plus a fixed per-file cost, so a batch of big archives/disk images (which
    # ClamAV unpacks) is not ten times slower than one of small photos. Each
    # batch records its weight for the ETA (see clam_eta).
    clam_weight=$(( bytes + files * CLAM_FILE_WEIGHT ))
    per=$(( (clam_weight + batches - 1) / batches ))
    clam_split_batches "${meta}" "${out}" "${per}"
    clam_alias_batch "${out}"
    batches=$(count_existing "${out}"/clambatch.*.lst)
    started=${EPOCHSECONDS}
    # shellcheck disable=SC2016 # expanded by the inner bash
    {
      if (( batches > 0 )); then
        printf '%s\0' "${out}"/clambatch.*.lst | xargs -0 -r -P "${jobs}" -I{} bash -c '
          out=$1 batch=$2 n=$3; shift 3; id=${batch##*/clambatch.}; id=${id%.lst}
          : >"${out}/clamscan.${id}.start"
          rc=0; clamscan "${@:1:n}" --file-list="${batch}" >"${out}/clamscan.${id}.part" 2>"${out}/clamscan.${id}.err" || rc=$?
          echo "${rc}" >"${out}/clamscan.${id}.rc"' _ "${out}" {} "${#clam_opts[@]}" "${clam_opts[@]}"
      fi
    } &
    xpid=$!
    while kill -0 "${xpid}" 2>/dev/null; do
      n=$(count_existing "${out}"/clamscan.*.rc)
      scan_progress "${out}" "clamav: ${n}/${batches} batches done, $(clam_eta "${out}" "${clam_weight}" "${jobs}")"
      sleep 10
    done
    wait "${xpid}" || true
    rm -f -- "${out}"/clambatch.* "${out}"/clamscan.*.start
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
  rm -f -- "${out}"/clamscan.*.part "${out}"/clamscan.[0-9a]*.err "${out}"/clamscan.*.rc
  parse_clam_log "${out}/clamscan.log" "${out}/findings.tsv" "${out}/gaps.tsv" "${root}" "${out}/clamlinks"
  # The aliases must not outlive the scan: the host rejects symlinks in a
  # worker's output directory as tampering.
  rm -rf -- "${out}/clamlinks" "${out}/clamlinks.idx"
  # clamscan prints access failures ("WARNING: ...: Can't access file") on
  # stdout mixed with the FOUND lines, and libclamav messages on stderr:
  # both mean files this run did not fully examine. Every such line is a gap;
  # nothing is filtered away on trust.
  while IFS= read -r line; do
    [[ ${line} == WARNING:* || ${line} == ERROR:* ]] || continue
    printf 'clamav\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
  done <"${out}/clamscan.log"
  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    printf 'clamav\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
  done <"${out}/clamscan.err"

  if [[ ${yara_rules} != - ]]; then
    scan_progress "${out}" "yara: scanning $(human_bytes "${total_bytes}") since $(date +%H:%M) (no per-file progress)"
    rc=0
    yara --compiled-rules --recursive --no-follow-symlinks --print-meta --no-warnings \
      --threads="$(nproc)" --timeout="${YARA_TIMEOUT}" --skip-larger="${YARA_MAX_BYTES}" \
      "${yara_rules}" "${root}" >"${out}/yara.log" 2>"${out}/yara.err" || rc=$?
    (( rc == 0 )) || printf 'yara\tyara exited %s (see yara.err)\t-\n' "${rc}" >>"${out}/gaps.tsv"
    parse_yara_output "${out}/yara.log" "${out}/findings.tsv" "${out}/gaps.tsv" "${root}"
    while IFS= read -r line; do
      # Oversized files already have a per-file gap from the inventory.
      [[ ${line} == skipping\ *" because it's larger than "* ]] && continue
      printf 'yara\t%s\t-\n' "$(tsv_escape "${line}")" >>"${out}/gaps.tsv"
    done <"${out}/yara.err"
  fi

  scan_progress "${out}" "done"
  printf 'files=%s\nbytes=%s\nsuspects=%s\nbundles=%s\nzero_len_hfsplus=%s\nos_metadata=%s\nmismatches=%s\n' "${files}" \
    "${bytes}" "${suspects}" "$(wc -l <"${out}/bundles.txt")" "${zero_len}" "${os_meta}" "${mismatches}" >"${out}/counts"
  rm -f -- "${list}" "${meta}"
}

if (( INTERNAL_SCAN )); then
  shift
  (( $# == 5 || $# == 6 )) || die "--internal-scan needs 5 arguments (a 6th, the walk mode, is optional)"
  internal_scan "$@"
  exit
fi

#--- Neutralizing reviewed threats: selection, export worker, quarantine ----
# --export and --quarantine act on a finished report. They find each scanned
# volume again through volumes.tsv's identity columns (source, filesystem
# UUID, APFS volume index, partition number) and select files through
# quarantine.tsv. Relative paths are only ever compared in their escaped form:
# a path found on the volume is escaped with tsv_esc and matched against the
# escaped string in the report, never the other way round.

# OS metadata clutter is OS_METADATA (defined with the scan patterns), so the
# scan's metadata count and --export's left-out set always agree.
declare -gA Q_REL=() Q_SHA=() Q_INFO=()
Q_KEYS=()

# is_os_clutter <relative path>: true for OS metadata clutter.
is_os_clutter() {
  local rc=1 had=0
  shopt -q nocasematch && had=1
  shopt -s nocasematch
  [[ $1 =~ ${OS_METADATA} ]] && rc=0
  (( had )) || shopt -u nocasematch
  return "${rc}"
}

# write_quarantine_template <report dir>: quarantine.tsv lists each file of
# findings.tsv once (unique volume, sha256, path) with its strongest class and
# every distinct "source: detail". DEFINITE and LIKELY lines are active,
# REVIEW lines are commented out.
write_quarantine_template() {
  local dir=$1
  [[ -f ${dir}/findings.tsv ]] || return 0
  {
    cat <<'HEADER'
# quarantine.tsv - which files --export leaves out and --quarantine archives
# and removes. Generated from findings.tsv: DEFINITE and LIKELY detections are
# active, REVIEW findings are commented out. To select a file, delete the
# leading "# " of its line; to keep a file, put "# " in front of its line.
# Only active (uncommented) lines are acted on; blank and "#" lines are
# ignored. --export also leaves out every other file with the SHA-256 of an
# active line. Keep the five tab-separated columns and do not edit the paths
# (they are escaped exactly as in findings.tsv).
# volume_tag	sha256	class	detail	relpath
HEADER
    awk -F'\t' -v OFS='\t' '
      NF >= 6 {
        r = ($1 == "DEFINITE" ? 3 : ($1 == "LIKELY" ? 2 : ($1 == "REVIEW" ? 1 : 0)))
        if (!r) next
        k = $4 OFS $5 OFS $6; d = $2 ": " $3
        if (!(k in rank)) { order[++n] = k; rank[k] = r; cls[k] = $1; det[k] = d; seen[k, d] = 1; next }
        if (r > rank[k]) { rank[k] = r; cls[k] = $1 }
        if (!((k, d) in seen)) { seen[k, d] = 1; det[k] = det[k] "; " d }
      }
      END { for (i = 1; i <= n; i++) { k = order[i]; split(k, f, OFS)
              print (rank[k] >= 2 ? 0 : 1), f[1], f[2], cls[k], det[k], f[3] } }' "${dir}/findings.tsv" \
      | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 -k6,6 \
      | awk -F'\t' -v OFS='\t' '{ print ($1 == 1 ? "# " : "") $2, $3, $4, $5, $6 }'
  } >"${dir}/quarantine.tsv"
}

# load_quarantine_selection <quarantine.tsv>: read the active lines into
# Q_KEYS (ordered "tag<TAB>escaped relpath"), Q_REL[key]=sha256,
# Q_INFO[key]="class<TAB>detail" and Q_SHA[sha256]=1. A malformed active line
# is an error: the selection must be exactly what the user wrote.
load_quarantine_selection() {
  local file=$1 line rest tabs tag sum cls det rel key n=0
  Q_KEYS=(); Q_REL=(); Q_SHA=(); Q_INFO=()
  [[ -f ${file} && -r ${file} ]] || { printf 'cannot read %s\n' "${file}" >&2; return 1; }
  while IFS= read -r line || [[ -n ${line} ]]; do
    n=$(( n + 1 ))
    line=${line%$'\r'}
    [[ ${line} =~ ^[[:space:]]*(#|$) ]] && continue
    tabs=${line//[!$'\t']/}
    if (( ${#tabs} != 4 )); then
      printf '%s line %d: expected 5 tab-separated columns (volume_tag, sha256, class, detail, relpath)\n' \
        "${file##*/}" "${n}" >&2
      return 1
    fi
    tag=${line%%$'\t'*}; rest=${line#*$'\t'}
    sum=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    cls=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    det=${rest%%$'\t'*}; rel=${rest#*$'\t'}
    if [[ -z ${tag} || -z ${rel} || ! ${sum} =~ ^([0-9a-f]{64}|-)$ ]]; then
      printf '%s line %d: bad volume tag, sha256 or path\n' "${file##*/}" "${n}" >&2
      return 1
    fi
    key=${tag}$'\t'${rel}
    [[ -n ${Q_REL[${key}]+x} ]] || Q_KEYS+=("${key}")
    Q_REL[${key}]=${sum}
    Q_INFO[${key}]=${cls}$'\t'${det}
    [[ ${sum} == - ]] || Q_SHA[${sum}]=1
  done <"${file}"
}

# match_volume_tag <volumes.tsv> <fstype> <uuid|-> <partition number|-> <APFS volume|->:
# print the report tag of the scanned volume this one is. The filesystem UUID
# decides (the partition number breaks a tie between clones); only when one
# side has no UUID does fstype + partition number decide. Exit 1: no match,
# 2: ambiguous, 3: the report predates the identity columns.
match_volume_tag() {
  awk -F'\t' -v fs="$2" -v uuid="$3" -v part="$4" -v av="$5" '
    NF < 7 { old = 1; next }
    $2 != fs || $6 != av { next }
    uuid != "-" && $5 == uuid { u[++nu] = $1; up[nu] = $7 }
    (uuid == "-" || $5 == "-") && $7 == part { p[++np] = $1 }
    END {
      if (nu == 1) { print u[1]; exit 0 }
      if (nu > 1) {
        for (i = 1; i <= nu; i++) if (up[i] == part) { m++; t = u[i] }
        if (m == 1) { print t; exit 0 }
        print "ambiguous: " nu " scanned volumes share UUID " uuid > "/dev/stderr"; exit 2
      }
      if (np == 1) { print p[1]; exit 0 }
      if (np > 1) { print "ambiguous: " np " scanned " fs " volumes match partition " part > "/dev/stderr"; exit 2 }
      if (old) { print "volumes.tsv has no volume identity columns (report from an older version); rescan" > "/dev/stderr"; exit 3 }
      print "no scanned " fs " volume with UUID " uuid " / partition " part > "/dev/stderr"; exit 1
    }' "$1"
}

# quarantine_fs_types <fstype>: the mount type to try for an in-place
# read-write quarantine, or an explanation and failure for filesystems Linux
# cannot safely write.
quarantine_fs_types() {
  case $1 in
    vfat|exfat|ext2|ext3|ext4|btrfs|xfs) printf '%s' "$1" ;;
    # ntfs3 only: ntfs-3g is a userspace parser of hostile metadata and would
    # run as root through try_mount's sudo.
    ntfs) printf 'ntfs3' ;;
    apfs|hfs|hfsplus)
      printf '%s has no safe read-write Linux driver: quarantine on a Mac (or a macOS VM), or use --export\n' "$1" >&2
      return 1 ;;
    *)
      printf '%s is not supported for in-place quarantine (only vfat, exfat, ntfs, ext2/3/4, btrfs, xfs); use --export\n' "${1:-unknown}" >&2
      return 1 ;;
  esac
}

# check_export_dest <dest>: print DEST as an absolute path, or explain why it
# cannot be used: it must be new or empty, outside /tmp and /var/tmp (hidden by
# the sandbox's PrivateTmp), outside the scanner's mounts, free of whitespace.
check_export_dest() {
  local d
  [[ -n $1 ]] || { echo 'DEST is empty' >&2; return 1; }
  d=$(readlink -m -- "$1")
  case ${d} in
    /tmp|/tmp/*|/var/tmp|/var/tmp/*)
      echo "DEST ${d} is under /tmp or /var/tmp (PrivateTmp hides it from the export sandbox)" >&2; return 1 ;;
    /run/scan-untrusted-media.*)
      echo "DEST ${d} is inside the scanner's mounts" >&2; return 1 ;;
    /) echo 'DEST must not be /' >&2; return 1 ;;
  esac
  [[ ${d} != *[[:space:]]* ]] || { echo "DEST ${d} contains whitespace (systemd sandbox path)" >&2; return 1; }
  if [[ -e ${d} ]]; then
    [[ -d ${d} ]] || { echo "DEST ${d} exists and is not a directory" >&2; return 1; }
    [[ -z $(ls -A -- "${d}") ]] || { echo "DEST ${d} is not empty" >&2; return 1; }
  fi
  printf '%s' "${d}"
}

# export_tree <volume root> <dest dir> <files.tsv> <quarantine.tsv> <tag> <log> <keep metadata 0|1> <progress dir> [walk]:
# the export worker (runs inside the sandbox, or directly in tests). Copies
# every regular file below <volume root> into <dest dir> unless it is OS
# clutter, absent from the volume's scan inventory, selected in quarantine.tsv
# or shares the SHA-256 of a selected file. walk is "strict" (find -xdev) or
# "cross" (btrfs subvolumes of this tool's own mount; see internal_scan).
# Copies get mode 0644 (directories 0755) and nothing else from the source:
# no owner, exec/setuid bits, xattrs or ACLs. Each copy is hashed again and
# deleted unless it matches files.tsv. Log lines: status, reason, tag, sha256,
# escaped relpath.
export_tree() {
  local root=${1%/} out=${2%/} files_tsv=$3 qfile=$4 tag=$5 log=$6 keep=$7 prog=$8 walk=${9:-strict}
  local sum size mtime mode mime erel ty rel src dst want got n=0 total=0 copied=0 bytes=0 lfd line key
  local -a xdev=(-xdev)
  local -A want_sum=() want_size=() seen=()
  [[ ${walk} == cross ]] && xdev=()
  [[ -d ${root} && -d ${out} && -f ${files_tsv} && -d ${prog} ]] \
    || { echo "internal-export: bad paths" >&2; return 1; }
  load_quarantine_selection "${qfile}" || return 1
  umask 022
  while IFS=$'\t' read -r sum size mtime mode mime erel; do
    [[ -n ${erel} ]] || continue
    want_sum[${erel}]=${sum} want_size[${erel}]=${size}
    total=$(( total + 1 ))
  done <"${files_tsv}"
  exec {lfd}>>"${log}"
  nz_log() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${tag}" "$3" "$4" >&"${lfd}"; }
  scan_progress "${prog}" "export: 0/${total} files"
  while IFS= read -r -d '' ty && IFS= read -r -d '' rel; do
    n=$(( n + 1 ))
    (( n % 200 )) || scan_progress "${prog}" "export: ${n}/${total} files examined, ${copied} copied ($(human_bytes "${bytes}"))"
    tsv_esc "${rel}"; erel=${REPLY}
    [[ ${ty} == f ]] && seen[${erel}]=1
    want=${want_sum[${erel}]--}
    if (( ! keep )) && is_os_clutter "${rel}"; then
      nz_log skipped 'OS metadata (--keep-metadata copies it)' "${want}" "${erel}"; continue
    fi
    if [[ ${ty} != f ]]; then
      nz_log skipped "not a regular file (find type ${ty})" - "${erel}"; continue
    fi
    if [[ -z ${want_sum[${erel}]+x} ]]; then
      nz_log skipped 'not in the scan inventory (files.tsv): never scanned' - "${erel}"; continue
    fi
    if [[ ${want} == - ]]; then
      nz_log skipped 'unreadable at scan time (no sha256 recorded)' - "${erel}"; continue
    fi
    if [[ -n ${Q_REL[${tag}$'\t'${erel}]+x} ]]; then
      nz_log skipped 'selected in quarantine.tsv' "${want}" "${erel}"; continue
    fi
    if [[ -n ${Q_SHA[${want}]+x} ]]; then
      nz_log skipped 'same sha256 as a file selected in quarantine.tsv' "${want}" "${erel}"; continue
    fi
    src=${root}/${rel} dst=${out}/${rel}
    if [[ ${rel} == */* ]] && ! mkdir -p -- "${dst%/*}" 2>/dev/null; then
      nz_log error 'cannot create the destination directory' "${want}" "${erel}"; continue
    fi
    if [[ -e ${dst} || -L ${dst} ]]; then
      nz_log error 'destination already exists (case-insensitive DEST?)' "${want}" "${erel}"; continue
    fi
    # nofollow: a directory TARGET that changes underneath cannot swap in a
    # symlink to a host file (the hash check below would also catch it).
    if ! dd if="${src}" iflag=nofollow bs=1M status=none >"${dst}" 2>/dev/null; then
      rm -f -- "${dst}"
      nz_log error 'read or write error while copying' "${want}" "${erel}"; continue
    fi
    got=$(sha256sum <"${dst}"); got=${got%% *}
    if [[ ${got} != "${want}" ]]; then
      rm -f -- "${dst}"
      nz_log mismatch "file changed since the scan (now ${got}); copy deleted" "${want}" "${erel}"; continue
    fi
    chmod 0644 -- "${dst}"
    nz_log copied - "${want}" "${erel}"
    copied=$(( copied + 1 )) bytes=$(( bytes + ${want_size[${erel}]:-0} ))
  done < <(find "${root}" "${xdev[@]}" -mindepth 1 ! -type d -printf '%y\0%P\0' 2>"${prog}/find.err")
  while IFS= read -r line; do
    tsv_esc "${line}"
    nz_log error "find: ${REPLY}" - -
  done <"${prog}/find.err"
  for erel in "${!want_sum[@]}"; do
    [[ -n ${seen[${erel}]+x} ]] || nz_log missing 'in files.tsv but no longer on the volume' "${want_sum[${erel}]}" "${erel}"
  done
  # An active quarantine.tsv line whose (tag, path) never matched a file on
  # this volume means the detection's path did not map to the inventory (a
  # spoofed or malformed scanner line): nothing was left out for it, and the
  # file it was meant to select may be sitting in DEST. That is an error, not
  # a quiet success.
  for key in "${Q_KEYS[@]}"; do
    [[ ${key%%$'\t'*} == "${tag}" ]] || continue
    [[ -z ${seen[${key#*$'\t'}]+x} ]] \
      && nz_log error 'selected in quarantine.tsv but never matched a file on this volume (detection did not map to a scanned file)' \
           "${Q_REL[${key}]}" "${key#*$'\t'}"
  done
  exec {lfd}>&-
  scan_progress "${prog}" "done: ${copied} files copied, $(human_bytes "${bytes}")"
}

# The conventional password for archived malware samples: it only stops
# accidental extraction and on-access scanners from re-flagging the archive.
QUARANTINE_PASSWORD=infected
NZ_LOG=
QDIR=

# nz_record <status> <reason> <tag> <sha256> <escaped relpath>: one log line.
nz_record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"${NZ_LOG}"; }

# nz_summary: counts per status and per reason from the run's log; true when
# nothing went wrong (no error, mismatch or missing line).
nz_summary() {
  echo
  log "Summary (full list: ${NZ_LOG}):"
  awk -F'\t' '{ c[$1]++ } END { for (k in c) printf "  %-12s %d\n", k ":", c[k] }' "${NZ_LOG}" | sort
  awk -F'\t' '$2 != "-" { r = $2; gsub(/ \(now [^)]*\)/, "", r); if (length(r) > 110) r = substr(r, 1, 110) "..."
                          c[$1 ": " r]++ }
              END { for (k in c) printf "  %8d  %s\n", c[k], k }' "${NZ_LOG}" | sort -rn | head -n 30
  ! awk -F'\t' '$1 == "error" || $1 == "mismatch" || $1 == "missing" { f = 1 } END { exit !f }' "${NZ_LOG}"
}

# nz_verify_archive <archive> <sha256>: 7-Zip's own test passes and the
# extracted content hashes to <sha256>.
nz_verify_archive() {
  local got
  7z t -p"${QUARANTINE_PASSWORD}" -bd -- "$1" >/dev/null 2>&1 || return 1
  got=$(7z x -so -p"${QUARANTINE_PASSWORD}" -bd -- "$1" 2>/dev/null | sha256sum) || return 1
  [[ ${got%% *} == "$2" ]]
}

# quarantine_file <path> <key>: verify, archive, verify the archive, write the
# stub, delete the original. Runs file operations through the caller's "run"
# prefix (sudo on Unix filesystems). Nothing on the volume is ever executed,
# and the stub is created with O_EXCL|O_NOFOLLOW so a planted symlink cannot
# redirect a root write onto the host.
quarantine_file() {
  local p=$1 key=$2 tag want got arch tmp stub erel cls det base
  tag=${key%%$'\t'*} erel=${key#*$'\t'} want=${Q_REL[${key}]}
  cls=${Q_INFO[${key}]%%$'\t'*} det=${Q_INFO[${key}]#*$'\t'}
  if [[ ${want} == - ]]; then
    nz_record error 'no sha256 recorded at scan time (the detection never mapped to a scanned file); left in place and nothing else was removed for it' "${tag}" - "${erel}"
    return 0
  fi
  got=$("${run[@]}" sha256sum -z -- "${p}" | tr -d '\0') || got=
  got=${got%% *}
  if [[ ${got} != "${want}" ]]; then
    nz_record mismatch "sha256 differs from quarantine.tsv (now ${got:-unreadable}); left in place" "${tag}" "${want}" "${erel}"
    return 0
  fi
  arch=${QDIR}/${want}.7z
  if ! { [[ -f ${arch} ]] && nz_verify_archive "${arch}" "${want}"; }; then
    tmp=${QDIR}/.${want}.partial.7z
    rm -f -- "${tmp}"
    # The member is named by its hash: nothing extracts under a name a file
    # manager would open, and hostile names never reach 7-Zip.
    if ! "${run[@]}" cat -- "${p}" \
        | 7z a -t7z -mhe=on -p"${QUARANTINE_PASSWORD}" -bd -si"${want}" -- "${tmp}" >/dev/null 2>&1; then
      rm -f -- "${tmp}"
      nz_record error '7-Zip could not archive it; left in place' "${tag}" "${want}" "${erel}"
      return 0
    fi
    if ! nz_verify_archive "${tmp}" "${want}"; then
      rm -f -- "${tmp}"
      nz_record error 'archive failed verification; left in place' "${tag}" "${want}" "${erel}"
      return 0
    fi
    chmod 0600 -- "${tmp}"
    mv -f -- "${tmp}" "${arch}"
  fi
  base=${p##*/}
  tsv_esc "${base}"
  base=${REPLY}
  stub=${p}.QUARANTINED.txt
  if ! nz_stub_text "${base}" "${want}" "${cls}" "${det}" | "${run[@]}" dd of="${stub}" conv=excl oflag=nofollow status=none 2>/dev/null; then
    stub=${p%/*}/QUARANTINED-${want}.txt
    nz_stub_text "${base}" "${want}" "${cls}" "${det}" \
      | "${run[@]}" dd of="${stub}" conv=excl oflag=nofollow status=none 2>/dev/null || {
        nz_record error 'could not write the stub; original left in place (archive kept)' "${tag}" "${want}" "${erel}"
        return 0; }
  fi
  if ! "${run[@]}" rm -- "${p}"; then
    "${run[@]}" rm -f -- "${stub}"
    nz_record error 'could not delete the original (archive kept)' "${tag}" "${want}" "${erel}"
    return 0
  fi
  [[ -s ${QDIR}/index.tsv ]] || printf '# date\tvolume_tag\tsha256\tclass\tdetail\trelpath\n' >"${QDIR}/index.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "${tag}" "${want}" "${cls}" "${det}" "${erel}" >>"${QDIR}/index.tsv"
  tsv_esc "${stub##*/}"
  nz_record quarantined "archived as quarantine/${want}.7z, stub ${REPLY}" "${tag}" "${want}" "${erel}"
}

# nz_stub_text <escaped name> <sha256> <class> <detail>
nz_stub_text() {
  cat <<STUB
This file was removed by scan-untrusted-media.sh --quarantine because it was
flagged as malware. Do not try to recover it unless you know it is safe.

Original name: $1
SHA-256:       $2
Detection:     $3: $4
Date:          $(date -R)
Archive:       $2.7z in the quarantine/ folder of the scan report
               ${NZ_REPORT} on $(uname -n)
               (7-Zip, password "${QUARANTINE_PASSWORD}", encrypted file names)

To restore (only on a machine where it cannot do harm):
  7z x -p${QUARANTINE_PASSWORD} $2.7z     # extracts a file named $2
  then rename that file back to the original name above.
STUB
}

if (( INTERNAL_EXPORT )); then
  shift
  (( $# == 8 || $# == 9 )) || die "--internal-export needs 8 arguments (a 9th, the walk mode, is optional)"
  export_tree "$@"
  exit
fi

#--- Report merge (pure helpers; also reached by tests) -----------------------
# collect_results: merge per-volume findings and gaps (adding the volume tag
# and each file's SHA-256) into findings.tsv and gaps.tsv at the top level.
collect_results() {
  local d tag
  : >"${REPORT_DIR}/findings.tsv"
  cp -- "${REPORT_DIR}/gaps-global.tsv" "${REPORT_DIR}/gaps.tsv"
  for d in "${REPORT_DIR}"/volumes/*/; do
    [[ -f ${d}files.tsv ]] || continue
    tag=${d%/}; tag=${tag##*/}
    # A finding whose path is not in the volume's inventory means the scanner
    # printed a path that maps to no scanned file (a malformed or forged
    # scanner line). It keeps its finding row (with sha "-") so nothing is
    # hidden, and also becomes a gap so --export can never treat the volume
    # as fully triaged while a detection went unmatched.
    awk -F'\t' -v OFS='\t' -v vol="${tag}" -v gaps="${REPORT_DIR}/gaps.tsv" 'NR == FNR { sha[$6] = $1; next }
      { if ($4 in sha) print $1, $2, $3, vol, sha[$4], $4
        else { print $1, $2, $3, vol, "-", $4
               print vol, "scan", "detection not mapped to a scanned file (malformed or forged scanner output): " $4, "-" >> gaps } }' \
      "${d}files.tsv" "${d}findings.tsv" >>"${REPORT_DIR}/findings.tsv"
    # One gap per tool and file: an oversized file is reported both by the
    # inventory and by ClamAV's own limit alert.
    awk -F'\t' -v OFS='\t' -v vol="${tag}" '$3 == "-" || !seen[$1 FS $3]++ { print vol, $1, $2, $3 }' \
      "${d}gaps.tsv" >>"${REPORT_DIR}/gaps.tsv"
  done
}

# Sourced by tests: stop before doing anything.
[[ ${SCAN_UNTRUSTED_MEDIA_LIB:-0} == 1 ]] && return 0

#--- Preflight --------------------------------------------------------------
(( EUID != 0 )) || die "Run as your normal user; privileged steps use sudo."
if [[ -n ${SESSION_ACTION} ]]; then
  (( ${#TARGETS[@]} == 0 )) || die "--${SESSION_ACTION}-session takes no TARGET"
else
  (( ${#TARGETS[@]} )) || { usage >&2; die "No TARGET given."; }
  [[ -z ${IMAGE_DIR} || -d ${IMAGE_DIR} ]] || die "--image-dir ${IMAGE_DIR} is not a directory"
fi
(( VT_ALL == 0 || USE_VT == 1 )) || die "--vt-all needs --vt"
(( ! VT_RATE_SET || USE_VT == 1 )) || die "--vt-rate only applies with --vt"
(( ! RESUME )) || [[ ${IMAGE_MODE} == image ]] || die "--resume continues an interrupted --image-dir image; it needs --image-dir"
if [[ -n ${YARA_RULES} ]]; then
  (( USE_YARA )) || die "--yara-rules and --no-yara contradict each other"
  [[ ${YARA_SET} == extended ]] || die "--yara-rules replaces the YARA Forge rules; it cannot be combined with --yara-set"
fi
if [[ -n ${NZ_MODE} ]]; then
  [[ -z ${SESSION_ACTION} ]] || die "--${NZ_MODE} cannot be combined with --${SESSION_ACTION}-session"
  (( ${#TARGETS[@]} == 1 )) || die "--${NZ_MODE} takes exactly one TARGET"
  [[ -z ${IMAGE_DIR} && -z ${REPORT_DIR} ]] \
    || die "--image-dir and --report-dir do not apply to --${NZ_MODE}"
  (( ! KEEP_MOUNTED )) || die "--keep-mounted does not apply to --${NZ_MODE}"
  # Scan-only settings have no meaning while neutralizing a finished report.
  (( USE_VT )) && die "--vt does not apply to --${NZ_MODE} (it is a scan-time option)"
  (( USE_YARA )) || die "--no-yara does not apply to --${NZ_MODE} (it is a scan-time option)"
  (( UPDATE )) || die "--no-update does not apply to --${NZ_MODE} (it is a scan-time option)"
  [[ -z ${YARA_RULES} ]] || die "--yara-rules does not apply to --${NZ_MODE} (it is a scan-time option)"
  [[ ${YARA_SET} == extended ]] || die "--yara-set does not apply to --${NZ_MODE} (it is a scan-time option)"
  [[ -z ${CLAM_DB} ]] || die "--clam-db does not apply to --${NZ_MODE} (it is a scan-time option)"
fi
if [[ ${SESSION_ACTION} == prepare ]]; then
  (( HARDEN_SESSION )) || die "--prepare-session is the session hardening; --no-session-hardening contradicts it"
fi
(( ! KEEP_METADATA )) || [[ ${NZ_MODE} == export ]] || die "--keep-metadata needs --export"
(( ! ASSUME_YES )) || [[ ${NZ_MODE} == quarantine ]] || die "--yes needs --quarantine"
[[ -z ${YARA_RULES} || -r ${YARA_RULES} ]] || die "Cannot read --yara-rules ${YARA_RULES}"
[[ -z ${CLAM_DB} || -e ${CLAM_DB} ]] || die "No such --clam-db ${CLAM_DB}"
[[ -z ${CLAM_DB} ]] || CLAM_DB=$(readlink -f -- "${CLAM_DB}")
[[ -z ${YARA_RULES} ]] || YARA_RULES=$(readlink -f -- "${YARA_RULES}")
USER_NAME=$(id -un)
USER_GID=$(id -g)
MNT_BASE=/run/scan-untrusted-media.$$
SYSTEMD_VERSION=$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 + 0 }') || SYSTEMD_VERSION=0
[[ ${SYSTEMD_VERSION} =~ ^[0-9]+$ ]] || SYSTEMD_VERSION=0
MOUNTS=()
LOOPS=()
CRYPT_MAPS=()
LVM_ACTIVE=()
RO_DEVS=()
RW_NODES=()
VOLUME_HANDLER=scan_volume
FRESHCLAM_WAS_ACTIVE=0
KEEPALIVE_PID=
CONSOLE_PID=
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
  local p missing=() kver mac_fs=1
  local -a pkgs_fedora=("${PKGS_FEDORA[@]}") pkgs_arch=("${PKGS_ARCH[@]}")
  local -a need=(clamscan yara yarac ddrescue file jq curl unzip sha256sum systemd-run losetup blkid lsblk)
  # --export only mounts and copies; --quarantine needs 7-Zip (both distros'
  # 7zip package provides /usr/bin/7z) and never mounts APFS or HFS+.
  case ${NZ_MODE} in
    export) pkgs_fedora=(apfs-fuse kernel-modules-extra) pkgs_arch=()
            need=(sha256sum systemd-run losetup blkid lsblk find) ;;
    quarantine) pkgs_fedora=("${PKGS_7ZIP_FEDORA[@]}") pkgs_arch=("${PKGS_7ZIP_ARCH[@]}") mac_fs=0
            need=(7z sha256sum blkid lsblk blockdev dd find) ;;
  esac
  kver=$(uname -r)
  case ${DISTRO} in
    fedora)
      for p in "${pkgs_fedora[@]}"; do
        [[ ${p} == kernel-modules-extra || ${p} == apfs-fuse ]] && continue
        rpm -q --whatprovides "${p}" >/dev/null 2>&1 || missing+=("${p}")
      done
      if (( ${#missing[@]} )); then
        log "Installing scanner tools: ${missing[*]}"
        sudo dnf -y install "${missing[@]}" || die "dnf install failed"
      fi
      # apfs-fuse exists only in newer Fedora repos (F43+); a missing package
      # must not abort the whole scan - APFS degrades to a coverage gap.
      if (( mac_fs )) && ! rpm -q --whatprovides apfs-fuse >/dev/null 2>&1; then
        sudo dnf -y install apfs-fuse \
          || warn "apfs-fuse is not installable on this release; APFS volumes will be reported as coverage gaps."
      fi
      # hfsplus.ko lives in kernel-modules-extra and must match the running
      # kernel; after a kernel update that means installing it and rebooting.
      if (( mac_fs )) && ! rpm -q "kernel-modules-extra-${kver}" >/dev/null 2>&1; then
        log "Installing kernel-modules-extra for the running kernel (HFS+ support)"
        sudo dnf -y install "kernel-modules-extra-${kver}" \
          || warn "kernel-modules-extra-${kver} is not installable; HFS+ volumes will not mount until you install kernel-modules-extra and reboot into the matching kernel."
      fi
      ;;
    arch)
      for p in "${pkgs_arch[@]}"; do
        pacman -Q "${p}" >/dev/null 2>&1 || missing+=("${p}")
      done
      if (( ${#missing[@]} )); then
        log "Installing scanner tools: ${missing[*]}"
        sudo pacman -S --needed --noconfirm "${missing[@]}" || die "pacman install failed"
      fi
      (( ! mac_fs )) || command -v apfs-fuse >/dev/null || warn "apfs-fuse is missing (AUR: apfs-fuse-git); APFS volumes will be reported as coverage gaps."
      ;;
    *) warn "Unrecognised distribution; tools must already be installed." ;;
  esac
  for p in "${need[@]}"; do
    command -v "${p}" >/dev/null || die "Required tool missing: ${p}"
  done
  (( ! mac_fs )) || { command -v apfs-fuse >/dev/null && command -v apfsutil >/dev/null; } \
    || warn "apfs-fuse/apfsutil missing: APFS volumes cannot be mounted."
}

cleanup() {
  local i
  set +e
  if (( KEEP_MOUNTED )) && (( ${#MOUNTS[@]} )); then
    log "Volumes left mounted read-only (--keep-mounted):"
    for i in "${MOUNTS[@]}"; do note "${i}"; done
    note "Unmount later with: sudo umount ${MNT_BASE}/*; then: sudo losetup -d ${LOOPS[*]:-<none>}"
    (( ${#LVM_ACTIVE[@]} )) && note "Deactivate LVM: sudo vgchange -an ${LVM_ACTIVE[*]%%|*}"
    (( ${#CRYPT_MAPS[@]} )) && note "Close unlocked volumes: sudo cryptsetup close ${CRYPT_MAPS[*]}"
  else
    for (( i = ${#MOUNTS[@]} - 1; i >= 0; i-- )); do
      sudo umount -- "${MOUNTS[i]}" 2>/dev/null || sudo umount -l -- "${MOUNTS[i]}" 2>/dev/null
      sudo rmdir -- "${MOUNTS[i]}" 2>/dev/null
    done
    # Inner layers first: LVM inside LUKS is the usual Linux full-disk layout.
    for (( i = ${#LVM_ACTIVE[@]} - 1; i >= 0; i-- )); do
      sudo vgchange -an --devices "${LVM_ACTIVE[i]#*|}" -- "${LVM_ACTIVE[i]%%|*}" >/dev/null 2>&1
    done
    for (( i = ${#CRYPT_MAPS[@]} - 1; i >= 0; i-- )); do
      sudo cryptsetup close -- "${CRYPT_MAPS[i]}" 2>/dev/null
    done
    for i in "${LOOPS[@]}"; do sudo losetup -d "${i}" 2>/dev/null; done
    [[ -d ${MNT_BASE} ]] && sudo rmdir -- "${MNT_BASE}" 2>/dev/null
  fi
  # --quarantine interrupted mid-volume: never leave a node writable.
  for i in "${RW_NODES[@]}"; do sudo blockdev --setro "${i}" 2>/dev/null; done
  remove_udev_hold
  # A paused freshclam daemon must not stay down just because the scan ended
  # on an error path (die/INT during prepare_clamav skips its restart).
  (( FRESHCLAM_WAS_ACTIVE )) && sudo systemctl start clamav-freshclam.service 2>/dev/null
  if (( ${#RO_DEVS[@]} )); then
    note "Scanned devices were left read-only for safety; restore with:"
    for i in "${RO_DEVS[@]}"; do note "  sudo blockdev --setrw ${i}"; done
  fi
  [[ -n ${KEEPALIVE_PID} ]] && kill "${KEEPALIVE_PID}" 2>/dev/null
  # Last: close the console so the console.log writer flushes before exit.
  # The poller dies first: its sleep must never inherit the console pipe, or
  # waiting for the writer blocks up to 60 s on every exit.
  [[ -n ${POLLER:-} ]] && { kill "${POLLER}" 2>/dev/null || true; wait "${POLLER}" 2>/dev/null || true; }
  if [[ -n ${CONSOLE_PID} ]]; then
    exec >&- 2>&-
    wait "${CONSOLE_PID}" 2>/dev/null
  fi
}

start_sudo() {
  sudo -v || die "sudo is required for imaging and mounting."
  # One failed refresh (ticket invalidated) must not end caching for good.
  # Detached from the console: its sleep child would otherwise hold the
  # console pipe open and delay every exit by up to 50 s.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n -v >/dev/null 2>&1 || true; sleep 50 >/dev/null 2>&1; done ) \
    >/dev/null 2>&1 &
  KEEPALIVE_PID=$!
}

#--- Session hardening --------------------------------------------------------
# GNOME automounts new media, renders thumbnails (image/video/PDF parsers) and
# lets Tracker index removable devices: all parse untrusted files before any
# scan runs. Turn them off for this user and leave them off; the report dir
# gets a script that restores the previous values.
UDEV_HOLD_RULE=/run/udev/rules.d/61-scan-untrusted-media.rules
UDEV_HOLD_INSTALLED=0

# install_udev_hold: a runtime udev rule that keeps udev's own processing of
# untrusted block devices from touching them: md auto-assembly, the kernel
# btrfs device scan and LVM auto-activation all stop on SYSTEMD_READY=0 (and
# LVM on DM_UDEV_DISABLE_OTHER_RULES_FLAG), before this script ever opens the
# device. Loop devices are covered too: --image-dir attaches hostile images
# through losetup --partscan, which triggers the same udev rules. The rule
# lives in /run (gone at reboot) and is removed by --restore-session, or by
# the scan's cleanup when the scan installed it itself.
install_udev_hold() {
  command -v udevadm >/dev/null || return 0
  if [[ -e ${UDEV_HOLD_RULE} ]]; then
    note "udev hold rule already installed (${UDEV_HOLD_RULE})"
    return 0
  fi
  sudo mkdir -p -- /run/udev/rules.d
  sudo tee -- "${UDEV_HOLD_RULE}" >/dev/null <<'RULE'
# scan-untrusted-media.sh: do not process untrusted block devices on plug or
# revalidation (no md assembly, no btrfs device scan, no LVM auto-activation,
# no desktop mounting). Removed by --restore-session or at scan exit.
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{SYSTEMD_READY}="0", ENV{UDISKS_IGNORE}="1", ENV{DM_UDEV_DISABLE_OTHER_RULES_FLAG}="1"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ENV{SYSTEMD_READY}="0", ENV{DM_UDEV_DISABLE_OTHER_RULES_FLAG}="1"
RULE
  sudo udevadm control --reload 2>/dev/null || true
  UDEV_HOLD_INSTALLED=1
  note "Installed udev hold rule ${UDEV_HOLD_RULE} (untrusted drives and images are not auto-processed)"
}

remove_udev_hold() {
  (( UDEV_HOLD_INSTALLED )) || return 0
  sudo rm -f -- "${UDEV_HOLD_RULE}"
  sudo udevadm control --reload 2>/dev/null || true
  UDEV_HOLD_INSTALLED=0
}

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

# acquire_device <dev>: refuse mounted or in-use devices, set them read-only,
# and image them only with --image-dir. Sets ACQUIRED to the image path or
# the device.
acquire_device() {
  local dev=$1 node mp holder mounted=() dir size avail have serial model name img map bad sum
  while read -r node mp; do
    [[ -n ${mp} ]] && mounted+=("${node} on ${mp}")
  done < <(lsblk -nrpo NAME,MOUNTPOINT -- "${dev}")
  if (( ${#mounted[@]} )); then
    printf '    %s\n' "${mounted[@]}" >&2
    die "${dev} has mounted filesystems. Unmount them first (udisksctl unmount -b <partition>), then rerun."
  fi
  swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "${dev}" && die "${dev} is in use as swap"
  # Anything holding a partition (an assembled md array, a device-mapper
  # layer, LVM) means udev or the kernel already processed this media: refuse
  # instead of scanning under and around whatever was auto-assembled.
  while read -r node; do
    for holder in /sys/class/block/${node##*/}/holders/*; do
      [[ -e ${holder} ]] || continue
      die "${dev} is in use: ${node} is held by ${holder##*/} (md/LVM/dm; detach it first)"
    done
  done < <(lsblk -nrpo NAME -- "${dev}")
  # lsblk lists the disk itself first, then its partitions. Accumulate across
  # targets so the read-only restore advice at exit names every device.
  while read -r node; do
    [[ -n ${node} ]] || continue
    local seen=0
    for mp in "${RO_DEVS[@]}"; do [[ ${mp} == "${node}" ]] && seen=1; done
    (( seen )) && continue
    sudo blockdev --setro "${node}" || die "blockdev --setro ${node} failed"
    RO_DEVS+=("${node}")
  done < <(lsblk -nrpo NAME -- "${dev}")
  # Model and serial come from the device firmware: trim them without xargs
  # (a quote in the string would abort the run) and strip control characters.
  model=$(lsblk -dno MODEL -- "${dev}")
  serial=$(lsblk -dno SERIAL -- "${dev}")
  model=${model#"${model%%[![:space:]]*}"}; model=${model%"${model##*[![:space:]]}"}
  serial=${serial#"${serial%%[![:space:]]*}"}; serial=${serial%"${serial##*[![:space:]]}"}
  model=${model//[[:cntrl:]]/}; serial=${serial//[[:cntrl:]]/}
  model=${model//$'\t'/ }; serial=${serial//$'\t'/ }
  size=$(sudo blockdev --getsize64 "${dev}")
  if [[ ${IMAGE_MODE} == direct ]]; then
    printf '%s\t%s\t%s\t%s\t(scanned in place)\t-\t-\n' "${dev}" "${model:--}" "${serial:--}" \
      "${size}" >>"${REPORT_DIR}/acquisition.tsv"
    ACQUIRED=${dev}
    return 0
  fi
  # ddrescue runs as root writing here; a group/world-writable directory
  # would let another local user plant a symlink for root to truncate.
  dir=$(readlink -f -- "${IMAGE_DIR}")
  (( 8#$(stat -c %a -- "${dir}") & 8#077 )) \
    && die "Image dir ${dir} is group- or world-writable; refusing to write images as root into it."
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
  local node=$1 tag=$2 line v mp vols=() listing fuseopts
  local -A enc=() vname=()
  local -a list_cmd=(sudo) fuse_cmd=(sudo)
  command -v apfs-fuse >/dev/null || { gap "${tag}" mount "APFS container not mounted: apfs-fuse missing"; return 0; }
  # apfsutil and apfs-fuse are reverse-engineered parsers of hostile
  # metadata: they must not run as root. Grant this user read access to the
  # (already read-only) node and run them unprivileged; without setfacl or
  # with an inaccessible /dev/fuse, fall back to sudo and say so once.
  if sudo setfacl -m "u:${USER_NAME}:r" -- "${node}" 2>/dev/null; then
    list_cmd=()
    if [[ -w /dev/fuse ]]; then
      fuse_cmd=()
    elif [[ -z ${APFS_ROOT_WARNED:-} ]]; then
      warn "/dev/fuse is not writable by this user; apfs-fuse falls back to running as root."
      APFS_ROOT_WARNED=1
    fi
  elif [[ -z ${APFS_ROOT_WARNED:-} ]]; then
    warn "setfacl failed on ${node}; APFS metadata is parsed as root (install the acl package to avoid it)."
    APFS_ROOT_WARNED=1
  fi
  listing=$("${list_cmd[@]}" apfsutil "${node}" 2>&1) || true
  printf '%s\n' "${listing}" >"${REPORT_DIR}/apfs-${tag}.txt"
  while IFS= read -r line; do
    if [[ ${line} =~ ^[[:space:]]*Volume[[:space:]]+([0-9]+) ]]; then
      v=${BASH_REMATCH[1]}; vols+=("${v}")
    elif [[ -n ${v:-} && ${line} =~ FileVault:[[:space:]]*Yes ]]; then
      enc[${v}]=1
    elif [[ -n ${v:-} && ${line} =~ Name:[[:space:]]*(.*)$ ]]; then
      # The name comes from the media; keep control characters and bidi
      # overrides out of the terminal and the report.
      tsv_esc "${BASH_REMATCH[1]}"
      vname[${v}]=${REPLY}
    fi
  done <<<"${listing}"
  (( ${#vols[@]} )) || vols=(0)
  for v in "${vols[@]}"; do
    mp=${MNT_BASE}/${tag}-v${v}
    if [[ -n ${enc[${v}]:-} ]]; then
      log "APFS volume ${v} '${vname[${v}]:-}' is encrypted: apfs-fuse will ask for its password or recovery key."
    fi
    if (( ${#fuse_cmd[@]} )); then
      # Root mount: the sandboxed worker runs as this user, so the mount
      # must be visible to it (allow_other needs user_allow_other in
      # /etc/fuse.conf, which root mounts bypass).
      sudo mkdir -p -- "${mp}"
      fuseopts="allow_other,nosuid,nodev,noexec,uid=${UID},gid=${USER_GID}"
    else
      # User mount: only the mounting user may access it, which is exactly
      # the worker's uid; fusermount requires the mountpoint be ours.
      sudo install -d -o "${USER_NAME}" -g "${USER_GID}" -m 0755 -- "${mp}"
      fuseopts="nosuid,nodev,noexec,uid=${UID},gid=${USER_GID}"
    fi
    if "${fuse_cmd[@]}" apfs-fuse -o "${fuseopts},vol=${v}" "${node}" "${mp}" </dev/tty; then
      MOUNTS+=("${mp}")
      "${VOLUME_HANDLER}" "${mp}" apfs "${tag}-v${v}" "${node}" "${v}"
    else
      sudo rmdir -- "${mp}" 2>/dev/null
      gap "${tag}-v${v}" mount "APFS volume ${v} '${vname[${v}]:-}' not mounted${enc[${v}]:+ (encrypted, not unlocked)}"
    fi
  done
}

# open_crypt <node> <fstype> <tag>: offer to unlock a LUKS or BitLocker
# volume read-only (passphrase or BitLocker recovery key from the terminal)
# and scan what is inside; declining or failing leaves a coverage gap.
open_crypt() {
  local node=$1 fstype=$2 tag=$3 type name answer what
  case ${fstype} in
    crypto_LUKS) type=luks what='LUKS passphrase' ;;
    *) type=bitlk what='BitLocker password or 48-digit recovery key' ;;
  esac
  if ! { : </dev/tty; } 2>/dev/null; then
    gap "${tag}" mount "${fstype} volume not opened (no terminal to ask for its passphrase)"
    return 0
  fi
  # The prompt goes to the terminal directly: stderr here is the line-buffered
  # console logger, and a read -p prompt would stay invisible until after the
  # answer (the scan would look hung).
  printf '==> %s is an encrypted %s volume. Unlock it read-only to scan its contents? [y/N] ' \
    "${node}" "${fstype}" >/dev/tty
  local answer=
  IFS= read -r answer </dev/tty || answer=
  if [[ ${answer} != [yY]* ]]; then
    gap "${tag}" mount "${fstype} volume not opened (declined)"
    return 0
  fi
  name=scan-utm-$$-${#CRYPT_MAPS[@]}
  log "Enter the ${what} for ${node}"
  if sudo cryptsetup open --readonly --type "${type}" --tries 3 -- "${node}" "${name}" </dev/tty; then
    CRYPT_MAPS+=("${name}")
    scan_block "/dev/mapper/${name}" "${tag}"
  else
    gap "${tag}" mount "${fstype} volume not opened (unlock failed)"
  fi
}

# open_lvm <node> <tag>: activate the volume group on this physical volume
# with each eligible logical volume read-only and scan it. --devices confines
# LVM to this node, so the host's own devices (and its devices file) are not
# involved. A VG whose name the host already uses is refused: renaming it
# (vgimportclone) would write to the untrusted media. Only linear and striped
# segment types are activated: thin/cache/raid/vdo/integrity LVs are parsed
# by extra kernel code the filesystem allowlist never agreed to expose.
open_lvm() {
  local node=$1 tag=$2 vg lv name segtypes clash=0 n
  local -a lv_names=() segs=()
  local -A lv_segs=() lv_seen=()
  vg=$(sudo pvs --noheadings -o vg_name --devices "${node}" -- "${node}" 2>/dev/null) || vg=
  vg=${vg//[[:space:]]/}
  if [[ -z ${vg} ]]; then
    gap "${tag}" mount "LVM physical volume without a readable volume group"
    return 0
  fi
  # A VG name the host already uses (in its own devices) means activating the
  # untrusted one would clash; renaming it would write to the media.
  while IFS= read -r n; do
    n=${n//[[:space:]]/}   # vgs pads its columns
    [[ ${n} == "${vg}" ]] && clash=1
  done < <(sudo vgs --noheadings -o vg_name 2>/dev/null || true)
  if (( clash )); then
    gap "${tag}" mount "LVM volume group '${vg}' has the same name as one on this host; not activated"
    return 0
  fi
  # Segment types per LV, read from the metadata before anything is
  # activated: only linear and striped LVs are activated at all, one at a
  # time. Activating the whole VG would set up thin/cache/raid/vdo/integrity
  # targets too, exposing their kernel parsers to hostile metadata even if
  # the LV is never scanned. lvs prints one row per segment.
  while read -r name segtypes; do
    [[ -n ${name} ]] || continue
    if [[ -z ${lv_seen[${name}]+x} ]]; then lv_seen[${name}]=1; lv_names+=("${name}"); fi
    lv_segs[${name}]+=" ${segtypes}"
  done < <(sudo lvs --noheadings -o lv_name,segtype --devices "${node}" -- "${vg}" 2>/dev/null || true)
  if (( ${#lv_names[@]} == 0 )); then
    gap "${tag}" mount "LVM volume group '${vg}' lists no logical volumes (or spans other disks)"
    return 0
  fi
  LVM_ACTIVE+=("${vg}|${node}")
  for name in "${lv_names[@]}"; do
    local bad_seg=
    # shellcheck disable=SC2206 # the segment types are a space-joined list
    segs=(${lv_segs[${name}]})
    for segtypes in "${segs[@]}"; do
      case ${segtypes} in linear|striped) ;; *) bad_seg=${segtypes} ;; esac
    done
    if [[ -n ${bad_seg} ]]; then
      gap "${tag}-${name}" mount "LVM logical volume '${vg}/${name}' uses segment type '${bad_seg}'; not activated (its kernel target is not exposed to hostile metadata)"
      continue
    fi
    lv=/dev/${vg}/${name}
    if ! sudo lvchange -ay --devices "${node}" \
           --config 'activation { read_only_volume_list = [ "*" ] }' -- "${vg}/${name}" >/dev/null 2>"${REPORT_DIR}/mount.err" \
       || [[ ! -b ${lv} ]]; then
      gap "${tag}-${name}" mount "LVM logical volume '${vg}/${name}' did not activate (spans other disks, activation skip, or error): $(tr '\n' ' ' <"${REPORT_DIR}/mount.err")"
      continue
    fi
    scan_block "${lv}" "${tag}-${name}"
  done
}

# mount_and_scan <node> <fstype> <tag>
mount_and_scan() {
  local node=$1 fstype=$2 tag=$3 mp=${MNT_BASE}/$3
  local base="ro,nosuid,nodev,noexec" own="uid=${UID},gid=${USER_GID}"
  case ${fstype} in
    apfs) mount_apfs "${node}" "${tag}"; return 0 ;;
    swap) note "${tag}: swap, skipped"; return 0 ;;
    crypto_LUKS|BitLocker) open_crypt "${node}" "${fstype}" "${tag}"; return 0 ;;
    LVM2_member) open_lvm "${node}" "${tag}"; return 0 ;;
    linux_raid_member)
      gap "${tag}" mount "Linux md RAID member not assembled (do it by hand with mdadm --assemble --readonly, then scan the md device)"; return 0 ;;
    zfs_member)
      gap "${tag}" mount "ZFS pool member not imported (import by hand: zpool import -o readonly=on -N -R <dir>)"; return 0 ;;
    refs|ReFS)
      gap "${tag}" mount "Windows ReFS has no Linux driver; scan it from Windows or a Windows VM"; return 0 ;;
  esac
  # Only these drivers are exposed to hostile metadata. Mounting whatever
  # blkid names would make the kernel load obscure, rarely audited drivers
  # (classic HFS, JFS, ReiserFS, UFS, minix, ...): exactly the attack surface
  # a crafted drive aims at.
  case ${fstype} in
    vfat|exfat|ntfs|hfsplus|ext2|ext3|ext4|xfs|btrfs|f2fs|iso9660|udf|squashfs|erofs) ;;
    *) gap "${tag}" mount "${fstype:-unknown} filesystem not mounted: its driver is not on the allowlist for hostile media"; return 0 ;;
  esac
  case ${fstype} in
    vfat|exfat) try_mount "${node}" "${mp}" "${fstype}" "${base},${own},fmask=0333,dmask=0222" ;;
    # ntfs3 only: the ntfs-3g FUSE fallback is a userspace parser with a
    # history of heap overflows on crafted filesystems, and try_mount's sudo
    # would run it as root. A failed ntfs3 mount is a coverage gap instead.
    ntfs) try_mount "${node}" "${mp}" ntfs3 "${base},${own}" ;;
    hfsplus)
      sudo modprobe "${fstype}" 2>/dev/null \
        || { gap "${tag}" mount "${fstype} kernel module unavailable (install kernel-modules-extra for $(uname -r), or reboot into the kernel it matches)"; return 0; }
      try_mount "${node}" "${mp}" "${fstype}" "${base},${own}" ;;
    ext2|ext3|ext4) try_mount "${node}" "${mp}" "${fstype}" "${base},noload" ;;
    xfs)   try_mount "${node}" "${mp}" xfs "${base},norecovery" ;;
    # subvolid=5 is the volume's real top level: mounting the default
    # subvolume would let the media choose which subvolume the scan sees
    # (an empty one), hiding the rest below a different st_dev.
    btrfs) try_mount "${node}" "${mp}" btrfs "${base},rescue=nologreplay,subvolid=5" ;;
    f2fs)  try_mount "${node}" "${mp}" f2fs "${base},norecovery" ;;
    iso9660|udf) try_mount "${node}" "${mp}" "${fstype}" "${base},${own}" ;;
    *) try_mount "${node}" "${mp}" "${fstype}" "${base}" ;;   # squashfs, erofs
  esac || { gap "${tag}" mount "${fstype} mount failed: $(tr '\n' ' ' <"${REPORT_DIR}/mount.err")"; return 0; }
  "${VOLUME_HANDLER}" "${mp}" "${fstype}" "${tag}" "${node}"
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
# volume_identity <node|-> [APFS volume index]: the volumes.tsv identity
# columns: source (the partition node, or the backing image file of a loop
# device), filesystem UUID, APFS volume index, partition number (0 for a
# filesystem on the whole device). --export/--quarantine find the volume
# again by them. Directory targets have none.
volume_identity() {
  local node=$1 av=${2:--} name src uuid part=0
  if [[ ${node} == - ]]; then printf -- '-\t-\t-\t-'; return 0; fi
  name=${node##*/}
  [[ -r /sys/class/block/${name}/partition ]] && part=$(<"/sys/class/block/${name}/partition")
  src=${node}
  if [[ ${name} =~ ^(loop[0-9]+) && -r /sys/block/${BASH_REMATCH[1]}/loop/backing_file ]]; then
    src=$(<"/sys/block/${BASH_REMATCH[1]}/loop/backing_file")
  fi
  uuid=$(sudo blkid -p -s UUID -o value -- "${node}" 2>/dev/null) || uuid=
  [[ ${uuid} =~ ^[A-Za-z0-9._-]+$ ]] || uuid=-
  tsv_esc "${src}"
  printf '%s\t%s\t%s\t%s' "${REPLY}" "${uuid}" "${av}" "${part}"
}

# run_sandboxed <unit> <umask> <read-write paths> <command>...: run a worker
# in a transient systemd sandbox as the invoking user. CAP_DAC_READ_SEARCH lets
# it read files owned by the Mac account (uid 501, mode 0700) without root;
# no network, and the host is read-only except <read-write paths>
# (space-separated), which must be the smallest set that works - the worker
# parses hostile content, so it must never be able to write the report the
# host reads back, reach a Unix socket (the session D-Bus would run anything
# it asks for) or ptrace this script (same uid, same capabilities). The
# worker must be "bash <script>", never the script itself: under SELinux,
# systemd (init_t) may not execute a file labeled user_home_t (a checkout in
# ~), which fails every run with 203/EXEC. bash is bin_t and transitions to
# unconfined_service_t, which may read the script.
run_sandboxed() {
  local unit=$1 umask=$2 rw=$3
  # Secrets a CAP_DAC_READ_SEARCH worker could otherwise read straight
  # through ProtectSystem/ProtectHome=read-only and copy into its output.
  # The "-" prefix: a path that does not exist on this host is skipped
  # instead of failing the unit (every scan would die with 226/NAMESPACE).
  local -a hide=(-/root -/etc/shadow -/etc/shadow- -/etc/gshadow -/etc/gshadow- -/etc/ssh
                 "-${HOME}/.ssh" "-${HOME}/.gnupg" "-${VT_KEY_FILE%/*}")
  local -a pids=()
  shift 3
  # systemd 257+: the worker gets its own PID namespace and sees no host
  # process at all. Without it, a compromised worker (same uid, more
  # capabilities than this script) could write this script's memory through
  # /proc/<pid>/mem, which needs no ptrace syscall.
  (( SYSTEMD_VERSION >= 257 )) && pids=(-p PrivatePIDs=yes)
  sudo systemd-run --quiet --wait --pipe --collect --expand-environment=no \
    --unit="${unit}" \
    -p User="${USER_NAME}" -p WorkingDirectory=/ -p UMask="${umask}" \
    -p AmbientCapabilities=CAP_DAC_READ_SEARCH -p CapabilityBoundingSet=CAP_DAC_READ_SEARCH \
    -p NoNewPrivileges=yes -p PrivateNetwork=yes -p PrivateTmp=yes -p PrivateDevices=yes \
    -p ProtectSystem=strict -p ProtectHome=read-only -p ReadWritePaths="${rw}" \
    -p ProtectKernelTunables=yes -p ProtectKernelModules=yes -p ProtectKernelLogs=yes \
    -p ProtectControlGroups=yes -p ProtectClock=yes -p ProtectHostname=yes \
    -p ProtectProc=invisible -p ProcSubset=pid \
    -p 'RestrictAddressFamilies=~af_unix af_inet af_inet6 af_netlink af_packet af_key af_alg af_bluetooth af_vsock af_xdp af_rds af_tipc af_iucv af_can af_mctp af_ax25 af_ipx af_appletalk af_x25 af_atmpvc af_atmsvc af_irda af_pppox af_llc af_ib af_mpls af_phonet af_ieee802154 af_caif af_nfc af_kcm af_qipcrtr af_smc af_netrom af_bridge af_rose af_netbeui af_econet af_ash af_sna af_wanpipe' \
    -p RestrictNamespaces=yes -p RestrictSUIDSGID=yes \
    -p RestrictRealtime=yes -p LockPersonality=yes -p SystemCallArchitectures=native \
    -p SystemCallFilter=@system-service "${pids[@]}" \
    -p InaccessiblePaths="${hide[*]}" \
    -p Nice=5 -p IOSchedulingClass=best-effort -p IOSchedulingPriority=6 \
    -p Environment=LC_CTYPE=C.UTF-8 \
    -- "$@" </dev/null
}

# worker_output_tampered <dir>: remove symlinks and special files a worker
# left in its output directory and print how many there were. The host only
# ever reads regular files from there; a planted symlink (to ~/.ssh/id_*, say)
# would make the host itself copy a secret into the report.
worker_output_tampered() {
  local f n=0
  while IFS= read -r -d '' f; do
    rm -f -- "${f}"
    n=$(( n + 1 ))
  done < <(find "$1" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print0 2>/dev/null)
  printf '%s' "${n}"
}

# start_poller <dir> <label>: print the worker's progress file (see
# scan_progress) once a minute while a sandbox runs; stop_poller ends it.
# The subshell exits when the main script dies (background subshells ignore
# SIGINT, so a Ctrl-C otherwise leaves it looping forever), and its sleep is
# detached from stdout so it cannot hold the console pipe.
start_poller() {
  local dir=$1 label=$2
  ( last=
    while kill -0 "$$" 2>/dev/null; do
      sleep 60 >/dev/null 2>&1 || exit
      kill -0 "$$" 2>/dev/null || exit
      [[ -r ${dir}/progress ]] || continue
      cur=$(<"${dir}/progress")
      [[ ${cur} == "${last}" ]] || note "[${label} $(date +%H:%M)] ${cur}"
      last=${cur}
    done ) &
  POLLER=$!
}
stop_poller() {
  kill "${POLLER}" 2>/dev/null || true
  wait "${POLLER}" 2>/dev/null || true
}

# scan_volume <root> <fstype> <tag> [<node> [<APFS volume index>]]: record the
# volume (with its identity, see volume_identity) and run the scan worker on
# it in the sandbox (see run_sandboxed).
scan_volume() {
  local root=$1 fstype=$2 tag=$3 node=${4:--} apfs_vol=${5:--} out rc=0 walk tampered
  out=${REPORT_DIR}/volumes/${tag}
  mkdir -p -- "${out}"
  tsv_esc "${root}"
  printf '%s\t%s\t%s\t%s\n' "${tag}" "${fstype}" "${REPLY}" "$(volume_identity "${node}" "${apfs_vol}")" \
    >>"${REPORT_DIR}/volumes.tsv"
  # btrfs subvolumes of this tool's own mount are media content: cross them.
  # A caller-supplied directory keeps foreign nested mounts out (gaps).
  if [[ ${node} == - ]]; then walk=dir
  elif [[ ${fstype} == btrfs ]]; then walk=cross
  else walk=strict; fi
  UNIT_SEQ=$(( UNIT_SEQ + 1 ))
  log "Scanning ${tag} (${fstype}) at ${root}"
  start_poller "${out}" "${tag}"
  # The worker's only writable path is its own volumes/<tag>/ directory: it
  # parses hostile content, so it must not be able to replace report files
  # the host reads (summary.txt, quarantine.tsv, findings.tsv, ...) with
  # planted symlinks or rewritten rows.
  run_sandboxed "scan-utm-${EPOCHSECONDS}-$$-${UNIT_SEQ}" 0077 "${out}" \
    "${BASH}" "${SCRIPT_PATH}" --internal-scan "${root}" "${out}" "${fstype}" "${COMPILED_YARA}" "${CLAM_DB:--}" "${walk}" \
    || rc=$?
  stop_poller
  (( rc == 0 )) || gap "${tag}" scan "sandboxed scan exited ${rc}; results for this volume are incomplete"
  tampered=$(worker_output_tampered "${out}")
  (( tampered == 0 )) \
    || gap "${tag}" scan "the scan worker left ${tampered} symlink(s)/special file(s) in its output (removed): treat this volume's results as tampered"
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

count_class() { awk -F'\t' -v c="$1" '$1 == c { k[$4 "\t" $6] = 1 } END { print length(k) }' "${REPORT_DIR}/findings.tsv"; }

write_report() {
  local s=${REPORT_DIR}/summary.txt definite likely review gaps files=0 bytes=0 suspects=0 d k v tag
  local vt_known=0 vt_mal=0 vt_unknown=0 vt_unk_exec=0 zero=0 os_meta=0 mismatches=0
  definite=$(count_class DEFINITE); likely=$(count_class LIKELY); review=$(count_class REVIEW)
  gaps=$(wc -l <"${REPORT_DIR}/gaps.tsv")
  for d in "${REPORT_DIR}"/volumes/*/counts; do
    [[ -f ${d} ]] || continue
    # counts is written by the sandboxed worker. A compromised worker could
    # put anything in it; only plain non-negative integers ever reach shell
    # arithmetic ($(( files + v )) would otherwise run hostile code as this
    # user, and the sudo keepalive would hand it root). Anything else counts
    # as zero and is flagged.
    while IFS='=' read -r k v; do
      if [[ ! ${v} =~ ^[0-9]+$ ]]; then
        tag=${d%/counts}; tag=${tag##*/}
        printf -- '%s\tsanitization\tworker wrote an unparsable "%s" count (ignored; treat this volume as unreliable)\t-\n' \
          "${tag}" "$(tsv_escape "${k}")" >>"${REPORT_DIR}/gaps.tsv"
        gaps=$(( gaps + 1 ))
        continue
      fi
      case ${k} in
        files) files=$(( files + v )) ;; bytes) bytes=$(( bytes + v )) ;;
        suspects) suspects=$(( suspects + v )) ;; zero_len_hfsplus) zero=$(( zero + v )) ;;
        os_metadata) os_meta=$(( os_meta + v )) ;; mismatches) mismatches=$(( mismatches + v )) ;;
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
    printf 'Volumes scanned (tag, filesystem, mountpoint, source, filesystem UUID):\n'
    cut -f1-5 "${REPORT_DIR}/volumes.tsv" 2>/dev/null | sed 's/^/  /' || echo '  none'
    printf '\nFiles: %s (%s); executable/auto-run items for review: %s\n' "${files}" \
      "$(human_bytes "${bytes}")" "${suspects}"
    printf 'Content not matching its extension: %s; OS metadata (AppleDouble ._*, Spotlight,\n' "${mismatches}"
    printf 'Recycle Bin, ...; scanned, kept out of the name inventory): %s\n\n' "${os_meta}"
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
    printf '\nReport files: summary.txt, console.log, findings.tsv, gaps.tsv, volumes/<tag>/{files,suspect,findings,gaps}.tsv,\n'
    printf 'bundles.txt, clamscan.log, yara.log%s\n' "$( (( USE_VT )) && echo ', virustotal.tsv')"
  } >"${s}"
  echo
  cat -- "${s}"
  echo
  log "Report: ${REPORT_DIR}"
  (( definite + likely == 0 ))
}

#--- Neutralizing reviewed threats: --export and --quarantine -----------------
# Both modes start from a finished report and its reviewed quarantine.tsv.
# --export never writes to the untrusted media: it mounts it read-only the
# way a scan does and copies what is wanted out through the sandbox.
# --quarantine changes the media itself and is the riskier of the two.
PKGS_7ZIP_FEDORA=(7zip)
PKGS_7ZIP_ARCH=(7zip)
NZ_TAG=
NZ_WHY=
NZ_DEST_DEV=
POLLER=
declare -gA Q_FOUND=() NZ_DONE=()

# nz_check_report: validate REPORT_DIR (a finished report from this version,
# with a quarantine.tsv the user has reviewed) and load the selection.
nz_check_report() {
  local d
  [[ -d ${NZ_REPORT} ]] || die "No such report directory: ${NZ_REPORT}"
  d=$(readlink -f -- "${NZ_REPORT}")
  case ${d} in
    /tmp|/tmp/*|/var/tmp|/var/tmp/*)
      die "Report dir must not be under /tmp or /var/tmp (PrivateTmp hides it from the sandbox)." ;;
  esac
  [[ ${d} != *[[:space:]]* ]] || die "Report dir must not contain whitespace (systemd sandbox path)"
  [[ -f ${d}/volumes.tsv && -f ${d}/findings.tsv ]] || die "${d} is not a finished scan report (no volumes.tsv/findings.tsv)"
  awk -F'\t' 'NF < 7 { bad = 1 } END { exit bad }' "${d}/volumes.tsv" \
    || die "${d}/volumes.tsv has no volume identity columns (report from an older version); rescan the media first."
  if [[ ! -f ${d}/quarantine.tsv ]]; then
    write_quarantine_template "${d}"
    die "Created ${d}/quarantine.tsv from findings.tsv. Review it (only active lines are acted on), then rerun."
  fi
  load_quarantine_selection "${d}/quarantine.tsv" || die "Fix ${d}/quarantine.tsv first."
  NZ_REPORT=${d}
}

# nz_begin <mode>: the run's log, a private work dir that stands in for
# REPORT_DIR (mount errors, gaps and APFS listings of the shared mount helpers
# land there, never in the original report), session hardening, tools, sudo.
nz_begin() {
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  NZ_LOG=${NZ_REPORT}/$1-${ts}.log
  REPORT_DIR=${NZ_REPORT}/$1-${ts}.work
  mkdir -m 0700 -- "${REPORT_DIR}"
  : >"${REPORT_DIR}/gaps-global.tsv"
  printf '# %s %s, report %s, target %s\n# status\treason\tvolume_tag\tsha256\trelpath\n' \
    "$1" "$(date -R)" "${NZ_REPORT}" "${TARGETS[0]}" >"${NZ_LOG}"
  (( HARDEN_SESSION )) && harden_session "${REPORT_DIR}/restore-session-settings.sh"
  install_tools
  start_sudo
  install_udev_hold
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  sudo mkdir -p -m 0755 -- "${MNT_BASE}"
}

# nz_log_gaps: volumes the mount helpers could not open become error lines.
nz_log_gaps() {
  local vtag src reason
  while IFS=$'\t' read -r vtag src reason _; do
    nz_record error "volume not opened (${src}): ${reason}" "${vtag}" - -
  done <"${REPORT_DIR}/gaps-global.tsv"
}

# nz_volume_tag <node> <fstype> [APFS volume]: set NZ_TAG to the report tag
# of a volume found on the target now, or empty with the reason in NZ_WHY.
nz_volume_tag() {
  local src uuid av part
  IFS=$'\t' read -r src uuid av part <<<"$(volume_identity "$1" "${3:--}")"
  NZ_WHY=
  NZ_TAG=$(match_volume_tag "${NZ_REPORT}/volumes.tsv" "$2" "${uuid}" "${part}" "${av}" 2>"${REPORT_DIR}/match.err") \
    || { NZ_TAG=; NZ_WHY="$(<"${REPORT_DIR}/match.err") (source ${src})"; }
}

# export_volume <mountpoint> <fstype> <probe tag> <node|-> [APFS volume]: the
# VOLUME_HANDLER in --export mode. Maps the mounted volume to its report tag
# and runs export_tree on it in the sandbox (see run_sandboxed): the invoking
# user with CAP_DAC_READ_SEARCH, no network, writing only DEST and its own
# per-volume work directory (never the report itself: the report is what the
# host reads back). The worker's log lines are collected from the work dir
# afterwards and appended to the run log.
export_volume() {
  local mp=$1 fstype=$2 probe=$3 node=${4:--} av=${5:--} tag files out work rc=0 walk tampered
  NZ_WHY=
  if [[ ${node} == - ]]; then
    # volumes.tsv stores the directory path in its escaped form (see tsv_esc);
    # compare the live path escaped the same way.
    tsv_esc "${mp}"
    tag=$(awk -F'\t' -v m="${REPLY}" 'NF >= 7 && $4 == "-" && $3 == m { print $1; exit }' "${NZ_REPORT}/volumes.tsv")
    [[ -n ${tag} ]] || NZ_WHY="no scanned directory ${mp} in volumes.tsv"
  else
    nz_volume_tag "${node}" "${fstype}" "${av}"
    tag=${NZ_TAG}
  fi
  if [[ -z ${tag} ]]; then
    warn "${probe} (${node}, ${fstype}) is not exported: ${NZ_WHY:-no matching scanned volume}"
    nz_record error "volume not exported: ${NZ_WHY:-no matching scanned volume}" "${probe}" - -
    return 0
  fi
  if [[ -n ${NZ_DONE[${tag}]+x} ]]; then
    warn "${probe} maps to ${tag} again; not exported twice"
    nz_record error "a second volume on the target maps to this report volume; not exported" "${tag}" - -
    return 0
  fi
  NZ_DONE[${tag}]=1
  files=${NZ_REPORT}/volumes/${tag}/files.tsv
  if [[ ! -f ${files} ]]; then
    nz_record error 'no files.tsv for this volume (its scan did not finish); nothing copied' "${tag}" - -
    return 0
  fi
  [[ $(stat -c %d -- "${mp}") != "${NZ_DEST_DEV}" ]] || die "DEST ${NZ_DEST} is on the untrusted volume ${tag}"
  out=${NZ_DEST}/${tag} work=${REPORT_DIR}/${tag}
  mkdir -m 0755 -- "${out}"
  mkdir -m 0700 -- "${work}"
  # Match the scan's walk: btrfs subvolumes of this tool's own mount are
  # crossed; everything else stays within the filesystem.
  if [[ ${node} != - && ${fstype} == btrfs ]]; then walk=cross; else walk=strict; fi
  UNIT_SEQ=$(( UNIT_SEQ + 1 ))
  log "Exporting ${tag} (${fstype}) from ${mp} -> ${out}"
  start_poller "${work}" "export ${tag}"
  : >"${work}/export.log"
  run_sandboxed "export-utm-${EPOCHSECONDS}-$$-${UNIT_SEQ}" 0022 "${NZ_DEST} ${work}" \
    "${BASH}" "${SCRIPT_PATH}" --internal-export "${mp}" "${out}" "${files}" \
    "${NZ_REPORT}/quarantine.tsv" "${tag}" "${work}/export.log" "${KEEP_METADATA}" "${work}" "${walk}" || rc=$?
  stop_poller
  tampered=$(worker_output_tampered "${work}")
  (( tampered == 0 )) \
    || nz_record error "the export worker left ${tampered} symlink(s)/special file(s) in its work dir (removed); treat this volume's export as tampered" "${tag}" - -
  # The worker could not append to the run log itself (no write access to the
  # report); splice its lines in now, in order.
  cat -- "${work}/export.log" >>"${NZ_LOG}" 2>/dev/null || true
  if (( rc )); then
    warn "${tag}: sandboxed export exited ${rc}; this volume is incomplete"
    nz_record error "sandboxed export exited ${rc}; this volume is incomplete" "${tag}" - -
  fi
  [[ -r ${work}/progress ]] && note "${tag}: $(<"${work}/progress")"
  return 0
}

# nz_check_selection_mapped: every active quarantine.tsv line must name a file
# of the scan inventory (same volume, path and SHA-256). A line that does not
# map - a detection whose scanner output could not be tied to a file - would
# leave nothing out, and the file it meant could be copied: refuse up front.
nz_check_selection_mapped() {
  local key tag rel want files
  local -a bad=()
  for key in "${Q_KEYS[@]}"; do
    tag=${key%%$'\t'*} rel=${key#*$'\t'} want=${Q_REL[${key}]}
    files=${NZ_REPORT}/volumes/${tag}/files.tsv
    if [[ ${want} == - ]]; then
      bad+=("${tag}  ${rel}  (no SHA-256: the detection did not map to a scanned file)")
    elif [[ ! -f ${files} ]] || ! awk -F'\t' -v r="${rel}" -v s="${want}" \
           '$6 == r && $1 == s { f = 1; exit } END { exit !f }' "${files}"; then
      bad+=("${tag}  ${rel}  (not in the scan inventory with that SHA-256)")
    fi
  done
  (( ${#bad[@]} == 0 )) && return 0
  printf '    %s\n' "${bad[@]}" >&2
  die "These active quarantine.tsv lines do not map to a scanned file, so --export could not leave them out. Find the real file in volumes/<tag>/files.tsv and fix the line (or comment it out deliberately), then rerun."
}

export_main() {
  local target=${TARGETS[0]} free need
  nz_check_report
  NZ_DEST=$(check_export_dest "${NZ_DEST}") || die "Choose a new or empty DEST directory."
  if [[ -d ${target} ]]; then
    target=$(readlink -f -- "${target}")
    [[ ${NZ_DEST} != "${target}" && ${NZ_DEST} != "${target}"/* && ${target} != "${NZ_DEST}"/* ]] \
      || die "DEST and TARGET must not contain each other"
  fi
  mkdir -p -- "${NZ_DEST}"
  chmod 0755 -- "${NZ_DEST}"
  NZ_DEST_DEV=$(stat -c %d -- "${NZ_DEST}")
  if [[ -d ${target} && $(stat -c %d -- "${target}") == "${NZ_DEST_DEV}" ]]; then
    die "DEST ${NZ_DEST} is on the same filesystem as TARGET ${target}"
  fi
  need=$(awk -F'\t' '{ s += $2 } END { printf "%.0f", s }' "${NZ_REPORT}"/volumes/*/files.tsv 2>/dev/null) || need=0
  free=$(df -B1 --output=avail -- "${NZ_DEST}" | tail -n 1)
  (( free >= ${need:-0} )) \
    || warn "DEST has $(human_bytes "${free}") free; the scanned volumes hold $(human_bytes "${need}")."
  nz_check_selection_mapped
  nz_begin export
  log "Exporting ${target} -> ${NZ_DEST}"
  note "${#Q_KEYS[@]} file(s) selected in quarantine.tsv (and any file with the same SHA-256) are left out."
  (( KEEP_METADATA )) || note "OS metadata clutter (._*, .DS_Store, .Spotlight-V100, ...) is left out (--keep-metadata keeps it)."
  VOLUME_HANDLER=export_volume
  if [[ -b ${target} ]]; then
    IMAGE_MODE=direct
    acquire_device "${target}"
    scan_block "${ACQUIRED}" target
  elif [[ -f ${target} ]]; then
    attach_image "$(readlink -f -- "${target}")"
    scan_block "${ATTACHED}" target
  else
    export_volume "${target}" "$(findmnt -no FSTYPE -T "${target}" 2>/dev/null || echo unknown)" dir -
  fi
  nz_log_gaps
  if nz_summary; then
    log "Export complete: ${NZ_DEST}"
    return 0
  fi
  warn "Export incomplete: see the error/mismatch/missing lines in ${NZ_LOG}"
  return 3
}

# nz_set_rw <node>: make one partition writable. On current kernels a
# partition stays read-only while its whole disk is, so the parent disk is
# made writable too when (and only when) that is what still blocks it.
nz_set_rw() {
  local node=$1 parent
  sudo blockdev --setrw "${node}" || return 1
  RW_NODES+=("${node}")
  [[ $(sudo blockdev --getro "${node}") == 0 ]] && return 0
  parent=$(lsblk -ndo PKNAME -- "${node}" 2>/dev/null) || parent=
  [[ -n ${parent} ]] || return 1
  parent=/dev/${parent##*/}
  sudo blockdev --setrw "${parent}" || return 1
  RW_NODES+=("${parent}")
  [[ $(sudo blockdev --getro "${node}") == 0 ]]
}

# nz_set_ro: every node nz_set_rw touched goes back to read-only.
nz_set_ro() {
  local i
  for (( i = ${#RW_NODES[@]} - 1; i >= 0; i-- )); do
    sudo blockdev --setro "${RW_NODES[i]}" || warn "Could not set ${RW_NODES[i]} read-only again"
  done
  RW_NODES=()
}

# quarantine_volume <node> <fstype> <tag>: mount one volume read-write
# (nosuid,nodev,noexec), quarantine its selected files, unmount, and make the
# node read-only again.
quarantine_volume() {
  local node=$1 fstype=$2 tag=$3 mp=${MNT_BASE}/q-$3 t opts rw_ok=0 p rel
  local -a types=() run=() hits=() xdev=(-xdev)
  read -r -a types <<<"$(quarantine_fs_types "${fstype}")"
  case ${fstype} in
    vfat|exfat) opts="rw,nosuid,nodev,noexec,uid=${UID},gid=${USER_GID},fmask=0133,dmask=0022" ;;
    ntfs) opts="rw,nosuid,nodev,noexec,uid=${UID},gid=${USER_GID}" ;;
    # The scan mounted subvolid=5 (the volume's top level) and walked the
    # subvolumes; quarantine must resolve the same paths.
    btrfs) opts="rw,nosuid,nodev,noexec,subvolid=5"; xdev=(); run=(sudo) ;;
    *) opts=rw,nosuid,nodev,noexec; run=(sudo) ;;
  esac
  log "Quarantining on ${tag} (${fstype}, ${node})"
  if ! nz_set_rw "${node}"; then
    nz_set_ro
    nz_record error "could not make ${node} writable" "${tag}" - -
    return 0
  fi
  for t in "${types[@]}"; do
    try_mount "${node}" "${mp}" "${t}" "${opts}" && { rw_ok=1; break; }
  done
  if (( ! rw_ok )); then
    nz_set_ro
    nz_record error "read-write ${fstype} mount failed: $(tr '\n' ' ' <"${REPORT_DIR}/mount.err")" "${tag}" - -
    return 0
  fi
  # Collect the matches first: the walk must not see the volume change.
  # xdev matches the scan's walk mode (btrfs subvolumes are crossed).
  while IFS= read -r -d '' p; do
    rel=${p#"${mp}"/}
    tsv_esc "${rel}"
    [[ -n ${Q_REL[${tag}$'\t'${REPLY}]+x} ]] || continue
    Q_FOUND[${tag}$'\t'${REPLY}]=1
    hits+=("${p}")
  done < <("${run[@]}" find "${mp}" "${xdev[@]}" -type f -print0 2>/dev/null)
  for p in "${hits[@]}"; do
    rel=${p#"${mp}"/}
    tsv_esc "${rel}"
    quarantine_file "${p}" "${tag}"$'\t'"${REPLY}"
  done
  sync
  if sudo umount -- "${mp}"; then
    MOUNTS=("${MOUNTS[@]:0:${#MOUNTS[@]}-1}")
    sudo rmdir -- "${mp}" 2>/dev/null || true
  else
    nz_record error "could not unmount ${mp}; it is unmounted on exit" "${tag}" - -
  fi
  nz_set_ro
}

# nz_confirm: y/N from the terminal unless --yes. The prompt is written to
# /dev/tty directly (stderr is the buffered console logger and would hide it
# until after the answer).
nz_confirm() {
  local ans=
  (( ASSUME_YES )) && return 0
  { : </dev/tty; } 2>/dev/null || die "No terminal to confirm on; rerun with --yes."
  printf 'Archive and remove these files from the drive? [y/N] ' >/dev/tty
  IFS= read -r ans </dev/tty || ans=
  [[ ${ans} == [yY] || ${ans} == [yY][eE][sS] ]] || die "Aborted; nothing was changed."
}

quarantine_main() {
  local target=${TARGETS[0]} key tag fs why node info fstype
  local -a bad=() nodes=()
  local -A tag_fs=() tag_dm=() sel_tags=() seen_tags=()
  nz_check_report
  [[ -b ${target} ]] || die "--quarantine works on the drive itself (a block device); for an image or a directory use --export."
  if (( ${#Q_KEYS[@]} == 0 )); then
    log "quarantine.tsv has no active lines; nothing to do."
    return 0
  fi
  while IFS=$'\t' read -r tag fs _ src _; do
    tag_fs[${tag}]=${fs}
    # Volumes inside LUKS or LVM sit on device-mapper nodes (/dev/mapper/x,
    # /dev/<vg>/<lv>), which --quarantine does not open; say so up front
    # instead of reporting every selected file there as missing.
    if [[ ${src} =~ ^/dev/[^/]+/ ]]; then tag_dm[${tag}]=${src}; fi
  done <"${NZ_REPORT}/volumes.tsv"
  for key in "${Q_KEYS[@]}"; do sel_tags[${key%%$'\t'*}]=1; done
  for tag in "${!sel_tags[@]}"; do
    if [[ -z ${tag_fs[${tag}]+x} ]]; then
      bad+=("${tag}: not a volume in volumes.tsv")
    elif [[ -n ${tag_dm[${tag}]+x} ]]; then
      bad+=("${tag}: inside LUKS/LVM (${tag_dm[${tag}]}); in-place quarantine does not unlock or activate those - use --export")
    elif ! why=$(quarantine_fs_types "${tag_fs[${tag}]}" 2>&1 >/dev/null); then
      bad+=("${tag}: ${why}")
    fi
  done
  if (( ${#bad[@]} )); then
    printf '    %s\n' "${bad[@]}" >&2
    die "Cannot quarantine in place there; comment those lines out of quarantine.tsv or use --export."
  fi
  log "Selected for quarantine on ${target} (volume, class, detail, path):"
  for key in "${Q_KEYS[@]}"; do
    note "${key%%$'\t'*}  ${Q_INFO[${key}]%%$'\t'*}  ${Q_INFO[${key}]#*$'\t'}  ${key#*$'\t'}"
  done
  warn "The affected volume(s) will be mounted READ-WRITE. That replays filesystem journals and runs the kernel driver's write paths on hostile metadata; for the highest-risk media do this in a disposable VM, or use --export instead."
  nz_confirm
  nz_begin quarantine
  QDIR=${NZ_REPORT}/quarantine
  mkdir -p -- "${QDIR}"
  chmod 0700 -- "${QDIR}"
  IMAGE_MODE=direct
  acquire_device "${target}"
  mapfile -t nodes < <(lsblk -nrpo NAME -- "${ACQUIRED}")
  for node in "${nodes[@]}"; do
    info=$(sudo blkid -p -o export -- "${node}" 2>/dev/null) || info=
    fstype=$(sed -n 's/^TYPE=//p' <<<"${info}")
    [[ -n ${fstype} ]] || continue
    nz_volume_tag "${node}" "${fstype}"
    tag=${NZ_TAG}
    if [[ -z ${tag} ]]; then
      note "${node} (${fstype}): no scanned volume matches (${NZ_WHY}); left alone"
      continue
    fi
    [[ -n ${sel_tags[${tag}]+x} ]] || continue
    if [[ -n ${seen_tags[${tag}]+x} ]]; then
      nz_record error "${node} also maps to this report volume; left alone" "${tag}" - -
      continue
    fi
    seen_tags[${tag}]=1
    quarantine_volume "${node}" "${fstype}" "${tag}"
  done
  for key in "${Q_KEYS[@]}"; do
    [[ -n ${Q_FOUND[${key}]+x} ]] \
      || nz_record missing "not found on ${target} (volume not matched, or the file is gone)" \
           "${key%%$'\t'*}" "${Q_REL[${key}]}" "${key#*$'\t'}"
  done
  if nz_summary; then
    log "Quarantine complete; archives in ${QDIR}"
    return 0
  fi
  warn "Quarantine incomplete: see the error/mismatch/missing lines in ${NZ_LOG}"
  return 3
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
  # Session-only modes: no report dir, tools or scanning.
  case ${SESSION_ACTION} in
    prepare)
      log "Hardening the desktop session before any untrusted drive is attached"
      harden_session "${SESSION_RESTORE}"
      start_sudo
      trap cleanup EXIT
      trap 'exit 130' INT TERM
      install_udev_hold
      # The rule outlives this run; --restore-session removes it (cleanup only
      # removes rules a scan installed itself).
      UDEV_HOLD_INSTALLED=0
      log "Ready. Plug the drives in now: the desktop will not mount or preview them, and"
      log "udev will not auto-assemble, scan or activate anything on them (until --restore-session)."
      log "Scan with: ${0##*/} /dev/sdX"
      return 0 ;;
    restore)
      [[ -f ${SESSION_RESTORE} ]] || die "Nothing to restore: ${SESSION_RESTORE} does not exist"
      sh -- "${SESSION_RESTORE}" || die "restoring the desktop settings failed; see ${SESSION_RESTORE}"
      rm -f -- "${SESSION_RESTORE}"
      if [[ -e ${UDEV_HOLD_RULE} ]]; then
        sudo rm -f -- "${UDEV_HOLD_RULE}" 2>/dev/null \
          && sudo udevadm control --reload 2>/dev/null \
          || warn "Could not remove ${UDEV_HOLD_RULE}; remove it by hand."
      fi
      log "Desktop session settings restored; udev hold rule removed"
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
  # Keep a copy of everything printed from here on as console.log, without
  # colour codes or other control characters (APFS volume names and mount
  # errors come from the untrusted media). Prompts use /dev/tty directly.
  # What reaches the terminal keeps this run's own SGR colour codes but no
  # other control characters: untrusted text cannot replay escapes there
  # either. One awk process prints and logs, so cleanup can wait for it.
  exec > >(LC_ALL=C awk -v logfile="${REPORT_DIR}/console.log" '
    {
      t = $0; n = split(t, a, /\033\[[0-9;]*m/, seps)
      t = ""
      for (i = 1; i <= n; i++) {
        gsub(/[\001-\010\013-\014\016-\037\177]/, "", a[i])
        # Only the colour codes log/warn/die emit survive (no conceal etc.).
        if (i < n && seps[i] !~ /^\033\[(0|1;3[123])m$/) seps[i] = ""
        t = t a[i] (i < n ? seps[i] : "") }
      print t; fflush()
      s = $0; gsub(/\033\[[0-9;]*m/, "", s); gsub(/[\001-\010\013-\037\177]/, "", s)
      print s >> logfile; fflush(logfile) }') 2>&1
  CONSOLE_PID=$!
  log "Report directory: ${REPORT_DIR}"

  (( HARDEN_SESSION )) && harden_session "${REPORT_DIR}/restore-session-settings.sh"
  install_tools
  start_sudo
  install_udev_hold
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
  write_quarantine_template "${REPORT_DIR}" && log "Review ${REPORT_DIR}/quarantine.tsv before --export or --quarantine"
  return "${rc}"
}

case ${NZ_MODE} in
  export) export_main; exit $? ;;
  quarantine) quarantine_main; exit $? ;;
esac
main
exit $?
