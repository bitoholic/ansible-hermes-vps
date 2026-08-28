# 01: Gateway module — route-data interface + Caddyfile adapter (owns `mfa_auth`)

**What to build:** A `gateway` module becomes the single owner of ingress authoring. It exposes a `gateway_routes` list of `{ host, upstream, mfa }` pairs and renders one Caddy site block per entry through a single Caddyfile adapter, wrapping each in the shared `mfa_auth` forward-auth snippet unless `mfa: false`. The `mfa_auth` snippet definition (forward-auth to the Authelia upstream) moves out of SilverBullet and lives only in the gateway. A new `roles/gateway` renders the Caddyfile into the ingress deploy directory (the SilverBullet compose dir, since Caddy runs there). SilverBullet stops authoring routing: its hardcoded `dash.`/`auth.` blocks and its own `Caddyfile.j2` are deleted, and it renders the gateway's template instead. The rendered Caddyfile for today's three routes (`wiki.`, `dash.`, `auth.`) is **byte-equivalent** to the current output, so behavior does not change when the config moves.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `gateway_routes` data interface exists and the gateway renders exactly one site block per route.
- [ ] The `mfa_auth` snippet is defined once in the gateway adapter and applied by default; `auth.` is rendered `mfa: false`.
- [ ] `roles/gateway` is the only writer of the Caddyfile; SilverBullet's `Caddyfile.j2` and its hardcoded `dash.`/`auth.` blocks are gone.
- [ ] Rendered Caddyfile for the current three routes is byte-equivalent to the pre-change output (regression-safe migration).
- [ ] `ansible-playbook site.yml --check --diff` previews the full Caddyfile identically to a real run.

