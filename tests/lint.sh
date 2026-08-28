#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v ansible-lint >/dev/null 2>&1; then
  echo "ansible-lint is not installed" >&2
  exit 1
fi

ansible-playbook --syntax-check site.yml >/tmp/hermes-syntax.log
ansible-playbook --syntax-check tests/test_playbook.yml >/tmp/hermes-test-syntax.log
ansible-lint site.yml tests/test_playbook.yml tests/test_resolver.yml

# Single-seam contract: only the `secrets` resolver role may read credentials from the
# environment. Any other `lookup('env', …)` for a secret is a regression against the seam.
# Comments (#) and the resolver role itself are excluded. The per-profile Hermes secrets
# that were a temporary exception are now sourced from secrets.profiles.* (epic 02 #04),
# so no exception remains.
if grep -rnE "lookup\([^)]*env" roles/ group_vars/all/main.yml site.yml tests/test_playbook.yml tests/test_resolver.yml \
    | grep -v '#' \
    | grep -v "roles/secrets/"; then
  echo "FAIL: lookup('env', …) used outside the secrets resolver (single-seam contract)" >&2
  exit 1
fi

# Ensure operator-facing env catalogs (.env.template, setup-env.sh) stay in sync
# with the secret manifest. Regenerate with: python3 scripts/generate-env.py
python3 scripts/generate-env.py --check

# Resolver unit test: crafted-env resolution + fail-fast naming (runs under --check).
./tests/check-resolver.sh

# Hermes profile config render invariants (epic 02 ticket #02/#03 guard): every profile
# renders through the single shared config.yaml.j2 without losing its shape.
./tests/check-config-render.sh
