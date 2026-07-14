#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ansible-playbook --syntax-check site.yml
ansible-playbook --syntax-check tests/test_playbook.yml

echo "Verification complete: syntax checks passed for site.yml and tests/test_playbook.yml."
