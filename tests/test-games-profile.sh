#!/usr/bin/env bash
# Mocked, CI-safe checks for the standalone games profile of the Arch and
# Fedora workstation scripts: lib/select-games.awk (with whatever awk the host
# has: mawk on Ubuntu CI, gawk elsewhere), the pacman and dnf metadata readers
# that feed it, and the offline dry-run plans.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELECT=${REPO_ROOT}/lib/select-games.awk
TEST_ROOT=$(mktemp -d -p "${TMPDIR:-/var/tmp}" games-profile.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() { printf 'ASSERT: %s\n' "$*" >&2; exit 1; }

# The exclusion list both scripts use (they must agree).
arch_exclude=$(sed -n "s/^GAMES_EXCLUDE='\(.*\)'$/\1/p" "${REPO_ROOT}/setup-arch-workstation.sh")
fedora_exclude=$(sed -n "s/^GAMES_EXCLUDE='\(.*\)'$/\1/p" "${REPO_ROOT}/setup-fedora-workstation.sh")
[[ -n ${arch_exclude} && ${arch_exclude} == "${fedora_exclude}" ]] \
  || fail 'the Arch and Fedora scripts must share one GAMES_EXCLUDE'

# select <avail> <total> < records: run the selector with a 20% reserve.
select_games() {
  awk -v exclude="${arch_exclude}" -v avail="$1" -v total="$2" -v reserve=20 -f "${SELECT}"
}

GB=1073741824
records() {
  # R name size provides conflicts depends
  printf 'R\t%s\t%s\t%s\t%s\t%s\n' \
    crossdock-bin $((GB / 100)) crossdock crossdock '' \
    lib32-openal $((GB / 100)) libopenal.so '' '' \
    ut2004-data-archiveorg $((5 * GB)) ut2004-data ut2004-data '' \
    ut2004-data-gog $((5 * GB)) ut2004-data ut2004-data '' \
    ut2004-data-steam $((5 * GB)) ut2004-data ut2004-data '' \
    ut2004-bin $((GB / 7)) ut2004 'ut2004-gog ut2004-steam' 'sdl2 ut2004-data' \
    wreckfest-wine-gog $((30 * GB)) '' '' 'gamelaunch umu-launcher' \
    wreckfest-wine-steam $((30 * GB)) '' '' 'gamelaunch gbe-fork-bin' \
    wreckfest-gog-dlc1 1000 '' '' wreckfest-wine-gog \
    doom3-data-gog $((2 * GB)) 'doom3-data doom3xp-data' 'doom3-data doom3xp-data' '' \
    doom3-data-steam $((GB + GB / 2)) doom3-data doom3-data '' \
    doom3xp-data-steam $((GB / 2)) doom3xp-data doom3xp-data '' \
    dhewm3 $((GB / 80)) '' '' 'openal doom3-data' \
    quake3-data-gog $((GB * 4 / 5)) quake3-data quake3-data '' \
    quake3-data-steam $((GB * 4 / 5)) quake3-data quake3-data '' \
    cro-mag-rally-net-bin $((GB / 6)) 'cro-mag-rally-net cro-mag-rally' 'cro-mag-rally-net cro-mag-rally' ''
}

test_selector() {
  local out installs
  # Plenty of space, quake3-data-steam and an AUR cro-mag-rally-net installed.
  out=$({ records; printf 'I\tquake3-data-steam\tquake3-data\tquake3-data\n'
          printf 'I\tcro-mag-rally-net\tcro-mag-rally\t\n'; } | select_games $((1000 * GB)) $((2000 * GB)))
  installs=$(awk '$1 == "install" { print $2 }' <<<"${out}" | tr '\n' ' ')
  grep -qx 'keep quake3-data-steam' <<<"${out}" || fail 'an installed alternative is kept'
  [[ " ${installs}" != *' quake3-data-gog '* ]] || fail 'an installed Steam copy is not replaced by GOG'
  [[ " ${installs}" != *' crossdock-bin '* && " ${installs}" != *' lib32-openal '* ]] \
    || fail 'tools and libraries are not installed as games'
  [[ " ${installs}" == *' ut2004-data-gog '* && " ${installs}" != *' ut2004-data-steam '* && " ${installs}" != *' ut2004-data-archiveorg '* ]] \
    || fail "GOG wins a declared conflict (got: ${installs})"
  [[ " ${installs}" == *' wreckfest-wine-gog '* && " ${installs}" != *' wreckfest-wine-steam '* ]] \
    || fail 'GOG wins between same-named sources'
  [[ " ${installs}" == *' wreckfest-gog-dlc1 '* ]] || fail 'the GOG game brings its DLC'
  [[ " ${installs}" == *' doom3-data-gog '* && " ${installs}" != *' doom3xp-data-steam '* && " ${installs}" != *' doom3-data-steam '* ]] \
    || fail 'a package providing what the GOG data provides is skipped'
  grep -q '^skip cro-mag-rally-net-bin conflicts with installed cro-mag-rally-net$' <<<"${out}" \
    || fail 'a conflict with an installed package skips the game'
  [[ ${installs%%ut2004-bin*} == *ut2004-data-gog* && ${installs%%dhewm3*} == *doom3-data-gog* ]] \
    || fail "providers install before their users (got: ${installs})"
  grep -qx "install ut2004-bin $((GB / 7)) ut2004-data-gog" <<<"${out}" \
    || fail 'ut2004-bin lists the provider it needs'

  # A Steam copy the repository no longer publishes still counts as installed.
  out=$(printf 'R\twreckfest-wine-gog\t%s\t\t\t\nI\twreckfest-wine-steam\t\t\n' $((30 * GB)) \
    | select_games $((1000 * GB)) $((2000 * GB)))
  grep -qx 'skip wreckfest-wine-gog alternative to installed wreckfest-wine-steam' <<<"${out}" \
    || fail "an installed unpublished source keeps its game (got: ${out})"

  # 40 GiB free of 50: the 30 GiB GOG Wreckfest and its DLC are dropped, and
  # the Steam copy is not substituted.
  out=$(records | select_games $((40 * GB)) $((50 * GB)))
  installs=$(awk '$1 == "install" { print $2 }' <<<"${out}" | tr '\n' ' ')
  [[ " ${installs}" != *' wreckfest-'* ]] || fail "Wreckfest is dropped to keep 20% free (got: ${installs})"
  grep -q '^skip wreckfest-wine-gog would leave less than 20% of the disk free$' <<<"${out}" \
    || fail 'the dropped game names the reserve'
  grep -q '^skip wreckfest-gog-dlc1 needs wreckfest-wine-gog' <<<"${out}" || fail 'its DLC follows it'
  awk '$1 == "space" { exit !($3 - $2 >= $5) }' <<<"${out}" || fail 'the selection leaves the reserve free'

  # Dropping a data package drops the engine that would pull another one.
  out=$(printf 'R\tut2004-data-gog\t%s\tut2004-data\tut2004-data\t\nR\tut2004-data-steam\t%s\tut2004-data\tut2004-data\t\nR\tut2004-bin\t%s\tut2004\t\tut2004-data\n' \
          $((6 * GB)) $((6 * GB)) $((GB / 7)) | select_games $((8 * GB)) $((10 * GB)))
  ! grep -q '^install' <<<"${out}" || fail "no engine without its chosen data (got: ${out})"

  # No room at all.
  out=$(records | select_games $((GB / 2)) $((100 * GB)))
  ! grep -q '^install' <<<"${out}" || fail 'nothing installs when the reserve is used up'
}

test_arch_records() (
  set --
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${REPO_ROOT}/setup-arch-workstation.sh")
  local sync=${TEST_ROOT}/arch-sync local_db=${TEST_ROOT}/arch-local out
  mkdir -p "${sync}/quake3-data-gog-1-7" "${sync}/quake3e-2026.10.14-9" "${local_db}/quake3-data-steam-1-5"
  printf '%%FILENAME%%\nquake3-data-gog-1-7-any.pkg.tar.zst\n\n%%NAME%%\nquake3-data-gog\n\n%%ISIZE%%\n831117885\n\n%%PROVIDES%%\nquake3-data\nquake3-ta-data=1\n\n%%CONFLICTS%%\nquake3-data\n\n' \
    >"${sync}/quake3-data-gog-1-7/desc"
  printf '%%FILENAME%%\nquake3e.pkg.tar.zst\n\n%%NAME%%\nquake3e\n\n%%ISIZE%%\n2889698\n\n%%CONFLICTS%%\nquake3e-git\n\n%%DEPENDS%%\ncurl\nquake3-data\nsdl2>=2.0\n\n%%OPTDEPENDS%%\nquake3-ta-data: Team Arena\n\n' \
    >"${sync}/quake3e-2026.10.14-9/desc"
  printf '%%NAME%%\nquake3-data-steam\n\n%%VERSION%%\n1-5\n\n%%PROVIDES%%\nquake3-data\n\n%%CONFLICTS%%\nquake3-data\n\n' \
    >"${local_db}/quake3-data-steam-1-5/desc"
  (cd "${sync}" && bsdtar -czf "${TEST_ROOT}/game-packages.db" -- *)
  out=$(game_records_arch "${TEST_ROOT}/game-packages.db" "${local_db}")
  grep -qxP 'R\tquake3-data-gog\t831117885\tquake3-data quake3-ta-data\tquake3-data\t' <<<"${out}" \
    || fail "Arch sync record (got: ${out})"
  grep -qxP 'R\tquake3e\t2889698\t\tquake3e-git\tcurl quake3-data sdl2' <<<"${out}" \
    || fail 'Arch versioned dependencies lose their constraint; optional ones are left out'
  grep -qxP 'I\tquake3-data-steam\tquake3-data\tquake3-data' <<<"${out}" || fail 'Arch local record'
)

test_fedora_records() (
  set --
  rpm() {
    case $1 in
      -E) printf '45\n' ;;
      -qa) printf 'quake3-data-steam\tquake3-data quake3-data-steam \tquake3-data \n' ;;
    esac
  }
  # shellcheck disable=SC1090
  source <(sed '/^#--- Preflight/,$d' "${REPO_ROOT}/setup-fedora-workstation.sh")
  local cache=${TEST_ROOT}/libdnf5 out
  # shellcheck disable=SC2034 # both read by the sourced game_records_fedora
  DNF_SYSTEM_CACHE=${cache} ARCH=x86_64
  mkdir -p "${cache}/game-packages-0123/repodata"
  cat <<'XML' | gzip >"${cache}/game-packages-0123/repodata/abc-primary.xml.gz"
<?xml version="1.0" encoding="UTF-8"?>
<metadata xmlns="http://linux.duke.edu/metadata/common" xmlns:rpm="http://linux.duke.edu/metadata/rpm" packages="3">
<package type="rpm">
  <name>quake3e</name>
  <arch>aarch64</arch>
  <size package="1" installed="999" archive="1"/>
</package>
<package type="rpm">
  <name>quake3e</name>
  <arch>x86_64</arch>
  <size package="1183339" installed="2889698" archive="2900000"/>
  <format>
    <rpm:provides>
      <rpm:entry name="quake3e" flags="EQ" epoch="0" ver="2026.10.14" rel="9.fc45"/>
      <rpm:entry name="quake3e(x86-64)" flags="EQ" epoch="0" ver="2026.10.14" rel="9.fc45"/>
    </rpm:provides>
    <rpm:requires>
      <rpm:entry name="/usr/bin/sh"/>
      <rpm:entry name="(libX11 if glibc(x86-64))"/>
      <rpm:entry name="quake3-data"/>
      <rpm:entry name="gamelaunch" flags="GE" epoch="0" ver="1.2.0"/>
    </rpm:requires>
    <rpm:conflicts>
      <rpm:entry name="quake3e-git"/>
    </rpm:conflicts>
  </format>
</package>
<package type="rpm">
  <name>quake3-data-gog</name>
  <arch>noarch</arch>
  <size package="1" installed="831117885" archive="1"/>
  <format>
    <rpm:provides>
      <rpm:entry name="quake3-data"/>
      <rpm:entry name="quake3-data-gog" flags="EQ" epoch="0" ver="1" rel="7.fc45"/>
    </rpm:provides>
    <rpm:conflicts>
      <rpm:entry name="quake3-data"/>
    </rpm:conflicts>
  </format>
</package>
</metadata>
XML
  out=$(game_records_fedora)
  [[ $(grep -c '^R' <<<"${out}") == 2 ]] || fail "Fedora records skip other architectures (got: ${out})"
  grep -qxP 'R\tquake3e\t2889698\tquake3e\tquake3e-git\tquake3-data gamelaunch' <<<"${out}" \
    || fail "Fedora record keeps plain names only (got: ${out})"
  grep -qxP 'R\tquake3-data-gog\t831117885\tquake3-data quake3-data-gog\tquake3-data\t' <<<"${out}" \
    || fail 'Fedora noarch record'
  grep -qxP 'I\tquake3-data-steam\tquake3-data quake3-data-steam \tquake3-data ' <<<"${out}" \
    || fail 'Fedora installed record'
)

test_dry_runs() {
  local out script
  for script in setup-arch-workstation.sh setup-fedora-workstation.sh; do
    out=$(bash "${REPO_ROOT}/${script}" --profile games --dry-run) || fail "${script} games dry run failed"
    grep -q '^Profile: games; mode: dry-run' <<<"${out}" || fail "${script} games dry run announces itself"
    grep -q 'standalone; nothing from the core or full profiles' <<<"${out}" || fail "${script} games is standalone"
    grep -q 'GOG, Steam, other sources' <<<"${out}" || fail "${script} games dry run states the source order"
    grep -q '20% of the /opt filesystem' <<<"${out}" || fail "${script} games dry run states the reserve"
    ! grep -Eqi 'rustup|antigravity|clamav|firewalld' <<<"${out}" || fail "${script} games dry run leaves the workstation alone"
    bash "${REPO_ROOT}/${script}" --help | grep -Fq -- '--profile core|full|games' || fail "${script} --help documents games"
  done
}

test_selector
test_arch_records
test_fedora_records
test_dry_runs
printf 'games profile: PASS (awk: %s)\n' "$(awk -W version 2>/dev/null | head -n 1 || awk --version | head -n 1)"
