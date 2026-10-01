#!/usr/bin/env bash
# Read-only live verification of the Windscribe exit-node fleet (epic 23 ticket #06).
#
#   scripts/verify-exit-nodes.sh [host]           host = argument, else $TARGET_HOST
#   scripts/verify-exit-nodes.sh --self-test      prove the read-only guarantee and the parsing logic (no network)
#
# Run it any time you doubt an exit location. It CHANGES NOTHING on the VPS or inside any pair's
# containers: every remote command goes through remote(), which refuses (before any connection is
# made) anything that is not on the allowlist below or that contains a shell metacharacter — the
# same defence-in-depth design as scripts/verify-live.sh (epic 21 #05), which this script's style is
# modelled on. `--self-test` proves that refusal without ever touching the network.
#
# Exit status: 0 = no check FAILED (inconclusive/skipped checks are reported, never counted as
# passes); 1 = at least one FAIL.
#
# Run through the deploy wrapper's script mode (epic 22) the encrypted store supplies TARGET_HOST;
# nothing here waits for epic 22 — export it by hand otherwise.
#
# Never printed: the host, any tailnet or public IP address (exit-country/exit-IP evidence is shown
# only as "differs from the VPS's own public IP: yes/no" and the resolved country name, never the
# address itself; rule/route output is shown as counts only).
#
# What this CANNOT do (attended steps, ticket #07's phone test): confirm a real client's exit-node
# picker shows the location and actually routes through it, or that pulling the tunnel down live
# recovers exactly as ticket #01 found. It also cannot confirm Tailscale ADMIN-CONSOLE approval of
# an exit node specifically (as opposed to it merely ADVERTISING) — this repo provisions no
# Tailscale API key, and a node's own local status looks identical whether or not an admin has
# approved it; only a client's own exit-node picker (the phone test) can tell the difference. This
# script verifies "advertised, online, no local health warnings" and reports approval status as
# INCONCLUSIVE, honestly, rather than guessing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ONE multiplexed SSH connection for the whole run — same UFW-rate-limit rationale as verify-live.sh.
MUX_DIR=""
if [[ -n "${HERMES_VERIFY_SSH:-}" ]]; then
  SSH_CMD="$HERMES_VERIFY_SSH"
else
  MUX_DIR="$(mktemp -d)"
  SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$MUX_DIR/cm -o ControlPersist=60"
fi
cleanup() {
  if [[ -n "$MUX_DIR" ]]; then
    # shellcheck disable=SC2086
    [[ -n "${HOST:-}" ]] && $SSH_CMD -O exit "$HOST" >/dev/null 2>&1
    rm -rf "$MUX_DIR"
  fi
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------------
# The remote-command allowlist: the ONLY things this script may run on the VPS. All read-only —
# including every docker exec, which only ever runs a read-only diagnostic inside the container
# (nc -z, wget -O- GET, tailscale status, sysctl -n, ip/nft listing) never a mutation. wget, not
# curl: gluetun's image is Alpine-based and has no curl (confirmed live — a first version of this
# script used curl and every exit-IP/country check silently came back INCONCLUSIVE as a result).
# ---------------------------------------------------------------------------------------------------
ALLOWED_REMOTE=(
  "^docker ps -a --format '\{\{\.Names\}\} \{\{\.State\}\}'$"
  "^docker inspect --format '\{\{\.Name\}\} \{\{\.State\.Status\}\} \{\{\.HostConfig\.RestartPolicy\.Name\}\}' [a-z0-9-]+( [a-z0-9-]+)*$"
  "^docker inspect --format '\{\{\.State\.Pid\}\}' exit-node-[a-z0-9-]+-tunnel$"
  "^docker inspect --format '\{\{json \.NetworkSettings\.Networks\}\}' exit-node-[a-z0-9-]+-(tunnel|node|sidecar)$"
  "^docker inspect --format '\{\{json \.NetworkSettings\.Ports\}\}' exit-node-[a-z0-9-]+-(tunnel|node|sidecar)$"
  "^docker inspect --format '\{\{\.HostConfig\.NetworkMode\}\}' exit-node-[a-z0-9-]+-(node|sidecar)$"
  '^docker exec exit-node-[a-z0-9-]+-node tailscale status --self --json$'
  '^docker exec exit-node-[a-z0-9-]+-tunnel wget -q -T [0-9]+ -O - https://ifconfig\.co/json$'
  '^docker exec exit-node-[a-z0-9-]+-(node|sidecar) nc -zv -w[0-9]+ [0-9a-fA-F:.]+ [0-9]+$'
  '^sudo nsenter -t [0-9]+ -n sysctl -n net\.ipv6\.conf\.all\.forwarding$'
  '^sudo nsenter -t [0-9]+ -n nft list ruleset$'
  '^sudo nsenter -t [0-9]+ -n ip rule show$'
  '^sudo nsenter -t [0-9]+ -n ip -6 rule show$'
  '^sudo iptables -S DOCKER-USER$'
  '^sudo ip6tables -S DOCKER-USER$'
  '^ip -4 route show$'
  '^ip -4 rule show$'
  '^ip -6 route show$'
  '^ip -6 rule show$'
  '^tailscale ip -4$'
  '^tailscale status --self --json$'
  '^sudo sysctl -n net\.ipv4\.ip_forward$'
  '^sudo sysctl -n net\.ipv6\.conf\.all\.forwarding$'
)
METACHARS_RE='[;&|<>`$
]'

command_allowed() {  # <cmd> -> 0 if it may be sent
  local cmd="$1" re
  [[ "$cmd" =~ $METACHARS_RE ]] && return 1
  for re in "${ALLOWED_REMOTE[@]}"; do [[ "$cmd" =~ $re ]] && return 0; done
  return 1
}
exec 9>&2
abort_unreachable() {
  echo >&9
  echo "ABORT: cannot reach the host over SSH (connection failed). Not retrying — UFW rate-limits SSH and further attempts extend the block. Wait ~40 s, then try once." >&9
  exit 2
}
trap abort_unreachable USR1
remote() {  # <cmd>: run a read-only command on the VPS, or refuse
  command_allowed "$1" || { echo "REFUSED (not read-only / not allowlisted): $1" >&2; return 97; }
  local rc
  # shellcheck disable=SC2086
  $SSH_CMD "$HOST" "$1"; rc=$?
  if (( rc == 255 )); then kill -USR1 $$; sleep 1; fi
  return $rc
}

# ---------------------------------------------------------------------------------------------------
# Result bookkeeping
# ---------------------------------------------------------------------------------------------------
PASS=0; FAIL=0; INCONCLUSIVE=0; SKIP=0
ok()   { echo "  PASS         $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL         $*"; FAIL=$((FAIL+1)); }
inc()  { echo "  INCONCLUSIVE $*"; INCONCLUSIVE=$((INCONCLUSIVE+1)); }
skip() { echo "  SKIPPED      $*"; SKIP=$((SKIP+1)); }
info() { echo "  info         $*"; }
section() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------------------------------
# Pure helpers (unit-tested by --self-test)
# ---------------------------------------------------------------------------------------------------
configured_locations() {  # the real exit_nodes list -> "name|region|city" one per line (region/city
                          # can contain spaces, e.g. "United Kingdom" — a plain space-split would
                          # misparse that, so a delimiter the values cannot contain is used instead)
  python3 -c '
import yaml,sys
for e in yaml.safe_load(open(sys.argv[1]))["exit_nodes"]:
    print("%s|%s|%s" % (e["name"], e["region"], e["city"]))' "$REPO_ROOT/roles/exit_nodes/defaults/main.yml"
}
route_table_and_priority() {  # -> "table priority" from the real defaults, so the script never hardcodes them twice
  python3 -c '
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
print(d["exit_nodes_return_route_table"], d["exit_nodes_return_route_priority"])' "$REPO_ROOT/roles/exit_nodes/defaults/main.yml"
}
tailnet_subnets() {  # -> "v4subnet v6subnet" from the real group_vars, same reason
  python3 -c '
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
print(d["tailscale_subnet"], d["tailscale_subnet_v6"])' "$REPO_ROOT/group_vars/all/main.yml"
}
region_matches_country() {  # <region> <reported-country> -> 0 if they plausibly mean the same place
  # An exact (case-insensitive) match against the configured region, e.g. "United Kingdom". This
  # is a real, if unlikely, false-FAIL risk: if ifconfig.co ever changed its country-name format
  # (an abbreviation, a subdivision) this would report a wrong-country FAIL rather than
  # distinguishing "genuinely wrong location" from "string format drifted" — worth widening if
  # that's ever observed in practice; ifconfig.co has used full country names consistently so far,
  # matching this repo's own exit_nodes.region convention exactly.
  local region="${1,,}" country="${2,,}"
  [[ "$region" == "$country" ]]
}

# ---------------------------------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------------------------------
self_test() {
  local n=0 bad_n=0
  t() { n=$((n+1)); if "$@"; then :; else bad_n=$((bad_n+1)); echo "SELF-TEST FAIL: $*" >&2; fi; }
  not() { ! "$@"; }
  refuses() { ! command_allowed "$1"; }
  allows()  { command_allowed "$1"; }
  # things the script legitimately sends
  t allows "docker ps -a --format '{{.Names}} {{.State}}'"
  t allows "docker inspect --format '{{.Name}} {{.State.Status}} {{.HostConfig.RestartPolicy.Name}}' exit-node-london-tunnel exit-node-london-node exit-node-london-sidecar"
  t allows "docker inspect --format '{{.State.Pid}}' exit-node-london-tunnel"
  t allows "docker inspect --format '{{json .NetworkSettings.Networks}}' exit-node-london-tunnel"
  t allows "docker inspect --format '{{json .NetworkSettings.Ports}}' exit-node-london-tunnel"
  t allows "docker inspect --format '{{.HostConfig.NetworkMode}}' exit-node-london-node"
  t allows 'docker exec exit-node-london-node tailscale status --self --json'
  t allows 'docker exec exit-node-london-tunnel wget -q -T 10 -O - https://ifconfig.co/json'
  t allows 'docker exec exit-node-london-sidecar nc -zv -w5 100.64.0.1 22'
  t allows 'sudo nsenter -t 12345 -n sysctl -n net.ipv6.conf.all.forwarding'
  t allows 'sudo nsenter -t 12345 -n nft list ruleset'
  t allows 'sudo nsenter -t 12345 -n ip rule show'
  t allows 'sudo nsenter -t 12345 -n ip -6 rule show'
  t allows 'sudo iptables -S DOCKER-USER'
  t allows 'sudo ip6tables -S DOCKER-USER'
  t allows 'ip -4 route show'
  t allows 'ip -4 rule show'
  t allows 'ip -6 route show'
  t allows 'ip -6 rule show'
  t allows 'tailscale ip -4'
  t allows 'tailscale status --self --json'
  t allows 'sudo sysctl -n net.ipv4.ip_forward'
  t allows 'sudo sysctl -n net.ipv6.conf.all.forwarding'
  # the allowlist must not have been widened beyond the exact shapes above
  for c in 'docker exec exit-node-london-tunnel sh' 'docker exec exit-node-london-node tailscale up' \
           'docker exec exit-node-london-node tailscale status' 'docker exec exit-node-london-tunnel wget -O - https://ifconfig.co/json' \
           'docker exec exit-node-london-sidecar nc -l 22' 'sudo nsenter -t 12345 -n ip route add default via 1.2.3.4' \
           'sudo nsenter -t 12345 -n nft flush ruleset' 'sudo iptables -S' 'sudo iptables -L' 'ip route' 'ip rule' \
           'docker exec exit-node-london-tunnel cat /etc/shadow' 'docker inspect exit-node-london-tunnel' \
           'docker logs exit-node-london-tunnel' 'tailscale status' 'sudo sysctl -w net.ipv4.ip_forward=1' \
           'sudo sysctl -n net.ipv4.ip_forward; reboot'; do
    t refuses "$c"
  done
  # the mutating / dangerous things it must never send
  for c in 'docker rm -f exit-node-london-tunnel' 'docker stop exit-node-london-tunnel' 'docker restart exit-node-london-tunnel' \
           'docker compose up -d' 'docker exec exit-node-london-node tailscale down' 'docker exec exit-node-london-node tailscale set --exit-node=' \
           'sudo nsenter -t 12345 -n ip rule del' 'sudo nsenter -t 12345 -n iptables -F' 'sudo reboot' 'sudo systemctl restart docker' \
           'tailscale set --advertise-exit-node' 'tailscale up'; do
    t refuses "$c"
  done
  # chaining / substitution / redirection is refused even when the leading command is allowed
  for c in 'ip -4 route show; reboot' 'ip -4 route show && reboot' 'ip -4 route show | sh' 'ip -4 route show $(reboot)' \
           'sudo iptables -S DOCKER-USER > /etc/x'; do
    t refuses "$c"
  done
  # remote() must refuse WITHOUT ever invoking ssh
  local marker out rc
  marker="$(mktemp -u)"
  out=$(SSH_CMD="touch $marker" HOST=selftest remote 'sudo reboot' 2>&1); rc=$?
  t [ "$rc" = 97 ]; t [ ! -e "$marker" ]
  rm -f "$marker"
  # pure helpers (called directly, same shell — no subshell needed, so no export -f dance)
  t region_matches_country "United Kingdom" "United Kingdom"
  t not region_matches_country "United Kingdom" "Poland"
  t grep -q 'london|United Kingdom|London' <(configured_locations)
  t grep -qx '52 50' <(route_table_and_priority)
  t grep -qx '100.64.0.0/10 fd7a:115c:a1e0::/48' <(tailnet_subnets)
  if (( bad_n )); then echo "self-test: $bad_n of $n assertions FAILED" >&2; return 1; fi
  echo "self-test OK ($n assertions): mutating and chained commands are refused before any connection; parsing logic behaves"
}

if [[ "${1:-}" == "--self-test" ]]; then self_test; exit $?; fi
if [[ "${1:-}" == "--allowed" ]]; then command_allowed "${2:-}" && echo yes || echo no; exit 0; fi

HOST="${1:-${TARGET_HOST:-}}"
[[ -n "$HOST" ]] || { echo "usage: $0 <host>   (or set TARGET_HOST)   |   $0 --self-test" >&2; exit 2; }
[[ "$HOST" != -* ]] || { echo "refusing a host that looks like an ssh option" >&2; exit 2; }
echo "Exit-node fleet live verification (read-only)"

remote 'tailscale ip -4' >/dev/null 2>&1; pre=$?
(( pre == 0 || pre == 1 )) || { echo "ABORT: the preflight command failed (status $pre) — is the host reachable and is tailscale installed?" >&2; exit 2; }

VPS_TS_IP="$(remote 'tailscale ip -4' 2>/dev/null | head -1)"
VPS_PUB_IP="$(remote 'ip -4 route show' 2>/dev/null | grep -o 'src [0-9.]*' | head -1 | awk '{print $2}')"
read -r RETURN_TABLE RETURN_PRIORITY <<<"$(route_table_and_priority)"
read -r SUBNET_V4 SUBNET_V6 <<<"$(tailnet_subnets)"

if ! LOCATIONS="$(configured_locations 2>&1)" || [[ -z "$LOCATIONS" ]]; then
  bad "cannot determine the configured exit-node locations from roles/exit_nodes/defaults/main.yml — nothing was verified"
  LOCATIONS=""
fi

LOCATION_LINES=()
if [[ -n "$LOCATIONS" ]]; then
  # Read every location line into an array FIRST, then loop over the array with a plain `for` —
  # not `while read <<<"$LOCATIONS"`. Each loop iteration below calls remote() (ssh), and ssh reads
  # from whatever stdin it inherits; inside a `while read <<<heredoc` loop, the loop body shares the
  # SAME stdin fd as the `read` builtin driving the loop — ssh, even though the remote command needs
  # no input, still drains from that shared fd, so the *next* iteration's `read` sees EOF and the
  # loop silently stops after one location. Found live: a real 2-location deploy only ever checked
  # the first location, with no error. Reading into an array first (this script's other single-shot
  # `<<<` reads are fine — they're one read each, never inside a loop body that also calls remote())
  # removes the shared-stdin dependency entirely, matching verify-live.sh's own SERVICES-array idiom.
  readarray -t LOCATION_LINES <<<"$LOCATIONS"
fi
for location_line in "${LOCATION_LINES[@]}"; do
  IFS='|' read -r name region city <<<"$location_line"
  [[ -z "$name" ]] && continue
  section "location: $name ($region, $city)"
  TUNNEL="exit-node-$name-tunnel"; NODE="exit-node-$name-node"; SIDECAR="exit-node-$name-sidecar"

  # -- running, with the declared restart policy --------------------------------------------------
  declared=$(remote "docker inspect --format '{{.Name}} {{.State.Status}} {{.HostConfig.RestartPolicy.Name}}' $TUNNEL $NODE $SIDECAR" 2>/dev/null || true)
  verified=0
  for svc in "$TUNNEL" "$NODE" "$SIDECAR"; do
    line=$(printf '%s\n' "$declared" | grep -E "^/?$svc " | head -1)
    if [[ -z "$line" ]]; then bad "$svc: container not found"; continue; fi
    read -r _ st pol <<<"$line"
    if [[ "$st" == running && "$pol" == unless-stopped ]]; then ok "$svc: running, restart=unless-stopped"; verified=$((verified+1))
    else bad "$svc: state=$st restart=$pol (want running / unless-stopped)"; fi
  done
  if (( verified < 3 )); then
    bad "$name: not all 3 services are healthy — skipping this location's remaining checks"
    continue
  fi

  # -- isolation: the tunnel is attached to exit_nodes_net and nothing else; node/sidecar share its
  #    netns entirely (network_mode: service:tunnel) and so correctly report ZERO networks of their
  #    own via docker inspect — Docker never populates .NetworkSettings.Networks for a container
  #    riding another container's network namespace, confirmed live against the real deploy (a
  #    healthy pair reported "{}" for node/sidecar, which a first version of this check wrongly
  #    treated as a FAIL). Isolation for those two is proven instead via HostConfig.NetworkMode,
  #    which Docker sets to "container:<id>" for a service: network_mode — never "bridge"/"host"/
  #    a network name — combined with the empty Networks map (no independent attachment at all).
  nets=$(remote "docker inspect --format '{{json .NetworkSettings.Networks}}' $TUNNEL" 2>/dev/null) || { bad "$TUNNEL: cannot read attached networks"; nets=""; }
  if [[ -n "$nets" ]]; then
    n_count=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)))" <<<"$nets" 2>/dev/null || echo -1)
    if [[ "$n_count" != "1" ]]; then bad "$TUNNEL: attached to $n_count network(s), expected exactly 1"
    elif grep -q 'exit_nodes_net' <<<"$nets"; then ok "$TUNNEL: attached only to its own dedicated network"
    else bad "$TUNNEL: its one attached network is not exit_nodes_net"; fi
  fi
  for svc in "$NODE" "$SIDECAR"; do
    nets=$(remote "docker inspect --format '{{json .NetworkSettings.Networks}}' $svc" 2>/dev/null) || { bad "$svc: cannot read attached networks"; continue; }
    n_count=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)))" <<<"$nets" 2>/dev/null || echo -1)
    mode=$(remote "docker inspect --format '{{.HostConfig.NetworkMode}}' $svc" 2>/dev/null) || mode=""
    if [[ "$n_count" == "0" && "$mode" == container:* ]]; then
      ok "$svc: no network of its own — shares the tunnel's netns (network_mode: $mode)"
    else
      bad "$svc: expected zero independent networks and network_mode: container:<tunnel>, got $n_count network(s) and mode '$mode'"
    fi
  done

  # -- no published host port anywhere in the pair ---------------------------------------------------
  for svc in "$TUNNEL" "$NODE" "$SIDECAR"; do
    ports=$(remote "docker inspect --format '{{json .NetworkSettings.Ports}}' $svc" 2>/dev/null) || { bad "$svc: cannot read published ports"; continue; }
    # .NetworkSettings.Ports maps container-port -> [] of host bindings, or null when EXPOSEd but not
    # published — only a non-null value means the host actually publishes it, so counting map keys
    # (as a naive check would) gives a false FAIL on any image that EXPOSEs a port in its Dockerfile.
    published=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for v in d.values() if v))" <<<"$ports" 2>/dev/null || echo -1)
    if [[ "$published" == "0" ]]; then ok "$svc: no published host port"
    else bad "$svc: has $published published host port(s) — the feature must publish none"; fi
  done

  # -- Tailscale: advertised, online (admin approval cannot be checked from here) -------------------
  self_json=$(remote "docker exec $NODE tailscale status --self --json" 2>/dev/null) || { bad "$name: cannot read Tailscale status"; self_json=""; }
  if [[ -n "$self_json" ]]; then
    online=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Self',{}).get('Online', False))" <<<"$self_json" 2>/dev/null)
    exit_opt=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Self',{}).get('ExitNodeOption', False))" <<<"$self_json" 2>/dev/null)
    [[ "$online" == "True" ]] && ok "$name: Tailscale node is online" || bad "$name: Tailscale node is not online"
    [[ "$exit_opt" == "True" ]] && ok "$name: node advertises exit-node capability" || bad "$name: node does not advertise exit-node capability"
    inc "$name: admin-console approval cannot be confirmed from the node's own status (no Tailscale API key is provisioned; only a client's exit-node picker can tell — see #07's phone test)"
  fi

  # -- exit IP: differs from the VPS's own public IP, and matches the configured country -----------
  exit_json=$(remote "docker exec $TUNNEL wget -q -T 10 -O - https://ifconfig.co/json" 2>/dev/null) || exit_json=""
  if [[ -z "$exit_json" ]]; then
    inc "$name: could not reach ifconfig.co from inside the tunnel to determine the exit IP/country"
  else
    exit_ip=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('ip',''))" <<<"$exit_json" 2>/dev/null)
    exit_country=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('country',''))" <<<"$exit_json" 2>/dev/null)
    if [[ -z "$exit_ip" ]]; then inc "$name: could not parse the exit IP from ifconfig.co"
    elif [[ -n "$VPS_PUB_IP" && "$exit_ip" == "$VPS_PUB_IP" ]]; then bad "$name: the exit IP equals the VPS's own public IP — traffic is not actually leaving via Windscribe"
    else ok "$name: exit IP differs from the VPS's own public IP"; fi
    if [[ -z "$exit_country" ]]; then inc "$name: could not determine the exit country"
    elif region_matches_country "$region" "$exit_country"; then ok "$name: exit country ($exit_country) matches the configured region"
    else bad "$name: exit country is '$exit_country', expected '$region'"; fi
  fi

  # -- firewall: IPv6 forwarding denied, Tailscale's own forward chains present ---------------------
  pid=$(remote "docker inspect --format '{{.State.Pid}}' $TUNNEL" 2>/dev/null) || pid=""
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    bad "$name: could not determine the tunnel's PID for netns inspection"
  else
    v6fwd=$(remote "sudo nsenter -t $pid -n sysctl -n net.ipv6.conf.all.forwarding" 2>/dev/null)
    [[ "$v6fwd" == "0" ]] && ok "$name: IPv6 forwarding is denied" || bad "$name: IPv6 forwarding is '$v6fwd' (expected 0 / denied)"

    # Presence-only, not an exact-match diff against a recorded ruleset (unlike verify-live.sh's own
    # normalize_rules()/diff for DOCKER-USER): Tailscale's nftables ruleset carries its own internal
    # bookkeeping that varies by version, so a byte-exact comparison would be far more brittle than
    # useful here. This confirms Tailscale's own chains exist (so fix #2 stays unnecessary, per
    # #01/#03) but would not catch an extra, unrelated forwarding rule added elsewhere in the same
    # ruleset — a real, narrower guarantee than "exactly the expected rules."
    ruleset=$(remote "sudo nsenter -t $pid -n nft list ruleset" 2>/dev/null) || ruleset=""
    if grep -q 'ts-forward' <<<"$ruleset" && grep -q 'ts-postrouting' <<<"$ruleset"; then
      ok "$name: Tailscale's own ts-forward/ts-postrouting chains are present (fix #2 is unnecessary, per #01/#03)"
    else
      bad "$name: Tailscale's own forward/postrouting chains are missing from the tunnel's netns"
    fi

    v4rule=$(remote "sudo nsenter -t $pid -n ip rule show" 2>/dev/null) || v4rule=""
    v6rule=$(remote "sudo nsenter -t $pid -n ip -6 rule show" 2>/dev/null) || v6rule=""
    # Never print the subnet/table in a FAIL message (this script's own no-address-printed rule) —
    # the well-known Tailscale CGNAT range isn't a real device address, but consistency is simpler
    # to audit than a case-by-case exception.
    if grep -q "to $SUBNET_V4 lookup $RETURN_TABLE" <<<"$v4rule"; then ok "$name: IPv4 return-path rule present"
    else bad "$name: IPv4 return-path rule is missing"; fi
    if grep -q "to $SUBNET_V6 lookup $RETURN_TABLE" <<<"$v6rule"; then ok "$name: IPv6 return-path rule present"
    else bad "$name: IPv6 return-path rule is missing"; fi
  fi

  # -- trust boundary: unreachable from inside the pair ---------------------------------------------
  if [[ -z "$VPS_TS_IP" ]]; then inc "$name: could not determine the VPS's own tailnet address — trust-boundary probe of it skipped"
  else
    if remote "docker exec $SIDECAR nc -zv -w5 $VPS_TS_IP 22" >/dev/null 2>&1; then
      bad "$name: the VPS's own tailnet SSH port is reachable from inside the pair — trust boundary is broken"
    else ok "$name: the VPS's own tailnet address is unreachable from inside the pair"; fi
  fi
  if [[ -n "${HERMES_VERIFY_OTHER_TAILNET_IP:-}" ]]; then
    if remote "docker exec $SIDECAR nc -zv -w5 $HERMES_VERIFY_OTHER_TAILNET_IP 22" >/dev/null 2>&1; then
      bad "$name: another tailnet device is reachable from inside the pair — trust boundary is broken"
    else ok "$name: another tailnet device is unreachable from inside the pair"; fi
  else
    skip "$name: no other tailnet device to probe (set HERMES_VERIFY_OTHER_TAILNET_IP to check)"
  fi
done

# ---------------------------------------------------------------------------------------------------
section "firewall interplay: no per-pair DOCKER-USER entries, tunnels reach the internet by the container-bridge early return alone"
for fam in 4 6; do
  cmd=iptables; [[ $fam == 6 ]] && cmd=ip6tables
  live=$(remote "sudo $cmd -S DOCKER-USER" 2>/dev/null) || { bad "v$fam: cannot read the live DOCKER-USER chain"; continue; }
  if grep -q 'exit-node\|exit_node' <<<"$live"; then
    bad "v$fam: the DOCKER-USER chain contains an entry naming the exit-node feature — it must need none (the container-bridge early return already lets its UDP egress through)"
  else
    ok "v$fam: DOCKER-USER holds no exit-node-specific entries"
  fi
done

# ---------------------------------------------------------------------------------------------------
section "host routing: unchanged by the exit-node feature (no host route/rule mutation)"
route4_n=$(remote 'ip -4 route show' 2>/dev/null | wc -l); rule4_n=$(remote 'ip -4 rule show' 2>/dev/null | wc -l)
route6_n=$(remote 'ip -6 route show' 2>/dev/null | wc -l); rule6_n=$(remote 'ip -6 rule show' 2>/dev/null | wc -l)
info "current host counts: $route4_n IPv4 routes, $rule4_n IPv4 rules, $route6_n IPv6 routes, $rule6_n IPv6 rules"
if [[ -n "${HERMES_VERIFY_ROUTE4_BASELINE:-}" && -n "${HERMES_VERIFY_RULE4_BASELINE:-}" ]]; then
  [[ "$route4_n" == "$HERMES_VERIFY_ROUTE4_BASELINE" ]] && ok "IPv4 route count matches the recorded baseline" || bad "IPv4 route count ($route4_n) does not match the recorded baseline ($HERMES_VERIFY_ROUTE4_BASELINE)"
  [[ "$rule4_n" == "$HERMES_VERIFY_RULE4_BASELINE" ]] && ok "IPv4 rule count matches the recorded baseline" || bad "IPv4 rule count ($rule4_n) does not match the recorded baseline ($HERMES_VERIFY_RULE4_BASELINE)"
else
  inc "no recorded baseline (set HERMES_VERIFY_ROUTE4_BASELINE / HERMES_VERIFY_RULE4_BASELINE once, from a known-good run, to check against it in future runs) — a host-specific number cannot be safely assumed generically"
fi

# ---------------------------------------------------------------------------------------------------
section "optional: the VPS's own plain exit node (ticket #09 — egress from the VPS's own public IP, droppable)"
self_json=$(remote 'tailscale status --self --json' 2>/dev/null)
if [[ -z "$self_json" ]]; then
  inc "plain exit node: could not read this host's own Tailscale status"
else
  advertised=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Self',{}).get('ExitNodeOption', False))" <<<"$self_json" 2>/dev/null)
  if [[ "$advertised" == "True" ]]; then
    ok "plain exit node: this host advertises itself as an exit node"
  else
    inc "plain exit node: not advertised — expected if ticket #09 was never enabled on this host; a real regression otherwise"
  fi
fi
for fam in 4 6; do
  if [[ $fam == 4 ]]; then key='net.ipv4.ip_forward'; else key='net.ipv6.conf.all.forwarding'; fi
  val=$(remote "sudo sysctl -n $key" 2>/dev/null)
  if [[ "$val" == "1" ]]; then
    ok "v$fam forwarding enabled ($key=1) — persisted by the Tailscale installer in /etc/sysctl.d/99-tailscale.conf (epic 21's runtime-state audit); survives a reboot"
  else
    bad "v$fam forwarding is NOT enabled ($key=${val:-unknown}) — the plain exit node cannot forward traffic"
  fi
done
info "NOT verified here: a real tailnet device actually selecting this plain exit node and confirming traffic is forwarded, not silently dropped, by the DOCKER-USER port-class rules — a runtime chain-ordering question no self-only check can prove either way; see .scratch/23-windscribe-exit-nodes/issues/09-plain-vps-exit-node.md for the one-time attended result."

# ---------------------------------------------------------------------------------------------------
printf '\n== summary ==\n  %d passed, %d FAILED, %d inconclusive, %d skipped\n' "$PASS" "$FAIL" "$INCONCLUSIVE" "$SKIP"
(( INCONCLUSIVE + SKIP > 0 )) && echo "  (inconclusive and skipped checks are NOT passes — see above)"
echo "  NOT verified here (attended, ticket #07): a real client's exit-node picker, an active tunnel-down/recovery test, and Tailscale admin-console exit-node approval."
echo "  NOT verified here (attended, ticket #09): a real tailnet device routing live traffic through the VPS's own plain exit node."
(( FAIL == 0 ))
