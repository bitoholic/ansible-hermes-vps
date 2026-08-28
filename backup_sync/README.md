# backup_sync

Standalone, CLI-driven module that owns the wiki → GitHub synchronization behavior. The
`backup` Ansible role is a thin *adapter*: it deploys this module and calls it, but no sync
logic lives in Jinja shell templates.

## Commands

All commands take `--repo <dir>` (the wiki git checkout). `sync` and `create-pr` additionally
take `--branch <b>` and `--message <m>`.

| Command | Purpose |
| --- | --- |
| `backup_sync sync --repo <dir> --branch <b> --message <m>` | Stage, commit (only if dirty), and push the working branch. |
| `backup_sync create-pr --repo <dir> --branch <b> --message <m>` | Open a PR from the working branch to `main`. Idempotent on "already exists" / "no commits". |
| `backup_sync git-crypt-init --repo <dir> [--key-out <path>]` | Initialize git-crypt and export the offline-recovery key (idempotent). |

## Secrets

The GitHub token is supplied via the environment (`GITHUB_TOKEN`, or the var named by
`--token-env`). **It is never embedded into a remote URL or an API URL.** The clone flow and
the module obtain credentials from the environment only.

## Testing

Unit tests drive the commands against fakes — a temp local bare remote for `sync`, a mocked
GitHub API for `create-pr`, and a temp repo for `git-crypt-init`. Run them via
`tests/check-backup-sync.sh`.
