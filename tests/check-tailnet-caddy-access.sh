#!/usr/bin/env bash
# Epic 20 (preserve real source IP for tailnet-facing Caddy access) full-epic guard —
# ticket #01.
#
# The shared test files (tests/test_gateway_render.yml, tests/test_docker_compose.yml)
# already cover the rendered shape in depth: the internal PROXY-protocol Unix-socket
# listener, its `allow` restriction, the v6 matcher extension, the exact-5-routes
# second-block count, and caddy-relay's compose shape. Re-run here too, per this
# repo's established per-epic-summary-script convention. This script adds what isn't
# covered by rendering a synthetic fixture: assertions against the REAL
# template/task files themselves, and two security-critical regression guards a
# synthetic render can't express — "don't reintroduce the broken third-party
# module" and "don't reintroduce the IP-allowlist auth-bypass this epic's own
# review caught" (see section 5b below).
#
# What this script does NOT and cannot verify: the actual live behavior this epic
# fixes — a real Tailscale client's traffic surviving the masquerade round-trip,
# HAProxy actually forwarding with a real PROXY protocol header, Caddy actually
# recognizing the real source IP again. There is no Tailscale network, no real
# masquerade, and no real PROXY-protocol handshake available in a rendering-only test
# environment — that verification is operator-validated on the real VPS, per this
# repo's established practice for anything requiring live network state (epic 18's
# DNS handover, epic 19's DNS-01 issuance).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false
# shellcheck source=support/yaml_block_assertions.sh
source "$REPO_ROOT/tests/support/yaml_block_assertions.sh"

# line_of <file> <pattern> — first matching line number, or empty. Same shape as
# tests/check-adguard-dns.sh's own (not shared yet — only two callers exist so far,
# below this repo's own established "unify at a third caller" threshold). `-e`
# before the pattern (not just `grep -nE "$2"`): this system's grep is ugrep, which
# — unlike GNU grep — treats a pattern starting with `-` (e.g. `- name: ...`, a
# real, needed pattern here) as an option flag and errors out rather than
# searching; verified empirically (a bare call reproduced "invalid option - name:
# ...") before adding this.
line_of() { grep -nE -e "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

echo "== tailnet-caddy-access guard (epic 20) =="

# 1: consolidated compose + gateway render — internal listener, allow restriction, v6
# matchers, second-address count, caddy-relay shape (asserted by the shared test files
# themselves; re-run here per convention above).
ansible-playbook tests/test_docker_compose.yml
echo "docker compose render OK"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f /tmp/docker_compose_test/docker-compose.yml config -q
  echo "docker compose config OK"
else
  echo "SKIP docker compose config (docker not available)"
fi
ansible-playbook tests/test_gateway_render.yml
echo "gateway render (tailnet-caddy-access) OK"

# 2: the Dockerfile must NOT compile in a third-party proxy-protocol module — a real
# regression this epic's own implementation hit and reverted (verified via an actual
# xcaddy build on the live VPS: compiling in github.com/mastercactapus/caddy2-
# proxyprotocol panics at runtime with "module already registered", since Caddy
# 2.11.4 already ships caddy.listeners.proxy_protocol natively). A future edit
# re-adding it would silently reintroduce a build-breaking regression that only
# surfaces at actual `xcaddy build` time, not at Dockerfile-syntax-check time.
DOCKERFILE=roles/gateway/files/Dockerfile
if grep -q -- '--with github\.com/mastercactapus/caddy2-proxyprotocol' "$DOCKERFILE"; then
  echo "FAIL: $DOCKERFILE compiles in a third-party proxy-protocol module — caddy.listeners.proxy_protocol already ships natively in the pinned Caddy version and this panics at build time (module already registered)"
  exit 1
fi
echo "Dockerfile third-party proxy-protocol module regression guard OK"

# 3: caddy-relay's config template — send-proxy-v2 (not v1), and both bind lines are
# conditional on their address fact being non-empty (an unconditional `bind :443`
# with an empty tailscale_ip_v4/v6 fact would silently become an unscoped,
# all-interfaces bind, defeating the entire point of this relay).
HAPROXY_CFG=roles/gateway/templates/haproxy.cfg.j2
check_in "$HAPROXY_CFG" 'send-proxy-v2' "haproxy.cfg.j2 must use PROXY protocol v2 (send-proxy-v2), not v1"
check_in "$HAPROXY_CFG" '\{% if tailscale_ip_v4 %\}' "haproxy.cfg.j2's v4 bind line must be conditional on the fact being non-empty"
check_in "$HAPROXY_CFG" '\{% if tailscale_ip_v6 %\}' "haproxy.cfg.j2's v6 bind line must be conditional on the fact being non-empty"
# user/group haproxy: found on the live VPS via a real crash-loop — without these,
# the master process (started as root, per caddy-relay.yml.j2's own comment) never
# drops privileges at all, running every worker as root indefinitely.
check_in "$HAPROXY_CFG" '^\s*user haproxy\s*$' "haproxy.cfg.j2 must drop to the unprivileged haproxy user after binding"
check_in "$HAPROXY_CFG" '^\s*group haproxy\s*$' "haproxy.cfg.j2 must drop to the unprivileged haproxy group after binding"
# chroot INTO the shared socket directory itself, not /var/empty (an earlier
# version of this file's own choice) — a chroot to /var/empty would make the
# Unix socket below UNREACHABLE post-chroot at connect() time. Caught before
# deploying by reasoning through Linux chroot()/connect()-time path
# resolution, not via a live crash-loop.
check_in "$HAPROXY_CFG" '^\s*chroot \{\{ caddy_relay_socket_container_path \}\}\s*$' "haproxy.cfg.j2 must chroot into the shared socket directory (not /var/empty, which would make the socket unreachable post-chroot)"
check_in "$HAPROXY_CFG" 'server caddy unix@/\{\{ caddy_relay_socket_filename \}\} send-proxy-v2' "haproxy.cfg.j2's backend must forward to Caddy over the shared Unix socket, not a TCP address"
if grep -qE '^\s*bind :443\s*$' "$HAPROXY_CFG"; then
  echo "FAIL: $HAPROXY_CFG has an unconditional 'bind :443' line — would silently become an unscoped, all-interfaces bind if a tailscale IP fact were ever empty"
  exit 1
fi
echo "haproxy.cfg.j2 shape OK"

# 4: caddy-relay's compose fragment — host networking (to bind the Tailscale
# interface's IP directly, same precedent as beszel-agent) and a pinned image (no
# floating :latest, matching this repo's standing convention for every other image).
RELAY_FRAGMENT=roles/docker/templates/services/caddy-relay.yml.j2
check_in "$RELAY_FRAGMENT" 'network_mode: host' "caddy-relay must run with network_mode: host"
if grep -qi ':latest' "$RELAY_FRAGMENT"; then
  echo "FAIL: $RELAY_FRAGMENT pins a floating :latest tag — version must be explicit"
  exit 1
fi
# Security fix (found in review, PR #105): the internal listener is a shared Unix
# domain socket, NOT a Docker-published TCP port — a loopback TCP port + IP
# allow-list could never actually distinguish "the relay" from any other
# host-networked container (beszel-agent already is one) or host-level process,
# since Docker's own port-publish NAT rewrites every such connection's source to
# the same bridge address range. A Unix socket has no network-layer identity to
# spoof: only a container with this exact directory bind-mounted can reach it.
check_in "$RELAY_FRAGMENT" '\{\{ caddy_relay_socket_dir \}\}:\{\{ caddy_relay_socket_container_path \}\}' "caddy-relay must bind-mount the shared socket directory, not publish a TCP port"
if grep -qE 'ports:' "$RELAY_FRAGMENT"; then
  echo "FAIL: $RELAY_FRAGMENT publishes a Docker port — the internal listener must be a Unix socket only, reachable exclusively via the shared bind-mounted directory"
  exit 1
fi
echo "caddy-relay compose fragment shape OK"

# 5: Caddy's own compose fragment — 443 must be scoped to a specific address
# (ansible_default_ipv4.address), never a bare, unscoped "443:443" — that would
# leave 0.0.0.0:443 bound and there would be no free <tailscale-ip>:443 combination
# left for caddy-relay to claim, silently defeating the whole design.
CADDY_FRAGMENT=roles/docker/templates/services/caddy.yml.j2
if grep -qE '^\s*-\s*"443:443"\s*$' "$CADDY_FRAGMENT"; then
  echo "FAIL: $CADDY_FRAGMENT still publishes 443 unscoped (bare \"443:443\") — must be IP-scoped so caddy-relay has a free <tailscale-ip>:443 to bind"
  exit 1
fi
check_in "$CADDY_FRAGMENT" 'ansible_default_ipv4\.address' "caddy's 443 publish must be scoped to this VPS's own public IP"
check_in "$CADDY_FRAGMENT" '\{\{ caddy_relay_socket_dir \}\}:\{\{ caddy_relay_socket_container_path \}\}' "caddy must bind-mount the shared socket directory for the internal PROXY-protocol listener"
if grep -qE 'caddy_proxy_protocol_port' "$CADDY_FRAGMENT"; then
  echo "FAIL: $CADDY_FRAGMENT still references caddy_proxy_protocol_port — the internal listener was redesigned as a Unix socket (no TCP port at all, see caddy_relay_socket_dir)"
  exit 1
fi
echo "caddy compose fragment shape OK"

# 5b: Caddyfile.j2's internal listener's allow-list must NOT include Docker's
# bridge pool. Security fix (found in review, PR #105): an earlier version of this
# listener was a loopback TCP port with `allow 127.0.0.1/32 ::1/128 172.16.0.0/12`
# — added to work around Docker's port-publish NAT rewriting caddy-relay's own
# source to a bridge address, but 172.16.0.0/12 is Docker's ENTIRE default bridge
# pool, not "just the relay": any host-networked container (beszel-agent already
# is one, network_mode: host) or host-level process could reach the same
# Docker-published loopback port, get NAT'd to the same apparent address, and
# forge a PROXY header claiming an arbitrary tailnet source IP — fully bypassing
# both mfa_auth and tailnet_only. This is a hard regression guard, not a
# judgement call: a future change reintroducing an IP-based allow-list here
# (rather than the current Unix-socket design) must fail this check.
if grep -q '172\.16\.0\.0/12' roles/gateway/templates/Caddyfile.j2; then
  echo "FAIL: roles/gateway/templates/Caddyfile.j2 allows Docker's entire bridge pool (172.16.0.0/12) to present a trusted PROXY header — this was a confirmed auth-bypass vector (any host-networked container, e.g. beszel-agent, or host-level process could forge a source IP and bypass mfa_auth/tailnet_only). The internal listener must be a Unix socket scoped by bind-mount, not an IP allow-list."
  exit 1
fi
# relay_socket_bind is computed once from the shared caddy_relay_socket_*
# group_vars and used both for the internal listener's own `servers` address
# and every gated route's `bind` line — structurally the same value on both
# sides (no more literal-string byte-for-byte match to drift), see
# group_vars/all/main.yml's own comment.
check_in roles/gateway/templates/Caddyfile.j2 "set relay_socket_bind = 'unix/' ~ caddy_relay_socket_container_path ~ '/' ~ caddy_relay_socket_filename ~ '\|' ~ caddy_relay_socket_permission" "Caddyfile.j2 must compute its internal listener's Unix-socket address from the shared caddy_relay_socket_* group_vars, not a hardcoded literal"
check_in roles/gateway/templates/Caddyfile.j2 'servers \{\{ relay_socket_bind \}\} \{' "Caddyfile.j2's internal listener must be a Unix socket, not a TCP port"
check_in group_vars/all/main.yml '^caddy_relay_socket_container_path:' "caddy_relay_socket_container_path must be defined in group_vars/all/main.yml"
check_in group_vars/all/main.yml '^caddy_relay_socket_filename:' "caddy_relay_socket_filename must be defined in group_vars/all/main.yml"
check_in group_vars/all/main.yml '^caddy_relay_socket_permission:' "caddy_relay_socket_permission must be defined in group_vars/all/main.yml"
check_in roles/gateway/templates/Caddyfile.j2 'bind_line=relay_socket_bind' "gated routes' second site block must bind the shared Unix socket, via the same relay_socket_bind the internal listener itself uses"
echo "Caddyfile.j2 internal listener security boundary OK (Unix socket, no Docker bridge pool trust)"

# 5c: a Caddyfile/haproxy.cfg content-only change (no compose-fragment change
# alongside it) must actually take effect — found on a real live deploy that
# `docker compose up`'s own change-detection does not recreate a container just
# because a bind-mounted file's content changed on disk. Every past Caddyfile
# change in this repo's history happened to also touch the compose fragment,
# which is exactly why this went unnoticed until now.
GATEWAY_TASKS=roles/gateway/tasks/main.yml
GATEWAY_HANDLERS=roles/gateway/handlers/main.yml
[[ -f "$GATEWAY_HANDLERS" ]] || { echo "FAIL: $GATEWAY_HANDLERS does not exist"; exit 1; }
check_in "$GATEWAY_HANDLERS" '^- name: Restart caddy$' "gateway handlers must define a 'restart caddy' handler"
check_in "$GATEWAY_HANDLERS" '^- name: Restart caddy-relay$' "gateway handlers must define a 'restart caddy-relay' handler"
# Line-number ordering, not entry_has/block_of: a plain task-list item's boundary
# (the next `- name:` at the same indent) doesn't match block_of's "next bare-word
# key at column 0" boundary rule (designed for group_vars-style YAML, not task
# lists) — verified empirically that block_of silently swallows every task after
# the first one here, which would make this check pass even if notify: were
# missing entirely. Confirms each notify: line falls strictly between its own
# task's "- name:" line and the next task's, i.e. it's attached to the right task.
# `|| true` on each: under `set -o pipefail`, line_of's internal pipeline
# (grep | head | cut) propagates grep's own "no match" exit code as the whole
# function's exit status — without `|| true`, a bare assignment like this one
# trips `set -e` and exits immediately on a genuine no-match case, skipping
# straight past the graceful "FAIL: could not find..." loop below entirely
# (verified empirically: reproduced this exact silent-exit-with-no-message
# failure before adding `|| true` here).
DEPLOY_CADDYFILE_LINE="$(line_of "$GATEWAY_TASKS" '- name: Deploy Caddyfile')" || true
DEPLOY_HAPROXY_LINE="$(line_of "$GATEWAY_TASKS" '- name: Deploy haproxy\.cfg')" || true
NOTIFY_CADDY_LINE="$(line_of "$GATEWAY_TASKS" 'notify: Restart caddy$')" || true
NOTIFY_RELAY_LINE="$(line_of "$GATEWAY_TASKS" 'notify: Restart caddy-relay')" || true
for pair in "DEPLOY_CADDYFILE_LINE:the Deploy Caddyfile task" "DEPLOY_HAPROXY_LINE:the Deploy haproxy.cfg task" "NOTIFY_CADDY_LINE:notify: restart caddy" "NOTIFY_RELAY_LINE:notify: restart caddy-relay"; do
  name="${pair##*:}"; var="${pair%%:*}"
  [[ -n "${!var}" ]] || { echo "FAIL: could not find $name in $GATEWAY_TASKS"; exit 1; }
done
if (( NOTIFY_CADDY_LINE <= DEPLOY_CADDYFILE_LINE )) || (( NOTIFY_CADDY_LINE >= DEPLOY_HAPROXY_LINE )); then
  echo "FAIL: notify: restart caddy is not attached to the Deploy Caddyfile task"
  exit 1
fi
if (( NOTIFY_RELAY_LINE <= DEPLOY_HAPROXY_LINE )); then
  echo "FAIL: notify: restart caddy-relay is not attached to (or comes before) the Deploy haproxy.cfg task"
  exit 1
fi
echo "Caddy/caddy-relay config-reload handler wiring OK"

# 6: the tailscale role must query this host's own Tailscale IP(s) AFTER "Bring up
# Tailscale" — the tailscale0 interface (and therefore any address on it) doesn't
# exist before that task has run.
TS_TASKS=roles/tailscale/tasks/main.yml
# `|| true` on each: see the comment above the Caddyfile/haproxy.cfg ordering
# check for why a bare assignment here would otherwise skip past the
# graceful "FAIL: could not find..." loop below under set -o pipefail.
BRING_UP_LINE="$(line_of "$TS_TASKS" 'Bring up Tailscale')" || true
QUERY_V4_LINE="$(line_of "$TS_TASKS" "Query this host's own Tailscale IPv4 address")" || true
QUERY_V6_LINE="$(line_of "$TS_TASKS" "Query this host's own Tailscale IPv6 address")" || true
for pair in "BRING_UP_LINE:the Bring up Tailscale task" "QUERY_V4_LINE:the Tailscale IPv4 query" "QUERY_V6_LINE:the Tailscale IPv6 query"; do
  name="${pair##*:}"; var="${pair%%:*}"
  [[ -n "${!var}" ]] || { echo "FAIL: could not find $name in $TS_TASKS"; exit 1; }
done
if (( QUERY_V4_LINE <= BRING_UP_LINE )) || (( QUERY_V6_LINE <= BRING_UP_LINE )); then
  echo "FAIL: the Tailscale IP queries must run AFTER Bring up Tailscale (tailscale0 doesn't exist before that)"
  exit 1
fi
check_in "$TS_TASKS" "ignore_errors: .\{\{ ansible_check_mode \}\}." "the Tailscale IP query tasks must tolerate --check (command modules don't run under check mode)"
echo "tailscale IP fact-gathering ordering OK"

# 7: caddy_relay_socket_dir is defined once, as a real named constant, not a
# magic path scattered across files.
check_in group_vars/all/main.yml '^caddy_relay_socket_dir:' "caddy_relay_socket_dir must be defined in group_vars/all/main.yml"
echo "caddy_relay_socket_dir defined OK"

# 8: the gateway role must actually create the shared socket directory before
# either container tries to bind-mount it — same wiki_volume ensure_directory
# pattern beszel's own hub<->agent socket dir uses.
check_in "$GATEWAY_TASKS" 'wiki_volume_directory_path: "\{\{ caddy_relay_socket_dir \}\}"' "gateway role must ensure the shared caddy-relay socket directory exists before it's bind-mounted"
echo "caddy-relay socket directory provisioning OK"

echo "tailnet-caddy-access guard OK"
