#!/usr/bin/env bash
# Live check: every Hermes skill pack entry from group_vars/all/hermes_skills.yml is
# actually registered in the running hermes-agent. Requires the container on the VPS;
# skipped in CI where docker/hermes isn't available. (epic 08)
set -uo pipefail

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^hermes-agent$'; then
  echo "SKIP: hermes-agent container not running (CI)"; exit 0
fi

EXPECTED=$(cat <<'LIST'
brainstorming
dispatching-parallel-agents
executing-plans
finishing-a-development-branch
receiving-code-review
requesting-code-review
subagent-driven-development
systematic-debugging
test-driven-development
using-git-worktrees
using-superpowers
verification-before-completion
writing-plans
writing-skills
ask-matt
code-review
codebase-design
diagnosing-bugs
domain-modeling
grill-with-docs
implement
improve-codebase-architecture
prototype
research
resolving-merge-conflicts
setup-matt-pocock-skills
tdd
to-spec
to-tickets
triage
wayfinder
wizard
claude-handoff
implement-spec
loop-me
retro
setup-ts-deep-modules
writing-beats
writing-fragments
writing-shape
git-guardrails-claude-code
migrate-to-shoehorn
scaffold-exercises
setup-pre-commit
grill-me
grilling
handoff
teach
to-questionnaire
wait-what
writing-for-agents
LIST
)

installed="$(docker exec hermes-agent hermes skills list 2>/dev/null || true)"
missing=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if ! echo "$installed" | awk -F'│' '{n=$2; gsub(/^[ \t]+|[ \t]+$/, "", n); print n}' | grep -qx "$name"; then
    echo "MISSING skill: $name"
    missing=$((missing+1))
  fi
done <<< "$EXPECTED"

if [ "$missing" -gt 0 ]; then
  echo "FAIL: $missing Hermes skill(s) missing"; exit 1
fi
echo "hermes skills OK ($(echo "$EXPECTED" | grep -c .) expected present)"
