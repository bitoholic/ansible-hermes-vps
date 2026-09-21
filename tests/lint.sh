#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Placeholder-garbage guard: the literal placeholder string (the all-caps IP word)
# must never re-enter the repo. It leaked into the deployed Caddyfile (trusted_proxies
# rendered verbatim into production config); the variable was renamed to
# docker_bind_address and every mention scrubbed. tests/lint.sh is excluded because
# this message describes the pattern. This fails the build if the string comes back.
if git grep -n 'IP_ADDR''ESS' -- . ':(exclude)tests/lint.sh' >/dev/null 2>&1; then
  echo "FAIL: placeholder IP_ADDR""ESS string found (scrub it; use docker_bind_address):" >&2
  git grep -n 'IP_ADDR''ESS' -- . ':(exclude)tests/lint.sh' >&2
  exit 1
fi

if ! command -v ansible-lint >/dev/null 2>&1; then
  echo "ansible-lint is not installed" >&2
  exit 1
fi

# SOPS and age (epic 22) are required like ansible-lint: the encrypted-secrets tests must run, never skip
# silently. Install: age from your distribution; sops from https://github.com/getsops/sops/releases
# (see the onboarding runbook in the README).
for tool in sops age age-keygen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is not installed (required by the encrypted-secrets tests; install age and sops, see the README's onboarding section)" >&2
    exit 1
  fi
done

ansible-playbook --syntax-check site.yml >/tmp/hermes-syntax.log
ansible-playbook --syntax-check tests/test_playbook.yml >/tmp/hermes-test-syntax.log
ansible-lint site.yml tests/test_playbook.yml tests/test_resolver.yml tests/test_docker_user_rules.yml tests/test_boot_ordering.yml

# Single-seam contract: only the `secrets` resolver role may read credentials from the
# environment. Any other `lookup('env', …)` for a secret is a regression against the seam.
# Comments (#) and the resolver role itself are excluded. The per-profile Hermes secrets
# that were a temporary exception are now sourced from secrets.profiles.* (epic 02 #04),
# so no exception remains.
if grep -rnE "lookup\([^)]*env" roles/ group_vars/all/main.yml site.yml tests/test_playbook.yml tests/test_resolver.yml \
    | grep -v '#' \
    | grep -v "roles/secrets/"; then
  echo "FAIL: lookup('env', …) used outside the secrets resolver (single-seam contract)" >&2
  exit 1
fi

# Ensure operator-facing env catalogs (.env.template, setup-env.sh) stay in sync
# with the secret manifest. Regenerate with: python3 scripts/generate-env.py
python3 scripts/generate-env.py --check

# Resolver unit test: crafted-env resolution + fail-fast naming (runs under --check).
./tests/check-resolver.sh

# Hermes profile config render invariants (epic 02 ticket #02/#03 guard): every profile
# renders through the single shared config.yaml.j2 without losing its shape.
./tests/check-config-render.sh

# Docker compose render invariants (epic 11 ticket #06): the consolidated docker-compose.yml
# renders all enabled services correctly and passes docker compose config validation.
./tests/check-docker-compose-render.sh

# Hermes profile render behavioral test (epic 02 ticket #05): N profiles -> N file sets,
# default present, .env regression + per-profile secret scoping.
./tests/check-hermes-profile.sh

# Hermes skill packs (epic 08): superpowers + mattpocock skills registered in the running
# hermes-agent. Skipped automatically in CI where the container isn't present.
./tests/check-hermes-skills.sh

# Conduit personal Matrix homeserver + Hermes Matrix integration (epic 06 ticket #04):
# config renders with the shared registration secret, no published port, Hermes env wired,
# gateway surface unchanged, and bot registration is idempotent by contract.
./tests/check-conduit.sh

# Gateway Caddyfile render test (epic 03 ticket #04): byte-equivalence regression vs the legacy
# Caddyfile, one site block per route with mfa_auth applied unless mfa: false, fail-fast on
# malformed routes.
./tests/check-gateway-render.sh

# Custom Docker services (epic 12 ticket #07): OwnTracks + Syncplay compose render
# (and docker compose config when docker is present), Caddyfile owntracks/matrix blocks,
# firewall contract greps (8443 rate-limit; syncplay per-IP limit-from), secrets manifest
# entries, and syncplay_allowed_ips defined.
./tests/check-custom-services.sh

# Tailscale private-access + source-based MFA access model (epic 07 ticket #03): secrets defined,
# Caddyfile renders the mfa_auth bypass matcher, and the tailscale role defines the ufw allow
# rules. Live ufw/Tailscale behavior is operator-validated on the VPS (guarded/skipped in CI).
./tests/check-tailscale.sh

# Boot-persistent, atomic DOCKER-USER rules + the boot firewall unit (epic 21 ticket #02): asserts on
# the RENDERED rules' behavior (port classification for both IP families, blast radius limited to the
# DOCKER-USER chain, byte-stable rendering), the boot unit's ordering, the staged fail-closed coupling,
# and — when podman and the disposable epic-21 image exist — the shared loader inside that container.
# Surviving a real reboot / Docker restart is operator-validated in the attended drill (ticket #06).
./tests/check-docker-user-firewall.sh

# Restart policies (epic 21 ticket #03): every RENDERED compose service must survive a reboot or a crash
# (caddy/authelia/silverbullet stayed down after a reboot). The guard runs over the rendered service set inside
# tests/test_docker_compose.yml; this script proves the guard has teeth (missing / 'no' / on-failure / a
# multi-service fragment with one gap / empty all fail) and pins the three services found live.
./tests/check-restart-policies.sh

# Boot ordering, single-owner host DNS (staged) and the runtime-state audit (epic 21 ticket #04): Docker after
# tailscaled by an ordering-only drop-in, the resolv.conf repoint decision table (a working resolver is left
# exactly as found unless the switch is on or the file would be broken), the resolver drop-in's fallback order,
# and docs/reboot-resilience.md covering every enabled service with stated bounds. Real systemd ordering, Tailscale
# releasing resolv.conf and the stopped/hung DNS delays are operator-validated in the attended drill (#06).
./tests/check-boot-ordering.sh

# AdGuard DNS-serving (epic 18 ticket #05): the host-level systemd-resolved handover's
# sequencing contract (must run after the docker stack starts, wait -> drop-in ->
# repoint -> restart order, kept out of the role's early-phase tasks), the UDP
# restricted-port firewall class, the compose fragment's DNS port publish, and the
# manual Tailscale-console documentation. Static/structural only — the live host-level
# change itself is operator-validated on the VPS, never executed here.
./tests/check-adguard-dns.sh

# backup_sync module tests (epic 04 tickets #01-#04): CLI interface + sync/create-pr/git-crypt-init
# unit tests (git-crypt-init guarded/skipped when the git-crypt binary is absent). Also asserts the
# backup role is a thin adapter (epic 04 ticket #07): deploys only the module, the credential helper,
# the watcher units, and the cron — no stray script templates.
./tests/check-backup-sync.sh
./tests/check-backup-role.sh

# wiki_volume ownership seam (epic 05 ticket #05): the wiki data dir is created/owned by exactly
# the wiki_volume role, and no other role re-resolves llm_wiki via getent. A live idempotency/owner
# run of the role is operator-validated on the VPS (guarded/skipped when llm_wiki is absent).
./tests/check-wiki-volume.sh

# Machine-checked role ordering (epic 15 ticket #01, extended by epic 18 ticket #06):
# gateway depends on owntracks/beszel/adguard via real meta/main.yml dependencies, not
# site.yml list position for any of them — and site.yml must not list any of the three
# explicitly too, or they'd run twice per playbook execution.
./tests/check-role-ordering.sh

# Second-wave custom services full-epic guard (epic 18 ticket #06): consolidated
# compose/gateway render re-verification, the real (not test-mirrored) firewall port
# classes for Beszel/AdGuard, the new secrets' required/default shape (guards against
# ticket #03's near-miss deploy-deadlock regressing), env-catalog sync, and skip-tags/
# README membership for beszel and adguard.
./tests/check-second-wave-services.sh

# Cloudflare-proxied-ingress full-epic guard (epic 19 ticket #03): consolidated
# compose/gateway render re-verification (matrix/owntracks on :8443, DNS-01 scoped to
# exactly those two routes), cloudflare_api_token's required/no-default secrets-manifest
# shape, env-catalog sync, and the Caddy Dockerfile's version pin (no :latest, builder
# and runtime stages match).
./tests/check-cloudflare-proxied-ingress.sh

# Tailnet-Caddy-access full-epic guard (epic 20 ticket #01): consolidated compose/
# gateway render re-verification (internal PROXY-protocol listener, its loopback-only
# `allow` restriction, the v6 matcher extension, caddy-relay's shape), plus real-file
# regression guards a synthetic render can't express: the Dockerfile must not
# reintroduce the third-party proxy-protocol module (build-breaking — verified live),
# haproxy.cfg.j2's bind lines must stay conditional on their address facts, and
# caddy.yml.j2's 443 publish must stay IP-scoped, never a bare "443:443".
./tests/check-tailnet-caddy-access.sh

# Bounded role-execution duplication (epic 17): docker's and wiki_volume's own tasks
# run more than once per site.yml execution (Ansible's role dedup defeated by tag
# inheritance, pre-existing and not fully eliminated) — this bounds the duplication
# at the level epic 17 delivers, so it can't silently regress further.
./tests/check-role-duplication.sh

# docker-starts-before-config ordering fix (epic 16 ticket #01): docker's compose-stack
# start moved to the end of the play, after every config-deploying role; conduit/hermes
# provisioning moved out of their default sequence the same way; silverbullet's redundant
# second "up" call is gone.
./tests/check-stack-start-ordering.sh

# Role skip-tags guard (epic 10): every role in site.yml carries a tags entry matching its name,
# and the protected roles (secrets, users, ssh_hardening, common) are guarded by a pre-flight assert
# in site.yml so they cannot be skipped via --skip-tags.
echo "== role skip-tags guard =="
for role in secrets users ssh_hardening common tailscale docker conduit hermes authelia gateway silverbullet owntracks backup beszel adguard; do
  if ! grep -q "tags:" "roles/${role}/tasks/main.yml"; then
    echo "FAIL: roles/${role}/tasks/main.yml has no task-level tags entry" >&2
    exit 1
  fi
done
if ! grep -q "Protected roles: secrets, users, ssh_hardening, common" site.yml; then
  echo "FAIL: site.yml is missing the protected-roles pre-flight assert" >&2
  exit 1
fi
echo "role skip-tags guard OK"

# Live verification script and the reboot-drill procedure (epic 21 ticket #05): the script is read-only over a
# documented allowlist, multiplexes one SSH connection (UFW rate-limits new connections), and reports
# INCONCLUSIVE - never PASS - for anything it cannot support. Exercised against a fake ssh; the real VPS
# check is operator-run (scripts/verify-live.sh, drill in #06).
./tests/check-live-verification.sh

# Deploy wrapper (epic 22 ticket #01): decrypts the SOPS + age store into the child's environment only, runs only
# vetted invocation shapes, pins Ansible's own file writes off, streams live and returns the child's status. Run as
# a black box against a fixture tree with a throwaway key (no real key or secret is ever needed).
./tests/check-deploy-wrapper.sh
