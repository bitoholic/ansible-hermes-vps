# 04: git-crypt-init command + unit test

**What to build:** The `backup_sync git-crypt-init` command, which ports the git-crypt init / key-export / fetch flow (currently inline in `roles/backup/tasks/main.yml`) into the module as an idempotent, testable function. It initializes git-crypt for the wiki repo, exports the symmetric key for offline recovery, restricts its permissions, and (optionally) fetches it back to the control node. The offline-recovery key flow becomes reliable and unit-tested rather than buried in Ansible tasks.

**Blocked by:** 01 (Scaffold backup_sync module).

**Status:** ready-for-agent

- [ ] `backup_sync git-crypt-init --repo <dir> --key-out <path>` initializes git-crypt only when not already initialized (idempotent).
- [ ] Exports the symmetric key to `--key-out` and sets mode `0600`; skips re-export when the key already exists.
- [ ] Unit test runs in a temp repo (guarded/skipped when the `git-crypt` binary is absent in CI) and asserts idempotent init + single key export across two invocations.
