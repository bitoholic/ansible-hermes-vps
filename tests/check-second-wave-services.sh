#!/usr/bin/env bash
# Epic 18 (second-wave custom services) full-epic guard — ticket #06.
#
# Mirrors epic 12's own tests/check-custom-services.sh: a consolidated,
# epic-wide pass proving the epic's three services (OwnTracks frontend, Beszel,
# AdGuard) and the new tailnet_only route type integrate correctly, re-running
# the shared render tests here too (epic 12's own established convention,
# not accidental duplication — check-custom-services.sh does the same for
# test_docker_compose.yml/test_gateway_render.yml). This script covers what
# isn't already owned by a per-ticket script: tests/check-adguard-dns.sh
# (ticket #05) already covers the DNS-sequencing specifics in depth, and
# tests/check-role-ordering.sh (extended by this same ticket) covers the
# gateway-dependency/no-duplicate-execution proof for beszel and adguard.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false
# shellcheck source=support/yaml_block_assertions.sh
source "$REPO_ROOT/tests/support/yaml_block_assertions.sh"

echo "== second-wave services guard (epic 18) =="

# 1: consolidated compose + gateway render — all four new services, all three
# new tailnet_only routes, every pre-existing route unchanged (asserted by the
# shared test files themselves; re-run here per the epic-12 convention noted
# above).
ansible-playbook tests/test_docker_compose.yml
echo "docker compose render OK"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f /tmp/docker_compose_test/docker-compose.yml config -q
  echo "docker compose config OK"
else
  echo "SKIP docker compose config (docker not available)"
fi

ansible-playbook tests/test_gateway_render.yml
echo "gateway render (second-wave services) OK"

# 2: firewall — Beszel hub (8090) and AdGuard admin UI (3001) are in the REAL
# TCP-restricted list (group_vars/all/main.yml), not just test_docker_compose.yml's
# own separately-maintained mirror of it (that mirror could drift from
# production with nothing else catching it).
entry_has group_vars/all/main.yml '^docker_published_restricted_ports:' '  - 8090' "beszel hub port 8090 in docker_published_restricted_ports"
entry_has group_vars/all/main.yml '^docker_published_restricted_ports:' '  - 3001' "adguard admin UI port 3001 in docker_published_restricted_ports"
echo "TCP restricted-port firewall contract (beszel/adguard) OK"

# 3: secrets manifest SHAPE, not just presence — required/default correctness
# for the epic's new secrets. Beszel's key/token must stay required: false
# (ticket #03's near-miss deploy-deadlock: they can only be obtained after a
# first deploy already stood up the hub, so required: true would brick every
# future deploy of the whole VPS). AdGuard's password hash must stay
# required: true (operator-precomputed, no chicken-and-egg problem, unlike
# Beszel's).
SECRETS=group_vars/all/secrets.yml
for entry in beszel_agent_key beszel_agent_token adguard_admin_username adguard_admin_password_hash; do
  check_in "$SECRETS" "^  ${entry}:" "secrets manifest entry: $entry"
done
entry_has "$SECRETS" '^  beszel_agent_key:' 'required: false' "beszel_agent_key must stay required: false (ticket #03's deploy-deadlock fix)"
entry_has "$SECRETS" '^  beszel_agent_token:' 'required: false' "beszel_agent_token must stay required: false (ticket #03's deploy-deadlock fix)"
entry_has "$SECRETS" '^  adguard_admin_username:' 'default: "admin"' "adguard_admin_username missing its default"
entry_has "$SECRETS" '^  adguard_admin_password_hash:' 'required: true' "adguard_admin_password_hash must be required: true (operator-precomputed, no chicken-and-egg problem)"
echo "secrets manifest shape (required/default) OK"

# 4: env-catalog sync — already run unconditionally by tests/lint.sh; re-asserted
# here too since this is the epic-summary script, same belt-and-suspenders
# reasoning as check #1 above.
python3 scripts/generate-env.py --check
echo "env catalog sync OK"

# 5 (spec.md's own Testing Decisions, found missing in review — same class of
# gap as check #2 above): docker_enabled_services includes all four new
# services, and docker_volumes gained NO new entries (confirms the
# bind-mount-over-named-volume decision held), against the REAL
# roles/docker/defaults/main.yml — not test_docker_compose.yml's own hardcoded
# mirror of both lists.
DOCKER_DEFAULTS=roles/docker/defaults/main.yml
for svc in owntracks-frontend beszel-hub beszel-agent adguard; do
  entry_has "$DOCKER_DEFAULTS" '^docker_enabled_services:' "  - ${svc}\$" "docker_enabled_services includes ${svc}"
done
# caddy-relay (epic 20) isn't this epic's own service, but the exact-count check
# right below needs the real total to include it — spot-checked here too, same
# reasoning as the four services above.
entry_has "$DOCKER_DEFAULTS" '^docker_enabled_services:' '  - caddy-relay$' "docker_enabled_services includes caddy-relay (epic 20)"
# Exact count too (caught in review as an asymmetry with the docker_volumes
# exact-count check below): presence alone wouldn't catch a duplicate entry or
# an unrelated, unauthorized 5th addition slipping in alongside this epic's
# four. 13 = the 8 pre-epic-18 services (caddy, authelia, silverbullet,
# conduit, signal-cli, hermes-agent, owntracks, syncplay) + this epic's 4 +
# epic 20's caddy-relay (the tailnet-facing PROXY-protocol relay) — bumped
# from 12 by that later epic, not this one; kept here rather than duplicated
# into a separate epic-20 check since this IS the single existing exact-count
# assertion for this list.
DOCKER_ENABLED_COUNT="$(block_of "$DOCKER_DEFAULTS" '^docker_enabled_services:' | grep -c '  - ')"
if [[ "$DOCKER_ENABLED_COUNT" != "13" ]]; then
  echo "FAIL: $DOCKER_DEFAULTS docker_enabled_services has $DOCKER_ENABLED_COUNT entries, expected exactly 13 (8 pre-epic-18 + epic 18's 4 + epic 20's caddy-relay) — a duplicate or an unrelated addition may have slipped in"
  exit 1
fi
DOCKER_VOLUMES_COUNT="$(block_of "$DOCKER_DEFAULTS" '^docker_volumes:' | grep -c '  - ')"
if [[ "$DOCKER_VOLUMES_COUNT" != "3" ]]; then
  echo "FAIL: $DOCKER_DEFAULTS docker_volumes has $DOCKER_VOLUMES_COUNT entries, expected exactly 3 (caddy_data, caddy_config, syncplay_data) — epic 18 should not have added any named volumes (bind-mounts only)"
  exit 1
fi
echo "docker_enabled_services/docker_volumes (real file) OK"

# 6: skip-tags guard membership for the epic's two new roles — already asserted
# generically by tests/lint.sh's own role loop; spot-checked here too for the
# same reason as #4.
check_in tests/lint.sh '\bbeszel\b' "beszel in the skip-tags guard role list"
check_in tests/lint.sh '\badguard\b' "adguard in the skip-tags guard role list"
check_in README.md '`beszel`' "beszel in the README skippable-roles table"
check_in README.md '`adguard`' "adguard in the README skippable-roles table"
echo "skip-tags guard membership (beszel/adguard) OK"

echo "second-wave services guard OK"
