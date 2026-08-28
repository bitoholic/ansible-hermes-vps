# 03: Migrate backup role to secrets.<name>

**What to build:** The `backup` role is switched from direct `lookup('env', …)` calls to the resolved `secrets.<name>` dictionary. The GitHub token (used for the wiki clone and sync) now comes from the resolver rather than an inline `lookup('env', …)`.

**Blocked by:** 01 (secret manifest + resolver must exist first).

**Status:** ready-for-agent

- [ ] All secret references in `roles/backup` tasks use `secrets.<name>` instead of `lookup('env', …)`.
- [ ] The wiki clone/sync uses the token from `secrets` rather than a direct env lookup.
- [ ] `ansible-playbook --check --diff` passes for the backup tasks.
