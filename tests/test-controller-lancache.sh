#!/usr/bin/env bash
# Exercise setup-fedora-controllers.sh's lancache helpers (lancache-gen,
# lancache-toggle, lancache-ctl) end to end, unprivileged and offline: a
# fixture cache-domains git repo, a fake lancache heartbeat, a stub upstream
# resolver and a scratch dnsmasq on random localhost ports, all under one
# temp dir.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTROLLER=${REPO_ROOT}/setup-fedora-controllers.sh

for tool in dnsmasq dig curl flock git jq python3 sha256sum cmp; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "SKIP: ${tool} is not installed"; exit 0; }
done

T=$(mktemp -d -p "${TMPDIR:-/var/tmp}" controller-lancache.XXXXXX)
HB_PID=
cleanup() {
  [[ -s ${T}/dnsmasq.pid ]] && kill "$(cat "${T}/dnsmasq.pid")" 2>/dev/null
  [[ -s ${T}/upstream.pid ]] && kill "$(cat "${T}/upstream.pid")" 2>/dev/null
  [[ -n ${HB_PID} ]] && kill "${HB_PID}" 2>/dev/null
  rm -rf -- "${T}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

PASSED=0
fail() { printf 'ASSERT: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$(( PASSED + 1 )); printf 'ok %d - %s\n' "${PASSED}" "$*"; }
free_port() {
  python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

#--- Production helper text --------------------------------------------------
[[ $(grep -c '^#--- Lancache DNS helpers ' "${CONTROLLER}") == 1 ]] \
  || fail 'lancache helper start marker is missing or ambiguous'
[[ $(grep -c '^#--- End lancache DNS helpers ' "${CONTROLLER}") == 1 ]] \
  || fail 'lancache helper end marker is missing or ambiguous'
# Globals the emitters bake in as defaults (each is overridden below)
# shellcheck disable=SC2034
{
  LANCACHE_IP=192.168.1.11
  LANCACHE_DOMAINS_URL=https://github.com/uklans/cache-domains.git
  LANCACHE_DOMAINS_DIR=/var/lib/cache-domains
  LANCACHE_SRC_CONF=/etc/dnsmasq.lancache/lancache.conf
  LANCACHE_ACTIVE_CONF=/etc/dnsmasq.d/50-lancache.conf
  LANCACHE_DISABLE_FLAG=/etc/dnsmasq.lancache/disabled
  LANCACHE_STATE_DIR=/run/lancache-toggle
  LANCACHE_GEN=/usr/local/sbin/lancache-gen
  LANCACHE_TOGGLE=/usr/local/sbin/lancache-toggle
}
# shellcheck disable=SC1090
source <(sed -n '/^#--- Lancache DNS helpers /,/^#--- End lancache DNS helpers /p' \
  "${CONTROLLER}")
mkdir -p "${T}/bin"
lancache_gen_script > "${T}/bin/lancache-gen"
lancache_toggle_script > "${T}/bin/lancache-toggle"
lancache_ctl_script > "${T}/bin/lancache-ctl"
chmod 755 "${T}/bin/"*
grep -q '^HEARTBEAT_URL=${HEARTBEAT_URL:-http://192.168.1.11/lancache-heartbeat}$' \
  "${T}/bin/lancache-toggle" || fail 'toggle does not bake in the heartbeat URL'
ok 'helpers extracted from the controller script'

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "${T}/bin/"* || fail 'shellcheck flagged a helper'
  ok 'shellcheck clean on the generated helpers'
else
  echo '# shellcheck not installed; skipping the helper lint'
fi

#--- Fixture cache-domains repo ----------------------------------------------
FIX=${T}/fixture
mkdir -p "${FIX}"
cat > "${FIX}/cache_domains.json" <<'EOF'
{
  "cache_domains": [
    { "name": "steam", "domain_files": ["steam.txt"] },
    { "name": "blizzard", "domain_files": ["blizzard.txt"] },
    { "name": "misc", "domain_files": ["misc.txt", "extra.txt"] }
  ]
}
EOF
printf 'lancache.steamcontent.com\n' > "${FIX}/steam.txt"
printf '# Blizzard\r\n*.cdn.blizzard.com\r\n  Level3.Blizzard.com  \r\n\r\n' > "${FIX}/blizzard.txt"
{
  echo '# twenty-odd plain names'
  for i in $(seq -w 1 20); do echo "cdn${i}.example-cdn.net"; done
  echo 'cdn01.example-cdn.net   # duplicate with a trailing comment'
} > "${FIX}/misc.txt"
printf 'bad_name!.example.com\nlancache.steamcontent.com\n' > "${FIX}/extra.txt"
fixture_commit() {
  git -C "${FIX}" add -A
  git -C "${FIX}" -c user.name=test -c user.email=test@invalid commit -qm "$1"
}
git -C "${FIX}" init -q
fixture_commit 'initial'

#--- Environment shared by every helper --------------------------------------
DNS_PORT=$(free_port)
UP_PORT=$(free_port)
HB_PORT=$(free_port)
export LANCACHE_IP=192.168.1.11
export REPO_URL=file://${FIX}
export DOMAINS_DIR=${T}/cache-domains
export OUT=${T}/lancache/lancache.conf SRC=${T}/lancache/lancache.conf
export ACTIVE=${T}/conf.d/50-lancache.conf
export DISABLE_FLAG=${T}/lancache/disabled
export STATE_DIR=${T}/state LOCK=${T}/state.lock
export HEARTBEAT_URL=http://127.0.0.1:${HB_PORT}/lancache-heartbeat
export RESTART_CMD=${T}/bin/restart-dns RECOVER_CMD=${T}/bin/restart-dns
export TEST_CMD="dnsmasq --test --conf-file=${T}/dnsmasq.conf"
export LOGGER=${T}/bin/logger
export TOGGLE=${T}/bin/lancache-toggle GEN=${T}/bin/lancache-gen
export DNS_PORT DNS_SERVER=127.0.0.1
export T

cat > "${T}/bin/logger" <<'EOF'
#!/usr/bin/env bash
# logger -t <tag> -p <prio> -- <message>
printf '%s %s %s\n' "$2" "$4" "$6" >> "${T}/journal"
EOF
cat > "${T}/bin/restart-dns" <<'EOF'
#!/usr/bin/env bash
set -u
pidf=${T}/dnsmasq.pid
if [[ -s ${pidf} ]]; then
  pid=$(cat "${pidf}")
  kill "${pid}" 2>/dev/null
  for _ in $(seq 50); do kill -0 "${pid}" 2>/dev/null || break; sleep 0.1; done
fi
echo restart >> "${T}/restarts"
sleep "${RESTART_DELAY:-0}"
exec dnsmasq --conf-file="${T}/dnsmasq.conf"
EOF
chmod 755 "${T}/bin/logger" "${T}/bin/restart-dns"
: > "${T}/journal"
: > "${T}/restarts"

mkdir -p "${T}/conf.d" "${T}/lancache"
cat > "${T}/upstream.conf" <<EOF
port=${UP_PORT}
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-hosts
user=$(id -un)
pid-file=${T}/upstream.pid
log-facility=${T}/upstream.log
address=/lancache.steamcontent.com/203.0.113.7
address=/lancache.steamcontent.com/2001:db8::7
address=/example.net/198.51.100.9
address=/example.net/2001:db8::9
EOF
# Mirrors the controller's layout: EL's stock conf-dir line, the always-loaded
# lancache base fragment, and a hagezi-style block entry
cat > "${T}/dnsmasq.conf" <<EOF
port=${DNS_PORT}
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-hosts
server=127.0.0.1#${UP_PORT}
user=$(id -un)
pid-file=${T}/dnsmasq.pid
log-facility=${T}/dnsmasq.log
conf-dir=${T}/conf.d,.rpmnew,.rpmsave,.rpmorig
EOF
echo 'local-ttl=30' > "${T}/conf.d/40-lancache-base.conf"
echo 'local=/ads.example.org/' > "${T}/conf.d/hagezi-pro.conf"
dnsmasq --conf-file="${T}/upstream.conf" || fail 'stub upstream did not start'
dnsmasq --conf-file="${T}/dnsmasq.conf" || fail 'scratch dnsmasq did not start'

cat > "${T}/heartbeat.py" <<'EOF'
import http.server, sys
port, ctl = int(sys.argv[1]), sys.argv[2]
class Heartbeat(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(ctl) as f:
            up = f.read().strip() == "up"
        self.send_response(204 if up and self.path == "/lancache-heartbeat" else 503)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), Heartbeat).serve_forever()
EOF
echo up > "${T}/hb"
python3 -I "${T}/heartbeat.py" "${HB_PORT}" "${T}/hb" &
HB_PID=$!
for _ in $(seq 50); do
  curl -fs -o /dev/null "${HEARTBEAT_URL}" && break
  sleep 0.1
done
curl -fs -o /dev/null "${HEARTBEAT_URL}" || fail 'fake heartbeat did not come up'

#--- Query helpers -----------------------------------------------------------
q() { dig +tries=1 +time=2 -p "${DNS_PORT}" @127.0.0.1 "$@"; }
answer() { q +short "$1" "$2" | paste -sd ' ' -; }
nodata() { # <type> <name>: NOERROR with an empty answer section
  local out
  out=$(q +noall +comments "$1" "$2")
  [[ ${out} == *'status: NOERROR'* && ${out} == *'ANSWER: 0,'* ]]
}
journal_count() { grep -c -- "$1" "${T}/journal" || true; }
restarts() { wc -l < "${T}/restarts"; }
toggle() { "${T}/bin/lancache-toggle" >/dev/null; }
hb() { echo "$1" > "${T}/hb"; }

answer A lancache.steamcontent.com | grep -qx '203.0.113.7' \
  || fail 'baseline should resolve through the stub upstream'
ok 'scratch dnsmasq resolves through the stub upstream'

#--- lancache-gen ------------------------------------------------------------
"${GEN}" > "${T}/gen.out" 2> "${T}/gen.err" || { cat "${T}/gen.err" >&2; fail 'lancache-gen failed'; }
commit=$(git -C "${FIX}" rev-parse --short=12 HEAD)
grep -q "^# Source: uklans/cache-domains @ ${commit} (23 domains) -> 192.168.1.11$" "${OUT}" \
  || fail "header lacks the commit/count: $(sed -n 2p "${OUT}")"
for d in lancache.steamcontent.com cdn.blizzard.com level3.blizzard.com cdn07.example-cdn.net; do
  grep -qx "address=/${d}/192.168.1.11" "${OUT}" || fail "missing address= for ${d}"
  grep -qx "local=/${d}/" "${OUT}" || fail "missing local= for ${d}"
done
[[ $(grep -c '^address=' "${OUT}") == 23 && $(grep -c '^local=' "${OUT}") == 23 ]] \
  || fail 'expected 23 unique domains (comments/blank/CR/duplicates dropped)'
! grep -q '[*!_ ]' <(grep -v '^#' "${OUT}") || fail 'wildcards or junk leaked into the overrides'
grep -q "skipping malformed entry 'bad_name!.example.com'" "${T}/gen.err" \
  || fail 'malformed entry was not reported'
ok 'lancache-gen: comments, CRs, wildcards, case and duplicates normalised; malformed entry skipped'

cp "${OUT}" "${T}/good.conf"
"${GEN}" 2>/dev/null | grep -q 'unchanged' || fail 'second run should report unchanged'
cmp -s "${OUT}" "${T}/good.conf" || fail 'unchanged run altered the file'
MIN_DOMAINS=1000 "${GEN}" 2>/dev/null && fail 'implausibly small list should be refused'
cmp -s "${OUT}" "${T}/good.conf" || fail 'refused list replaced the last good file'
LANCACHE_IP=999.1.1.1 "${GEN}" 2>/dev/null && fail 'dnsmasq --test failure should be refused'
cmp -s "${OUT}" "${T}/good.conf" || fail 'invalid list replaced the last good file'
DOMAINS_DIR=${T}/nowhere REPO_URL=file://${T}/missing-repo "${GEN}" 2>/dev/null \
  && fail 'a failed fetch should exit non-zero'
cmp -s "${OUT}" "${T}/good.conf" || fail 'failed fetch replaced the last good file'
[[ -z $(find "${T}/lancache" -name '.*') ]] || fail 'lancache-gen left a staging file behind'
ok 'lancache-gen keeps the last good file on small, invalid, or unfetchable input'

#--- lancache-toggle: hysteresis ---------------------------------------------
hb up
toggle; toggle
[[ ! -e ${ACTIVE} ]] || fail 'two heartbeats must not enable the overrides yet'
toggle
[[ -e ${ACTIVE} ]] || fail 'three heartbeats should enable the overrides'
cmp -s "${ACTIVE}" "${SRC}" || fail 'active copy differs from the source'
[[ ! -L ${ACTIVE} ]] || fail 'active overrides must be a copy, not a symlink'
[[ $(journal_count 'now resolve to the cache') == 1 && $(restarts) == 1 ]] \
  || fail 'enabling should log once and restart dnsmasq once'
ok 'heartbeat up x3 enables the overrides (one log line, one restart)'

[[ $(answer A lancache.steamcontent.com) == 192.168.1.11 ]] || fail 'A should be the cache'
[[ $(answer A eu.cdn.blizzard.com) == 192.168.1.11 ]] || fail 'wildcard subdomain should be the cache'
nodata AAAA lancache.steamcontent.com || fail 'AAAA should be NOERROR/NODATA'
nodata AAAA eu.cdn.blizzard.com || fail 'wildcard AAAA should be NOERROR/NODATA'
ttl=$(q +noall +answer A lancache.steamcontent.com | awk '{print $2}')
(( ttl <= 30 )) || fail "override TTL ${ttl} > 30"
[[ $(answer A example.net) == 198.51.100.9 && $(answer AAAA example.net) == 2001:db8::9 ]] \
  || fail 'unrelated names must keep A and AAAA'
q +noall +comments A ads.example.org | grep -q 'status: NXDOMAIN' \
  || fail 'hagezi-style block should still answer NXDOMAIN'
ok 'A -> 192.168.1.11 (TTL <= 30), AAAA -> NODATA; other names dual-stack; blocks intact'

hb down
toggle
[[ -e ${ACTIVE} ]] || fail 'one miss must not withdraw (hysteresis)'
toggle
[[ ! -e ${ACTIVE} ]] || fail 'two misses should withdraw the overrides'
[[ $(answer A lancache.steamcontent.com) == 203.0.113.7 ]] || fail 'A should come from upstream again'
[[ $(answer AAAA lancache.steamcontent.com) == 2001:db8::7 ]] || fail 'AAAA should come from upstream again'
[[ $(journal_count 'withdrawn: heartbeat missed 2 times') == 1 && $(restarts) == 2 ]] \
  || fail 'withdrawal should log once and restart once'
toggle; toggle
[[ $(wc -l < "${T}/journal") == 2 && $(restarts) == 2 ]] || fail 'steady state must stay silent'
ok 'heartbeat down x1 holds, x2 withdraws; upstream A/AAAA return; steady state is silent'

hb up
toggle
HEARTBEAT_URL=http://127.0.0.1:$(free_port)/lancache-heartbeat toggle
[[ $(cat "${STATE_DIR}/fails") == 1 && $(cat "${STATE_DIR}/passes") == 0 \
   && $(cat "${STATE_DIR}/last") == down* ]] \
  || fail 'an unreachable cache should count as a miss'
ok 'an unreachable heartbeat port counts as a miss'

#--- Manual flag and lancache-ctl --------------------------------------------
hb up
touch "${DISABLE_FLAG}"
toggle; toggle; toggle; toggle
[[ ! -e ${ACTIVE} ]] || fail 'the disable flag must beat a healthy heartbeat'
"${T}/bin/lancache-ctl" status > "${T}/ctl.out"
grep -q '^overrides : inactive' "${T}/ctl.out" && grep -q '^manual    : DISABLED' "${T}/ctl.out" \
  && grep -q 'passes=4 fails=0' "${T}/ctl.out" || { cat "${T}/ctl.out" >&2; fail 'ctl status is wrong'; }
ok 'disable flag + healthy heartbeat stays disabled; ctl status reports it'

"${T}/bin/lancache-ctl" enable > "${T}/ctl.out"
[[ -e ${ACTIVE} && ! -e ${DISABLE_FLAG} ]] || fail 'ctl enable should clear the flag and enable'
grep -q '^A         : 192.168.1.11$' "${T}/ctl.out" && grep -q '^AAAA      : (no answer)$' "${T}/ctl.out" \
  || { cat "${T}/ctl.out" >&2; fail 'ctl status lookup is wrong'; }
"${T}/bin/lancache-ctl" disable > /dev/null
[[ ! -e ${ACTIVE} && -e ${DISABLE_FLAG} ]] || fail 'ctl disable should withdraw now'
grep -q 'withdrawn: manually disabled' "${T}/journal" || fail 'manual withdrawal was not logged'
"${T}/bin/lancache-ctl" enable > /dev/null
[[ -e ${ACTIVE} ]] || fail 'ctl enable should re-enable'
ok 'lancache-ctl enable/disable apply immediately'

#--- Refresh while active ----------------------------------------------------
echo 'newcdn.example.org' >> "${FIX}/misc.txt"
fixture_commit 'add a domain'
before=$(restarts)
"${GEN}" > /dev/null 2>&1 || fail 'lancache-gen failed on the update'
grep -qx 'address=/newcdn.example.org/192.168.1.11' "${ACTIVE}" \
  || fail 'lancache-gen should refresh the live copy through the toggle'
[[ $(answer A newcdn.example.org) == 192.168.1.11 && $(restarts) == $(( before + 1 )) ]] \
  || fail 'refresh should restart dnsmasq once and serve the new domain'
grep -q 'overrides refreshed' "${T}/journal" || fail 'refresh was not logged'
ok 'lancache-gen update while active refreshes the live copy and restarts once'

#--- Overrides that break --test ---------------------------------------------
cp "${SRC}" "${T}/src.good"
cp "${ACTIVE}" "${T}/active.before"
echo 'address=/broken.example/999.1.1.1' >> "${SRC}"
lines=$(wc -l < "${T}/journal") before=$(restarts)
toggle && fail 'a source that fails dnsmasq --test should exit non-zero'
cmp -s "${ACTIVE}" "${T}/active.before" || fail 'the previous live copy should be put back'
[[ $(answer A lancache.steamcontent.com) == 192.168.1.11 && $(restarts) == "${before}" ]] \
  || fail 'a --test failure must leave the running dnsmasq alone'
toggle || fail 'a known-bad source should be skipped quietly'
[[ $(wc -l < "${T}/journal") == $(( lines + 1 )) ]] || fail 'the failure should log exactly once'
grep -q 'make the merged dnsmasq config fail --test' "${T}/journal" || fail 'wrong failure message'
cp "${T}/src.good" "${SRC}"
toggle
cmp -s "${ACTIVE}" "${SRC}" || fail 'the good source should be live again'
ok 'overrides that break --test: previous live copy kept, no restart, logged once'

#--- A failed restart on first enable ----------------------------------------
cat > "${T}/bin/fail-restart" <<'EOF'
#!/usr/bin/env bash
# A restart that leaves dnsmasq down, like a failed systemctl restart
[[ -s ${T}/dnsmasq.pid ]] && kill "$(cat "${T}/dnsmasq.pid")" 2>/dev/null
sleep 0.3
exit 1
EOF
chmod 755 "${T}/bin/fail-restart"
"${T}/bin/lancache-ctl" disable > /dev/null
rm -f "${DISABLE_FLAG}"
lines=$(wc -l < "${T}/journal")
RESTART_CMD=${T}/bin/fail-restart toggle && fail 'a failed restart should exit non-zero'
[[ ! -e ${ACTIVE} ]] || fail 'the overrides must come back out after a failed restart'
[[ $(answer A lancache.steamcontent.com) == 203.0.113.7 ]] \
  || fail 'RECOVER_CMD should bring dnsmasq back up without the overrides'
grep -q 'restored the previous config, retrying in 600 s' "${T}/journal" || fail 'restart failure not logged'
toggle || fail 'the hold-off should skip quietly'
[[ ! -e ${ACTIVE} && $(wc -l < "${T}/journal") == $(( lines + 1 )) ]] \
  || fail 'the hold-off should defer the retry without logging'
"${T}/bin/lancache-ctl" status > "${T}/ctl.out"
grep -q '^last try  : FAILED; retry after' "${T}/ctl.out" || fail 'ctl status should show the hold-off'
"${T}/bin/lancache-ctl" enable > /dev/null
[[ -e ${ACTIVE} ]] || fail 'lancache-ctl enable should clear the hold-off and retry'
ok 'failed restart: overrides removed, DNS recovered, retry held off until ctl enable'

#--- A config that is already broken -----------------------------------------
"${T}/bin/lancache-ctl" disable > /dev/null
rm -f "${DISABLE_FLAG}"
echo 'address=/admin.example/999.1.1.1' > "${T}/conf.d/zz-admin.conf"
before=$(restarts)
toggle && fail 'a broken baseline should exit non-zero'
[[ ! -e ${ACTIVE} && $(restarts) == "${before}" ]] \
  || fail 'nothing may be installed or restarted on top of a broken config'
grep -q 'already fails --test without new lancache overrides' "${T}/journal" || fail 'broken baseline not logged'
rm -f "${T}/conf.d/zz-admin.conf"
"${T}/bin/lancache-ctl" enable > /dev/null
[[ -e ${ACTIVE} ]] || fail 'enable should succeed once the config is fixed'
ok 'already-broken config: no install, no restart; enable retries once fixed'

#--- New cache IP while upstream is unreachable ------------------------------
mv "${FIX}" "${FIX}.away"
LANCACHE_IP=192.168.1.12 "${GEN}" > /dev/null 2> "${T}/gen.err" \
  && fail 'a failed fetch should still exit non-zero'
mv "${FIX}.away" "${FIX}"
grep -q 'rebuilding from the existing checkout' "${T}/gen.err" || fail 'fetch failure not reported'
grep -q -- '-> 192.168.1.12$' "${OUT}" || fail 'the new cache IP must reach the overrides without upstream'
[[ ! -e ${ACTIVE} ]] || fail 'overrides for another IP must be withdrawn'
grep -q 'targets 192.168.1.12, not 192.168.1.11' "${T}/journal" || fail 'IP mismatch not logged'
toggle
[[ ! -e ${ACTIVE} ]] || fail 'a source for another IP must never go live'
"${GEN}" > /dev/null 2>&1 || fail 'lancache-gen should succeed with upstream back'
toggle
[[ -e ${ACTIVE} ]] || fail 'matching overrides should go live again'
ok 'fetch failure rebuilds from the checkout; the toggle refuses overrides for another IP'

#--- Upstream history rewrite ------------------------------------------------
branch=$(git -C "${FIX}" symbolic-ref --short HEAD)
git -C "${FIX}" checkout -q --orphan rewritten
echo 'rewritten.example.org' >> "${FIX}/misc.txt"
fixture_commit 'rewritten history'
git -C "${FIX}" branch -q -M rewritten "${branch}"
"${GEN}" > /dev/null 2>&1 || fail 'lancache-gen should survive an upstream force-push'
grep -qx 'address=/rewritten.example.org/192.168.1.11' "${OUT}" \
  || fail 'the rewritten upstream should be picked up'
ok 'lancache-gen follows an upstream history rewrite (fetch + hard reset)'

#--- Locking -----------------------------------------------------------------
passes=$(cat "${STATE_DIR}/passes")
flock "${LOCK}" sleep 2 &
holder=$!
sleep 0.3
start=${SECONDS}
toggle || fail 'a busy lock should exit 0'
(( SECONDS - start < 2 )) || fail 'a busy lock should exit immediately'
[[ $(cat "${STATE_DIR}/passes") == "${passes}" ]] || fail 'the locked-out run must not probe'
wait "${holder}"
ok 'a held lock makes the toggle exit quietly without probing'

"${T}/bin/lancache-ctl" disable > /dev/null
rm -f "${DISABLE_FLAG}"
before=$(restarts) lines=$(journal_count 'now resolve to the cache')
pids=()
for _ in 1 2 3 4 5 6; do
  RESTART_DELAY=1 "${T}/bin/lancache-toggle" > /dev/null &
  pids+=("$!")
done
wait "${pids[@]}"
[[ $(restarts) == $(( before + 1 )) && $(journal_count 'now resolve to the cache') == $(( lines + 1 )) ]] \
  || fail "concurrent runs: $(( $(restarts) - before )) restarts (want 1)"
ok 'six concurrent toggles: exactly one acts'

[[ -z $(find "${T}/conf.d" -name '.*') ]] || fail 'the toggle left a staging file behind'
echo "PASS: ${PASSED} lancache checks"
