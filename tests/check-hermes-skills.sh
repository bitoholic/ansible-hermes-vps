#!/usr/bin/env bash
# Live check: every skill in the ACTIVE hermes_skills set is actually registered in the
# running hermes-agent. The expected set is resolved through Ansible from
# group_vars/all/hermes_skills.yml, so swapping packs (hermes_skills pointing at a
# different pack, or concatenated packs) is picked up without editing this script.
# Requires the container on the VPS; skipped in CI where docker/hermes isn't available.
# (epic 08; reworked for the pack-split seam)
set -uo pipefail

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^hermes-agent$'; then
  echo "SKIP: hermes-agent container not running (CI)"; exit 0
fi

export ANSIBLE_BECOME=false
EXPECTED="$(ansible localhost -c local -m debug -a 'var=hermes_skills' 2>/dev/null | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    data = json.loads(raw[raw.index("{"):])
    skills = data["hermes_skills"]
    if not isinstance(skills, list):
        raise ValueError("hermes_skills did not resolve to a list")
    print("\n".join(entry["name"] for entry in skills))
except Exception as exc:
    print(f"resolve error: {exc}", file=sys.stderr)
    sys.exit(1)
')" || { echo "FAIL: could not resolve hermes_skills from group_vars/all/hermes_skills.yml"; exit 1; }

if [ -z "$EXPECTED" ]; then
  echo "hermes skills OK: hermes_skills resolves to no packs (nothing to verify — swap packs in group_vars/all/hermes_skills.yml)"; exit 0
fi

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
