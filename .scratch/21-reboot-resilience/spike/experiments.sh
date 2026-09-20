#!/usr/bin/env bash
# Epic 21 ticket #01 — experiments on how Docker treats a pre-populated DOCKER-USER chain.
# RUNS ONLY inside the disposable podman container built from ./Containerfile (see ./run.sh).
# The container has its own network namespace, so nothing here can touch the workstation's
# or the production VPS's firewall. Output is a plain-text evidence log.
set -uo pipefail

# Fail CLOSED: if the guard cannot be loaded or does not pass, stop. (A bare `source` that fails would
# leave spike_guard undefined and the script would carry on — on a host that means flushing its firewall.)
[[ -f /run/.containerenv ]] || { echo "refusing: not inside a podman container" >&2; exit 2; }
[[ -r /spike/guard.sh ]] || { echo "refusing: /spike/guard.sh not readable" >&2; exit 2; }
source /spike/guard.sh || exit 2
declare -F spike_guard >/dev/null || { echo "refusing: spike_guard not defined" >&2; exit 2; }
spike_guard || exit 2

LOG=/var/log/dockerd-spike.log
MARK_A='-p tcp --dport 61001 -m comment --comment spike-marker-A -j DROP'
MARK_B='-p tcp --dport 61002 -m comment --comment spike-marker-B -j ACCEPT'

hdr() { printf '\n==== %s ====\n' "$*"; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

start_dockerd() {
  : > "$LOG"
  nohup dockerd --storage-driver=vfs --exec-opt native.cgroupdriver=cgroupfs \
        --host=unix:///var/run/docker.sock >>"$LOG" 2>&1 &
  echo $! > /run/dockerd.pid
  for _ in $(seq 1 120); do docker info >/dev/null 2>&1 && return 0; sleep 0.25; done
  echo "dockerd did not become ready; log tail:"; tail -15 "$LOG"; return 1
}
stop_dockerd() {  # wait for the process to really exit (a running container makes shutdown take ~10 s)
  local pid; pid=$(cat /run/dockerd.pid 2>/dev/null || true)
  [[ -n $pid ]] && kill "$pid" 2>/dev/null
  for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  rm -f /var/run/docker.pid; sleep 1
}
chain_dump() { local fam=$1; ${fam} -S DOCKER-USER 2>&1 | sed 's/^/    /'; }
forward_dump() { local fam=$1; ${fam} -S FORWARD 2>&1 | grep -E 'DOCKER-USER|DOCKER-FORWARD|policy|-P' | sed 's/^/    /'; }

hdr "environment (differences from the production VPS are disclosed in the ticket notes)"
docker --version; iptables --version; ip6tables --version; echo "kernel: $(uname -r)  (VPS runs its own kernel; this is the workstation's)"
echo "storage driver: vfs (nesting)  |  ip_forward at start: $(sysctl -n net.ipv4.ip_forward)"

hdr "E1  fresh daemon start, no pre-existing chain: what does Docker create?"
iptables -F 2>/dev/null; ip6tables -F 2>/dev/null
iptables -X DOCKER-USER 2>/dev/null; ip6tables -X DOCKER-USER 2>/dev/null
start_dockerd || exit 1
echo "  v4 DOCKER-USER after start:"; chain_dump iptables
echo "  v6 DOCKER-USER after start:"; chain_dump ip6tables
echo "  v4 FORWARD hooks:"; forward_dump iptables
echo "  v6 FORWARD hooks:"; forward_dump ip6tables

hdr "E2  chain pre-populated BEFORE daemon start (simulates loading rules before docker.service)"
stop_dockerd
# Docker leaves its own chains behind on stop; clear everything so this is a true cold start.
for f in iptables ip6tables; do $f -F; $f -X 2>/dev/null; $f -t nat -F; $f -t nat -X 2>/dev/null; done
for f in iptables ip6tables; do
  $f -N DOCKER-USER
  $f -A DOCKER-USER $MARK_A
  $f -A DOCKER-USER $MARK_B
done
echo "  before start (v4):"; chain_dump iptables
start_dockerd || exit 1
echo "  after start (v4):"; chain_dump iptables
echo "  after start (v6):"; chain_dump ip6tables
for f in iptables ip6tables; do
  n=$($f -S DOCKER-USER | grep -c 'spike-marker'); echo "  $f markers surviving daemon START: $n/2"
done
echo "  FORWARD jump to DOCKER-USER present (v4)? $(iptables -S FORWARD | grep -c 'jump\|-j DOCKER-USER')"

hdr "E3  daemon RESTART with populated chain (also: FORWARD jump neither duplicated nor lost)"
stop_dockerd
echo "  after daemon STOP (v4 markers): $(iptables -S DOCKER-USER 2>&1 | grep -c spike-marker)/2"
start_dockerd || exit 1
for f in iptables ip6tables; do
  n=$($f -S DOCKER-USER | grep -c 'spike-marker'); echo "  $f markers surviving daemon RESTART: $n/2"
  echo "  $f FORWARD jumps to DOCKER-USER after restart: $($f -S FORWARD | grep -c -- '-j DOCKER-USER') (want exactly 1)"
done

hdr "E4  network create / container run with populated chain — does Docker modify DOCKER-USER?"
docker pull -q docker.io/library/busybox:latest >/dev/null 2>&1 && echo "  image pulled" || echo "  (image pull failed; skipping E4/E7)"
if docker image inspect busybox >/dev/null 2>&1; then
  docker network create spike-net >/dev/null
  docker run -d --rm --name spike-web --network spike-net -p 8081:80 busybox sh -c 'while true; do echo -e "HTTP/1.1 200 OK\r\n\r\nok" | nc -l -p 80; done' >/dev/null
  echo "  v4 DOCKER-USER after container start:"; chain_dump iptables
  docker rm -f spike-web >/dev/null 2>&1
  echo "  E4b: daemon RESTART while a restart-policy container is RUNNING (chain must still be intact)"
  docker run -d --restart unless-stopped --name spike-web-r -p 8083:80 busybox sh -c 'while true; do echo ok | nc -l -p 80; done' >/dev/null
  stop_dockerd; start_dockerd || exit 1
  for _ in $(seq 1 100); do docker ps -q --filter name=spike-web-r | grep -q . && break; sleep 0.2; done
  for f in iptables ip6tables; do
    echo "    $f markers: $($f -S DOCKER-USER | grep -c 'spike-marker')/2, FORWARD jumps: $($f -S FORWARD | grep -c -- '-j DOCKER-USER'), container running again: $(docker ps -q --filter name=spike-web-r | grep -c .)"
  done
  docker rm -f spike-web-r >/dev/null 2>&1
fi

hdr "E5  iptables-restore --noflush: scope (replaces ONLY the declared chain) and idempotence"
# Snapshot another chain (Docker's own) so we can prove it is untouched.
before_docker=$(iptables -S DOCKER | md5sum)
cat > /tmp/rules.v4 <<EOF
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i br+ -m comment --comment "bridge return" -j RETURN
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -p tcp --dport 8081 -m comment --comment new-rule -j ACCEPT
COMMIT
EOF
iptables-restore --noflush < /tmp/rules.v4 && echo "  restore ok"
echo "  DOCKER-USER after restore:"; chain_dump iptables
echo "  old markers gone (replaced, not appended): $(iptables -S DOCKER-USER | grep -c spike-marker) (want 0)"
echo "  Docker's own DOCKER chain untouched: $([[ "$(iptables -S DOCKER | md5sum)" == "$before_docker" ]] && echo yes || echo NO)"
echo "  FORWARD jump intact: $(iptables -S FORWARD | grep -c 'DOCKER-USER')"
echo "  run twice -> identical chain?"
a=$(iptables -S DOCKER-USER | md5sum); iptables-restore --noflush < /tmp/rules.v4; b=$(iptables -S DOCKER-USER | md5sum)
[[ "$a" == "$b" ]] && echo "    identical" || echo "    DIFFERENT"

hdr "E6  probe test: is a canary rule ever observed absent while the chain is being replaced?"
# NOTE: this is a sampling probe (~30 ms per fork), so it is weak evidence about sub-millisecond gaps.
# Atomicity itself rests on nftables' transactional commit (iptables-restore submits one netlink
# transaction); this test shows the contrast with flush-then-append, not a proof of atomicity.
iptables-restore --noflush < /tmp/rules.v4
missing_file=/tmp/missing.count; echo 0 > $missing_file
( while [[ ! -f /tmp/stop-probe ]]; do
    iptables -C DOCKER-USER -p tcp --dport 8081 -m comment --comment new-rule -j ACCEPT 2>/dev/null \
      || echo $(( $(cat $missing_file) + 1 )) > $missing_file
  done ) &
probe=$!
for _ in $(seq 1 300); do iptables-restore --noflush < /tmp/rules.v4; done
touch /tmp/stop-probe; wait $probe 2>/dev/null; rm -f /tmp/stop-probe
echo "  300 --noflush replacements: $(cat $missing_file) probes found the canary absent (want 0)"
echo "  for contrast, flush-then-append (the CURRENT role behavior):"
echo 0 > $missing_file
( while [[ ! -f /tmp/stop-probe ]]; do
    iptables -C DOCKER-USER -p tcp --dport 8081 -m comment --comment new-rule -j ACCEPT 2>/dev/null \
      || echo $(( $(cat $missing_file) + 1 )) > $missing_file
  done ) &
probe=$!
for _ in $(seq 1 300); do
  iptables -F DOCKER-USER; iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A DOCKER-USER -p tcp --dport 8081 -m comment --comment new-rule -j ACCEPT
done
touch /tmp/stop-probe; wait $probe 2>/dev/null; rm -f /tmp/stop-probe
echo "  300 flush+append cycles: $(cat $missing_file) probes found the canary absent (a count of failed probes, not of cycles)"

hdr "done (E7, the exposure-window measurement, lives in e7-window.sh)"
