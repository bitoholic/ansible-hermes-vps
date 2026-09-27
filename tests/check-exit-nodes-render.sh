#!/usr/bin/env bash
# Exit-node schema/list validation test (epic 23 ticket #02): asserts the schema's own shape, that
# the default list (London + Warsaw) and a three-entry fixture pass validation, and that malformed
# entries (duplicate/invalid/missing name, empty region, missing city, empty list) and a malformed
# hostname prefix (an IP-shaped deploy target, a dotted or over-long explicit override) all fail
# fast at deploy time naming the offending value.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export ANSIBLE_BECOME=false

echo "== exit_nodes schema/list validation invariants =="
ansible-playbook tests/test_exit_nodes_render.yml
echo "exit_nodes validation OK"
