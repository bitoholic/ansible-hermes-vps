#!/usr/bin/env bash
# Behaviorally exercises the hermes profile render loop (epic 02 ticket #05): renders every
# profile's config.yaml/SOUL.md/.env/skills into a temp dir and asserts the external contract
# (N profiles -> N file sets, default present, .env regression, per-profile secret scoping).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ansible.cfg sets become=true; these local render tests must not escalate.
export ANSIBLE_BECOME=false

# Stub the env vars the profile lookups read (none remain after #04, but keep harmless).
export NOUS_PORTAL_API_KEY=dummy-nous \
       CONTEXT7_API_KEY_CODER=dummy-c7

echo "== hermes profile render behavioral test =="
ansible-playbook tests/test_hermes_profile.yml
echo "profile render OK"
