# 07: Wire module tests + dry-run guard

**What to build:** The module's unit tests run as a first-class step in the repo's CI harness, and a role-level check confirms the slimmed `backup` role deploys only the module + systemd units + cron. This guarantees sync/PR/git-crypt regressions are caught in CI and that a `--check --diff` preview of the role is faithful — the two operator-facing promises from the spec.

**Blocked by:** 02 (sync command), 03 (create-pr command), 04 (git-crypt-init command), 05 (role slimmed to adapter), 06 (close token-in-URL leak).

**Status:** ready-for-agent

- [ ] `tests/check-backup-sync.sh` runs the module's unit tests (sync / create-pr / git-crypt-init) and is added to `tests/lint.sh`.
- [ ] `lint.sh` exits non-zero if any module test fails.
- [ ] A check (in `lint.sh` or `test_playbook.yml`) confirms `roles/backup` dry-run deploys only the module, the watcher units, and the cron — no stray script templates.
