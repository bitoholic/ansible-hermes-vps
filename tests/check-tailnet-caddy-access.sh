#!/usr/bin/env bash
# Epic 20 (preserve real source IP for tailnet-facing Caddy access) full-epic guard —
# ticket #01.
#
# The shared test files (tests/test_gateway_render.yml, tests/test_docker_compose.yml)
# already cover the rendered shape in depth: the internal PROXY-protocol listener, its
# `allow` restriction, the v6 matcher extension, the exact-5-routes second-address
# count, and caddy-relay's compose shape. Re-run here too, per this repo's established
# per-epic-summary-script convention. This script adds what isn't covered by rendering
# a synthetic fixture: assertions against the REAL template/task files themselves, and
# the security-critical "don't reintroduce the broken third-party module" regression
# guard a synthetic render can't express.
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
check_in "$HAPROXY_CFG" '^\s*chroot /var/empty\s*$' "haproxy.cfg.j2 must chroot after binding (confirmed /var/empty exists in the pinned image)"
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
check_in "$CADDY_FRAGMENT" '127\.0\.0\.1:\{\{ caddy_proxy_protocol_port \}\}' "caddy must publish the internal PROXY-protocol listener to loopback only"
echo "caddy compose fragment shape OK"

# 5b: Caddyfile.j2's internal listener must trust more than just loopback — found on
# a real live deploy that caddy-relay's own connection to this listener transits
# Docker's port-publish NAT for 127.0.0.1:{{ caddy_proxy_protocol_port }}, which
# rewrites ITS source to the gateway network's bridge address, not literal loopback.
# A loopback-only allow list silently defeats the entire fix (Caddy falls back to
# the raw, NAT'd peer address exactly like the original bug being fixed).
check_in roles/gateway/templates/Caddyfile.j2 '172\.16\.0\.0/12' "Caddyfile.j2's proxy_protocol allow list must include Docker's bridge address pool, not just loopback"

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

# 7: caddy_proxy_protocol_port is defined once, as a real named constant, not a
# magic number scattered across files.
check_in group_vars/all/main.yml '^caddy_proxy_protocol_port:' "caddy_proxy_protocol_port must be defined in group_vars/all/main.yml"
echo "caddy_proxy_protocol_port defined OK"

echo "tailnet-caddy-access guard OK"
