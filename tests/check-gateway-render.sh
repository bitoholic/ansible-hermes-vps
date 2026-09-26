#!/usr/bin/env bash
# Renders the gateway Caddyfile adapter from gateway_routes and asserts its external behavior
# (epic 03 ticket #04 guard, later ticket #00 dropped the legacy Caddyfile byte-equivalence
# check when Conduit's route moved off a hardcoded block): one site block per route with
# mfa_auth applied unless mfa: false, and fail-fast on malformed routes. Ensures the ingress
# can't drift from the declared route list.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ansible.cfg sets become=true; these local render tests must not escalate.
export ANSIBLE_BECOME=false

# Stub the env var the resolver reads so the gateway role's include_vars of per-role defaults is
# inert here (the test assembles gateway_routes directly from those defaults).
export SILVERBULLET_DOMAIN=test.example.com

echo "== gateway Caddyfile render invariants =="
ansible-playbook tests/test_gateway_render.yml
echo "gateway render OK"
