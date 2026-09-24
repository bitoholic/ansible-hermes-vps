#!/usr/bin/env bash
# Read-only live verification of the VPS's reboot resilience (epic 21 ticket #05).
#
#   scripts/verify-live.sh [host]           host = argument, else $TARGET_HOST
#   scripts/verify-live.sh --self-test      prove the read-only guarantee and the parsing logic (no network)
#
# Run it after any reboot, or any time you doubt the VPS. It CHANGES NOTHING on the VPS: every remote
# command goes through remote(), which refuses (before any connection is made) anything that is not on the
# allowlist below or that contains a shell metacharacter, so a mutating command cannot be sent even by a
# bug in this script. `--self-test` proves that refusal.
#
# Exit status: 0 = no check FAILED (inconclusive/skipped checks are reported, never counted as passes);
#              1 = at least one FAIL.
#
# Run through the deploy wrapper's script mode (epic 22) the encrypted store supplies TARGET_HOST and
# SILVERBULLET_DOMAIN; nothing here waits for epic 22 — export them by hand otherwise. The domain is used
# only to build tailnet-route probes and is NEVER printed (routes are shown as <label>.<domain>).
#
# Never printed: the host, the domain, any IP address, rule contents (the DOCKER-USER rules carry the Syncplay
# friend's address — drift is reported as counts only).
#
# What this CANNOT do (attended steps of the drill, docs/reboot-resilience.md): reboot, stop or pause
# AdGuard, restart Docker, or enable the staged switches — a read-only script must not.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ONE multiplexed SSH connection for the whole run. UFW rate-limits SSH (`limit 22/tcp`: 6 new connections
# per 30 s per source address), and this script makes ~35 checks — a fresh connection per check locked the
# operator out of their own VPS for the duration of the limit (found on the first live run). ControlMaster
# opens one connection and every check reuses it; ControlPersist lets it close itself if we are killed.
# A test (or an operator) may substitute the transport with HERMES_VERIFY_SSH.
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
    [[ -n "${HOST:-}" ]] && $SSH_CMD -O exit "$HOST" >/dev/null 2>&1   # close the shared connection
    rm -rf "$MUX_DIR"
  fi
  return 0
}
trap cleanup EXIT
SYSFS_NET="${HERMES_VERIFY_SYSFS_NET:-/sys/class/net}"   # a test may point this at a fixture
SKIP_LOCAL="${HERMES_VERIFY_SKIP_LOCAL:-0}"   # 1 = skip probes that need this workstation's network (used by tests)
DOMAIN="${SILVERBULLET_DOMAIN:-}"

# ---------------------------------------------------------------------------------------------------
# The remote-command allowlist: the ONLY things this script may run on the VPS. All read-only.
# ---------------------------------------------------------------------------------------------------
ALLOWED_REMOTE=(
  '^sudo cat /etc/hermes-vps/firewall/docker-user\.v[46]\.rules$'
  '^sudo ip6?tables -S DOCKER-USER$'
  '^sudo ufw status$'
  '^systemctl (is-enabled|is-active) [a-z0-9@._-]+( [a-z0-9@._-]+)*$'
  '^systemctl show [a-z0-9@._-]+ -p (After|Before|Requires|Wants) --value$'
  "^docker ps -a --format '\{\{\.Names\}\} \{\{\.State\}\}'$"
  "^docker inspect --format '\{\{\.Name\}\} \{\{\.State\.Status\}\} \{\{\.HostConfig\.RestartPolicy\.Name\}\}' [a-z0-9-]+( [a-z0-9-]+)*$"
  '^getent hosts [a-z0-9.-]+$'
  '^cat /etc/resolv\.conf$'
  '^tailscale ip -4$'
  '^ip -4 route get 1\.1\.1\.1$'
)
# Shell metacharacters are refused outright (no chaining, redirection, substitution).
METACHARS_RE='[;&|<>`$
]'

command_allowed() {  # <cmd> -> 0 if it may be sent
  local cmd="$1" re
  [[ "$cmd" =~ $METACHARS_RE ]] && return 1
  for re in "${ALLOWED_REMOTE[@]}"; do [[ "$cmd" =~ $re ]] && return 0; done
  return 1
}
# UFW rate-limits SSH and further attempts EXTEND the block, so a dead connection must stop the run at the first
# failed attempt (ssh exits 255) rather than let every remaining check retry. remote() is mostly called inside
# $(...), where `exit` would only leave the subshell — so it signals the main shell, which aborts with status 2.
exec 9>&2   # the operator's real stderr: most checks run with 2>/dev/null, which must not swallow the abort message
abort_unreachable() {
  echo >&9
  echo "ABORT: cannot reach the host over SSH (connection failed). Not retrying — UFW rate-limits SSH and further attempts extend the block. Wait ~40 s, then try once." >&9
  exit 2
}
trap abort_unreachable USR1
remote() {  # <cmd>: run a read-only command on the VPS, or refuse
  command_allowed "$1" || { echo "REFUSED (not read-only / not allowlisted): $1" >&2; return 97; }
  local rc
  # shellcheck disable=SC2086  # SSH_CMD is intentionally word-split (command + options)
  $SSH_CMD "$HOST" "$1"; rc=$?
  if (( rc == 255 )); then kill -USR1 $$; sleep 1; fi   # 255 = ssh's own failure; the trap aborts the run
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
normalize_rules() {  # stdin: rule lines -> the DOCKER-USER '-A' rules in comparable form, one per line
  python3 -c '
import re,sys
for line in sys.stdin:
    line=line.strip()
    if not line.startswith("-A DOCKER-USER"): continue
    line=line.replace("\"","")                              # iptables -S only quotes when it must
    line=re.sub(r"(-s [0-9a-fA-F:.]+)/(32|128)\b",r"\1",line)   # a /32 (/128) host is printed with its mask
    print(re.sub(r"\s+"," ",line))'
}

route_is_plain_internet() {  # <dev> <sysfs-type> <link-detail> -> 0 if a normal internet-facing NIC
  local dev="$1" type="$2" detail="$3"
  [[ "$dev" == tailscale* || "$dev" == tun* || "$dev" == wg* || "$dev" == ppp* ]] && return 1
  [[ "$detail" =~ (wireguard|tun|tap|vxlan|gre) ]] && return 1
  [[ "$type" == "1" ]]   # 1 = ARPHRD_ETHER (Ethernet / Wi-Fi); 65534/none = tunnel
}

expected_services() {  # the same list the compose stack is rendered from
  python3 -c '
import yaml,sys
print(" ".join(yaml.safe_load(open(sys.argv[1]))["docker_enabled_services"]))' "$REPO_ROOT/roles/docker/defaults/main.yml"
}
public_ports() {  # the public ingress ports (what the firewall lets through to anyone)
  python3 -c '
import sys,yaml
print(" ".join(str(x) for x in yaml.safe_load(open(sys.argv[1]))["docker_published_public_ports"]))' "$REPO_ROOT/group_vars/all/main.yml"
}
tailnet_route_labels() {  # every gateway route a role publishes as tailnet_only (from each role's *_gateway_publish)
  python3 -c '
import glob,sys,yaml
out=[]
for f in sorted(glob.glob(sys.argv[1]+"/roles/*/defaults/main.yml")):
    d=yaml.safe_load(open(f)) or {}
    for k,v in d.items():
        if k.endswith("_gateway_publish") and isinstance(v,list):
            out += [r["host"] for r in v if r.get("tailnet_only")]
print(" ".join(out))' "$REPO_ROOT"
}
restricted_ports() {  # the tailnet-only TCP ports, resolving templated entries such as "{{ conduit_port }}"
  python3 -c '
import re,sys,yaml
d=yaml.safe_load(open(sys.argv[1])); out=[]
for p in d["docker_published_restricted_ports"]:
    if isinstance(p,int): out.append(p); continue
    m=re.fullmatch(r"\{\{\s*(\w+)\s*\}\}",str(p))          # a templated entry: look the variable up
    if m and isinstance(d.get(m.group(1)),int): out.append(d[m.group(1)])
    else: sys.exit("cannot resolve restricted port entry: %r" % (p,))   # never silently drop a port
print(" ".join(str(x) for x in out))' "$REPO_ROOT/group_vars/all/main.yml"
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
  t allows 'sudo iptables -S DOCKER-USER'
  t allows 'sudo ip6tables -S DOCKER-USER'
  t allows 'sudo cat /etc/hermes-vps/firewall/docker-user.v4.rules'
  t allows 'systemctl is-enabled docker tailscaled ufw'
  t allows 'systemctl show docker.service -p After --value'
  t allows "docker ps -a --format '{{.Names}} {{.State}}'"
  t allows "docker inspect --format '{{.Name}} {{.State.Status}} {{.HostConfig.RestartPolicy.Name}}' caddy authelia"
  t allows 'getent hosts example.com'
  # the allowlist must not have been widened: other files, other unit properties, other tools, other arguments
  for c in 'sudo cat /etc/shadow' 'sudo cat /etc/hermes-vps/firewall/docker-user.v4.rules /etc/shadow' 'sudo cat /etc/hermes-vps/firewall/../../shadow' \
           'systemctl show docker -p ExecStart --value' 'systemctl show docker.service -p Environment --value' 'sudo ufw status verbose' \
           'sudo iptables -S' 'sudo iptables -L' 'docker inspect caddy' 'docker logs caddy' 'docker ps' 'cat /etc/shadow' 'tailscale status' 'tailscale ip'; do
    t refuses "$c"
  done
  # the mutating / dangerous things it must never send
  for c in 'systemctl restart docker' 'systemctl stop tailscaled' 'systemctl start x' 'systemctl enable docker' \
           'systemctl daemon-reload' 'sudo iptables -F DOCKER-USER' 'sudo iptables -A DOCKER-USER -j DROP' \
           'sudo iptables-restore < /x' 'sudo ufw disable' 'sudo ufw allow 22' 'docker rm -f caddy' 'docker stop adguard' \
           'docker pause adguard' 'docker compose up -d' 'docker exec caddy sh' 'sudo reboot' 'sudo shutdown -h now' \
           'sudo rm -rf /etc/hermes-vps' 'tailscale set --accept-dns=false' 'tailscale up' 'resolvectl flush-caches' \
           'sudo tee /etc/x' 'sudo sed -i s/a/b/ /etc/x' 'sudo apt-get install x'; do
    t refuses "$c"
  done
  # chaining / substitution / redirection is refused even when the leading command is allowed
  for c in 'getent hosts example.com; reboot' 'getent hosts example.com && reboot' 'getent hosts example.com | sh' \
           'getent hosts $(reboot)' 'getent hosts `reboot`' 'cat /etc/resolv.conf > /etc/x' 'cat /etc/resolv.conf >> /etc/x'; do
    t refuses "$c"
  done
  # the metacharacter layer on its own: a payload in the one slot the per-command patterns leave free (the quote
  # characters of the docker format string) is refused because of the metacharacter, not the pattern
  t refuses "docker ps -a --format \`{{.Names}} {{.State}}\`"
  t refuses 'docker ps -a --format $x{{.Names}} {{.State}}$x'
  t refuses "docker ps -a --format ;{{.Names}} {{.State}};"
  # the metacharacter layer is defence in depth: with a deliberately permissive pattern it alone must still refuse
  local ALLOWED_REMOTE=('^getent hosts .*$')
  for c in 'getent hosts $(reboot)' 'getent hosts `reboot`' 'getent hosts a;reboot' 'getent hosts a|sh' 'getent hosts a&&b' 'getent hosts a>x'; do
    t refuses "$c"
  done
  t allows 'getent hosts example.com'
  # remote() must refuse WITHOUT ever invoking ssh
  local marker out rc
  marker="$(mktemp -u)"
  out=$(SSH_CMD="touch $marker" HOST=selftest remote 'systemctl restart docker' 2>&1); rc=$?
  t [ "$rc" = 97 ]; t [ ! -e "$marker" ]
  rm -f "$marker"
  # rule normalization: live `iptables -S` form == rendered restore form
  local live rendered
  live=$(printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -s 203.0.113.7/32 -p tcp -m tcp --dport 8999 -m comment --comment "syncplay friend access" -j ACCEPT' | normalize_rules)
  rendered=$(printf '%s\n' '# c' '*filter' ':DOCKER-USER - [0:0]' '-A DOCKER-USER -s 203.0.113.7 -p tcp -m tcp --dport 8999 -m comment --comment "syncplay friend access" -j ACCEPT' 'COMMIT' | normalize_rules)
  t [ "$live" = "$rendered" ]
  t [ "$(printf '%s\n' '-N DOCKER-USER' | normalize_rules | wc -l)" = 0 ]        # an emptied chain has no rules
  # route classification: a VPN/tunnel path is never a valid outside-in vantage
  t route_is_plain_internet enp1s0 1 'link/ether'
  t route_is_plain_internet wlp1s0 1 'link/ether'
  t not route_is_plain_internet tailscale0 65534 'tun'
  t not route_is_plain_internet LDN-Biscuits 65534 'wireguard'
  t not route_is_plain_internet wg0 1 'link/ether'
  t not route_is_plain_internet eth9 65534 'link/none'
  t not route_is_plain_internet eth9 1 'wireguard'
  # every restricted port must be probed — including the templated one (8008) a naive parse drops
  t bash -c "[[ ' $(restricted_ports) ' == *' 8008 '* ]]"
  t bash -c "[[ ' $(public_ports) ' == *' 443 '* ]]"
  t bash -c "[[ ' $(tailnet_route_labels) ' == *' adguard '* ]]"
  if (( bad_n )); then echo "self-test: $bad_n of $n assertions FAILED" >&2; return 1; fi
  echo "self-test OK ($n assertions): mutating and chained commands are refused before any connection; parsing and route logic behave"
}

if [[ "${1:-}" == "--self-test" ]]; then self_test; exit $?; fi
# `--allowed <cmd>`: print yes/no for whether a command would be sent (lets tests audit what a fake ssh received).
if [[ "${1:-}" == "--allowed" ]]; then command_allowed "${2:-}" && echo yes || echo no; exit 0; fi

HOST="${1:-${TARGET_HOST:-}}"
[[ -n "$HOST" ]] || { echo "usage: $0 <host>   (or set TARGET_HOST)   |   $0 --self-test" >&2; exit 2; }

[[ "$HOST" != -* ]] || { echo "refusing a host that looks like an ssh option" >&2; exit 2; }
echo "Reboot-resilience live verification (read-only)"

# ONE cheap call first: if the host is unreachable stop here, before the ~30 checks below each retry.
remote 'tailscale ip -4' >/dev/null 2>&1; pre=$?
(( pre == 0 || pre == 1 )) || { echo "ABORT: the preflight command failed (status $pre) — is the host reachable and is tailscale installed?" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------------
section "DOCKER-USER rules match the rendered rules (both IP families)"
for fam in 4 6; do
  cmd=iptables; [[ $fam == 6 ]] && cmd=ip6tables
  rendered=$(remote "sudo cat /etc/hermes-vps/firewall/docker-user.v${fam}.rules" 2>/dev/null) || { bad "v$fam: rendered rules file unreadable on the VPS"; continue; }
  live=$(remote "sudo $cmd -S DOCKER-USER" 2>/dev/null) || { bad "v$fam: cannot read the live DOCKER-USER chain"; continue; }
  exp_n=$(printf '%s\n' "$rendered" | normalize_rules | wc -l); live_n=$(printf '%s\n' "$live" | normalize_rules | wc -l)
  if [[ "$live_n" == 0 ]]; then
    bad "v$fam: the live DOCKER-USER chain is EMPTY (expected $exp_n rules) — the reboot fault this epic fixes"
  elif [[ "$(printf '%s\n' "$rendered" | normalize_rules)" == "$(printf '%s\n' "$live" | normalize_rules)" ]]; then
    ok "v$fam: live chain equals the rendering ($live_n rules, same order)"
  else
    bad "v$fam: live chain ($live_n rules) differs from the rendering ($exp_n rules)"
    # counts only: the rules carry the Syncplay friend's address, and this output may be pasted around
    exp_f=$(mktemp); live_f=$(mktemp)
    printf '%s\n' "$rendered" | normalize_rules >"$exp_f"; printf '%s\n' "$live" | normalize_rules >"$live_f"
    info "  $(grep -vxFf "$live_f" "$exp_f" | wc -l) rendered rule(s) missing from the live chain, $(grep -vxFf "$exp_f" "$live_f" | wc -l) live rule(s) not in the rendering (0 and 0 = same rules in a different order, which changes what they allow)"
    rm -f "$exp_f" "$live_f"
  fi
done

# ---------------------------------------------------------------------------------------------------
section "boot firewall unit and ordering"
u=hermes-docker-user-firewall.service
[[ "$(remote "systemctl is-enabled $u" 2>/dev/null)" == enabled ]] && ok "$u is enabled" || bad "$u is not enabled at boot"
[[ "$(remote "systemctl is-active $u" 2>/dev/null)" == active ]] && ok "$u is active" || bad "$u is not active"
# Capture first, then test: `remote | grep -q` under pipefail reports a false failure when grep exits early and the
# sender gets SIGPIPE.
before=$(remote "systemctl show $u -p Before --value" 2>/dev/null); after=$(remote "systemctl show docker.service -p After --value" 2>/dev/null)
requires=$(remote "systemctl show docker.service -p Requires --value" 2>/dev/null)
[[ "$before" == *docker.service* ]] && ok "the unit is ordered Before=docker.service" || bad "the unit is not ordered before docker.service"
[[ "$after" == *tailscaled.service* ]] && ok "docker.service is ordered after tailscaled" || bad "docker.service is not ordered after tailscaled"
[[ "$(remote 'systemctl is-active tailscaled' 2>/dev/null)" == active ]] && ok "tailscaled is active" || bad "tailscaled is not active"
if [[ "$requires" == *"$u"* ]]; then info "fail-closed coupling: ENABLED (Docker requires the firewall unit)"; else info "fail-closed coupling: disabled (staged; the attended drill enables it)"; fi

# ---------------------------------------------------------------------------------------------------
section "containers: running, with the declared restart policy"
if ! svc_list=$(expected_services 2>&1) || [[ -z "$svc_list" ]]; then
  bad "cannot determine the expected container set from roles/docker/defaults/main.yml — no container was verified"; SERVICES=()
else read -r -a SERVICES <<<"$svc_list"; fi
# docker inspect prints every container it FOUND and exits non-zero if any is missing — keep that output, so one
# missing container is reported for itself instead of discarding the results of all of them.
declared=$(remote "docker inspect --format '{{.Name}} {{.State.Status}} {{.HostConfig.RestartPolicy.Name}}' ${SERVICES[*]}" 2>/dev/null || true)
verified=0
for s in "${SERVICES[@]}"; do
  line=$(printf '%s\n' "$declared" | grep -E "^/?$s " | head -1)
  if [[ -z "$line" ]]; then bad "$s: container not found"; continue; fi
  read -r _ st pol <<<"$line"
  if [[ "$st" == running && "$pol" == unless-stopped ]]; then ok "$s: running, restart=unless-stopped"; verified=$((verified+1))
  else bad "$s: state=$st restart=$pol (want running / unless-stopped)"; fi
done
(( ${#SERVICES[@]} > 0 )) && info "$verified of ${#SERVICES[@]} expected containers verified"

# ---------------------------------------------------------------------------------------------------
section "base services and firewall"
for svc in docker tailscaled ufw; do
  [[ "$(remote "systemctl is-enabled $svc" 2>/dev/null)" == enabled ]] && ok "$svc is enabled at boot" || bad "$svc is not enabled at boot"
done
if [[ "$(remote 'systemctl is-enabled ssh.socket' 2>/dev/null)" == enabled || "$(remote 'systemctl is-enabled ssh.service' 2>/dev/null)" == enabled ]]; then ok "SSH starts at boot (socket or service)"; else bad "SSH is not enabled at boot"; fi
ufw_status=$(remote 'sudo ufw status' 2>/dev/null)
[[ "$ufw_status" == "Status: active"* ]] && ok "UFW is active" || bad "UFW is not active"

# ---------------------------------------------------------------------------------------------------
section "host DNS (AdGuard up; the stopped/paused cases are attended drill steps)"
[[ -n "$(remote 'getent hosts example.com' 2>/dev/null)" ]] && ok "the host resolves example.com" || bad "the host cannot resolve names"
rc=$(remote 'cat /etc/resolv.conf' 2>/dev/null | head -3)
if grep -qi 'generated by tailscale' <<<"$rc"; then info "resolv.conf owner: Tailscale (host DNS ownership change not enabled)"
elif grep -qi 'systemd-resolved\|resolved' <<<"$rc"; then info "resolv.conf owner: systemd-resolved (host DNS ownership change enabled)"
else info "resolv.conf owner: other"; fi

# ---------------------------------------------------------------------------------------------------
section "reachability from this workstation"
# probe <ip> <port> <timeout>: 0 if a TCP connection succeeds. Needs `timeout`; without it every probe would report
# "closed", so its absence makes the probes INCONCLUSIVE instead (see below).
UNROUTABLE_CONTROL="203.0.113.1"   # RFC 5737 TEST-NET-3: never a real host (the negative control for the outside-in probe)
TIMEOUT_BIN="${HERMES_VERIFY_TIMEOUT_BIN:-timeout}"   # a test may point this at a command that does not exist
probe() { "$TIMEOUT_BIN" "$3" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
if [[ "$SKIP_LOCAL" == 1 ]]; then skip "workstation-side probes disabled (HERMES_VERIFY_SKIP_LOCAL=1)"
elif ! command -v "$TIMEOUT_BIN" >/dev/null; then inc "workstation-side probes: no 'timeout' command here — every probe would look closed, so none was run"
else
  pub=$(remote 'ip -4 route get 1.1.1.1' 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}')
  if [[ -z "$pub" ]]; then inc "could not determine the VPS's public address"; else
    answered=0
    if ! pub_ports=$(public_ports 2>&1) || [[ -z "$pub_ports" ]]; then bad "cannot read the public ingress ports from group_vars/all/main.yml"; pub_ports=""; fi
    for p in $pub_ports; do
      if probe "$pub" "$p" 5; then ok "public ingress port $p answers"; answered=$((answered+1)); else bad "public ingress port $p does not answer"; fi
    done
    # Outside-in probe of the restricted ports — only meaningful over a plain internet path, and only if this
    # workstation can reach the VPS at all (a public port that answers is the positive control: without one,
    # "closed" cannot be told from "no route / no egress").
    dev=$(ip route get "$pub" 2>/dev/null | grep -o 'dev [^ ]*' | head -1 | awk '{print $2}')
    type=$(cat "$SYSFS_NET/$dev/type" 2>/dev/null); detail=$(ip -d link show "$dev" 2>/dev/null | tr '\n' ' ')
    if ! route_is_plain_internet "${dev:-none}" "${type:-0}" "$detail"; then
      inc "outside-in probe of the restricted ports: this workstation's route to the VPS goes through '$dev' (a tunnel/VPN, not a plain internet path), so the result would mean nothing — run from a plain connection"
    elif (( answered == 0 )); then
      inc "outside-in probe of the restricted ports: no public port answered, so 'closed' cannot be told from 'unreachable' — no positive control"
    elif ! rports=$(restricted_ports 2>&1) || [[ -z "$rports" ]]; then
      bad "cannot read the restricted ports from group_vars/all/main.yml — none was probed"
    else
      # NEGATIVE CONTROL: a network that intercepts TCP (a router redirecting port 53 to its own resolver, a captive
      # portal, a transparent proxy) answers on ANY address. So every restricted port is also probed on an address that
      # cannot be a real host (RFC 5737 TEST-NET-3); if that answers too, the answer says nothing about the VPS and that
      # port is reported INCONCLUSIVE — never a leak, never a pass.
      leaked=""; intercepted=""; probed=0; verified=0
      for p in $rports; do
        probed=$((probed+1))
        if probe "$pub" "$p" 4; then
          if probe "$UNROUTABLE_CONTROL" "$p" 4; then intercepted="$intercepted $p"; else leaked="$leaked $p"; fi
        else verified=$((verified+1)); fi
      done
      [[ -n "$leaked" ]] && bad "restricted TCP port(s) reachable from the internet:$leaked"
      [[ -n "$intercepted" ]] && inc "restricted TCP port(s)$intercepted answer on an address that cannot be a real host too: this network intercepts them, so their outside-in result means nothing — run from another connection"
      [[ -z "$leaked" && $verified -gt 0 ]] && ok "$verified of $probed restricted TCP ports verified unreachable from the public internet (plain path via $dev; public ports answered; unroutable-address control used)"
    fi
    info "restricted UDP ports (DNS 53) are not probed: an unanswered UDP probe cannot tell closed from filtered"
  fi
  tsip=$(remote 'tailscale ip -4' 2>/dev/null | head -1)
  if [[ -z "$DOMAIN" ]]; then skip "tailnet-gated routes: SILVERBULLET_DOMAIN is not set (run through the wrapper's script mode or export it)"
  elif [[ -z "$tsip" ]]; then inc "tailnet-gated routes: could not read the VPS's Tailscale address"
  elif ! labels=$(tailnet_route_labels 2>&1) || [[ -z "$labels" ]]; then bad "cannot read the tailnet-only routes from the roles' gateway_publish"
  else
    for label in $labels; do
      # -k: this is a reachability probe (does the route answer over the tailnet), not a certificate check
      code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve "$label.$DOMAIN:443:$tsip" "https://$label.$DOMAIN/" 2>/dev/null)
      case "$code" in
        2??|3??|401) ok "tailnet route $label.<domain> answers ($code)";;
        000|"") inc "tailnet route $label.<domain>: could not connect — is this workstation on the tailnet? (not counted as a pass or a fail)";;
        *) bad "tailnet route $label.<domain> returned '$code' over the tailnet";;
      esac
    done
  fi
fi

# ---------------------------------------------------------------------------------------------------
printf '\n== summary ==\n  %d passed, %d FAILED, %d inconclusive, %d skipped\n' "$PASS" "$FAIL" "$INCONCLUSIVE" "$SKIP"
(( INCONCLUSIVE + SKIP > 0 )) && echo "  (inconclusive and skipped checks are NOT passes — see above)"
(( FAIL == 0 ))
