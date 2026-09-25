#!/usr/bin/env bash
# Epic 22 ticket #05 guard: a full local dry run of the real roles (tests/test_playbook.yml), at HIGH VERBOSITY and
# WITH --diff, must never print one of the crafted fixture secret values — proving suppression at the source works
# on its own, independent of the deploy wrapper's own output redaction (epic 22 #02), which this run never goes
# through at all (no wrapper, no sops, just `ansible-playbook` directly against a stubbed `secrets` fact).
#
# What this CANNOT verify: roles that need a real Debian/Ubuntu host to even reach their rendering tasks under
# --check (`ansible.builtin.apt` requires the python3-apt binding on the CONTROL node too, which only exists on a
# Debian/Ubuntu control host) — those roles (tailscale, ssh_hardening's package step) are already excluded from
# tests/test_playbook.yml for this reason (pre-existing, not introduced by this ticket) and are instead covered by
# the static suppression guard (tests/check-secret-suppression.sh), which needs no host at all. On a control host
# that isn't Debian/Ubuntu-family (this repo's own target OS, per every role's own prerequisite assert), this test
# skips rather than failing on an environment mismatch it cannot fix.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export ANSIBLE_BECOME=false
echo "== full-playbook secret leak check (epic 22 #05) =="

if ! python3 -c "import apt" >/dev/null 2>&1; then
  echo "SKIP: python3-apt (the Debian/Ubuntu APT Python binding) is not available on this control host, so" \
       "roles using ansible.builtin.apt cannot even reach --check mode here (a control-host limitation, not a" \
       "target-host one). This is covered instead by tests/check-secret-suppression.sh, which needs no host at all."
  exit 0
fi
if [[ "$(id -u)" != "0" ]]; then
  echo "SKIP: this dry run needs root (to pre-seed the llm_wiki/admin system accounts several roles assert exist —" \
       "--check mode never creates them for real, so a later real lookup would otherwise fail on ANY fresh control" \
       "host, unrelated to suppression). Never run tests/lint.sh as root on a real workstation for this reason —" \
       "this check is meant for a disposable container, and is covered otherwise by check-secret-suppression.sh."
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: no reachable Docker daemon on this control host — the docker role's own network/compose tasks need" \
       "one for real (--check mode can't simulate past a live daemon dependency either). Covered otherwise by" \
       "check-secret-suppression.sh, which needs no host, daemon or container at all."
  exit 0
fi

# --check mode never actually creates a user or group, so a LATER task that reads real system state (wiki_volume's
# own getent lookup, called from several of the roles below) would otherwise fail on a fresh control host — not a
# suppression concern, just check mode's own limit. Pre-seed exactly what the users role would have created for
# real, idempotently and harmlessly (this test only ever runs against a disposable container/host, never the VPS).
getent group llm_wiki >/dev/null || groupadd --system llm_wiki
getent passwd llm_wiki >/dev/null || useradd --system --gid llm_wiki --no-create-home --shell /usr/sbin/nologin llm_wiki
getent passwd admin >/dev/null || useradd --create-home admin

# A few tasks build their source path from `playbook_dir` (correct when the real entry point is site.yml, at the
# repo root) — since this dry run's entry point is tests/test_playbook.yml, playbook_dir resolves to tests/
# instead. Transient symlinks (removed on exit, never committed) make that resolve the same way.
ln -sfn ../roles tests/roles
ln -sfn ../backup_sync tests/backup_sync
trap 'rm -f tests/roles tests/backup_sync' EXIT

# Only the canaries reachable by the roles actually previewed in tests/test_playbook.yml (common, docker, authelia,
# silverbullet, hermes, backup) — see that file's comment for why owntracks/adguard/conduit/gateway aren't included.
CANARIES=(
  LEAK-CANARY-AUTHELIA-HASH LEAK-CANARY-AUTHELIA-SESSION LEAK-CANARY-AUTHELIA-STORAGE
  LEAK-CANARY-SILVERBULLET-PW LEAK-CANARY-OPENROUTER-KEY LEAK-CANARY-NOUS-KEY LEAK-CANARY-GITHUB-TOKEN
  LEAK-CANARY-RESEND-KEY LEAK-CANARY-CONTEXT7-KEY LEAK-CANARY-DASHBOARD-HASH LEAK-CANARY-BACKUP-TOKEN
  LEAK-CANARY-PROFILE-CONTEXT7-KEY
)

set +e
OUT="$(ansible-playbook tests/test_playbook.yml --check --diff -vvv -e secrets_enforce_required=false 2>&1)"; RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "FAIL: the dry run itself did not succeed (rc=$RC)" >&2; echo "$OUT" | tail -60 >&2; exit 1; }

leaked=()
for c in "${CANARIES[@]}"; do
  grep -qF "$c" <<<"$OUT" && leaked+=("$c")
done
if [[ ${#leaked[@]} -gt 0 ]]; then
  echo "FAIL: the following fixture secret(s) appeared in verbose+diff output: ${leaked[*]}" >&2
  exit 1
fi
echo "no fixture secret value appeared in verbose (-vvv), diff-enabled output across common/docker/authelia/" \
     "silverbullet/hermes/backup"
