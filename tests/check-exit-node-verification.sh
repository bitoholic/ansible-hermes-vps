#!/usr/bin/env bash
# Epic 23 ticket #06 guard: the read-only live verification script (scripts/verify-exit-nodes.sh).
#
# Runs the WHOLE script against a fake `ssh` that replays a healthy 2-location fleet and several
# broken ones, and asserts:
#   1. it passes on a healthy fleet and FAILS (non-zero, naming the problem) on each fault the ticket
#      exists to catch: a stopped/misconfigured container, a pair attached to an extra network, an
#      offline/non-advertising Tailscale node, an exit IP that equals the VPS's own public IP, an
#      exit country that doesn't match the configured region, IPv6 forwarding enabled, a missing
#      Tailscale forward chain, a missing return-path rule (either family), a reachable trust
#      boundary, and a DOCKER-USER entry naming the feature; it must never turn "nothing was
#      checked" into a PASS (admin-console approval, the other-tailnet-device probe and the route/
#      rule baseline are INCONCLUSIVE/SKIPPED, not passes, when they cannot be determined);
#   2. it is READ-ONLY: every command sent to the fake ssh is on its own allowlist (audited after the
#      run), and --self-test proves mutating/chained commands are refused before any connection;
#   3. it never reports an inconclusive or skipped check as a pass, and prints no address.
# What this CANNOT verify: the real VPS, real Tailscale, the real network — the operator runs it
# live, and the phone test / tunnel-down test / admin-approval confirmation are ticket #07's job.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
SCRIPT=scripts/verify-exit-nodes.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "== exit-node live verification script guard (epic 23 #06) =="

[[ -x "$SCRIPT" ]] || fail "$SCRIPT must be executable"
bash -n "$SCRIPT" || fail "$SCRIPT has a syntax error"
bash "$SCRIPT" --self-test >"$TMP/selftest.out" 2>&1 || { cat "$TMP/selftest.out" >&2; fail "--self-test failed"; }
cat "$TMP/selftest.out"

# Registered with the deploy wrapper's script mode (epic 22), per the ticket's own AC.
grep -qE '^verify-exit-nodes\s+scripts/verify-exit-nodes\.sh$' scripts/registered-scripts.conf \
  || fail "scripts/registered-scripts.conf does not register verify-exit-nodes"

# The allowlist itself must contain no mutating verbs.
if sed -n '/^ALLOWED_REMOTE=(/,/^)/p' "$SCRIPT" | grep -qE 'restart|stop|start |enable |disable|reload| up | down|flush|-F |-A DOCKER| -X | -P | -I | -D | -R |rm -|reboot|shutdown|pause|kill|tailscale (up|down|set)'; then
  fail "the allowlist contains a mutating verb"
fi
if grep -vE '^\s*#' "$SCRIPT" | grep -nE '(^|[^_A-Za-z])ssh ' | grep -vE 'SSH_CMD|HERMES_VERIFY_SSH|ssh -o|an ssh option' >/dev/null; then
  fail "the script calls ssh outside remote()"
fi
grep -q 'BatchMode=yes' "$SCRIPT" && grep -q -- '-O exit' "$SCRIPT" || fail "the script must never prompt and must close its shared connection"
grep -q 'ControlMaster=auto' "$SCRIPT" && grep -q 'ControlPersist=' "$SCRIPT" && grep -q 'ControlPath=' "$SCRIPT" \
  || fail "the script must reuse ONE SSH connection (ControlMaster) — UFW rate-limits SSH"
echo "allowlist has no mutating verbs; ssh only via remote(); one multiplexed connection OK"

# ---- fixture: a fake ssh that replays a 2-location (london/warsaw) fleet -------------------------
cat > "$TMP/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
# fake ssh: $1 = host, $2 = the remote command; replays $FAKE_SCENARIO and logs every command received.
echo "$2" >> "$FAKE_LOG"
S="${FAKE_SCENARIO:-healthy}"
[[ "$S" == unreachable ]] && exit 255
locbroken="${FAKE_BROKEN_LOCATION:-}"
case "$2" in
  "tailscale ip -4") echo 100.64.0.1 ;;
  "ip -4 route show") echo "default via 198.51.100.1 dev eth0"; echo "198.51.100.0/24 dev eth0 src 198.51.100.7" ;;
  "ip -4 rule show") echo "0: from all lookup local"; echo "32766: from all lookup main"; echo "32767: from all lookup default" ;;
  "ip -6 route show") echo "default via 2001:db8::1 dev eth0" ;;
  "ip -6 rule show") echo "0: from all lookup local"; echo "32766: from all lookup main" ;;
  "sudo iptables -S DOCKER-USER")
    echo "-N DOCKER-USER"
    [[ "$S" == docker-user-has-exit-node-entry ]] && echo '-A DOCKER-USER -d 172.20.0.0/16 -j ACCEPT -m comment --comment "exit-node"'
    echo "-A DOCKER-USER -j RETURN" ;;
  "sudo ip6tables -S DOCKER-USER") echo "-N DOCKER-USER"; echo "-A DOCKER-USER -j RETURN" ;;
  "docker inspect --format '{{.Name}} {{.State.Status}} {{.HostConfig.RestartPolicy.Name}}' "*)
    names="${2##*\' }"
    for n in $names; do
      short="${n#exit-node-}"; loc="${short%%-*}"
      st=running; pol=unless-stopped
      if [[ "$loc" == "$locbroken" ]]; then
        [[ "$S" == container-stopped ]] && st=exited
        [[ "$S" == wrong-policy ]] && pol=no
      fi
      echo "/$n $st $pol"
    done ;;
  "docker inspect --format '{{.State.Pid}}' exit-node-"*"-tunnel")
    loc="${2#*exit-node-}"; loc="${loc%-tunnel*}"
    echo "1000$( [[ "$loc" == london ]] && echo 1 || echo 2 )" ;;
  "docker inspect --format '{{json .NetworkSettings.Networks}}' exit-node-"*)
    loc="${2#*exit-node-}"; loc="${loc%%-*}"
    if [[ "$S" == extra-network && "$loc" == "$locbroken" ]]; then
      echo '{"exit_nodes_net":{},"internal":{}}'
    else
      echo '{"exit_nodes_net":{}}'
    fi ;;
  "docker inspect --format '{{json .NetworkSettings.Ports}}' exit-node-"*)
    loc="${2#*exit-node-}"; loc="${loc%%-*}"
    if [[ "$S" == published-port && "$loc" == "$locbroken" ]]; then
      echo '{"8888/tcp":[{"HostIp":"0.0.0.0","HostPort":"8888"}]}'
    else
      echo '{"8888/tcp":null}'   # an image-level EXPOSE with no host binding must not count as published
    fi ;;
  "docker exec exit-node-"*"-node tailscale status --self --json")
    loc="${2#*exit-node-}"; loc="${loc%%-*}"
    online=true; exitopt=true
    [[ "$S" == not-online && "$loc" == "$locbroken" ]] && online=false
    [[ "$S" == not-advertising && "$loc" == "$locbroken" ]] && exitopt=false
    printf '{"Self":{"Online":%s,"ExitNodeOption":%s}}' "$online" "$exitopt" ;;
  "docker exec exit-node-"*"-tunnel curl -s --max-time "*" https://ifconfig.co/json")
    loc="${2#*exit-node-}"; loc="${loc%%-*}"
    ip=203.0.113.50; country="United Kingdom"; [[ "$loc" == warsaw ]] && country="Poland"
    if [[ "$loc" == "$locbroken" ]]; then
      [[ "$S" == exit-ip-equals-vps ]] && ip=198.51.100.7
      [[ "$S" == wrong-country ]] && country="Germany"
      [[ "$S" == geoip-unreachable ]] && exit 1
    fi
    printf '{"ip":"%s","country":"%s"}' "$ip" "$country" ;;
  "sudo nsenter -t "*" -n sysctl -n net.ipv6.conf.all.forwarding")
    pid="${2#*-t }"; pid="${pid%% *}"
    loc=london; [[ "$pid" == 10002 ]] && loc=warsaw
    if [[ "$S" == ipv6-forwarding-enabled && "$loc" == "$locbroken" ]]; then echo 1; else echo 0; fi ;;
  "sudo nsenter -t "*" -n nft list ruleset")
    pid="${2#*-t }"; pid="${pid%% *}"
    loc=london; [[ "$pid" == 10002 ]] && loc=warsaw
    if [[ "$S" == missing-forward-chain && "$loc" == "$locbroken" ]]; then echo "table ip filter { }"
    else echo "table ip filter { chain ts-forward { } chain ts-postrouting { } }"; fi ;;
  "sudo nsenter -t "*" -n ip rule show")
    pid="${2#*-t }"; pid="${pid%% *}"
    loc=london; [[ "$pid" == 10002 ]] && loc=warsaw
    if [[ "$S" == missing-return-rule-v4 && "$loc" == "$locbroken" ]]; then echo "0: from all lookup local"
    else echo "50: from all to 100.64.0.0/10 lookup 52"; fi ;;
  "sudo nsenter -t "*" -n ip -6 rule show")
    pid="${2#*-t }"; pid="${pid%% *}"
    loc=london; [[ "$pid" == 10002 ]] && loc=warsaw
    if [[ "$S" == missing-return-rule-v6 && "$loc" == "$locbroken" ]]; then echo "0: from all lookup local"
    else echo "50: from all to fd7a:115c:a1e0::/48 lookup 52"; fi ;;
  "docker exec exit-node-"*"-sidecar nc -zv -w5 "*)
    loc="${2#*exit-node-}"; loc="${loc%%-*}"
    target="${2##* }"
    if [[ "$S" == trust-boundary-broken && "$loc" == "$locbroken" ]]; then exit 0; fi
    [[ "$target" == "999" || "$2" == *"9.9.9.9"* ]] && exit 0   # HERMES_VERIFY_OTHER_TAILNET_IP fixture: reachable-by-design test
    exit 1 ;;
  *) echo "fake-ssh: unexpected command: $2" >&2; exit 99 ;;
esac
FAKE
chmod +x "$TMP/fake-ssh"

no_leak() {
  if grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' <<<"$OUT"; then echo "$OUT" >&2; fail "$1: the output contains an IP address"; fi
  if grep -q 'fixture-host' <<<"$OUT"; then echo "$OUT" >&2; fail "$1: the output contains the host"; fi
}
run() {  # run <scenario> [broken-location] -> sets OUT and RC
  : > "$TMP/cmds.log"
  set +e
  OUT="$(FAKE_SCENARIO="$1" FAKE_BROKEN_LOCATION="${2:-}" FAKE_LOG="$TMP/cmds.log" HERMES_VERIFY_SSH="$TMP/fake-ssh" \
        bash "$SCRIPT" fixture-host 2>&1)"; RC=$?
  set -e; no_leak "scenario '$1'"
}
expect_fail() { run "$1" "${3:-}"; [[ $RC -ne 0 ]] || { echo "$OUT" >&2; fail "scenario '$1': the script passed but must FAIL"; }
                grep -q -- "$2" <<<"$OUT" || { echo "$OUT" >&2; fail "scenario '$1': failed but did not report '$2'"; }; }

run healthy
[[ $RC -eq 0 ]] || { echo "$OUT" >&2; fail "the healthy fleet did not pass (rc=$RC)"; }
grep -q '0 FAILED' <<<"$OUT" || fail "healthy summary must say 0 FAILED"
for loc in london warsaw; do
  grep -q "PASS         exit-node-$loc-tunnel: running, restart=unless-stopped" <<<"$OUT" || fail "healthy: $loc tunnel was not verified"
  grep -q "PASS         exit-node-$loc-tunnel: no published host port" <<<"$OUT" || fail "healthy: $loc tunnel published-port check missing (or a plain image EXPOSE was wrongly treated as published)"
  grep -q "PASS         $loc: Tailscale node is online" <<<"$OUT" || fail "healthy: $loc online check missing"
  grep -q "PASS         $loc: exit IP differs from the VPS's own public IP" <<<"$OUT" || fail "healthy: $loc exit-IP check missing"
  grep -q "PASS         $loc: exit country (.*) matches the configured region" <<<"$OUT" || fail "healthy: $loc country check missing"
  grep -q "PASS         $loc: IPv6 forwarding is denied" <<<"$OUT" || fail "healthy: $loc IPv6-forwarding check missing"
  grep -q "PASS         $loc: IPv4 return-path rule present" <<<"$OUT" || fail "healthy: $loc IPv4 return-path check missing"
  grep -q "PASS         $loc: IPv6 return-path rule present" <<<"$OUT" || fail "healthy: $loc IPv6 return-path check missing"
  grep -q "PASS         $loc: the VPS's own tailnet address is unreachable from inside the pair" <<<"$OUT" || fail "healthy: $loc trust-boundary check missing"
  grep -q "INCONCLUSIVE $loc: admin-console approval cannot be confirmed" <<<"$OUT" || fail "healthy: $loc must report approval as INCONCLUSIVE, never a pass"
done
echo "healthy 2-location fleet passes; every check present per location"

expect_fail container-stopped              'exit-node-london-tunnel: state=exited'                london
expect_fail wrong-policy                   'exit-node-london-tunnel: state=running restart=no'    london
expect_fail extra-network                  'attached to 2 network(s), expected exactly 1'         london
expect_fail published-port                 'has 1 published host port(s)'                          london
expect_fail not-online                     'london: Tailscale node is not online'                 london
expect_fail not-advertising                'london: node does not advertise exit-node capability' london
expect_fail exit-ip-equals-vps             "exit IP equals the VPS's own public IP"               london
expect_fail wrong-country                  "exit country is 'Germany'"                            london
expect_fail ipv6-forwarding-enabled        "IPv6 forwarding is '1'"                               london
expect_fail missing-forward-chain          'forward/postrouting chains are missing'               london
expect_fail missing-return-rule-v4         'IPv4 return-path rule is missing'                     london
expect_fail missing-return-rule-v6         'IPv6 return-path rule is missing'                     london
expect_fail trust-boundary-broken          'trust boundary is broken'                             london
expect_fail docker-user-has-exit-node-entry 'contains an entry naming the exit-node feature'
echo "each fault the ticket exists to catch is reported and fails the run"

# a GeoIP fetch failure is INCONCLUSIVE, never a fail or a pass
run geoip-unreachable london
[[ $RC -eq 0 ]] || { echo "$OUT" >&2; fail "a GeoIP fetch failure must not fail the whole run"; }
grep -q 'INCONCLUSIVE london: could not reach ifconfig.co' <<<"$OUT" || { echo "$OUT" >&2; fail "GeoIP failure must be reported INCONCLUSIVE"; }
echo "a third-party GeoIP lookup failure is INCONCLUSIVE, never a fail or a pass"

# no other-tailnet-device IP supplied: SKIPPED, not a pass; supplied and reachable: FAIL
run healthy
grep -q 'SKIPPED      london: no other tailnet device to probe' <<<"$OUT" || fail "with no HERMES_VERIFY_OTHER_TAILNET_IP, the probe must be SKIPPED"
: > "$TMP/cmds.log"; set +e
OUT="$(FAKE_SCENARIO=trust-boundary-broken FAKE_BROKEN_LOCATION=x FAKE_LOG="$TMP/cmds.log" HERMES_VERIFY_SSH="$TMP/fake-ssh" HERMES_VERIFY_OTHER_TAILNET_IP=9.9.9.9 \
      bash "$SCRIPT" fixture-host 2>&1)"; RC=$?; set -e
[[ $RC -ne 0 ]] && grep -q "another tailnet device is reachable" <<<"$OUT" || { echo "$OUT" >&2; fail "a reachable other-tailnet-device probe must FAIL"; }
echo "the other-tailnet-device probe is SKIPPED by default, and has teeth when an address is supplied"

# route/rule baseline: INCONCLUSIVE without a recorded baseline, compared when one is supplied
run healthy
grep -q 'INCONCLUSIVE no recorded baseline' <<<"$OUT" || fail "without a recorded baseline the route/rule check must be INCONCLUSIVE"
: > "$TMP/cmds.log"; set +e
OUT="$(FAKE_SCENARIO=healthy FAKE_LOG="$TMP/cmds.log" HERMES_VERIFY_SSH="$TMP/fake-ssh" HERMES_VERIFY_ROUTE4_BASELINE=1 HERMES_VERIFY_RULE4_BASELINE=1 \
      bash "$SCRIPT" fixture-host 2>&1)"; RC=$?; set -e
[[ $RC -ne 0 ]] && grep -q 'route count (2) does not match the recorded baseline (1)' <<<"$OUT" || { echo "$OUT" >&2; fail "a mismatched recorded baseline must FAIL (rc=$RC)"; }
echo "route/rule baseline: INCONCLUSIVE with none recorded, and has teeth once one is supplied"

# an unreachable host aborts at the first failed attempt
run unreachable
[[ $RC -eq 2 ]] || { echo "$OUT" >&2; fail "an unreachable host must abort with status 2 (got $RC)"; }
grep -q 'ABORT' <<<"$OUT" || fail "an unreachable host must say it aborted"
[[ "$(grep -c . "$TMP/cmds.log")" -le 1 ]] || fail "an unreachable host made $(grep -c . "$TMP/cmds.log") connection attempts"
echo "an unreachable host aborts after one failed attempt"

# nothing sensitive printed on any path
for sc in healthy container-stopped exit-ip-equals-vps trust-boundary-broken; do run "$sc" london; done
echo "no address or host is printed on any path"

# skipped/inconclusive checks are counted separately, never as passes
run healthy
grep -qE '[0-9]+ passed, 0 FAILED, [0-9]+ inconclusive, [1-9][0-9]* skipped' <<<"$OUT" || fail "summary must count skipped/inconclusive separately from passes"
grep -q 'NOT passes' <<<"$OUT" || fail "summary must say skipped/inconclusive are not passes"
grep -q "NOT verified here (attended, ticket #07)" <<<"$OUT" || fail "the summary must plainly state the phone test / tunnel-down test / admin approval are not verified here"
echo "skipped/inconclusive checks are counted separately, never as passes; attended-only items are stated plainly"

# Audit: everything the script sent to ssh (across the last healthy run) is on its own allowlist.
n=0; while IFS= read -r c; do
  [[ -z "$c" ]] && continue; n=$((n+1))
  [[ "$(bash "$SCRIPT" --allowed "$c")" == yes ]] || fail "the script sent a command that is not read-only/allowlisted: $c"
done < "$TMP/cmds.log"
(( n > 10 )) || fail "audit saw too few commands ($n) — the fake ssh was not exercised"
echo "read-only audit OK ($n remote commands sent, all allowlisted)"

echo "exit-node live verification script guard OK"
