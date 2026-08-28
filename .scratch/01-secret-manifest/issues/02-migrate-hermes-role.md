# 02: Migrate hermes role to secrets.<name>

**What to build:** The `hermes` role (the largest consumer of secrets) is switched from direct `lookup('env', …)` calls to reading the resolved `secrets.<name>` dictionary introduced in ticket 01. Runtime behavior and rendered files are byte-equivalent to before; only the resolution path changes.

**Blocked by:** 01 (secret manifest + resolver must exist first).

**Status:** ready-for-agent

- [ ] All secret references in `roles/hermes` tasks and templates use `secrets.<name>` instead of `lookup('env', …)`.
- [ ] Rendered `.env` / `config.yaml` / `SOUL.md` content is unchanged versus the pre-migration output for the default and `coder` / `intel` profiles.
- [ ] `ansible-playbook --check --diff` passes for the hermes tasks.
