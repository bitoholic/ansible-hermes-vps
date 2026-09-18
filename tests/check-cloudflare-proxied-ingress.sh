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

echo "== cloudflare-proxied-ingress guard (epic 19) =="

check_in() { grep -qEi "$2" "$1" || { echo "FAIL: $1 missing: $3"; exit 1; }; }

# block_of/entry_has: same boundary-aware shape as tests/check-second-wave-services.sh's own
# (see that file's comment for why a fixed-line `grep -A<N>` window doesn't have this guarantee
# — verified empirically there to silently pass a real regression).
block_of() {
  local key_pat="$2"
  local indent="${key_pat#^}"; indent="${indent%%[^ ]*}"
  awk -v key_pat="$key_pat" -v exit_pat="^${indent}[A-Za-z_]" '
    $0 ~ key_pat { found=1; print; next }
    found && $0 ~ exit_pat { exit }
    found { print }
  ' "$1"
}
entry_has() { block_of "$1" "$2" | grep -qE "$3" || { echo "FAIL: $1 missing: $4"; exit 1; }; }
entry_lacks() { if block_of "$1" "$2" | grep -qE "$3"; then echo "FAIL: $1: $4"; exit 1; fi; }

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

echo "cloudflare-proxied-ingress guard OK"
