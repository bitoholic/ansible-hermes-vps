#!/usr/bin/env bash
# Guard for the Tailscale private-access + source-based MFA access model (epic 07 #03).
# CI-surfacesafe checks (always run):
#   1. secrets.tailscale_authkey is defined (single-seam contract: read from env) and the
#      tailscale role enforces it in its pre-flight assert.
#   2. The gateway Caddyfile contains the mfa_auth source-IP bypass matcher using the shared
#      tailscale_subnet constant (ADR-0001).
#   3. The tailscale role defines the ufw allow rules (22/80/443 + Tailscale interface) and
#      default-deny incoming.
# Live run (guarded by TAILSCALE_LIVE=1): runs the tailscale role twice against the real host
#   and asserts the second run is fully idempotent (operator-validated on the VPS).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false

echo "== tailscale access guard =="

# 1. Secret defined (single-seam: resolver reads it from env).
if ! grep -qE '^[[:space:]]*tailscale_authkey:' group_vars/all/secrets.yml; then
  echo "FAIL: secrets.tailscale_authkey missing from the manifest"; exit 1
fi
if ! grep -qE 'env: TAILSCALE_AUTHKEY' group_vars/all/secrets.yml; then
  echo "FAIL: tailscale_authkey is not wired to env TAILSCALE_AUTHKEY (single-seam contract)"; exit 1
fi
if ! grep -qE 'secrets\.tailscale_authkey' roles/tailscale/tasks/main.yml; then
  echo "FAIL: tailscale role does not require secrets.tailscale_authkey (pre-flight assert)"; exit 1
fi
# The default-deny incoming policy value must actually be deny.
if ! grep -qE 'common_ufw_default_incoming_policy: deny' group_vars/all/main.yml; then
  echo "FAIL: UFW default incoming policy is not deny"; exit 1
fi
echo "tailscale secret + default-deny contract OK"

# 2. Caddyfile mfa_auth bypass matcher using the shared subnet constant.
CF=roles/gateway/templates/Caddyfile.j2
if ! grep -q 'not remote_ip' "$CF"; then
  echo "FAIL: gateway Caddyfile missing the Tailscale source-IP bypass matcher"; exit 1
fi
if ! grep -q '{{ tailscale_subnet }}' "$CF"; then
  echo "FAIL: gateway Caddyfile does not reference the shared tailscale_subnet constant"; exit 1
fi
if ! grep -q 'forward_auth @not_tailscale' "$CF"; then
  echo "FAIL: gateway Caddyfile mfa_auth does not apply the bypass matcher"; exit 1
fi
echo "gateway MFA bypass matcher OK"

# 3. tailscale role ufw rules.
TS=roles/tailscale/tasks/main.yml
check() { grep -qE "$1" "$TS" || { echo "FAIL: tailscale role ufw missing: $2"; exit 1; }; }
check 'direction: incoming' 'default-deny incoming policy task'
check 'common_ufw_default_incoming_policy' 'role applies the deny incoming policy'
check 'direction: in' 'Tailscale interface inbound allow'
check 'interface: "{{ tailscale_interface }}"' 'Tailscale interface allow'
check 'common_ssh_port' 'SSH allow in rate-limit loop'
check '^[[:space:]]*- 80$' 'HTTP (80) allow'
check '^[[:space:]]*- 443$' 'HTTPS (443) allow'
check 'state: enabled' 'ufw enabled'
echo "tailscale ufw rules OK"

echo "tailscale access guard OK"

# Live idempotency run — operator-validated on the VPS only.
if [[ "${TAILSCALE_LIVE:-}" == "1" ]] && command -v ansible-playbook >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  PB="$TMP/tailscale_live.yml"
  cat > "$PB" <<YML
---
- hosts: localhost
  gather_facts: false
  vars:
    secrets:
      tailscale_authkey: "${TAILSCALE_AUTHKEY:-}"
  tasks:
    - ansible.builtin.include_role:
        name: tailscale
YML
  ansible-playbook "$PB" >/dev/null 2>&1 || { echo "FAIL: tailscale role failed on live run"; rm -rf "$TMP"; exit 1; }
  if ansible-playbook "$PB" 2>&1 | grep -q "changed=0"; then
    echo "tailscale live run OK (fully idempotent)"
  else
    echo "FAIL: tailscale role not idempotent on second live run"; rm -rf "$TMP"; exit 1
  fi
  rm -rf "$TMP"
else
  echo "SKIP live tailscale run (TAILSCALE_LIVE!=1; operator-validate on VPS)"
fi
