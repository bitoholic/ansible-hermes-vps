# 04: Migrate remaining roles to secrets.<name>

**What to build:** The remaining roles — `common`, `docker`, `authelia`, `silverbullet`, `users`, `ssh_hardening` — are switched from direct `lookup('env', …)` calls to the resolved `secrets.<name>` dictionary, completing the migration of all top-level secret consumers.

**Blocked by:** 01 (secret manifest + resolver must exist first).

**Status:** ready-for-agent

- [ ] All secret references across `common`, `docker`, `authelia`, `silverbullet`, `users`, and `ssh_hardening` use `secrets.<name>`.
- [ ] Rendered configs for authelia/silverbullet are unchanged versus pre-migration output.
- [ ] `ansible-playbook --check --diff` passes for these roles.
