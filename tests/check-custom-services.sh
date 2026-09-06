#!/usr/bin/env bash
# Guard for the epic 12 custom Docker services (OwnTracks + Syncplay).
# CI-safe checks (always run):
#   1. Rendered docker-compose.yml includes both services (and passes
#      `docker compose config` when docker is available).
#   2. Caddyfile renders the owntracks HTTPS block (SNI-shared 8448, bare
#      `tls` = ACME auto, no import mfa_auth) and the matrix prefix regression
#      guard (matrix.<domain>:8448, not bare domain).
#   3. Firewall contract: 8448 in the rate-limit loop; syncplay 8999 granted
#      per-IP via limit-from rules (allow + flood guard) driven by
#      syncplay_allowed_ips. NOTE: published ports bypass UFW INPUT — the
#      enforcement layer is DOCKER-USER (ticket #08); these greps pin the
#      declared contract until that lands.
#   4. Secrets manifest has both services' entries; syncplay_allowed_ips is
#      defined in group_vars/all/main.yml.
# Required-secret pre-flight (owntracks_admin_password, syncplay_password) is
# asserted by tests/check-resolver.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ansible.cfg sets become=true; these local render tests must not escalate.
export ANSIBLE_BECOME=false

echo "== custom services guard (owntracks + syncplay) =="

# 1: compose render + (optional) docker compose config validation.
ansible-playbook tests/test_docker_compose.yml
echo "docker compose render OK"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f /tmp/docker_compose_test/docker-compose.yml config -q
  echo "docker compose config OK"
else
  echo "SKIP docker compose config (docker not available)"
fi

# 2: Caddyfile external-behavior assertions (owntracks/matrix blocks).
ansible-playbook tests/test_gateway_render.yml
echo "gateway render (custom services) OK"

# 3: firewall contract — 8448 in the rate-limit loop.
if ! grep -A 12 'Rate-limit SSH, HTTP, HTTPS, and OwnTracks HTTPS' roles/tailscale/tasks/main.yml | grep -q '8448'; then
  echo "FAIL: 8448 missing from the UFW rate-limit loop"; exit 1
fi
echo "ufw 8448 rate-limit OK"

# 3: firewall contract — syncplay per-IP limit-from rules on 8999.
if ! grep -q 'Allow and rate-limit Syncplay from allowed IPs' roles/tailscale/tasks/main.yml; then
  echo "FAIL: syncplay per-IP allow task missing from tailscale role"; exit 1
fi
if ! grep -A 8 'Allow and rate-limit Syncplay from allowed IPs' roles/tailscale/tasks/main.yml | grep -q 'rule: limit'; then
  echo "FAIL: syncplay allow rule is not a limit rule (allow + flood guard)"; exit 1
fi
if ! grep -A 8 'Allow and rate-limit Syncplay from allowed IPs' roles/tailscale/tasks/main.yml | grep -q 'from: "{{ item }}"'; then
  echo "FAIL: syncplay rule does not iterate the allowed IPs"; exit 1
fi
if ! grep -A 8 'Allow and rate-limit Syncplay from allowed IPs' roles/tailscale/tasks/main.yml | grep -q 'port: 8999'; then
  echo "FAIL: syncplay rule does not target port 8999"; exit 1
fi
echo "ufw syncplay per-IP limit OK"

# 4: secrets manifest entries.
for entry in owntracks_admin_username owntracks_admin_password acme_email syncplay_password; do
  if ! grep -q "^  ${entry}:" group_vars/all/secrets.yml; then
    echo "FAIL: secrets manifest missing ${entry}"; exit 1
  fi
done
echo "secrets manifest entries OK"

# 4: syncplay_allowed_ips defined.
if ! grep -q '^syncplay_allowed_ips:' group_vars/all/main.yml; then
  echo "FAIL: syncplay_allowed_ips not defined in group_vars/all/main.yml"; exit 1
fi
echo "syncplay_allowed_ips defined OK"

echo "custom services guard OK"
