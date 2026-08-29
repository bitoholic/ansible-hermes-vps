#!/usr/bin/env bash
# Renders the shared roles/hermes/templates/config.yaml.j2 for every profile in
# hermes_profiles and asserts structural invariants (epic 02 ticket #02/#03 guard).
# Ensures removing a per-profile config template never silently drops a profile's config.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ansible.cfg sets become=true; these local render tests must not escalate.
export ANSIBLE_BECOME=false

# Stub the env vars the profile lookups read so rendered values are non-empty.
export NOUS_PORTAL_API_KEY=dummy-nous \
       CONTEXT7_API_KEY_CODER=dummy-c7

echo "== hermes profile config render invariants =="
ansible-playbook tests/test_config_render.yml
echo "config render OK"
