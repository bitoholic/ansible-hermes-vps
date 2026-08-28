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

# Single-seam contract: only the `secrets` resolver role may read secrets from the
# environment. Any other `lookup('env', …)` for a secret is a regression. The only
# intentional exception is the deferred per-profile consumption in group_vars/all/main.yml
# (hermes_profiles -> OPENROUTER_API_KEY_CODER/INTEL, NOUS_PORTAL_API_KEY, CONTEXT7_API_KEY_CODER),
# which will move to secrets.profiles.* in a later change. Comments (#) and the lint
# script itself are excluded so the guard does not match its own prose.
if grep -rnE "lookup\([^)]*env" roles/ group_vars/all/main.yml site.yml tests/test_playbook.yml tests/test_resolver.yml \
    | grep -v '#' \
    | grep -v "roles/secrets/" \
    | grep -vE "OPENROUTER_API_KEY_CODER|OPENROUTER_API_KEY_INTEL|NOUS_PORTAL_API_KEY|CONTEXT7_API_KEY_CODER"; then
  echo "FAIL: lookup('env', …) used outside the secrets resolver (single-seam contract)" >&2
  exit 1
fi

# Ensure operator-facing env catalogs (.env.template, setup-env.sh) stay in sync
# with the secret manifest. Regenerate with: python3 scripts/generate-env.py
python3 scripts/generate-env.py --check

# Resolver unit test: crafted-env resolution + fail-fast naming (runs under --check).
./tests/check-resolver.sh
