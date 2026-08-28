# 01: Secret manifest + resolver (expand)

**What to build:** A single secret-resolution interface for the whole stack. One manifest module declares every logical secret with its source env var, whether it is `required`, and an optional `default`. A resolver (a bootstrap play or small `secrets` role) reads the manifest once, resolves each entry via `lookup('env', …)`, and exposes a `secrets.<name>` dictionary. Nothing breaks yet: existing roles keep using today's inline lookups. A missing required secret fails fast with a clear, named message; an optional secret falls back to its default or empty. Resolver behavior is identical under `--check` (no writes).

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Manifest lists every secret currently resolved via `lookup('env', …)` with `env`, `required`, and optional `default` fields; logical names preserved (e.g. `authelia_session_secret`, `dashboard_admin_password_hash`).
- [ ] Resolver exposes a `secrets.<name>` dict after a bootstrap play/role, consuming the manifest.
- [ ] A required-but-unset secret raises a clear, named failure; an optional unset secret resolves to its default or empty.
- [ ] `--check` run resolves and fails fast identically, with no file writes.
- [ ] Playbook runs unchanged end-to-end (roles still on old lookups) — this ticket is purely additive.
