#!/usr/bin/env bash
# Epic 23 ticket #04 guard: the default location list, and the proof that adding a
# location is one list entry.
#
# Re-runs the two existing render checks that already carry this ticket's core proof
# (tests/check-exit-nodes-render.sh: the exit_nodes schema itself, default list and a
# three-entry fixture; tests/check-docker-compose-render.sh: renders the consolidated
# compose, including test_docker_compose.yml's three-entry london/warsaw/zurich fixture,
# proving the list-driven fragment mechanism scales to N pairs with no other change), then
# adds assertions directly against the REAL template/task/group_vars files this depends on
# — not the render tests' own fixtures — so a future edit to those files can't silently
# drift from what the render tests proved once and never check again.
#
# Honest limit: everything here is static. It cannot prove a location's tunnel actually
# reaches Windscribe, that DNS/live routing works, or that a third real location behaves
# like the fixture claims — that's ticket #01's live spike (one location, evidence-based)
# and the epic's own attended validation (ticket #07, phone test) for the real fleet.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=support/yaml_block_assertions.sh
source "$REPO_ROOT/tests/support/yaml_block_assertions.sh"

echo "== exit-node location scaling guard (epic 23 #04) =="

echo "-- re-running the render assertions --"
./tests/check-exit-nodes-render.sh
./tests/check-docker-compose-render.sh

DEFAULTS=roles/exit_nodes/defaults/main.yml
FRAGMENT=roles/docker/templates/services/exit_node_pair.yml.j2
GROUP_VARS=group_vars/all/main.yml
DOCKER_DEFAULTS=roles/docker/defaults/main.yml

echo "-- real default list: exactly London + Warsaw --"
entry_count="$(grep -cE '^\s*- name:' "$DEFAULTS")"
[ "$entry_count" -eq 2 ] || { echo "FAIL: $DEFAULTS: expected exactly 2 default entries, found $entry_count" >&2; exit 1; }
entry_has "$DEFAULTS" '^exit_nodes:' 'name: london' "default list must contain london"
entry_has "$DEFAULTS" '^exit_nodes:' 'name: warsaw' "default list must contain warsaw"
entry_has "$DEFAULTS" '^exit_nodes:' 'region: United Kingdom' "default list must set region: United Kingdom (london)"
entry_has "$DEFAULTS" '^exit_nodes:' 'city: London' "default list must set city: London"
entry_has "$DEFAULTS" '^exit_nodes:' 'region: Poland' "default list must set region: Poland (warsaw)"
entry_has "$DEFAULTS" '^exit_nodes:' 'city: Warsaw' "default list must set city: Warsaw"
echo "default list OK (exactly 2 entries: london/United Kingdom/London, warsaw/Poland/Warsaw)"

echo "-- real fragment template: generic by construction, not hardcoded per location --"
if grep -qiE 'london|warsaw|zurich' "$FRAGMENT"; then
  echo "FAIL: $FRAGMENT references a location literally — it must stay generic via item.name/item.region/item.city" >&2
  exit 1
fi
for field in name region city; do
  grep -q "item.${field}" "$FRAGMENT" || { echo "FAIL: $FRAGMENT does not reference item.${field}" >&2; exit 1; }
done
echo "fragment genericity OK (no location hardcoded, item.name/region/city all referenced)"

echo "-- distinct name, hostname and state directory per pair (real fragment) --"
grep -q -- '-{{ item.name }}-tunnel' "$FRAGMENT" || { echo "FAIL: $FRAGMENT: container/service names are not keyed by item.name" >&2; exit 1; }
grep -q -- '--hostname={{ exit_nodes_hostname_prefix }}-ws-{{ item.name }}' "$FRAGMENT" || { echo "FAIL: $FRAGMENT: tailnet hostname is not keyed by item.name" >&2; exit 1; }
grep -q -- '{{ exit_nodes_state_dir }}/{{ item.name }}:/var/lib/tailscale' "$FRAGMENT" || { echo "FAIL: $FRAGMENT: Tailscale state directory is not keyed by item.name" >&2; exit 1; }
echo "distinct name/hostname/state-directory-per-pair OK"

echo "-- one shared environment file, no per-location secrets (real fragment) --"
# The credentials path itself must stay a plain, non-item-templated reference — the whole
# point of "one credential set serves every location" (ticket #03's own documented decision,
# same file referenced by every pair, not one file per item.name).
if grep -E 'env_file' -A2 "$FRAGMENT" | grep -q 'item.name'; then
  echo "FAIL: $FRAGMENT: env_file path is templated by item.name — secrets must be shared, not per-location" >&2
  exit 1
fi
shared_refs="$(grep -cE 'path: "\{\{ exit_nodes_credentials_file \}\}"' "$FRAGMENT" || true)"
[ "${shared_refs:-0}" -ge 1 ] || {
  echo "FAIL: $FRAGMENT: expected at least one service to reference the single shared exit_nodes_credentials_file" >&2
  exit 1
}
echo "shared-credentials-file OK"

echo "-- wired generically into the docker role, not exit-node-specific code --"
entry_has "$GROUP_VARS" '^docker_list_fragments:' 'entries: "{{ exit_nodes }}"' "docker_list_fragments must wire the real exit_nodes list"
entry_has "$GROUP_VARS" '^docker_list_fragments:' 'template: .*exit_node_pair\.yml\.j2' "docker_list_fragments must point at the exit_node_pair fragment"
entry_lacks "$DOCKER_DEFAULTS" '^docker_enabled_services:' 'exit.?node' "docker_enabled_services must not also list an exit-node service (it renders only through docker_list_fragments, never twice)"
echo "generic wiring OK"

echo "exit-node location scaling guard OK"
