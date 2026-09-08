#!/usr/bin/env bash
# Bounded role-execution duplication (epic 17).
#
# docker's and wiki_volume's own tasks run more than once per site.yml execution —
# pre-existing, unrelated to epics 13-16, caused by Ansible's role-invocation
# deduplication getting defeated by tag inheritance (a role pulled in as a
# meta/main.yml dependency inherits its calling role's tags into its effective
# invocation identity, so two different parents pulling the same dependency don't
# deduplicate against each other even with identical role name and vars). Every
# repeated execution is individually idempotent, so this is harmless today, but
# wasteful and a latent risk for any future non-idempotent task. Epic 17 reduces it
# (docker 5->4, wiki_volume 11->7) without fully eliminating it — full elimination
# needs a fix to the tag-inheritance mechanism itself, out of scope here. This test
# bounds the result at the level epic 17 actually delivers, so a future change can't
# silently make the duplication worse without a test catching it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "== role-execution duplication guard (epic 17) =="

LIST_OUTPUT="$(ansible-playbook site.yml --list-tasks 2>&1)" || {
  echo "FAIL: --list-tasks failed on site.yml"; echo "$LIST_OUTPUT"; exit 1
}

WIKI_VOLUME_COUNT="$(echo "$LIST_OUTPUT" | grep -c "wiki_volume : Lookup llm_wiki passwd entry" || true)"
DOCKER_COUNT="$(echo "$LIST_OUTPUT" | grep -c "docker : Validate Docker role prerequisites" || true)"

# Known, accepted ceiling — NOT "exactly once". See the comment above and the epic
# 17 spec for why full elimination isn't achieved by this epic. Tightened here
# (epic 17, #02) from ticket #01's intermediate 8/5 now that docker's explicit
# site.yml entry is also removed.
WIKI_VOLUME_MAX=7
DOCKER_MAX=4

if (( WIKI_VOLUME_COUNT > WIKI_VOLUME_MAX )); then
  echo "FAIL: wiki_volume's tasks run $WIKI_VOLUME_COUNT times (expected <= $WIKI_VOLUME_MAX) - duplication regressed"
  exit 1
fi
echo "wiki_volume execution count OK ($WIKI_VOLUME_COUNT <= $WIKI_VOLUME_MAX)"

if (( DOCKER_COUNT > DOCKER_MAX )); then
  echo "FAIL: docker's tasks run $DOCKER_COUNT times (expected <= $DOCKER_MAX) - duplication regressed"
  exit 1
fi
echo "docker execution count OK ($DOCKER_COUNT <= $DOCKER_MAX)"

# Ordering safety (epic 17, #02): docker is now dependency-only, no longer an
# explicit site.yml entry. Its effective execution position shifted to wherever
# its first remaining dependent (conduit) sits — prove this is still early enough:
# before conduit's/hermes's/authelia's/silverbullet's own config-phase tasks, and
# before epic 16's end-of-play "Start consolidated docker compose stack" step.
DOCKER_FIRST_LINE="$(echo "$LIST_OUTPUT" | grep -n "docker : Validate Docker role prerequisites" | head -1 | cut -d: -f1)"
CONDUIT_CONFIG_LINE="$(echo "$LIST_OUTPUT" | grep -n "conduit : Deploy Conduit configuration" | head -1 | cut -d: -f1)"
HERMES_CONFIG_LINE="$(echo "$LIST_OUTPUT" | grep -n "hermes : Copy Hermes Dockerfile to hermes home" | head -1 | cut -d: -f1)"
AUTHELIA_CONFIG_LINE="$(echo "$LIST_OUTPUT" | grep -n "Render Authelia configuration" | head -1 | cut -d: -f1)"
SILVERBULLET_CONFIG_LINE="$(echo "$LIST_OUTPUT" | grep -n "Create SilverBullet deployment directory" | head -1 | cut -d: -f1)"
STACK_START_LINE="$(echo "$LIST_OUTPUT" | grep -n "docker : Start consolidated docker compose stack" | head -1 | cut -d: -f1)"

for pair in "CONDUIT_CONFIG_LINE:conduit config" "HERMES_CONFIG_LINE:hermes config" "AUTHELIA_CONFIG_LINE:authelia config" "SILVERBULLET_CONFIG_LINE:silverbullet config" "STACK_START_LINE:the end-of-play stack-start step"; do
  name="${pair##*:}"; var="${pair%%:*}"
  val="${!var}"
  if [[ -z "$DOCKER_FIRST_LINE" || -z "$val" ]]; then
    echo "FAIL: expected task names not found in --list-tasks output"; exit 1
  fi
  if (( DOCKER_FIRST_LINE >= val )); then
    echo "FAIL: docker's (now dependency-only) tasks do not run before $name (docker=$DOCKER_FIRST_LINE, $name=$val)"
    exit 1
  fi
done
echo "docker (dependency-only) still runs before every config-deploying role and the stack-start step OK"

echo "role-execution duplication guard OK"
