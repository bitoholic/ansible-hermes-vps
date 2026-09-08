#!/usr/bin/env bash
# Guard for the epic 12 custom Docker services (OwnTracks + Syncplay).
# CI-safe checks (always run):
#   1. Rendered docker-compose.yml includes both services (and passes
#      `docker compose config` when docker is available).
#   2. Caddyfile renders the owntracks HTTPS block (SNI-shared 8448,
#      https:// scheme = ACME automatic HTTPS, no tls directive, no import
#      mfa_auth, basic_auth present — the recorder has no HTTP auth of its own)
#      and the matrix prefix regression guard (matrix.<domain>:8448, not bare
#      domain).
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

# 2b: recorder-auth regression guard — OTR_AUTH_FILE/OTR_AUTH/OTR_STORAGE are not
# real recorder config keys (verified against upstream misc.c / doc/SECURITY.md);
# their presence means someone re-introduced the "auth is on" illusion this
# fixed. The htpasswd bind-mount into the container is dead weight for the same
# reason — Caddy reads the host-side file directly.
OWNTRACKS_FRAGMENT=roles/docker/templates/services/owntracks.yml.j2
if grep -qE 'OTR_AUTH_FILE|OTR_AUTH=|OTR_STORAGE=' "$OWNTRACKS_FRAGMENT"; then
  echo "FAIL: $OWNTRACKS_FRAGMENT references a non-existent recorder env var (OTR_AUTH_FILE/OTR_AUTH/OTR_STORAGE) — the recorder has no built-in HTTP auth, see doc/SECURITY.md upstream"; exit 1
fi
if grep -q 'htpasswd:/store/htpasswd' "$OWNTRACKS_FRAGMENT"; then
  echo "FAIL: $OWNTRACKS_FRAGMENT still bind-mounts htpasswd into the container — the recorder never reads it"; exit 1
fi
if ! grep -q 'OTR_STORAGEDIR=/store' "$OWNTRACKS_FRAGMENT"; then
  echo "FAIL: $OWNTRACKS_FRAGMENT missing OTR_STORAGEDIR (the real recorder storage-path var)"; exit 1
fi
echo "recorder-auth regression guard OK"

# 2c: owntracks role must run before gateway (htpasswd must exist before Caddy's
# basic_auth block is rendered from it). Epic 15 ticket #01 replaced the original
# list-position check here with a real roles/gateway/meta/main.yml dependency — see
# tests/check-role-ordering.sh for the full structural proof (dependency exists,
# compiled task order, and no duplicate execution). This just pins that the
# dependency declaration itself hasn't quietly regressed.
if ! grep -q "role: owntracks" roles/gateway/meta/main.yml 2>/dev/null; then
  echo "FAIL: roles/gateway/meta/main.yml must declare owntracks as a dependency"; exit 1
fi
echo "owntracks-before-gateway ordering OK (via gateway's meta dependency — see check-role-ordering.sh)"

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

# 3b: DOCKER-USER contract (epic 12 #08) — the real enforcement layer for published
# ports. Declared in the tailscale role (single firewall owner); live iptables state
# is operator-validated on the VPS. Pins the declarative contract here.
TS_TASKS=roles/tailscale/tasks/main.yml
if ! grep -q 'chain: DOCKER-USER' "$TS_TASKS"; then
  echo "FAIL: tailscale role does not manage the DOCKER-USER chain"; exit 1
fi
if ! grep -q 'declarative rebuild' "$TS_TASKS"; then
  echo "FAIL: DOCKER-USER chain is not rebuilt declaratively"; exit 1
fi
if ! grep -q 'in_interface: "{{ item }}"' "$TS_TASKS" || ! grep -q 'br+' "$TS_TASKS"; then
  echo "FAIL: docker bridge traffic must RETURN early (container-to-container flows)"; exit 1
fi
if ! grep -q 'destination_port: 8999' "$TS_TASKS"; then
  echo "FAIL: DOCKER-USER has no 8999 (syncplay) rules"; exit 1
fi
if ! grep -q 'syncplay_allowed_ips | default' "$TS_TASKS"; then
  echo "FAIL: DOCKER-USER syncplay allow rule does not iterate syncplay_allowed_ips"; exit 1
fi
if ! grep -q 'destination_port: "{{ item }}"' "$TS_TASKS" || ! grep -q 'docker_published_restricted_ports' "$TS_TASKS"; then
  echo "FAIL: DOCKER-USER restricted-port rules missing"; exit 1
fi
if ! grep -q 'docker_published_public_ports' "$TS_TASKS"; then
  echo "FAIL: DOCKER-USER public-port rules missing"; exit 1
fi
if ! grep -q 'tailscale_subnet_v6' "$TS_TASKS"; then
  echo "FAIL: DOCKER-USER v6 rules missing (published ports are dual-stack)"; exit 1
fi
if ! grep -q '^docker_published_restricted_ports:' group_vars/all/main.yml || \
   ! grep -q '^docker_published_public_ports:' group_vars/all/main.yml; then
  echo "FAIL: published-port classes not defined in group_vars/all/main.yml"; exit 1
fi
echo "docker-user contract OK"

# 3c: owntracks deployment wiring (epic 12 #08 Part B). Since epic 15 ticket #01,
# owntracks is wired in via gateway's meta/main.yml dependency rather than its own
# explicit site.yml entry (keeping both would run it twice — see
# tests/check-role-ordering.sh) — accept either form.
if ! grep -q 'role: owntracks' site.yml && ! grep -rq 'role: owntracks' roles/*/meta/main.yml; then
  echo "FAIL: owntracks role not wired into site.yml (directly, or via another role's meta dependency)"; exit 1
fi
if ! grep -q 'owntracks' tests/lint.sh; then
  echo "FAIL: owntracks missing from the skip-tags guard role list"; exit 1
fi
if ! grep -q 'role: wiki_volume' roles/owntracks/meta/main.yml; then
  echo "FAIL: owntracks role missing wiki_volume meta dependency (uid/gid seam)"; exit 1
fi
echo "owntracks deployment wiring OK"

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

# 5: owntracks htpasswd parsing survives a multi-line file (regression guard). Found
# live on the VPS: the operator manages family members' OwnTracks logins by hand,
# directly on the server, beyond the one Ansible-managed admin credential — the
# htpasswd file has more than one line in production. A prior version of the parsing
# here treated the whole file as one blob and split on every ':' in it, corrupting
# the parsed hash (and therefore Caddy's basic_auth block) the moment a second line
# existed. Invokes the real parse_htpasswd.yml task file directly (it needs nothing
# from the directory-creation tasks, so this doesn't need real system users) against
# a fixture with the admin line deliberately NOT first, surrounded by other users'
# lines, and asserts the resulting facts are correct and untainted by them.
TMP="$(mktemp -d)"
cat > "$TMP/htpasswd" <<'HTP'
someone_else:$2y$05$notTheAdminHashXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
admin:$2y$12$a7thxdwfGc.VYa/fNZb4P.URPZ0TRADf1iAo4n3yxfN0OAjVMmtdu
another_family_member:$2y$05$alsoNotTheAdminHashXXXXXXXXXXXXXXXXXXXXXXXXXX
HTP
PB="$TMP/owntracks_htpasswd_test.yml"
cat > "$PB" <<YML
---
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    owntracks_htpasswd_path: "$TMP/htpasswd"
    secrets:
      owntracks_admin_username: admin
  tasks:
    - ansible.builtin.include_tasks: "$REPO_ROOT/roles/owntracks/tasks/parse_htpasswd.yml"

    - ansible.builtin.assert:
        that:
          - owntracks_basic_auth_user == "admin"
          - owntracks_basic_auth_hash == "\$2y\$12\$a7thxdwfGc.VYa/fNZb4P.URPZ0TRADf1iAo4n3yxfN0OAjVMmtdu"
          - "'\n' not in owntracks_basic_auth_hash"
        fail_msg: >-
          owntracks htpasswd parsing corrupted by the other lines in the file:
          user=[{{ owntracks_basic_auth_user }}] hash=[{{ owntracks_basic_auth_hash }}]
YML
ansible-playbook "$PB" >/dev/null 2>&1 || { echo "FAIL: owntracks htpasswd multi-line parsing test failed"; rm -rf "$TMP"; exit 1; }
rm -rf "$TMP"
echo "owntracks multi-line htpasswd parsing OK"

echo "custom services guard OK"
