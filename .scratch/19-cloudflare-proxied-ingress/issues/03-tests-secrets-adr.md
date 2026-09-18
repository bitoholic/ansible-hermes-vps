# 03: Tests, secrets/env sync, and ADR superseding ADR-0003

**What to build:** Regression coverage proving the port/cert migration is scoped correctly, the new secret is wired into the standard env-setup flow, and the historical record (ADR-0003) is updated to reflect the new decision rather than left silently contradicted.

**Blocked by:** #02
**Blocks:** None

**Status:** ready-for-agent

- [x] Tests confirm both migrated routes render the new port value and the DNS-01 issuer directive, scoped to exactly those two route blocks — no other route is affected
- [x] Tests confirm the Caddy service definition builds (not pulls) with the pinned version
- [x] The new secret is present in the env-catalog sync check (`.env.template`/`setup-env.sh`) with the correct required/no-default shape
- [x] A new ADR is written documenting this epic's decision (port move + DNS-01 + custom Caddy build) and explicitly marks ADR-0003 as superseded, preserving its original incident/reasoning history rather than deleting or rewriting it

## Notes

See epic 19 spec, "Testing Decisions" and "Further Notes". The suggested follow-up on Cloudflare's SSL/TLS encryption mode (Full → Full-strict, now viable once a real cert is served) should be noted in the new ADR as an operator option, not implemented or enforced by this ticket.

## Implementation notes

- First two checkboxes (port/DNS-01 scoping, Caddy build-not-pull shape) were already covered by tickets #01/#02's own test files (`tests/test_gateway_render.yml`, `tests/test_docker_compose.yml`) — verified still passing, not re-implemented. This ticket's own new coverage is the version-pin check and the secrets-manifest shape check below.
- New `tests/check-cloudflare-proxied-ingress.sh` (epic-wide summary script, matching the established per-epic convention of `check-custom-services.sh`/`check-second-wave-services.sh`): re-runs `test_docker_compose.yml`/`test_gateway_render.yml`, and adds two checks that weren't covered anywhere yet:
  - `cloudflare_api_token`'s manifest SHAPE (`required: true`, no `default:` key at all) — `check-resolver.sh` already proved the fail-fast *naming* behavior, but nothing pinned the shape itself, the same gap `check-second-wave-services.sh` closed for beszel/adguard's secrets.
  - The Caddy Dockerfile's version pin: both `FROM caddy:...` lines (builder and runtime stage) must reference the same explicit version, never `:latest`. Each of the three new assertions (missing `:latest`, `required: true` regression, `default:` regression, version-mismatch regression) was verified empirically by introducing the exact regression, confirming the check fails with the right message, then reverting — the `block_of`/`entry_has`/`entry_lacks` helpers are the same boundary-aware shape used elsewhere in this repo's test scripts (not a fixed `grep -A<N>` window, which a prior ticket found could silently pass a real regression).
  - Wired into `tests/lint.sh` alongside the other per-epic summary scripts.
- `docs/adr/0004-matrix-owntracks-cloudflare-proxy-migration.md`: new ADR recording the port move, DNS-01 switch, and custom Caddy build decision, including the Cloudflare "Full (strict)" SSL/TLS-mode follow-up as a noted operator option (not implemented/enforced here, per the ticket's own instruction).
- `docs/adr/0003-matrix-public-cert-and-server-name.md`: `Status` line changed to point at ADR-0004 and note exactly which of its conclusions are superseded (port choice, DNS-record-exposure decision) versus which still stand (`server_name`, registration token). Original incident diagnosis and reasoning body left untouched, per the ticket's explicit instruction not to edit it in place.
- `README.md`: conduit bullet's ADR reference updated to say "superseded in part by ADR-0004" now that ADR-0004 actually exists (a prior round's version of this same wording was flagged as premature during ticket #02's review, since no successor ADR existed yet at that point).
- No role/template code changed in this ticket — purely test/doc additions, as the ticket's own scope describes.
- Full `tests/lint.sh` suite green (exit 0). `ansible-playbook --syntax-check site.yml` clean.
