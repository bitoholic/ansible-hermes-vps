#!/usr/bin/env bash
# Epic 19 (Cloudflare-proxied ingress for matrix/owntracks) full-epic guard — ticket #03.
#
# Ticket #02's own test files (tests/test_gateway_render.yml, tests/test_docker_compose.yml,
# tests/check-resolver.sh) already cover: the port move + DNS-01 directive scoped to exactly
# matrix/owntracks, the Caddy service building (not pulling) from ticket #01's Dockerfile, and
# cloudflare_api_token resolving/fail-fasting correctly. Re-run here too, per this repo's
# established per-epic-summary-script convention (tests/check-custom-services.sh and
# tests/check-second-wave-services.sh both do the same for their own epics). This script adds
# what isn't already covered elsewhere: the Dockerfile's version pin (no `:latest`, both stages
# match) and the secrets manifest's required/no-default SHAPE for cloudflare_api_token (not just
# presence/fail-fast-naming, already checked by check-resolver.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false
# shellcheck source=support/yaml_block_assertions.sh
source "$REPO_ROOT/tests/support/yaml_block_assertions.sh"

echo "== cloudflare-proxied-ingress guard (epic 19) =="

# 1: consolidated compose + gateway render — port move, DNS-01 scoping, Caddy build-not-pull
# shape (asserted by the shared test files themselves; re-run here per convention above).
ansible-playbook tests/test_docker_compose.yml
echo "docker compose render OK"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f /tmp/docker_compose_test/docker-compose.yml config -q
  echo "docker compose config OK"
else
  echo "SKIP docker compose config (docker not available)"
fi
ansible-playbook tests/test_gateway_render.yml
echo "gateway render (matrix/owntracks 8443 + DNS-01 scoping) OK"

# 2: resolver fail-fast NAMING is already proven by tests/check-resolver.sh; this pins the
# manifest entry's actual SHAPE (required: true, no default: key at all) the same way
# tests/check-second-wave-services.sh pins beszel/adguard's secrets shape.
SECRETS=group_vars/all/secrets.yml
check_in "$SECRETS" '^  cloudflare_api_token:' "secrets manifest entry: cloudflare_api_token"
entry_has "$SECRETS" '^  cloudflare_api_token:' 'required: true' "cloudflare_api_token must be required: true (the operator creates the Cloudflare token ahead of any deploy — no chicken-and-egg problem)"
entry_lacks "$SECRETS" '^  cloudflare_api_token:' 'default:' "cloudflare_api_token must have no default (a real API token can't have a safe placeholder)"
echo "cloudflare_api_token secrets manifest shape OK"

# 3: env-catalog sync — already run unconditionally by tests/lint.sh; re-asserted here too,
# same belt-and-suspenders reasoning as check-second-wave-services.sh's own re-assertion.
python3 scripts/generate-env.py --check
echo "env catalog sync OK"

# 4: Caddy Dockerfile version pin (epic 19 #01; this ticket's own new coverage) — both the
# builder and runtime stages must reference the SAME explicit Caddy version, never `:latest`,
# so a plugin rebuild is reproducible and the two stages can't silently drift apart.
DOCKERFILE=roles/gateway/files/Dockerfile
if grep -qi ':latest' "$DOCKERFILE"; then
  echo "FAIL: $DOCKERFILE pins a floating :latest tag — version must be explicit"; exit 1
fi
BUILDER_VERSION="$(grep -oP '(?<=FROM caddy:)[^-\s]+(?=-builder)' "$DOCKERFILE" | head -1)"
RUNTIME_VERSION="$(grep -oP '(?<=^FROM caddy:)[^-\s]+$' "$DOCKERFILE" | head -1)"
if [ -z "$BUILDER_VERSION" ] || [ -z "$RUNTIME_VERSION" ]; then
  echo "FAIL: $DOCKERFILE missing an explicit Caddy version on the builder or runtime FROM line"; exit 1
fi
if [ "$BUILDER_VERSION" != "$RUNTIME_VERSION" ]; then
  echo "FAIL: $DOCKERFILE builder ($BUILDER_VERSION) and runtime ($RUNTIME_VERSION) Caddy versions differ"; exit 1
fi
echo "Caddy Dockerfile version pin OK ($BUILDER_VERSION, builder == runtime)"

# 5: stale 8448 UFW rate-limit rule cleanup (found on the first real deploy of this
# migration) — the rate-limit loop only ensures 8443 present, it doesn't remove a
# pre-existing 8448 rule from before this ticket, since plain ufw rules aren't
# declaratively rebuilt the way the DOCKER-USER chain is. Must be delete: true,
# not just present, or a host deployed before this ticket keeps an orphaned rule
# for a port nothing publishes anymore forever.
TS_TASKS=roles/tailscale/tasks/main.yml
entry_has "$TS_TASKS" 'Remove the stale 8448 rate-limit rule' 'delete: true' "8448 UFW cleanup task must delete the stale rule, not just ensure a rule present"
entry_has "$TS_TASKS" 'Remove the stale 8448 rate-limit rule' 'port: 8448' "8448 UFW cleanup task must target port 8448"
echo "stale 8448 UFW rule cleanup OK"

echo "cloudflare-proxied-ingress guard OK"
