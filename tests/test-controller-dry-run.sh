#!/usr/bin/env bash
# Prove `setup-fedora-controllers.sh --dry-run` changes nothing and reports
# what a real run would do. Runs inside a throwaway Rocky 10 container as
# root, with shims standing in for the host tools a container lacks
# (systemd, firewalld, podman, SELinux). Every shim logs any mutating call;
# each scenario then requires an empty mutation log and a byte-identical
# filesystem (paths, types, sizes, modes and mtimes) outside scratch.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${CONTROLLER_TEST_IMAGE:-docker.io/rockylinux/rockylinux:10}

if [[ ${1:-} != --inside ]]; then
  command -v podman >/dev/null 2>&1 || { echo 'SKIP: podman is not installed'; exit 0; }
  exec podman run --rm -e DRY_TEST_DUMP -v "${REPO_ROOT}:/repo:ro,Z" "${IMAGE}" \
    bash /repo/tests/test-controller-dry-run.sh --inside
fi

CONTROLLER=/repo/setup-fedora-controllers.sh
fail() { printf 'ASSERT: %s\n' "$*" >&2; exit 1; }
PASSED=0
ok() { PASSED=$(( PASSED + 1 )); printf 'ok %d - %s\n' "${PASSED}" "$*"; }

dnf -q -y install dnsmasq dnf-automatic diffutils findutils git-core iproute jq \
  openssl procps-ng util-linux >/dev/null 2>&1 || fail 'could not install test prerequisites'

#--- Shims for tools the container lacks ------------------------------------
T=/test
mkdir -p "${T}/shims" "${T}/state" "${T}/log"
: > "${T}/state/active"; : > "${T}/state/enabled"; : > "${T}/state/units"
: > "${T}/state/firewall"; : > "${T}/state/images"
shim() { cat > "${T}/shims/$1"; chmod 755 "${T}/shims/$1"; }
mutation='echo "$(basename "$0") $*" >> /test/log/mutations; exit 0'

shim getenforce <<'EOF'
#!/bin/bash
echo Enforcing
EOF
shim timedatectl <<'EOF'
#!/bin/bash
echo Etc/UTC
EOF
shim findmnt <<'EOF'
#!/bin/bash
case "$*" in
  *FSTYPE*) echo ext4 ;;
  *) echo /dev/mmcblk0p3 ;;
esac
EOF
shim systemctl <<EOF
#!/bin/bash
sub=; units=()
for a; do [[ \$a == -* ]] && continue; [[ -z \$sub ]] && sub=\$a || units+=("\$a"); done
case \$sub in
  is-active)  for u in "\${units[@]}"; do grep -qx "\$u" /test/state/active || exit 3; done ;;
  is-enabled) for u in "\${units[@]}"; do grep -qx "\$u" /test/state/enabled || exit 1; done ;;
  cat)        for u in "\${units[@]}"; do grep -qx "\$u" /test/state/units || exit 1; done ;;
  show|status|list-*) exit 0 ;;
  *) ${mutation} ;;
esac
EOF
shim firewall-cmd <<EOF
#!/bin/bash
for a; do
  case \$a in
    --get-default-zone|--get-zone-of-interface=*) echo public; exit 0 ;;
    --get-zones) echo 'block drop public trusted'; exit 0 ;;
    --state) echo running; exit 0 ;;
    --query-service=*|--query-port=*) grep -qx "\${a#--query-*=}" /test/state/firewall; exit ;;
  esac
done
${mutation}
EOF
shim podman <<EOF
#!/bin/bash
case "\$1 \$2" in
  'image inspect')
    grep -qx "\$3" /test/state/images || exit 125
    printf '[{"Id":"sha256:%064d","Digest":"sha256:%064d"}]\n' 1 2 ;;
  'container exists') exit 1 ;;
  'inspect '*) exit 125 ;;
  *) ${mutation} ;;
esac
EOF
shim dnf <<EOF
#!/bin/bash
for a; do
  case \$a in
    check-update) printf 'kernel.x86_64  6.12.0-55.el10  baseos\nopenssl.x86_64  3.2.2-17.el10  baseos\n'; exit 100 ;;
    needs-restarting) exit 0 ;;
  esac
done
${mutation}
EOF
shim tune2fs <<EOF
#!/bin/bash
if [[ \$1 == -l ]]; then printf 'Block count:              1000000\nReserved block count:     50000\n'; exit 0; fi
${mutation}
EOF
shim sysctl <<EOF
#!/bin/bash
case "\$*" in *-w*|*--system*) ${mutation} ;; esac
case "\$*" in *swappiness*) echo 60 ;; *page-cluster*) echo 3 ;; esac
EOF
shim restorecon <<EOF
#!/bin/bash
${mutation}
EOF
# curl: release metadata comes from a fixture, HEAD requests succeed, the
# lancache heartbeat is down; any download into the host is a mutation
shim curl <<'EOF'
#!/bin/bash
echo "curl $*" >> /test/log/curl
out=; prev=
for a; do [[ $prev == -o ]] && out=$a; prev=$a; done
case "$*" in
  *lancache-heartbeat*) exit 7 ;;
  *' -fsIL '*|*' -I '*) exit 0 ;;
  *fw-update.ui.com*) cp /test/uos-release.json "$out"; exit 0 ;;
esac
if [[ -n $out && $out != /dev/null && $out != /var/tmp/controller-dry-run.* ]]; then
  echo "curl $*" >> /test/log/mutations
fi
exit 0
EOF
export PATH=${T}/shims:${PATH}

# The Quadlet generator records the unit directory it validated
GEN=/usr/lib/systemd/system-generators/podman-system-generator
mkdir -p "${GEN%/*}"
cat > "${GEN}" <<'EOF'
#!/bin/bash
for d in ${QUADLET_UNIT_DIRS//:/ }; do ls "$d"; done >> /test/log/generator
exit 0
EOF
chmod 755 "${GEN}"

cat > "${T}/uos-release.json" <<'EOF'
{"_embedded":{"firmware":[{"product":"unifi-os-server","platform":"linux-x64","channel":"release",
"version_major":5,"version_minor":2,"version_patch":3,"version":"v5.2.3",
"sha256_checksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
"_links":{"data":{"href":"https://fw-download.ubnt.com/data/unifi-os-server/1234-linux-x64-5.2.3-abcd"}},
"file_size":123456}]}}
EOF

# Offline cache-domains fixture for the lancache-gen preview
FIX=${T}/fixture
mkdir -p "${FIX}"
printf '{"cache_domains":[{"name":"steam","domain_files":["steam.txt"]},{"name":"misc","domain_files":["misc.txt"]}]}\n' \
  > "${FIX}/cache_domains.json"
echo lancache.steamcontent.com > "${FIX}/steam.txt"
for i in $(seq -w 1 25); do echo "cdn${i}.example-cdn.net"; done > "${FIX}/misc.txt"
git -C "${FIX}" init -q
git -C "${FIX}" add -A
git -C "${FIX}" -c user.name=t -c user.email=t@invalid commit -qm fixture
export LANCACHE_DOMAINS_URL=file://${FIX}

#--- Scenario runner ---------------------------------------------------------
snapshot() {
  {
    find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /test \
      -o -path /tmp -o -path /var/tmp -o -path /var/cache -o -path /var/log \
      -o -path /run \) -prune -o -printf '%p %y %s %m %T@\n'
    find /run -printf '%p %y %s %m %T@\n' 2>/dev/null
  } | grep -v '^/usr/lib/sysimage/rpm/rpmdb.sqlite-shm ' | sort  # rpm -q reads touch it
}
OUT=${T}/out
run_dry() { # <label> <controller args...>
  local label=$1
  shift
  : > "${T}/log/mutations"; : > "${T}/log/curl"; : > "${T}/log/generator"
  snapshot > "${T}/before"
  local status=0
  bash "${CONTROLLER}" --dry-run "$@" > "${OUT}" 2>&1 || status=$?
  if [[ ${EXPECT_FAIL:-0} == 1 ]]; then
    (( status != 0 )) || fail "${label}: dry run should have stopped where a real run would"
  elif (( status != 0 )); then
    tail -40 "${OUT}" >&2
    fail "${label}: dry run exited non-zero"
  fi
  snapshot > "${T}/after"
  if ! diff -u "${T}/before" "${T}/after" >&2; then
    fail "${label}: the dry run changed the filesystem"
  fi
  if [[ -s ${T}/log/mutations ]]; then
    cat "${T}/log/mutations" >&2
    fail "${label}: a host tool received a mutating call"
  fi
  [[ -z $(find /var/tmp -maxdepth 1 -name 'controller-dry-run.*' -print -quit) ]] \
    || fail "${label}: the dry-run overlay was left behind"
  [[ ${DRY_TEST_DUMP:-0} != 1 ]] || sed "s/^/[${label}] /" "${OUT}"
  if [[ ${EXPECT_FAIL:-0} == 1 ]]; then
    grep -q 'dry run stopped at the error above' "${OUT}" || fail "${label}: missing stop line"
  else
    grep -q 'dry run complete; nothing on this host was changed' "${OUT}" \
      || fail "${label}: missing completion line"
  fi
  ok "${label}: no filesystem change, no mutating host call, overlay cleaned up"
}
expect() { # <label> <fixed string>...
  local label=$1 needle
  shift
  for needle; do
    grep -Fq -- "${needle}" "${OUT}" || { tail -60 "${OUT}" >&2; fail "${label}: missing '${needle}'"; }
  done
}
refuse() { # <label> <extended regex>
  if grep -Eq -- "$2" "${OUT}"; then
    grep -En -- "$2" "${OUT}" >&2
    fail "$1: output must not match '$2'"
  fi
}

#--- 1. Fresh host: Omada + Shadowsocks + DNS + lancache ----------------------
run_dry 'fresh host' --no-unifi-os --lancache 192.168.1.11
expect 'fresh host' \
  'would install packages:' 'podman' \
  'would upgrade these packages' 'kernel.x86_64' \
  '+ new /etc/dnsmasq.d/lan-dns.conf' \
  '+ new /etc/dnsmasq.d/40-lancache-base.conf' '+local-ttl=30' \
  '+ new /usr/local/sbin/lancache-toggle' '+ new /usr/local/sbin/lancache-gen' \
  '+ new /etc/systemd/system/lancache-toggle.timer' \
  '+ new /etc/containers/systemd/omada.container' \
  '+ new /etc/containers/systemd/shadowsocks.container' \
  '+ new /etc/dnsmasq.lancache/lancache.conf' \
  '+address=/lancache.steamcontent.com/192.168.1.11' '+local=/lancache.steamcontent.com/' \
  'heartbeat at 192.168.1.11 does not answer now' \
  '+ new /var/lib/controller-setup/credentials.env' '+MONGO_ROOT_PASS=<redacted>' \
  '"password": "<redacted>"' 'mongodb://omada:<redacted>@omada-db' \
  '~ changed /etc/dnf/automatic.conf' '+apply_updates = yes' \
  'would enable dnsmasq.service' 'would restart dnsmasq.service' \
  'would enable and start lancache-toggle.timer' 'would start lancache-gen.service' \
  'would pull docker.io/mongo:' \
  'would add firewalld service controller-dns to zone public (permanent)' \
  'Dry run (planned end state).'
refuse 'fresh host' '(PASS|PASSWORD)=[0-9A-Za-z+/]{20,}'
refuse 'fresh host' 'would (add|remove) firewalld service controller-unifi-os'
refuse 'fresh host' 'Disabling UniFi OS Server'
grep -qx 'omada.container' "${T}/log/generator" \
  || fail 'fresh host: Quadlet validation did not see the would-be omada.container'
ok 'fresh host: packages, units, Quadlets, lancache overrides, redacted secrets reported'

#--- 2. Existing DNS box: legacy Steam toggle retired, small-storage on --------
mkdir -p /etc/dnsmasq.d /etc/systemd/system /usr/local/sbin /var/lib/controller-setup
echo 'address=/lancache.steamcontent.com/192.168.1.99' > /etc/dnsmasq.d/lancache.conf
echo '#!/bin/bash' > /usr/local/sbin/lancache-dns-toggle
printf '[Timer]\nOnUnitActiveSec=1min\n' > /etc/systemd/system/lancache-watch.timer
echo 'stale' > /var/lib/controller-setup/dnsmasq.applied
printf '%s\n' dnsmasq.service lancache-watch.timer firewalld.service > "${T}/state/active"
printf '%s\n' dnsmasq.service lancache-watch.timer firewalld.service > "${T}/state/enabled"
echo controller-dns > "${T}/state/firewall"
run_dry 'existing DNS box' --no-omada --no-shadowsocks --no-unifi-os --small-storage --no-zram
expect 'existing DNS box' \
  'would disable and stop lancache-watch.timer' \
  '- remove /etc/dnsmasq.d/lancache.conf' '- remove /usr/local/sbin/lancache-dns-toggle' \
  '- remove /etc/systemd/system/lancache-watch.timer' \
  'would restart dnsmasq.service' \
  '+ new /etc/systemd/journald.conf.d/10-controller-small-storage.conf' \
  '~ changed /etc/dnf/dnf.conf' '+installonly_limit=2' \
  'would run: tune2fs -m 1 /dev/mmcblk0p3' 'would run: dnf clean all'
refuse 'existing DNS box' 'would (enable and start|start) dnsmasq.service'
refuse 'existing DNS box' 'firewalld service controller-dns'
ok 'existing DNS box: legacy steering removal, dnsmasq restart, storage profile reported'

#--- 3. DNS turned off: everything script-owned for DNS comes out -------------
mkdir -p /etc/dnsmasq.lancache
echo 'conf' > /etc/dnsmasq.lancache/lancache.conf
echo 'local-ttl=30' > /etc/dnsmasq.d/40-lancache-base.conf
echo 'bind-dynamic' > /etc/dnsmasq.d/lan-dns.conf
printf '%s\n' dnsmasq.service lancache-toggle.timer firewalld.service > "${T}/state/active"
printf '%s\n' dnsmasq.service lancache-toggle.timer firewalld.service > "${T}/state/enabled"
run_dry 'dns off' --no-omada --no-shadowsocks --no-unifi-os --no-dns --no-zram
expect 'dns off' \
  'would disable and stop dnsmasq.service' 'would disable and stop lancache-toggle.timer' \
  '- remove /etc/dnsmasq.d/lan-dns.conf' '- remove /etc/dnsmasq.lancache (directory)' \
  '- remove /etc/dnsmasq.d/40-lancache-base.conf' \
  'would remove firewalld service controller-dns from zone public (permanent)'
ok 'dns off: units disabled, DNS files and lancache tree removed, firewall service dropped'

#--- 4. Fresh UniFi OS: release resolved, installer planned, not downloaded ----
rm -rf /etc/dnsmasq.lancache /etc/dnsmasq.d/40-lancache-base.conf /etc/dnsmasq.d/lan-dns.conf \
  /etc/dnsmasq.d/lancache.conf /usr/local/sbin/lancache-dns-toggle \
  /etc/systemd/system/lancache-watch.timer /var/lib/controller-setup
: > "${T}/state/active"; : > "${T}/state/enabled"; : > "${T}/state/firewall"
run_dry 'fresh UniFi OS' --no-omada --no-shadowsocks --no-dns --no-zram
expect 'fresh UniFi OS' \
  'UniFi OS Server 5.2.3 installer answers at' \
  'would download the UniFi OS Server 5.2.3 installer and verify SHA-256 aaaa' \
  'would run the UniFi OS Server 5.2.3 installer (--non-interactive --network-mode pasta --web-port 11443)' \
  'would enable uosserver.service' 'would start uosserver.service' \
  '+ new /var/lib/controller-setup/uos-bootstrap-version' \
  'would add firewalld service controller-unifi-os to zone public (permanent)'
if grep -v -- '-fsIL' "${T}/log/curl" | grep -q 'unifi-os-server/1234-linux-x64'; then
  fail 'fresh UniFi OS: the installer was fetched'
fi
ok 'fresh UniFi OS: metadata resolved, installer only HEAD-checked, install planned'

#--- 5. Converged host: apply a run's rendered state, then dry-run again ------
# Simulates a completed real run from the first dry run's own output: its
# files go onto the host, its planned directories, units and firewall
# services become real shim state. The second dry run must then see nothing
# to change and nothing to restart.
rm -rf /var/lib/controller-setup /etc/containers/systemd /opt/omada /opt/shadowsocks
printf '%s\n' docker.io/mongo:8.0 docker.io/mbentley/omada-controller:6 \
  ghcr.io/shadowsocks/ssserver-rust:latest > "${T}/state/images"
: > "${T}/state/active"; : > "${T}/state/enabled"; : > "${T}/state/firewall"
DRY_RUN_KEEP=1 bash "${CONTROLLER}" --dry-run --no-unifi-os --lancache 192.168.1.11 > "${OUT}" 2>&1 \
  || { tail -40 "${OUT}" >&2; fail 'converged host: first dry run failed'; }
overlay=$(find /var/tmp -maxdepth 1 -name 'controller-dry-run.*' -print -quit)
[[ -d ${overlay}/root ]] || fail 'converged host: DRY_RUN_KEEP=1 did not keep the rendered files'
sed 's/\x1b\[[0-9;]*m//g' "${OUT}" > "${T}/plain"
sed -n 's/^\[dry-run\] would create directory \([^ ]*\).*/\1/p' "${T}/plain" | xargs -r mkdir -p
cp -a "${overlay}/root/." /
rm -rf "${overlay}"
sed -n -E 's/^\[dry-run\] would (enable and start|enable|start|restart) ([^ ]+)$/\2/p' "${T}/plain" \
  | sort -u | tee "${T}/state/active" > "${T}/state/enabled"
sed -n -E 's/^\[dry-run\] would add firewalld service ([^ ]+) .*/\1/p' "${T}/plain" > "${T}/state/firewall"
run_dry 'converged host' --no-unifi-os --lancache 192.168.1.11
expect 'converged host' 'Totals: 0 new, 0 changed, 0 removed' \
  'omada-db unchanged; leaving it running' 'dnsmasq unchanged; leaving it running' \
  'shadowsocks unchanged; leaving it running'
refuse 'converged host' 'would (restart|stop|enable|disable) '
refuse 'converged host' 'would start (omada|omada-db|shadowsocks|dnsmasq|cockpit)'
refuse 'converged host' 'would (add|remove) firewalld'
ok 'converged host: second dry run plans no file changes, restarts or unit changes'

#--- Restart-hash parity ------------------------------------------------------
# A dry run predicts restarts by hashing would-be content; that digest must
# equal the real-run digest of the same files or every dry run would
# (mis)predict restarts
mkdir -p "${T}/hash"
echo a > "${T}/hash/one"; echo b > "${T}/hash/two"
eval "$(sed -n '/^#--- Dry-run layer /,/^#--- End dry-run layer /p' "${CONTROLLER}")"
eval "$(sed -n '/^input_hash() {/,/^}/p' "${CONTROLLER}")"
# DRY_RUN/DRY_ROOT steer the eval'd production functions
# shellcheck disable=SC2034
DRY_RUN=0
real=$(input_hash "${T}/hash/one" "${T}/hash/missing" "${T}/hash/two")
# shellcheck disable=SC2034
DRY_RUN=1 DRY_ROOT=$(mktemp -d)
: > "${DRY_ROOT}/gone"
dry=$(input_hash "${T}/hash/one" "${T}/hash/missing" "${T}/hash/two")
[[ ${real} == "${dry}" ]] || fail "restart hash differs: real ${real}, dry ${dry}"
ok 'dry-run restart hash equals the real-run hash (missing inputs included)'

#--- 6. Legacy Steam toggle retired without --lancache ------------------------
# The converged host minus lancache, with a recorded dnsmasq hash matching
# what is left: dropping the legacy override file must still restart
# dnsmasq, although the hash ignores absent files
rm -rf /etc/dnsmasq.lancache /etc/dnsmasq.d/40-lancache-base.conf /etc/dnsmasq.d/50-lancache.conf \
  /usr/local/sbin/lancache-* /etc/systemd/system/lancache-*
# shellcheck disable=SC2034  # steers the eval'd input_hash
DRY_RUN=0
input_hash /etc/dnsmasq.conf /etc/dnsmasq.d/lan-dns.conf /etc/dnsmasq.d/40-lancache-base.conf \
  > /var/lib/controller-setup/dnsmasq.applied
run_dry 'no lancache, nothing legacy' --no-unifi-os
expect 'no lancache, nothing legacy' 'dnsmasq unchanged; leaving it running'
refuse 'no lancache, nothing legacy' 'would restart dnsmasq'
echo 'address=/lancache.steamcontent.com/192.168.1.99' > /etc/dnsmasq.d/lancache.conf
run_dry 'legacy toggle retired' --no-unifi-os
expect 'legacy toggle retired' '- remove /etc/dnsmasq.d/lancache.conf' 'would restart dnsmasq.service'
ok 'retiring the legacy override file restarts dnsmasq even with an unchanged hash'

#--- 7. Validation sees the real conf-dir, not just this run's files ----------
# An admin fragment the run never writes breaks the merged config; the dry
# run must stop at dnsmasq --test exactly where a real run would
echo 'address=/admin.example/999.1.1.1' > /etc/dnsmasq.d/zz-admin.conf
EXPECT_FAIL=1 run_dry 'broken admin fragment' --no-unifi-os
expect 'broken admin fragment' 'dnsmasq --test failed on the merged configuration'
rm -f /etc/dnsmasq.d/zz-admin.conf /etc/dnsmasq.d/lancache.conf
ok 'merged dnsmasq validation includes untouched real fragments'

echo "PASS: ${PASSED} dry-run checks"
