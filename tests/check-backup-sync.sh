#!/usr/bin/env bash
# Invokes the backup_sync module's tests/interface checks (epic 04 ticket #01+ guard).
# For now this verifies the CLI scaffold: --help lists every subcommand, each subcommand
# documents its own --help, and a missing required arg fails clearly. As sync/create-pr/
# git-crypt-init land their unit tests, they are added here (and wired into tests/lint.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$REPO_ROOT/backup_sync/backup_sync"

echo "== backup_sync CLI interface =="

# --help lists every subcommand.
"$MODULE" --help | grep -qE '^\s*sync\s'            || { echo "FAIL: --help missing 'sync'"; exit 1; }
"$MODULE" --help | grep -qE '^\s*create-pr\s'       || { echo "FAIL: --help missing 'create-pr'"; exit 1; }
"$MODULE" --help | grep -qE '^\s*git-crypt-init\s'  || { echo "FAIL: --help missing 'git-crypt-init'"; exit 1; }

# Each subcommand documents its own --help.
for cmd in sync create-pr git-crypt-init; do
  "$MODULE" "$cmd" --help >/dev/null 2>&1 || { echo "FAIL: '$cmd --help' failed"; exit 1; }
done

# A missing required arg fails clearly (non-zero, mentions --repo).
if "$MODULE" sync >/dev/null 2>&1; then
  echo "FAIL: 'sync' without --repo should have errored"; exit 1
fi
out="$("$MODULE" sync 2>&1)" || true
echo "$out" | grep -q -- '--repo is required' || { echo "FAIL: missing-arg error unclear"; exit 1; }

# An unknown command fails clearly.
if "$MODULE" frobnicate >/dev/null 2>&1; then
  echo "FAIL: unknown command should have errored"; exit 1
fi

echo "backup_sync interface OK"
