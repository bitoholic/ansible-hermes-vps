# 02: Per-role route contributions (`gateway_publish`) assembled by gateway

**What to build:** Each role declares *what it publishes* instead of the gateway knowing every upstream. SilverBullet contributes `wiki → silverbullet:3000`, Authelia contributes `auth → authelia:9091` with `mfa: false`, and Hermes contributes `dash → hermes-agent:9119` — each via its own `gateway_publish` contribution (the role owns its publish entry). The gateway assembles `gateway_routes` from all role contributions. Publishing a future service (a new dashboard/admin UI) becomes a single entry in that service's own role, never an edit to SilverBullet's Caddyfile from inside another role's land. SilverBullet no longer encodes knowledge of Hermes or Authelia.

**Blocked by:** #01 (Gateway module — route-data interface + Caddyfile adapter)

**Status:** ready-for-agent

- [ ] Each relevant role declares its own `gateway_publish` contribution; the gateway assembles `gateway_routes` from them.
- [ ] The three current routes render identically to #01 (no behavior change from the move).
- [ ] Adding a published service is a one-line entry in its owning role, with no edit to SilverBullet/gateway routing code.
- [ ] `roles/silverbullet` contains no reference to `hermes-agent` or `authelia` upstreams.

