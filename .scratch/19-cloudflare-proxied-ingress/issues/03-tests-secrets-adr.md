# 03: Tests, secrets/env sync, and ADR superseding ADR-0003

**What to build:** Regression coverage proving the port/cert migration is scoped correctly, the new secret is wired into the standard env-setup flow, and the historical record (ADR-0003) is updated to reflect the new decision rather than left silently contradicted.

**Blocked by:** #02
**Blocks:** None

**Status:** ready-for-agent

- [ ] Tests confirm both migrated routes render the new port value and the DNS-01 issuer directive, scoped to exactly those two route blocks — no other route is affected
- [ ] Tests confirm the Caddy service definition builds (not pulls) with the pinned version
- [ ] The new secret is present in the env-catalog sync check (`.env.template`/`setup-env.sh`) with the correct required/no-default shape
- [ ] A new ADR is written documenting this epic's decision (port move + DNS-01 + custom Caddy build) and explicitly marks ADR-0003 as superseded, preserving its original incident/reasoning history rather than deleting or rewriting it

## Notes

See epic 19 spec, "Testing Decisions" and "Further Notes". The suggested follow-up on Cloudflare's SSL/TLS encryption mode (Full → Full-strict, now viable once a real cert is served) should be noted in the new ADR as an operator option, not implemented or enforced by this ticket.
