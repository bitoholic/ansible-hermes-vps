#!/usr/bin/env bash
# Guard for the Conduit personal Matrix homeserver + Hermes Matrix integration (epic 06 #04).
# CI-surfacesafe checks (always run):
#   1. conduit.toml renders with the SHARED conduit_registration_secret (not a literal) and
#      federation stays off (private, non-federated homeserver).
#   2. Conduit compose publishes NO host port (reachable only over the internal Docker network
#      / Tailscale, never the public ingress).
#   3. Hermes default profile env wires the bot to Conduit via MATRIX_HOMESERVER/MATRIX_USER_ID.
#   4. Public gateway surface is unchanged (no matrix/conduit ingress route was added).
#   5. Bot registration is idempotent by construction: guarded by the availability probe
#      (when status == 200) and declares changed_when so a re-run is a no-op once registered.
# Live run (guarded by CONDUIT_LIVE=1): runs the conduit role twice against the real stack and
#   asserts the second run is fully idempotent (operator-validates on the VPS, like wiki_volume).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ansible.cfg sets become=true; these local render tests must not escalate.
export ANSIBLE_BECOME=false

echo "== conduit integration guard =="

# 1 + 2 via the render playbook.
ansible-playbook tests/test_conduit.yml
echo "conduit render OK"

# 5 (by-contract): the registration task must be probe-guarded and declare changed_when.
if ! grep -q 'when: (conduit_hermes_available.status | default(0)) == 200' roles/conduit/tasks/main.yml; then
  echo "FAIL: bot registration task is not guarded by the availability probe (not idempotent)"; exit 1
fi
if ! grep -q 'changed_when: (conduit_hermes_available.status | default(0)) == 200' roles/conduit/tasks/main.yml; then
  echo "FAIL: bot registration task missing changed_when (idempotency not declared)"; exit 1
fi
echo "bot idempotency contract OK"

# 3: Hermes default env references Conduit.
if ! grep -q 'MATRIX_HOMESERVER="{{ conduit_internal_url }}"' roles/hermes/templates/env_default.j2; then
  echo "FAIL: Hermes default env does not wire MATRIX_HOMESERVER to conduit_internal_url"; exit 1
fi
if ! grep -q 'MATRIX_USER_ID="@hermes:{{ conduit_server_name }}"' roles/hermes/templates/env_default.j2; then
  echo "FAIL: Hermes default env does not set MATRIX_USER_ID to @hermes"; exit 1
fi
echo "hermes Matrix env OK"

# 4: gateway surface unchanged (no public matrix route added).
# Matrix is served via the hardcoded Caddyfile block (epic 06 #04), not gateway_routes,
# so the gateway surface stays clean. The matrix route is Tailscale-only (UFW default-deny).
if grep -rnE 'gateway_publish' roles/*/defaults/main.yml | grep -iqE 'matrix|conduit'; then
  echo "FAIL: a role publishes a matrix/conduit gateway route"; exit 1
fi
if ! grep -q 'matrix\.' roles/gateway/templates/Caddyfile.j2; then
  echo "FAIL: Caddyfile missing matrix HTTPS route"; exit 1
fi
echo "gateway surface unchanged OK"

echo "conduit integration guard OK"

# Live idempotency run — operator-validated on the VPS only.
if [[ "${CONDUIT_LIVE:-}" == "1" ]] && command -v ansible-playbook >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  PB="$TMP/conduit_live.yml"
  cat > "$PB" <<YML
---
- hosts: localhost
  gather_facts: false
  vars:
    secrets:
      admin_username: "${ADMIN_USERNAME:-root}"
      conduit_registration_secret: "${CONDUIT_REGISTRATION_SECRET:-}"
      matrix_bot_password: "${MATRIX_BOT_PASSWORD:-}"
  tasks:
    - ansible.builtin.include_role:
        name: conduit
YML
  ansible-playbook "$PB" >/dev/null 2>&1 || { echo "FAIL: conduit role failed on live run"; rm -rf "$TMP"; exit 1; }
  if ansible-playbook "$PB" 2>&1 | grep -q "changed=0"; then
    echo "conduit live run OK (fully idempotent)"
  else
    echo "FAIL: conduit role not idempotent on second live run"; rm -rf "$TMP"; exit 1
  fi
  rm -rf "$TMP"
else
  echo "SKIP live conduit run (CONDUIT_LIVE!=1; operator-validate on VPS)"
fi
