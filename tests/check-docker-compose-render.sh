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

# Static docker-compose-syntax validation, including Compose's own $VAR/${VAR} interpolation —
# catches a real bug class the Jinja-render assertions above cannot: ticket #07's live attended
# validation (epic 23) found that an unescaped `$` meant for a container's own shell (inside a
# HEALTHCHECK test command) gets silently resolved by Compose itself against its own unset
# variable namespace and replaced with an empty string, with no Jinja-render-time signal at all —
# only `docker compose config` actually exercises Compose's interpolation step.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f "${TMPDIR:-/tmp}/docker_compose_test/docker-compose.yml" config -q
  echo "docker compose config OK"
else
  echo "SKIP docker compose config (docker not available)"
fi
