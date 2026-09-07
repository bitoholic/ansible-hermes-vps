#!/usr/bin/env bash
# Guard that the wiki store has a single owner (epic 05 ticket #05).
# The wiki data directory (silverbullet_data_dir) must be created/owned by exactly the
# wiki_volume role, and no role may re-resolve llm_wiki via getent — both were duplicated
# across silverbullet/backup/hermes before the consolidation. A live idempotency/owner run
# of the role is operator-validated on the VPS (needs the llm_wiki user + become); it is
# guarded/skipped here when that user is absent, so CI stays green and the static contract
# is the CI-surfacesafe regression check.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLES="$REPO_ROOT/roles"

echo "== wiki_volume consumer-contract guard =="

# 1. Exactly one role may own silverbullet_data_dir's creation — wiki_volume. Since
#    epic 14 #01, wiki_volume itself routes this through its own directory-bootstrap
#    entrypoint (ensure_directory.yml) rather than a literal inline `file` task, so
#    this checks for either shape: a direct `file`+`state: directory` task on
#    silverbullet_data_dir, or an `include_tasks`/`include_role` call passing
#    silverbullet_data_dir as wiki_volume_directory_path.
owners=()
while IFS= read -r f; do
  if awk '
    /^[[:space:]]*- name:/ { if ((mod=="file" && path && state) || pathvar) found=1; mod=""; path=0; state=0; pathvar=0; next }
    /^[[:space:]]*(ansible\.builtin\.)?file:/ { mod="file"; next }
    /^[[:space:]]*path:[[:space:]]*"\{\{ silverbullet_data_dir/ { if (mod=="file") path=1; next }
    /^[[:space:]]*state:[[:space:]]*directory/ { if (mod=="file") state=1; next }
    /^[[:space:]]*wiki_volume_directory_path:[[:space:]]*"\{\{ silverbullet_data_dir/ { pathvar=1; next }
    END { if ((mod=="file" && path && state) || pathvar) found=1; if (found) print "X" }
  ' "$f" | grep -q X; then
    owners+=("$(basename "$(dirname "$(dirname "$f")")")")
  fi
done < <(find "$ROLES" -path '*/tasks/main.yml')
if [[ "${owners[*]:-}" != "wiki_volume" ]]; then
  echo "FAIL: roles owning silverbullet_data_dir's creation = [${owners[*]:-none}] (expected only wiki_volume)"
  exit 1
fi

# 1b. The entrypoint file itself must exist and use the resolved uid/gid facts, not
#     the literal llm_wiki username string (the facts are the module's interface).
ENTRYPOINT="$ROLES/wiki_volume/tasks/ensure_directory.yml"
if [[ ! -f "$ENTRYPOINT" ]]; then
  echo "FAIL: wiki_volume directory-bootstrap entrypoint missing ($ENTRYPOINT)"; exit 1
fi
if ! grep -q 'owner:.*wiki_volume_uid' "$ENTRYPOINT" || ! grep -q 'group:.*wiki_volume_gid' "$ENTRYPOINT"; then
  echo "FAIL: $ENTRYPOINT must own directories via wiki_volume_uid/wiki_volume_gid facts"; exit 1
fi

# 2. getent for llm_wiki must live only in wiki_volume — no other role re-resolves the user.
if grep -rn "ansible.builtin.getent" "$ROLES" | grep -v "roles/wiki_volume/"; then
  echo "FAIL: getent for llm_wiki found outside the wiki_volume role"; exit 1
fi

# 3. The llm_wiki passwd lookup key must appear only in wiki_volume.
if grep -rn "key: llm_wiki" "$ROLES" | grep -v "roles/wiki_volume/"; then
  echo "FAIL: 'key: llm_wiki' found outside the wiki_volume role"; exit 1
fi

echo "wiki_volume consumer-contract OK"

# 4. Best-effort live run: only when the llm_wiki user exists AND an operator opts in
#    (the role depends on `users`, which needs become + secrets on the VPS). Otherwise skip —
#    this mirrors the git-crypt-init guard in check-backup-sync.sh.
if [[ "${WIKI_VOLUME_LIVE:-}" == "1" ]] && command -v ansible-playbook >/dev/null 2>&1 && id llm_wiki >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  PB="$TMP/wiki_vol_test.yml"
  cat > "$PB" <<YML
---
- hosts: localhost
  gather_facts: false
  vars:
    silverbullet_data_dir: "$TMP/wiki"
  tasks:
    - ansible.builtin.include_role:
        name: wiki_volume
YML
  ansible-playbook "$PB" >/dev/null 2>&1 || { echo "FAIL: wiki_volume role failed"; rm -rf "$TMP"; exit 1; }
  st="$(stat -c '%U:%G %a' "$TMP/wiki")"
  if [[ "$st" != "llm_wiki:llm_wiki 775" ]]; then
    echo "FAIL: wiki dir owner/mode = $st (expected llm_wiki:llm_wiki 775)"; rm -rf "$TMP"; exit 1
  fi
  if ansible-playbook "$PB" 2>&1 | grep -q "changed=0"; then
    echo "wiki_volume live run OK (owner 775, idempotent)"
  else
    echo "FAIL: wiki_volume not idempotent on second run"; rm -rf "$TMP"; exit 1
  fi

  # Epic 14, #01: call the directory-bootstrap entrypoint directly with its own test
  # path/mode, per the ticket's acceptance criteria. A real dependent role (ticket
  # #02) already has wiki_volume as a meta/main.yml dependency, so its uid/gid facts
  # are resolved before the dependent calls tasks_from: ensure_directory — mirror
  # that here with an ordinary full-role include first, then the entrypoint alone.
  PB2="$TMP/wiki_vol_entrypoint_test.yml"
  cat > "$PB2" <<YML
---
- hosts: localhost
  gather_facts: false
  vars:
    silverbullet_data_dir: "$TMP/wiki-for-entrypoint-test"
  tasks:
    - ansible.builtin.include_role:
        name: wiki_volume
    - ansible.builtin.include_role:
        name: wiki_volume
        tasks_from: ensure_directory
      vars:
        wiki_volume_directory_path: "$TMP/entrypoint-target"
        wiki_volume_directory_mode: '0750'
YML
  ansible-playbook "$PB2" >/dev/null 2>&1 || { echo "FAIL: wiki_volume entrypoint failed"; rm -rf "$TMP"; exit 1; }
  st2="$(stat -c '%U:%G %a' "$TMP/entrypoint-target")"
  if [[ "$st2" != "llm_wiki:llm_wiki 750" ]]; then
    echo "FAIL: entrypoint dir owner/mode = $st2 (expected llm_wiki:llm_wiki 750)"; rm -rf "$TMP"; exit 1
  fi
  echo "wiki_volume directory-bootstrap entrypoint OK (owner 750, called directly)"
  rm -rf "$TMP"
else
  echo "SKIP live wiki_volume run (llm_wiki absent or WIKI_VOLUME_LIVE!=1; operator-validate on VPS)"
fi
