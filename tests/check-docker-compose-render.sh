#!/usr/bin/env bash
# Renders the consolidated docker-compose.yml and asserts all enabled services
# are present and the file passes docker compose config validation.
# Ensures the docker role's consolidated compose file is valid and complete.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ansible.cfg sets become=true; these local render tests must not escalate.
export ANSIBLE_BECOME=false

echo "== docker compose render invariants =="
ansible-playbook tests/test_docker_compose.yml
echo "docker compose render OK"
