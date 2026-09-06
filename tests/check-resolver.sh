#!/usr/bin/env bash
# Unit test for the secrets resolver.
# 1. With a complete crafted environment, the resolved `secrets` dict must match
#    expectations (global + per-profile scoped, nothing leaked to the global dict).
# 2. With one required secret unset, the resolver must fail fast and name it
#    (exercised under --check, matching the operator dry-run path).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_BECOME=false

# Crafted environment: every required secret plus a couple of optional ones whose
# resolved values we assert explicitly.
export OPENROUTER_API_KEY=WIKI_KEY
export NOUS_PORTAL_API_KEY=NOUS_KEY
export GITHUB_TOKEN=GH_TOKEN
export AUTHELIA_ADMIN_PASSWORD_HASH=AUTHELIA_HASH
export AUTHELIA_SESSION_SECRET=AUTHELIA_SESSION
export AUTHELIA_STORAGE_KEY=AUTHELIA_STORAGE
export SIGNAL_ACCOUNT=[EMAIL]
export SIGNAL_ALLOWED_USERS="u1,u2"
export DASHBOARD_ADMIN_PASSWORD_HASH=DASH_HASH
export ADMIN_SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCtestkey"
export OWNTRACKS_ADMIN_PASSWORD=OTR_PASS
export SYNCPLAY_PASSWORD=SYNC_PASS

echo "== resolver resolves expected values =="
ansible-playbook tests/test_resolver.yml --check -e secrets_enforce_required=false

echo "== resolver fails fast on a missing required secret (--check path) =="
# For each required secret, unset exactly that one (everything else remains
# exported) and assert the resolver fails fast naming it in the failure.
LOG=/tmp/hermes-resolver-fail.log
for pair in "AUTHELIA_ADMIN_PASSWORD_HASH:authelia_admin_password_hash" \
            "OWNTRACKS_ADMIN_PASSWORD:owntracks_admin_password" \
            "SYNCPLAY_PASSWORD:syncplay_password"; do
  env_var="${pair%%:*}"
  manifest_key="${pair##*:}"
  unset "$env_var"
  if ansible-playbook tests/test_resolver.yml --check >"$LOG" 2>&1; then
    echo "FAIL: resolver did not fail on a missing required secret ($manifest_key)" >&2
    exit 1
  fi
  if grep -q "$manifest_key" "$LOG"; then
    echo "fail-fast OK: missing required secret $manifest_key named in failure"
  else
    echo "FAIL: missing required secret $manifest_key not named in failure" >&2
    exit 1
  fi
  # restore the exported value for the next round
  case "$env_var" in
    AUTHELIA_ADMIN_PASSWORD_HASH) export AUTHELIA_ADMIN_PASSWORD_HASH=AUTHELIA_HASH ;;
    OWNTRACKS_ADMIN_PASSWORD)     export OWNTRACKS_ADMIN_PASSWORD=OTR_PASS ;;
    SYNCPLAY_PASSWORD)            export SYNCPLAY_PASSWORD=SYNC_PASS ;;
  esac
done
