# 04: Wire per-profile secrets from the resolver

**What to build:** Profile-specific secrets stop being read via `lookup('env', …)` in `group_vars/all/main.yml` (the deferred exception from the secret-manifest epic). Instead the role reads them from the resolved `secrets` dict: `secrets.profiles.<profile>.<leaf>` (introduced in `01-secret-manifest` #06). `hermes_profiles` entries reference their secret keys rather than embedding `lookup('env', …)`. The `tests/lint.sh` single-seam guard is updated to drop the `hermes_profiles` exception.

**Blocked by:** 01 (and 01-secret-manifest #06).

**Status:** ready-for-agent

- [ ] `group_vars/all/main.yml` `hermes_profiles` no longer contains `lookup('env', …)`.
- [ ] Role consumes `secrets.profiles.<profile>.<leaf>` for coder/intel keys (openrouter, nous, context7).
- [ ] `env_profile.j2` uses the resolved `secrets.profiles.*` values.
- [ ] `tests/lint.sh` seam guard no longer permits the `hermes_profiles` exception; lint green.
