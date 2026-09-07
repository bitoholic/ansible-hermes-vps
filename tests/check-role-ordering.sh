#!/usr/bin/env bash
# Machine-checked role ordering (epic 15, ticket #01: gateway depends on owntracks).
#
# gateway's Caddyfile render reads htpasswd credentials owntracks's tasks generate as
# facts. This was correct in site.yml only by list position until this ticket declared
# it as a real roles/gateway/meta/main.yml dependency.
#
# IMPORTANT, discovered while implementing this ticket: Ansible does NOT deduplicate a
# role that is both an explicit site.yml roles: entry AND a meta/main.yml dependency of
# another explicitly-listed role in the same play (verified empirically via
# `ansible-playbook --list-tasks`) — it only dedupes a dependency against another
# role's dependency on the same role. Keeping owntracks's own explicit site.yml entry
# alongside gateway's new dependency would run owntracks (and its wiki_volume/users
# chain) twice per playbook execution. So site.yml no longer lists owntracks
# separately — gateway's dependency (with matching tags: [owntracks]) is now the only
# thing that runs it, at the same effective position as before.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "== role ordering guard (epic 15) =="

# 1. gateway/meta/main.yml declares owntracks as a dependency.
if [[ ! -f roles/gateway/meta/main.yml ]] || ! grep -q "role: owntracks" roles/gateway/meta/main.yml; then
  echo "FAIL: roles/gateway/meta/main.yml does not declare owntracks as a dependency"; exit 1
fi

# 2. site.yml no longer lists owntracks as its own explicit roles: entry — required to
#    avoid the duplicate-execution trap above. If this ever needs to be reintroduced,
#    gateway's dependency on owntracks must be removed first.
if grep -q "role: owntracks" site.yml; then
  echo "FAIL: site.yml still lists owntracks explicitly — combined with gateway's meta"
  echo "      dependency, this duplicates owntracks/wiki_volume/users execution"
  exit 1
fi

# 3. Structural proof: a throwaway playbook with only tailscale then gateway (no
#    owntracks entry at all) must still run owntracks's tasks, before gateway's own,
#    purely via the meta dependency — order proven with --list-tasks (no execution).
TMP="$(mktemp -d)"
PB="$TMP/role_order_test.yml"
cat > "$PB" <<YML
---
- hosts: localhost
  gather_facts: false
  roles:
    - role: tailscale
      tags: [tailscale]
    - role: gateway
      tags: [gateway]
YML
LIST_OUTPUT="$(ansible-playbook "$PB" --list-tasks 2>&1)" || {
  echo "FAIL: --list-tasks failed on the throwaway ordering playbook"; echo "$LIST_OUTPUT"; rm -rf "$TMP"; exit 1
}
rm -rf "$TMP"

FIRST_OWNTRACKS_LINE="$(echo "$LIST_OUTPUT" | grep -n "owntracks : Generate htpasswd" | head -1 | cut -d: -f1)"
FIRST_GATEWAY_LINE="$(echo "$LIST_OUTPUT" | grep -n "gateway : Load per-role gateway_publish" | head -1 | cut -d: -f1)"
if [[ -z "$FIRST_OWNTRACKS_LINE" || -z "$FIRST_GATEWAY_LINE" ]]; then
  echo "FAIL: expected task names not found in --list-tasks output"; echo "$LIST_OUTPUT"; exit 1
fi
if (( FIRST_OWNTRACKS_LINE >= FIRST_GATEWAY_LINE )); then
  echo "FAIL: owntracks tasks did not run before gateway's own tasks"; echo "$LIST_OUTPUT"; exit 1
fi
echo "gateway->owntracks dependency ordering OK (owntracks runs first, via meta dependency alone)"

# 4. No-duplication proof against the REAL site.yml: owntracks's htpasswd task must
#    appear exactly once in the full compiled task list.
REAL_LIST="$(ansible-playbook site.yml --list-tasks 2>&1)" || {
  echo "FAIL: --list-tasks failed on site.yml"; echo "$REAL_LIST"; exit 1
}
COUNT="$(echo "$REAL_LIST" | grep -c "owntracks : Generate htpasswd for owntracks basic auth" || true)"
if [[ "$COUNT" != "1" ]]; then
  echo "FAIL: owntracks's htpasswd task appears $COUNT times in site.yml's compiled task list (expected exactly 1)"
  exit 1
fi
echo "no duplicate owntracks execution in site.yml OK"

echo "role ordering guard OK"
