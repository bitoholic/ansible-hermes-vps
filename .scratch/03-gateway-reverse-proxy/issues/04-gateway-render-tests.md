# 04: Gateway render test suite, wired into `lint.sh`

**What to build:** A behavioral render test that guards the gateway contract the way the repo already guards the hermes role. Given a `gateway_routes` list, the gateway Caddyfile template renders into a temp dir and the test asserts: each declared route yields exactly one site block; `mfa_auth` is present on MFA routes and absent on `mfa: false` routes; a malformed route (missing `upstream`, or non-boolean `mfa`) fails fast; and the rendered Caddyfile for today's three routes is byte-equivalent to the current `Caddyfile.j2` output (regression guard against behavior change during the move). Mirrors the existing `tests/test_config_render.yml` / `tests/test_hermes_profile.yml` pattern and the repo's `--check --diff` dry-run, and is wired into `tests/lint.sh`.

**Blocked by:** #01 (Gateway module), #02 (Per-role route contributions), #03 (Explicit MFA-exempt + fail-fast validation)

**Status:** ready-for-agent

- [ ] `tests/test_gateway_render.yml` (+ `tests/check-gateway-render.sh`) renders the gateway Caddyfile from `gateway_routes` and asserts one site block per route, MFA presence/absence, and byte-equivalence regression.
- [ ] A malformed-route case fails the render (covers missing `upstream` and non-boolean `mfa`).
- [ ] The gateway render check is wired into `tests/lint.sh` and the suite passes.
- [ ] `tests/verify.sh` syntax check stays green.

