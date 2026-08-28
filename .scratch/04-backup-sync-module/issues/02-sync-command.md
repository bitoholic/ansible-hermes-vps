# 02: sync command + unit test

**What to build:** The `backup_sync sync` command, which ports the existing real-time sync logic (from `roles/backup/templates/sync-to-dev.sh.j2`) verbatim into the module: ensure the working branch is checked out, `pull --rebase` from origin, stage everything, commit only if there are changes, and push. The behavior is now exercisable without a full Ansible play. A unit test drives it against a temp local bare remote so sync correctness (diff detection → commit → push) is caught in CI, not on the live wiki.

**Blocked by:** 01 (Scaffold backup_sync module).

**Status:** ready-for-agent

- [ ] `backup_sync sync --repo <dir> --branch <b> --message <m>` performs checkout / pull --rebase / add -A / conditional commit / push.
- [ ] With a clean tree, `sync` exits 0 having committed nothing (no empty commit).
- [ ] With a dirty tree, `sync` creates exactly one commit and pushes to the configured remote.
- [ ] Unit test uses a temp git repo + local bare remote and asserts the resulting commit and remote ref; no live wiki or token required.
- [ ] The old `sync-to-dev.sh.j2` logic is reproduced behavior-for-behavior (no behavior change vs current template).
