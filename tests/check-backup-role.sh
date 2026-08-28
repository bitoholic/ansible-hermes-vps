#!/usr/bin/env bash
# Guard that the backup role is a thin adapter over backup_sync (epic 04 ticket #07):
# it must deploy only the module, the git credential helper, the watcher units, and the cron —
# and must not carry the old copy-pasted sync/PR shell scripts. The live `ansible-playbook
# site.yml --check --diff` dry-run is operator-validated on the VPS (needs become + network);
# this static check is the CI-surfaceable equivalent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="$REPO_ROOT/roles/backup"
MAIN="$ROLE/tasks/main.yml"

echo "== backup role adapter guard =="

# 1. The role templates dir must hold ONLY the two watcher units — no sync/PR scripts.
stray="$(ls "$ROLE/templates" | grep -E 'sync-to-dev|create-daily-pr' || true)"
if [[ -n "$stray" ]]; then
  echo "FAIL: stray sync/PR templates still present: $stray"; exit 1
fi
for f in llm-wiki-watcher.path.j2 llm-wiki-watcher.service.j2; do
  [[ -f "$ROLE/templates/$f" ]] || { echo "FAIL: missing watcher template $f"; exit 1; }
done

# 2. The deleted scripts must not exist on disk.
for f in sync-to-dev.sh.j2 create-daily-pr.sh.j2; do
  [[ -e "$ROLE/templates/$f" ]] && { echo "FAIL: $f should have been deleted"; exit 1; }
done

# 3. main.yml must deploy the module, the credential helper, both watcher units, and the cron,
#    and must NOT reference the old scripts.
grep -q "backup_sync" "$MAIN" || { echo "FAIL: role does not deploy backup_sync module"; exit 1; }
grep -q "git-credential-env" "$MAIN" || { echo "FAIL: role does not deploy the credential helper"; exit 1; }
grep -q "llm-wiki-watcher.path" "$MAIN" || { echo "FAIL: role does not deploy watcher path unit"; exit 1; }
grep -q "llm-wiki-watcher.service" "$MAIN" || { echo "FAIL: role does not deploy watcher service unit"; exit 1; }
grep -q "create daily backup PR" "$MAIN" || { echo "FAIL: role does not schedule the nightly PR cron"; exit 1; }
if grep -qE 'sync-to-dev\.sh\.j2|create-daily-pr\.sh\.j2' "$MAIN"; then
  echo "FAIL: role still references deleted sync/PR templates"; exit 1
fi

# 4. The watcher service + cron must call the module, not the old scripts.
grep -q "backup_sync sync" "$ROLE/templates/llm-wiki-watcher.service.j2" || { echo "FAIL: watcher ExecStart does not call 'backup_sync sync'"; exit 1; }
grep -q "create-pr" "$MAIN" || { echo "FAIL: cron does not call 'backup_sync create-pr'"; exit 1; }

echo "backup role adapter guard OK"
