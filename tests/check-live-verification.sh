#!/usr/bin/env bash
# Epic 21 ticket #05 guard: the read-only live verification script (scripts/verify-live.sh).
#
# Runs the WHOLE script against a fake `ssh` that replays a healthy VPS and several broken ones, and asserts:
#   1. it passes on a healthy VPS and FAILS (non-zero, naming the problem) on each fault the epic exists to
#      catch — one scenario per check: emptied / drifted / reordered chains, a stopped container, a wrong
#      restart policy, a boot unit that is disabled / inactive / mis-ordered, Docker/Tailscale/UFW disabled or
#      inactive, a host that cannot resolve — and, with fake `ip`/`curl`/`timeout`, the workstation-side probes
#      (public ports, the outside-in restricted-port probe and its INCONCLUSIVE cases, the tailnet routes);
#      it must never turn "nothing was checked" (unreadable config, no positive control) into a PASS;
#   1b. a dead SSH connection stops the run at once (UFW rate-limits SSH; more attempts extend the block);
#   2. it is READ-ONLY: every command it sent to the fake ssh is on its own allowlist (audited after the run),
#      and its --self-test proves mutating / chained commands are refused before any connection;
#   3. it never reports an inconclusive or skipped check as a pass, and prints no address.
# What this CANNOT verify: the real VPS, real systemd, the real network — the operator runs it live, and the
# drill is attended (ticket #06). The fake `ip`/`curl`/`timeout` prove the script's decisions, not the network.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false
SCRIPT=scripts/verify-live.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "== live verification script guard (epic 21 #05) =="

[[ -x "$SCRIPT" ]] || fail "$SCRIPT must be executable"
bash -n "$SCRIPT" || fail "$SCRIPT has a syntax error"
bash "$SCRIPT" --self-test >"$TMP/selftest.out" 2>&1 || { cat "$TMP/selftest.out" >&2; fail "--self-test failed"; }
cat "$TMP/selftest.out"

# The allowlist itself must contain no mutating verbs.
if sed -n '/^ALLOWED_REMOTE=(/,/^)/p' "$SCRIPT" | grep -qE 'restart|stop|start |enable |disable|reload|-F|-A DOCKER|-X|-P |-I |-D |-R |rm |tee|sed -i|reboot|shutdown|up -d|pause|kill'; then
  fail "the allowlist contains a mutating verb"
fi
# ssh is only ever invoked through remote() (no stray direct ssh calls).
if grep -vE '^\s*#' "$SCRIPT" | grep -nE '(^|[^_A-Za-z])ssh ' | grep -vE 'SSH_CMD|HERMES_VERIFY_SSH|--ssh|ssh\.(socket|service)|SSH starts|SSH is not|ssh -o|an ssh option' >/dev/null; then
  fail "the script calls ssh outside remote()"
fi
# One multiplexed connection: UFW's `limit 22/tcp` (6 new connections / 30 s) locked the operator out when the
# script opened a fresh connection per check (found on its first live run).
grep -q 'BatchMode=yes' "$SCRIPT" && grep -q -- '-O exit' "$SCRIPT" || fail "the script must never prompt (BatchMode=yes) and must close its shared connection (-O exit)"
grep -q 'ControlMaster=auto' "$SCRIPT" && grep -q 'ControlPersist=' "$SCRIPT" && grep -q 'ControlPath=' "$SCRIPT" \
  || fail "the script must reuse ONE SSH connection (ControlMaster) — a connection per check trips UFW's SSH rate limit"
echo "allowlist has no mutating verbs; ssh only via remote(); one multiplexed connection OK"

# ---- fixtures: a rendered ruleset + a fake ssh that replays a scenario -------------------------------
ansible-playbook tests/test_docker_user_rules.yml -e "render_dir=$TMP/render" >"$TMP/render.log" 2>&1 || { cat "$TMP/render.log" >&2; fail "could not render the rules fixture"; }
SERVICES="$(python3 -c 'import yaml;print(" ".join(yaml.safe_load(open("roles/docker/defaults/main.yml"))["docker_enabled_services"]))')"
cat > "$TMP/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
# fake ssh: $1 = host, $2 = the remote command; replays $FAKE_SCENARIO and logs every command received.
echo "$2" >> "$FAKE_LOG"
R="$FAKE_RENDER"; S="${FAKE_SCENARIO:-healthy}"
[[ "$S" == unreachable ]] && exit 255
# the connection drops AFTER the preflight succeeded: every later command fails with ssh's own status 255
[[ "$S" == drops-after-preflight && "$2" != "tailscale ip -4" ]] && exit 255
live_chain() {  # what `iptables -S DOCKER-USER` prints: -N line + the rules (hosts carry their /32 mask)
  echo "-N DOCKER-USER"
  [[ "$S" == empty-chain ]] && return
  local skip=""; [[ "$S" == drifted-rule ]] && skip='--dport 3000'
  grep -E '^-A DOCKER-USER' "$1" | { if [[ "$S" == reordered-rules ]]; then tac; else cat; fi; } \
    | { if [[ -n "$skip" ]]; then grep -v -- "$skip"; else cat; fi; } | sed -E 's#(-s [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) #\1/32 #'
}
enabled() { [[ "$S" == "$1-disabled" ]] && echo disabled || echo enabled; }
case "$2" in
  "sudo cat /etc/hermes-vps/firewall/docker-user.v4.rules") cat "$R/docker-user.v4.rules" ;;
  "sudo cat /etc/hermes-vps/firewall/docker-user.v6.rules") cat "$R/docker-user.v6.rules" ;;
  "sudo iptables -S DOCKER-USER")  live_chain "$R/docker-user.v4.rules" ;;
  "sudo ip6tables -S DOCKER-USER") live_chain "$R/docker-user.v6.rules" ;;
  "systemctl is-enabled hermes-docker-user-firewall.service") [[ "$S" == unit-not-enabled ]] && echo disabled || echo enabled ;;
  "systemctl is-active hermes-docker-user-firewall.service") [[ "$S" == unit-inactive ]] && echo inactive || echo active ;;
  "systemctl is-active tailscaled") [[ "$S" == tailscaled-inactive ]] && echo inactive || echo active ;;
  "systemctl show hermes-docker-user-firewall.service -p Before --value")
     # slow-output: the answer arrives on the first line and MORE lines follow after a pause. A `remote | grep -q` would
     # exit early and SIGPIPE this writer (a false FAIL under pipefail); the script must capture first, then test.
     if [[ "$S" == slow-output ]]; then echo "docker.service shutdown.target"; sleep 0.3; echo "more.target"; sleep 0.3; echo "x.target"
     else [[ "$S" == not-before-docker ]] && echo "shutdown.target" || echo "docker.service shutdown.target"; fi ;;
  "systemctl show docker.service -p After --value")
     if [[ "$S" == slow-output ]]; then echo "network-online.target containerd.service tailscaled.service"; sleep 0.3; echo "more.target"; sleep 0.3; echo "x.target"
     else [[ "$S" == docker-not-after-tailscaled ]] && echo "network-online.target containerd.service" || echo "network-online.target containerd.service tailscaled.service"; fi ;;
  "systemctl show docker.service -p Requires --value") echo "containerd.service" ;;
  "systemctl is-enabled docker") enabled docker ;;
  "systemctl is-enabled tailscaled") enabled tailscaled ;;
  "systemctl is-enabled ufw") enabled ufw ;;
  "systemctl is-enabled ssh.socket") echo enabled ;;
  "systemctl is-enabled ssh.service") echo disabled ;;
  "sudo ufw status") if [[ "$S" == slow-output ]]; then echo "Status: active"; sleep 0.3; echo; echo "To Action From"; sleep 0.3; echo "22/tcp LIMIT Anywhere"
                     else [[ "$S" == ufw-inactive ]] && echo "Status: inactive" || echo "Status: active"; fi ;;
  "getent hosts example.com") [[ "$S" == no-resolve ]] && exit 2; echo "93.184.216.34 example.com" ;;
  "cat /etc/resolv.conf") echo "# resolv.conf(5) file generated by tailscale"; echo "nameserver 100.100.100.100" ;;
  "tailscale ip -4") [[ "$S" == no-tsip ]] || echo 100.64.0.1 ;;
  "ip -4 route get 1.1.1.1") [[ "$S" == no-pub ]] || echo "1.1.1.1 via 198.51.100.1 dev eth0 src 198.51.100.7 uid 1000" ;;
  "docker inspect --format "*) names="${2##*\' }"   # everything after the closing quote of the format string
     for n in $names; do
       st=running; pol=unless-stopped
       [[ "$S" == stopped-caddy && "$n" == caddy ]] && st=exited
       [[ "$S" == wrong-policy && "$n" == caddy ]] && pol=no
       [[ "$S" == missing-container && "$n" == owntracks ]] && continue   # docker inspect skips what it cannot find...
       echo "/$n $st $pol"
     done
     [[ "$S" == missing-container ]] && exit 1 ;;                         # ...and exits non-zero
  *) echo "fake-ssh: unexpected command: $2" >&2; exit 99 ;;
esac
FAKE
chmod +x "$TMP/fake-ssh"
# Fake workstation tools for the reachability probes: `timeout` answers the TCP probe from $FAKE_OPEN_PORTS,
# `ip` reports $FAKE_DEV, `curl` returns $FAKE_CURL_CODE (or $FAKE_CURL_BAD for one label as label:code).
mkdir -p "$TMP/bin" "$TMP/sysfs/eth0" "$TMP/sysfs/wg-vpn"
echo 1 > "$TMP/sysfs/eth0/type"; echo 65534 > "$TMP/sysfs/wg-vpn/type"
cat > "$TMP/bin/timeout" <<'F'
#!/usr/bin/env bash
arg="${*: -1}"; port="${arg##*/}"; port="${port%\"}"; ip="${arg#*/dev/tcp/}"; ip="${ip%%/*}"
if [[ "$ip" == 203.0.113.1 ]]; then   # the unroutable control address: only an INTERCEPTING network answers there
  [[ " ${FAKE_INTERCEPT_PORTS:-} " == *" $port "* ]]
else
  [[ " $FAKE_OPEN_PORTS ${FAKE_INTERCEPT_PORTS:-} " == *" $port "* ]]
fi
F
cat > "$TMP/bin/ip" <<'F'
#!/usr/bin/env bash
case "$*" in
  "route get "*) echo "$3 dev ${FAKE_DEV:-eth0} src 192.0.2.5" ;;
  "-d link show "*) [[ "${FAKE_DEV:-eth0}" == wg-vpn ]] && echo "link/none wireguard" || echo "link/ether aa:bb:cc:dd:ee:ff" ;;
  *) exit 1 ;;
esac
F
cat > "$TMP/bin/curl" <<'F'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == --resolve ]] && next=1 && continue; [[ -n "${next:-}" ]] && { label="${a%%.*}"; res="$a"; break; }; done
# the probe must go to the VPS's TAILSCALE address on 443 (never its public one): --resolve <label>.<domain>:443:<tailscale ip>
[[ "$res" == "$label.example.test:443:100.64.0.1" ]] || { echo "fake curl: unexpected --resolve '$res'" >&2; printf '999'; exit 0; }
[[ -n "${FAKE_CURL_BAD:-}" && "${FAKE_CURL_BAD%%:*}" == "$label" ]] && { printf '%s' "${FAKE_CURL_BAD##*:}"; exit 0; }
printf '%s' "${FAKE_CURL_CODE:-200}"
F
chmod +x "$TMP/bin/timeout" "$TMP/bin/ip" "$TMP/bin/curl"

# Nothing sensitive is printed, on ANY path: no IP address, host or domain in the output of any run below.
no_leak() {  # no_leak <label>
  if grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' <<<"$OUT"; then echo "$OUT" >&2; fail "$1: the output contains an IP address"; fi
  if grep -q 'fixture-host\|example\.test' <<<"$OUT"; then echo "$OUT" >&2; fail "$1: the output contains the host or the domain"; fi
}
run() {  # run <scenario> -> sets OUT and RC
  : > "$TMP/cmds.log"
  set +e
  OUT="$(FAKE_SCENARIO="$1" FAKE_RENDER="$TMP/render" FAKE_LOG="$TMP/cmds.log" HERMES_VERIFY_SSH="$TMP/fake-ssh" HERMES_VERIFY_SKIP_LOCAL=1 \
        bash "$SCRIPT" fixture-host 2>&1)"; RC=$?
  set -e; no_leak "scenario '$1'"
}
runl() {  # runl <scenario> [ENV=VAL...] -> like run, but WITH the workstation-side probes (fake ip/curl/timeout)
  local sc="$1"; shift
  : > "$TMP/cmds.log"
  set +e
  OUT="$(env FAKE_SCENARIO="$sc" FAKE_RENDER="$TMP/render" FAKE_LOG="$TMP/cmds.log" HERMES_VERIFY_SSH="$TMP/fake-ssh" ${SKIPENV-HERMES_VERIFY_SKIP_LOCAL=0} \
        HERMES_VERIFY_SYSFS_NET="$TMP/sysfs" SILVERBULLET_DOMAIN=example.test PATH="$TMP/bin:$PATH" \
        FAKE_OPEN_PORTS="80 443 8443" FAKE_DEV=eth0 "$@" bash "$SCRIPT" fixture-host 2>&1)"; RC=$?
  set -e; no_leak "scenario '$sc' $*"
}
expect_fail() { run "$1"; [[ $RC -ne 0 ]] || { echo "$OUT" >&2; fail "scenario '$1': the script passed but must FAIL"; }
                grep -q -- "$2" <<<"$OUT" || { echo "$OUT" >&2; fail "scenario '$1': failed but did not report '$2'"; }; }

run healthy
[[ $RC -eq 0 ]] || { echo "$OUT" >&2; fail "the healthy VPS did not pass (rc=$RC)"; }
grep -q '0 FAILED' <<<"$OUT" || fail "healthy summary must say 0 FAILED"
# every rendered rule for both families was compared, and every enabled service checked
for s in $SERVICES; do grep -q "PASS         $s: running, restart=unless-stopped" <<<"$OUT" || fail "healthy: service '$s' was not verified"; done
grep -q 'v4: live chain equals the rendering' <<<"$OUT" && grep -q 'v6: live chain equals the rendering' <<<"$OUT" || fail "healthy: both families' chains must be compared"
echo "healthy VPS passes; every enabled service and both rule families verified"

expect_fail empty-chain      'chain is EMPTY'
expect_fail drifted-rule     'differs from the rendering'
expect_fail stopped-caddy    'caddy: state=exited'
expect_fail wrong-policy     'caddy: state=running restart=no'
expect_fail unit-not-enabled 'is not enabled at boot'
expect_fail unit-inactive        'is not active'
expect_fail tailscaled-inactive  'tailscaled is not active'
expect_fail ufw-inactive         'UFW is not active'
expect_fail no-resolve           'cannot resolve names'
expect_fail docker-disabled      'docker is not enabled at boot'
expect_fail tailscaled-disabled  'tailscaled is not enabled at boot'
expect_fail ufw-disabled         'ufw is not enabled at boot'
expect_fail not-before-docker    'not ordered before docker.service'
expect_fail docker-not-after-tailscaled 'not ordered after tailscaled'
# the same rules in a different order are a DIFFERENT firewall (an early DROP shadows a later ACCEPT)
expect_fail reordered-rules      'differs from the rendering'
grep -q '0 and 0 = same rules in a different order' <<<"$OUT" || fail "a pure reordering must be named as such"
# ONE missing container must be reported for itself, and the others must still be verified individually
run missing-container; [[ $RC -ne 0 ]] || fail "a missing container must fail the run"
grep -q 'FAIL         owntracks: container not found' <<<"$OUT" || { echo "$OUT" >&2; fail "the missing container was not reported for itself"; }
grep -q 'PASS         caddy: running, restart=unless-stopped' <<<"$OUT" || fail "one missing container discarded the results for all the others"
echo "each fault the epic exists to catch is reported and fails the run"

# Nothing sensitive is printed: no IP address anywhere in the output, healthy or drifted (rule lines carry the
# Syncplay friend's address). The fixture rendering DOES contain an allowlisted address, so this has teeth.
grep -qE '^-A DOCKER-USER -s [0-9.]+ ' "$TMP/render/docker-user.v4.rules" || fail "fixture: the rendering must contain a source-address rule for the no-IP-in-output check to mean anything"
for sc in healthy drifted-rule reordered-rules empty-chain; do runl "$sc"; done   # (no_leak runs inside every runner)
echo "no address, host or domain is printed on any path (rule drift is reported as counts)"

# A dead SSH connection stops the run at the FIRST failed attempt (exit 2), it does not make every check retry.
run unreachable
[[ $RC -eq 2 ]] || { echo "$OUT" >&2; fail "an unreachable host must abort with status 2 (got $RC)"; }
grep -q 'ABORT' <<<"$OUT" || fail "an unreachable host must say it aborted"
[[ "$(grep -c . "$TMP/cmds.log")" -le 2 ]] || fail "an unreachable host made $(grep -c . "$TMP/cmds.log") connection attempts — UFW's SSH rate limit would block the operator"
grep -q ' PASS ' <<<"$OUT" && fail "an unreachable host must not report any pass"
run drops-after-preflight
[[ $RC -eq 2 ]] && grep -q 'ABORT' <<<"$OUT" || { echo "$OUT" >&2; fail "a connection that drops mid-run must abort with status 2 (got $RC)"; }
[[ "$(grep -c . "$TMP/cmds.log")" -le 3 ]] || fail "a dropped connection made $(grep -c . "$TMP/cmds.log") attempts — it must stop at the first failure"
echo "an unreachable host, or a connection that drops mid-run, aborts after one failed attempt"
# a host that could be parsed as an ssh option is refused before anything is sent
: > "$TMP/cmds.log"; set +e
OUT="$(FAKE_LOG="$TMP/cmds.log" HERMES_VERIFY_SSH="$TMP/fake-ssh" bash "$SCRIPT" -oProxyCommand=x 2>&1)"; RC=$?; set -e
[[ $RC -eq 2 && ! -s "$TMP/cmds.log" ]] || fail "a host starting with '-' must be refused before any ssh call (rc=$RC)"

# "Nothing was checked" is never a pass: break the config the script reads, in a scratch copy of the tree.
mk_tree() { rm -rf "$TMP/tree"; mkdir -p "$TMP/tree/scripts" "$TMP/tree/group_vars/all"; cp "$SCRIPT" "$TMP/tree/scripts/"
            cp --parents roles/docker/defaults/main.yml roles/*/defaults/main.yml "$TMP/tree/" 2>/dev/null || true
            cp group_vars/all/main.yml "$TMP/tree/group_vars/all/"; }
run_tree() {  # run_tree <extra env...>
  set +e
  OUT="$(env FAKE_SCENARIO=healthy FAKE_RENDER="$TMP/render" FAKE_LOG="$TMP/cmds.log" HERMES_VERIFY_SSH="$TMP/fake-ssh" HERMES_VERIFY_SKIP_LOCAL=0 \
        HERMES_VERIFY_SYSFS_NET="$TMP/sysfs" SILVERBULLET_DOMAIN=example.test PATH="$TMP/bin:$PATH" FAKE_OPEN_PORTS="80 443 8443" FAKE_DEV=eth0 \
        "$@" bash "$TMP/tree/scripts/verify-live.sh" fixture-host 2>&1)"; RC=$?
  set -e; no_leak "broken-config tree"
}
mk_tree; sed -i 's/^docker_enabled_services:/docker_enabled_services_renamed:/' "$TMP/tree/roles/docker/defaults/main.yml"
run_tree; [[ $RC -ne 0 ]] && grep -q 'cannot determine the expected container set' <<<"$OUT" || { echo "$OUT" >&2; fail "an unreadable container list must FAIL, not verify zero containers"; }
mk_tree; sed -i "s/'{{ conduit_port }}'/'{{ nonexistent_port }}'/; s/{{ conduit_port }}/{{ nonexistent_port }}/" "$TMP/tree/group_vars/all/main.yml"
grep -q nonexistent_port "$TMP/tree/group_vars/all/main.yml" || fail "fixture mutation did not apply"
run_tree; [[ $RC -ne 0 ]] && grep -q 'cannot read the restricted ports' <<<"$OUT" || { echo "$OUT" >&2; fail "an unresolvable restricted port must FAIL, not pass with nothing probed"; }
grep -q 'PASS.*restricted' <<<"$OUT" && fail "a restricted-port PASS was printed although no port was probed"
echo "unreadable config fails loudly; nothing-checked is never a pass"

# Workstation-side probes (fake timeout/ip/curl): decisions, not the network.
runl healthy
[[ $RC -eq 0 ]] || { echo "$OUT" >&2; fail "healthy with local probes must pass (rc=$RC)"; }
NRP=$(python3 -c 'import yaml;print(len(yaml.safe_load(open("group_vars/all/main.yml"))["docker_published_restricted_ports"]))')
grep -q "PASS         $NRP of $NRP restricted TCP ports verified unreachable" <<<"$OUT" || { echo "$OUT" >&2; fail "the restricted probe must report how many ports it probed"; }
for l in adguard monitor owntracks-ui; do grep -q "PASS         tailnet route $l\.<domain> answers (200)" <<<"$OUT" || fail "tailnet route $l was not probed"; done
runl healthy FAKE_OPEN_PORTS="80 443 8443 3000"
[[ $RC -ne 0 ]] && grep -q 'restricted TCP port(s) reachable from the internet: 3000' <<<"$OUT" || { echo "$OUT" >&2; fail "an exposed restricted port must FAIL the run"; }
for rp in $(python3 -c 'import yaml;d=yaml.safe_load(open("group_vars/all/main.yml"));print(" ".join(str(d["conduit_port"] if "conduit" in str(p) else p) for p in d["docker_published_restricted_ports"]))'); do
  runl healthy FAKE_OPEN_PORTS="80 443 8443 $rp"
  [[ $RC -ne 0 ]] && grep -q "restricted TCP port(s) reachable from the internet: $rp" <<<"$OUT" || { echo "$OUT" >&2; fail "an exposed restricted port $rp must FAIL (every one is probed, including the templated conduit port)"; }
done
# a network that intercepts a port (answers on ANY address) makes that port INCONCLUSIVE — not a leak, not a pass
runl healthy FAKE_INTERCEPT_PORTS="53"
[[ $RC -eq 0 ]] && grep -q 'INCONCLUSIVE restricted TCP port(s) 53 answer on an address that cannot be a real host too' <<<"$OUT" \
  && grep -q 'PASS.*6 of 7 restricted TCP ports verified' <<<"$OUT" && ! grep -q 'FAIL.*restricted' <<<"$OUT" || { echo "$OUT" >&2; fail "an intercepted port must be INCONCLUSIVE, the others verified (rc=$RC)"; }
runl healthy FAKE_INTERCEPT_PORTS="53" FAKE_OPEN_PORTS="80 443 8443 3000"
[[ $RC -ne 0 ]] && grep -q 'restricted TCP port(s) reachable from the internet: 3000' <<<"$OUT" && grep -q 'INCONCLUSIVE restricted TCP port(s) 53' <<<"$OUT" || { echo "$OUT" >&2; fail "a real leak must still FAIL next to an intercepted port (rc=$RC)"; }
runl healthy FAKE_INTERCEPT_PORTS="3000 8008 8642 9119 8090 3001 53"
grep -q 'PASS.*restricted' <<<"$OUT" && { echo "$OUT" >&2; fail "with every port intercepted there must be no restricted-port PASS"; }
runl healthy FAKE_OPEN_PORTS="80 443"
[[ $RC -ne 0 ]] && grep -q 'FAIL         public ingress port 8443 does not answer' <<<"$OUT" || fail "a dead public port must FAIL"
runl healthy FAKE_OPEN_PORTS=""
grep -q 'INCONCLUSIVE outside-in probe.*no positive control' <<<"$OUT" || { echo "$OUT" >&2; fail "with no public port answering, the restricted probe must be INCONCLUSIVE"; }
grep -q 'PASS.*restricted' <<<"$OUT" && fail "restricted-port PASS without a positive control"
runl healthy FAKE_DEV=wg-vpn
grep -q "INCONCLUSIVE outside-in probe.*goes through 'wg-vpn'" <<<"$OUT" || { echo "$OUT" >&2; fail "a tunnel route must make the outside-in probe INCONCLUSIVE"; }
grep -q 'PASS.*restricted' <<<"$OUT" && fail "restricted-port PASS over a VPN route"
runl healthy FAKE_CURL_CODE=000
grep -q 'INCONCLUSIVE tailnet route' <<<"$OUT" && ! grep -q 'PASS         tailnet route' <<<"$OUT" || { echo "$OUT" >&2; fail "curl 000 must be INCONCLUSIVE, never a pass"; }
[[ $RC -eq 0 ]] || fail "an unreachable tailnet (000) is not a failure of the VPS"
runl healthy FAKE_CURL_BAD=monitor:502
[[ $RC -ne 0 ]] && grep -q "FAIL         tailnet route monitor.<domain> returned '502'" <<<"$OUT" || { echo "$OUT" >&2; fail "a 5xx tailnet route must FAIL"; }
runl healthy HERMES_VERIFY_TIMEOUT_BIN=no-such-timeout-cmd
grep -q "INCONCLUSIVE workstation-side probes: no 'timeout' command" <<<"$OUT" && ! grep -q 'PASS.*restricted' <<<"$OUT" || { echo "$OUT" >&2; fail "without 'timeout' the probes must be INCONCLUSIVE (every port would look closed)"; }
# only the tailnet_only routes are probed: not the MFA-gated public ones
labels_out=$(python3 - <<'PY'
import glob,yaml
out=[]
for f in sorted(glob.glob("roles/*/defaults/main.yml")):
    d=yaml.safe_load(open(f)) or {}
    for k,v in d.items():
        if k.endswith("_gateway_publish") and isinstance(v,list): out += [r["host"] for r in v if not r.get("tailnet_only")]
print(" ".join(out))
PY
)
runl healthy
for l in $labels_out; do grep -q "tailnet route $l\.<domain>" <<<"$OUT" && fail "route '$l' is not tailnet_only but was probed as tailnet-gated"; done
# Slow, multi-line answers must not cause a false FAIL (SIGPIPE under pipefail): captured first, then tested.
run slow-output
[[ $RC -eq 0 ]] && grep -q 'PASS         UFW is active' <<<"$OUT" && grep -q 'ordered Before=docker.service' <<<"$OUT" && grep -q 'ordered after tailscaled' <<<"$OUT" \
  || { echo "$OUT" >&2; fail "slow multi-line output caused a false FAIL — a remote | grep -q under pipefail?"; }
# and no check may pipe a remote() call into grep -q/head (SIGPIPE) where its status is used
if grep -vE '^\s*#' "$SCRIPT" | grep -nE 'remote [^|]*\| *grep -q' >/dev/null; then fail "a check pipes remote() into 'grep -q' (SIGPIPE false-FAIL under pipefail)"; fi
# An address the script cannot read is INCONCLUSIVE, never a pass; an unset SKIP variable does not skip.
runl no-pub
grep -q 'INCONCLUSIVE could not determine the' <<<"$OUT" && ! grep -q 'PASS         public ingress' <<<"$OUT" || { echo "$OUT" >&2; fail "no public address: the public/restricted probes must be INCONCLUSIVE"; }
runl no-tsip
grep -q 'INCONCLUSIVE tailnet-gated routes: could not read' <<<"$OUT" && ! grep -q 'PASS         tailnet route' <<<"$OUT" || { echo "$OUT" >&2; fail "no Tailscale address: the tailnet routes must be INCONCLUSIVE"; }
SKIPENV= runl healthy   # HERMES_VERIFY_SKIP_LOCAL not set at all
{ [[ $RC -eq 0 ]] && grep -q 'PASS         public ingress port 443 answers' <<<"$OUT" && ! grep -q 'SKIPPED      workstation-side' <<<"$OUT"; } \
  || { echo "$OUT" >&2; fail "with HERMES_VERIFY_SKIP_LOCAL unset the workstation-side probes must run"; }
mk_tree; for f in "$TMP"/tree/roles/*/defaults/main.yml; do sed -i 's/tailnet_only:/tailnet_only_renamed:/' "$f"; done
run_tree; [[ $RC -ne 0 ]] && grep -q 'cannot read the tailnet-only routes' <<<"$OUT" || { echo "$OUT" >&2; fail "unreadable tailnet routes must FAIL, not verify none"; }
# 404 is what Caddy's (tailnet_only) matcher returns when it does NOT see a tailnet source: never a pass
for bad in adguard:404 monitor:403 owntracks-ui:500; do
  runl healthy FAKE_CURL_BAD=$bad
  [[ $RC -ne 0 ]] && grep -q "FAIL         tailnet route ${bad%%:*}\.<domain> returned '${bad##*:}'" <<<"$OUT" || { echo "$OUT" >&2; fail "tailnet route answering ${bad##*:} must FAIL"; }
done
for good in 200 302 401; do
  runl healthy FAKE_CURL_CODE=$good
  [[ $RC -eq 0 ]] && grep -q "PASS         tailnet route adguard\.<domain> answers ($good)" <<<"$OUT" || { echo "$OUT" >&2; fail "tailnet route answering $good must PASS"; }
done
runl healthy SILVERBULLET_DOMAIN=
grep -q 'SKIPPED      tailnet-gated routes' <<<"$OUT" || fail "no domain -> the tailnet routes must be SKIPPED, not passed"
echo "workstation-side probes: exposed/dead ports fail; VPN route, no positive control, curl 000 are INCONCLUSIVE, never a pass"

# Skipped / inconclusive checks are reported and are NOT passes.
run healthy
grep -q 'SKIPPED' <<<"$OUT" || fail "skipped checks must be reported"
grep -qE '[0-9]+ passed, 0 FAILED, [0-9]+ inconclusive, [1-9][0-9]* skipped' <<<"$OUT" || fail "summary must count skipped checks separately from passes"
grep -q 'NOT passes' <<<"$OUT" || fail "summary must say skipped/inconclusive are not passes"
echo "skipped/inconclusive checks are counted separately, never as passes OK"

# Audit: everything the script sent to ssh (across the last healthy run) is on its own allowlist.
n=0; while IFS= read -r c; do
  [[ -z "$c" ]] && continue; n=$((n+1))
  [[ "$(bash "$SCRIPT" --allowed "$c")" == yes ]] || fail "the script sent a command that is not read-only/allowlisted: $c"
done < "$TMP/cmds.log"
(( n > 15 )) || fail "audit saw too few commands ($n) — the fake ssh was not exercised"
echo "read-only audit OK ($n remote commands sent, all allowlisted)"
# The drill procedure: the parts a reviewer found missing or dangerous stay in the document.
DOC=docs/reboot-resilience.md
for needle in 'Late-dependency observation' 'Starting Docker anyway exposes the restricted ports' 'existing\* SSH session' \
              'no faster than every 40 s' 'provider console' 'hermes-docker-user-firewall' 'RestartCount'; do
  grep -q -- "$needle" "$DOC" || fail "$DOC (reboot drill) is missing: $needle"
done
# every command, switch and drop-in the drill names exists in the roles it refers to
for ref in tailscale_docker_user_firewall_fail_closed:roles/tailscale/defaults/main.yml host_dns_resolver_owner_enabled:group_vars/all/main.yml \
           10-hermes-firewall-fail-closed.conf:roles/tailscale/tasks/main.yml /usr/local/sbin/hermes-docker-user-rules:roles/tailscale/defaults/main.yml; do
  grep -q -- "${ref%%:*}" "$DOC" && grep -q -- "${ref%%:*}" "${ref#*:}" || fail "the drill refers to '${ref%%:*}' which is not defined in ${ref#*:}"
done
echo "drill procedure covers late-dependency observation, the rollback exposure warning and real names OK"
echo "live verification script guard OK"
