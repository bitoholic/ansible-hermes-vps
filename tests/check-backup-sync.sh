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

# sync unit test: drive `sync` against a temp local bare remote (no live wiki / token).
echo "== backup_sync sync unit test =="
tmp="$(mktemp -d)"
git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" >/dev/null 2>&1
git -C "$tmp/work" checkout -q -b vps-sync
printf 'hello\n' > "$tmp/work/file.txt"
git -C "$tmp/work" -c user.email=test@test -c user.name=test add -A
git -C "$tmp/work" -c user.email=test@test -c user.name=test commit -qm init
git -C "$tmp/work" push -q origin vps-sync
# A git identity so the module's own commit succeeds (the role/VPS provides this in prod).
git -C "$tmp/work" config user.email test@test
git -C "$tmp/work" config user.name test

printf 'world\n' >> "$tmp/work/file.txt"
"$MODULE" sync --repo "$tmp/work" --branch vps-sync --message "chore: sync wiki"
git -C "$tmp/work" log --oneline | grep -q "chore: sync wiki" || { echo "FAIL: sync did not commit"; rm -rf "$tmp"; exit 1; }
git -C "$tmp/remote.git" log --oneline vps-sync | grep -q "chore: sync wiki" || { echo "FAIL: sync did not push to remote"; rm -rf "$tmp"; exit 1; }

# Idempotent on a clean tree: no new commit, no empty commit.
before="$(git -C "$tmp/work" rev-parse HEAD)"
"$MODULE" sync --repo "$tmp/work" --branch vps-sync --message "chore: sync wiki"
after="$(git -C "$tmp/work" rev-parse HEAD)"
[[ "$before" == "$after" ]] || { echo "FAIL: sync created a commit on a clean tree"; rm -rf "$tmp"; exit 1; }
rm -rf "$tmp"
echo "sync unit test OK"

# create-pr unit test: mock the GitHub API with a fake `curl` on PATH (no live token).
echo "== backup_sync create-pr unit test =="
tmp="$(mktemp -d)"
fake="$tmp/fake"
mkdir -p "$fake/bin"
# Real git repo so the module can read remote.origin.url; slug parsed from an SSH URL.
git init -q "$tmp/repo"
git -C "$tmp/repo" remote add origin "git@github.com:acme/wiki.git"

# 201 success stub: records args, replies with a created-PR JSON + status line.
cat > "$fake/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$@" > "$(dirname "$0")/../curl_args"
printf '{"number": 1, "html_url": "http://fake/1"}\n201\n'
FAKE
chmod +x "$fake/bin/curl"

out="$(GITHUB_TOKEN=secret-token PATH="$fake/bin:$PATH" "$MODULE" create-pr --repo "$tmp/repo" --branch vps-sync --message "Daily sync" --api-url http://fake.example)"
grep -q "Created PR successfully" <<< "$out" || { echo "FAIL: create-pr did not report success"; rm -rf "$tmp"; exit 1; }

args="$(cat "$fake/curl_args")"
echo "$args" | grep -q "POST" || { echo "FAIL: create-pr did not POST"; rm -rf "$tmp"; exit 1; }
echo "$args" | grep -q "/repos/acme/wiki/pulls" || { echo "FAIL: wrong PR endpoint (owner/repo)"; rm -rf "$tmp"; exit 1; }
echo "$args" | grep -q 'Authorization: token secret-token' || { echo "FAIL: token not sent via Authorization header"; rm -rf "$tmp"; exit 1; }
echo "$args" | grep -q "fake.example/repos" | grep -q "secret-token" && { echo "FAIL: token leaked into the URL"; rm -rf "$tmp"; exit 1; }
echo "$args" | grep -q '"title": "Daily sync"' || { echo "FAIL: PR title missing"; rm -rf "$tmp"; exit 1; }
echo "$args" | grep -q '"head": "vps-sync"' || { echo "FAIL: PR head missing"; rm -rf "$tmp"; exit 1; }
echo "$args" | grep -q '"base": "main"' || { echo "FAIL: PR base missing"; rm -rf "$tmp"; exit 1; }

# 422 "already exists" is treated as success (idempotent nightly run).
cat > "$fake/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '{"message": "A pull request already exists for vps-sync."}\n422\n'
FAKE
chmod +x "$fake/bin/curl"
out="$(GITHUB_TOKEN=secret-token PATH="$fake/bin:$PATH" "$MODULE" create-pr --repo "$tmp/repo" --branch vps-sync --message "Daily sync" --api-url http://fake.example)"
grep -q "Pull request already exists" <<< "$out" || { echo "FAIL: 422 already-exists not handled idempotently"; rm -rf "$tmp"; exit 1; }

rm -rf "$tmp"
echo "create-pr unit test OK"

# git-crypt-init unit test: guarded — git-crypt may be absent in CI; skip rather than fail.
echo "== backup_sync git-crypt-init unit test =="
if ! command -v git-crypt >/dev/null 2>&1; then
  echo "SKIP git-crypt-init test (git-crypt not installed in this environment)"
else
  tmp="$(mktemp -d)"
  git init -q "$tmp/repo"
  key="$tmp/repo/git-crypt.key"
  "$MODULE" git-crypt-init --repo "$tmp/repo" --key-out "$key"
  [[ -e "$tmp/repo/.git/git-crypt/keys/default" ]] || { echo "FAIL: git-crypt not initialized"; rm -rf "$tmp"; exit 1; }
  [[ -s "$key" ]] || { echo "FAIL: key not exported"; rm -rf "$tmp"; exit 1; }
  perms="$(stat -c '%a' "$key")"
  [[ "$perms" == "600" ]] || { echo "FAIL: key perms $perms (want 600)"; rm -rf "$tmp"; exit 1; }
  # Idempotent: second run must succeed without re-initializing or re-exporting errors.
  "$MODULE" git-crypt-init --repo "$tmp/repo" --key-out "$key"
  mtime1="$(stat -c '%Y' "$key")"
  "$MODULE" git-crypt-init --repo "$tmp/repo" --key-out "$key"
  mtime2="$(stat -c '%Y' "$key")"
  [[ "$mtime1" == "$mtime2" ]] || { echo "FAIL: key re-exported on second init"; rm -rf "$tmp"; exit 1; }
  rm -rf "$tmp"
  echo "git-crypt-init unit test OK"
fi

echo "backup_sync OK"
