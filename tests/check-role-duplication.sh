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
# 17 spec for why full elimination isn't achieved by this epic. Ticket #01 (this
# commit) only removes the redundant sibling wiki_volume dependencies, so docker's
# bound stays at its pre-existing baseline here; ticket #02 tightens both once it
# also removes docker's explicit site.yml entry.
WIKI_VOLUME_MAX=8
DOCKER_MAX=5

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

echo "role-execution duplication guard OK"
