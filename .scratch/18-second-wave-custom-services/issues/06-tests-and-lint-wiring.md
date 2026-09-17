# 06: Tests, skip-tags guard, and lint wiring for the full epic

**What to build:** Full-stack regression coverage proving the epic's three services and the new route type integrate correctly without disturbing anything that existed before it.

**Blocked by:** #02, #03, #04, #05
**Blocks:** None

**Status:** ready-for-agent

- [ ] A new test suite (wired into the existing lint/test entry point) covers: the consolidated compose render with all four new services enabled; the rendered Caddyfile including the three new tailnet-only routes; and confirms every pre-existing route's Caddyfile output is unchanged
- [ ] The firewall test coverage confirms the new TCP-restricted ports (Beszel hub, AdGuard admin UI) and the new UDP-restricted port class (DNS) are present with the correct structure
- [ ] The secrets manifest test coverage confirms all new secret entries exist with the correct required/default shape, and the env-catalog sync check (`.env.template`/`setup-env.sh`) passes
- [ ] A machine-checked assertion confirms `beszel` and `adguard` are gateway dependencies, not separately listed top-level roles (guarding against the double-execution class of bug this repo has hit before, epic 15)
- [ ] The skip-tags guard confirms `beszel` and `adguard` behave like every other skippable role, and the README's skippable-roles table is updated

## Notes

See epic 18 spec, "Testing Decisions". Mirrors this repo's existing pattern of a dedicated tests-and-lint ticket at the end of a service-adding epic (see epic 12's own ticket #07).
