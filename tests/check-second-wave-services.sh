#!/usr/bin/env bash
# Epic 18 (second-wave custom services) full-epic guard — ticket #06.
#
# Mirrors epic 12's own tests/check-custom-services.sh: a consolidated,
# epic-wide pass proving the epic's three services (OwnTracks frontend, Beszel,
# AdGuard) and the new tailnet_only route type integrate correctly, re-running
# the shared render tests here too (epic 12's own established convention,
# not accidental duplication — check-custom-services.sh does the same for
# test_docker_compose.yml/test_gateway_render.yml). This script covers what
# isn't already owned by a per-ticket script: tests/check-adguard-dns.sh
# (ticket #05) already covers the DNS-sequencing specifics in depth, and
# tests/check-role-ordering.sh (extended by this same ticket) covers the
# gateway-dependency/no-duplicate-execution proof for beszel and adguard.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export ANSIBLE_BECOME=false

echo "== second-wave services guard (epic 18) =="

check_in() { grep -qEi "$2" "$1" || { echo "FAIL: $1 missing: $3"; exit 1; }; }

# entry_has <file> <key_pattern> <content_pattern> <description> — checks
# content_pattern only within the bounded block starting at key_pattern, up to
# (not including) the next line at the SAME indentation level. A fixed-line
# `grep -A<N>` window doesn't have this guarantee, and got this wrong twice
# here originally (caught in review, verified empirically): the check for
# beszel_agent_key's `required: false` kept passing even after flipping that
# key's own value to `true`, because the window bled into beszel_agent_token's
# unrelated `required: false` three lines later — and the identical shape
# existed for docker_published_restricted_ports's own window bleeding into
# docker_published_restricted_udp_ports's list right after it. Indentation for
# the boundary is derived from key_pattern's own leading spaces, so this works
# for both group_vars/all/main.yml's 0-indent top-level keys and
# group_vars/all/secrets.yml's 2-indent manifest entries.
entry_has() {
  local file="$1" key_pat="$2" content_pat="$3" desc="$4"
  local indent="${key_pat#^}"; indent="${indent%%[^ ]*}"
  awk -v key_pat="$key_pat" -v exit_pat="^${indent}[A-Za-z_]" '
    $0 ~ key_pat { found=1; print; next }
    found && $0 ~ exit_pat { exit }
    found { print }
  ' "$file" | grep -qE "$content_pat" || { echo "FAIL: $file missing: $desc"; exit 1; }
}

# 1: consolidated compose + gateway render — all four new services, all three
# new tailnet_only routes, every pre-existing route unchanged (asserted by the
# shared test files themselves; re-run here per the epic-12 convention noted
# above).
ansible-playbook tests/test_docker_compose.yml
echo "docker compose render OK"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f /tmp/docker_compose_test/docker-compose.yml config -q
  echo "docker compose config OK"
else
  echo "SKIP docker compose config (docker not available)"
fi

ansible-playbook tests/test_gateway_render.yml
echo "gateway render (second-wave services) OK"

# 2: firewall — Beszel hub (8090) and AdGuard admin UI (3001) are in the REAL
# TCP-restricted list (group_vars/all/main.yml), not just test_docker_compose.yml's
# own separately-maintained mirror of it (that mirror could drift from
# production with nothing else catching it).
entry_has group_vars/all/main.yml '^docker_published_restricted_ports:' '  - 8090' "beszel hub port 8090 in docker_published_restricted_ports"
entry_has group_vars/all/main.yml '^docker_published_restricted_ports:' '  - 3001' "adguard admin UI port 3001 in docker_published_restricted_ports"
echo "TCP restricted-port firewall contract (beszel/adguard) OK"

# 3: secrets manifest SHAPE, not just presence — required/default correctness
# for the epic's new secrets. Beszel's key/token must stay required: false
# (ticket #03's near-miss deploy-deadlock: they can only be obtained after a
# first deploy already stood up the hub, so required: true would brick every
# future deploy of the whole VPS). AdGuard's password hash must stay
# required: true (operator-precomputed, no chicken-and-egg problem, unlike
# Beszel's).
SECRETS=group_vars/all/secrets.yml
for entry in beszel_agent_key beszel_agent_token adguard_admin_username adguard_admin_password_hash; do
  check_in "$SECRETS" "^  ${entry}:" "secrets manifest entry: $entry"
done
entry_has "$SECRETS" '^  beszel_agent_key:' 'required: false' "beszel_agent_key must stay required: false (ticket #03's deploy-deadlock fix)"
entry_has "$SECRETS" '^  beszel_agent_token:' 'required: false' "beszel_agent_token must stay required: false (ticket #03's deploy-deadlock fix)"
entry_has "$SECRETS" '^  adguard_admin_username:' 'default: "admin"' "adguard_admin_username missing its default"
entry_has "$SECRETS" '^  adguard_admin_password_hash:' 'required: true' "adguard_admin_password_hash must be required: true (operator-precomputed, no chicken-and-egg problem)"
echo "secrets manifest shape (required/default) OK"

# 4: env-catalog sync — already run unconditionally by tests/lint.sh; re-asserted
# here too since this is the epic-summary script, same belt-and-suspenders
# reasoning as check #1 above.
python3 scripts/generate-env.py --check
echo "env catalog sync OK"

# 5: skip-tags guard membership for the epic's two new roles — already asserted
# generically by tests/lint.sh's own role loop; spot-checked here too for the
# same reason as #4.
check_in tests/lint.sh '\bbeszel\b' "beszel in the skip-tags guard role list"
check_in tests/lint.sh '\badguard\b' "adguard in the skip-tags guard role list"
check_in README.md '`beszel`' "beszel in the README skippable-roles table"
check_in README.md '`adguard`' "adguard in the README skippable-roles table"
echo "skip-tags guard membership (beszel/adguard) OK"

echo "second-wave services guard OK"
