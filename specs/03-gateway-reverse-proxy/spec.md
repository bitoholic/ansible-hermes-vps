# Spec: Gateway / Reverse-Proxy Seam

> Status: ready-for-agent (draft)
> Source: Architecture review candidate #3 — "Gateway / reverse-proxy seam"
> Related: `02-hermes-profile-module` (publishes the `dash.` route); `01-secret-manifest` (auth secrets)
> Vocabulary: "gateway", "Hermes agent", "profile", "wiki store".

## Problem Statement

The ingress chain — **Caddy → Authelia (MFA forward-auth) → service** — is owned by three roles that leak across their seams:

- `roles/silverbullet/templates/Caddyfile.j2` is the only file that defines the Caddy site blocks, and it **hardcodes routes for other roles' services**: `dash.{{ silverbullet_domain }} → hermes-agent:9119` and `auth.{{ silverbullet_domain }} → authelia:9091`.
- So the **SilverBullet** role knows about **Hermes** and **Authelia** — its Caddyfile must be edited whenever another service is published.
- The shared `mfa_auth` forward-auth snippet is defined inside the same Caddyfile, so the "everything is behind MFA" contract is implicit and easy to violate per-route.
- The **routing intent** (which subdomains exist, what they map to, all behind MFA) has no single owner.

This is a leaking seam: adding a published service means reaching into SilverBullet's Caddyfile from wherever the new container is defined (as Hermes already effectively does for `dash.`).

## Solution

Introduce a **`gateway` module** that owns the routing declarations as data: a list of `{ subdomain → upstream }` pairs, all wrapped in the shared `mfa_auth` snippet. A single Caddyfile template renders them. Publishing a new container (e.g. a future dashboard or admin UI) becomes **one route entry**, not an edit to SilverBullet's Caddyfile from inside another role's land.

This gives **locality** (proxy policy in one module) and **leverage** (a new ingress is a one-line route). It is an *adapter*-grade seam — currently only Caddy is the ingress adapter, so this is "worth exploring" rather than urgent until a second ingress appears; the module still removes the cross-role leakage today.

## User Stories

1. As a developer publishing a new container, I want to add one route entry to a gateway module, so that I don't edit SilverBullet's Caddyfile from another role.
2. As a reviewer, I want all published subdomains listed in one place, so that I can see the full ingress surface at a glance.
3. As a security reviewer, I want the MFA contract applied centrally to every route, so that a new route can't accidentally skip Authelia.
4. As an operator, I want the Caddyfile generated from the route list, so that the rendered config can't drift from the declared intent.
5. As a developer, I want the gateway module to own the `mfa_auth` snippet definition, so that the auth contract isn't buried in SilverBullet.
6. As an operator running `--check --diff`, I want the gateway template to render identically in check mode, so a dry run previews the full Caddyfile.
7. As a reviewer, I want the `dash. → hermes-agent` and `auth. → authelia` routes declared in the gateway module, so SilverBullet no longer encodes knowledge of other roles.
8. As a developer, I want to declare a route as MFA-exempt (e.g. `auth.` itself, or an ACME challenge) explicitly, so exceptions are visible, not implied by omission.
9. As an operator, I want a missing upstream or unknown subdomain to fail fast at render time, so that a typo doesn't produce a silent 502.
10. As a future-proofing dev, I want the route list to be ingress-adapter-agnostic data, so a second ingress (e.g. Traefik) could be added as a new adapter without touching role logic.

## Implementation Decisions

- **Module introduced:** `gateway` — owns the route declarations and the `mfa_auth` snippet. Could be a dedicated role or a `group_vars` data structure + a single Caddyfile template; the data (route list) is the interface, the Caddyfile is one adapter over it.
- **Interface exposed:** a `gateway_routes` list of `{ host, upstream, mfa: bool }`; the gateway renders one site block each, wrapping in `mfa_auth` unless `mfa: false`.
- **Seam:** the gateway module is the single writer of the Caddyfile. SilverBullet stops owning routing and instead contributes its upstream (`silverbullet:3000`) as a route entry; Authelia contributes `authelia:9091` (`mfa: false`); Hermes contributes `hermes-agent:9119`.
- **Highest seam preserved:** only the gateway writes the ingress config. Other roles declare *what they publish*; they do not emit Caddy site blocks. The deletion test passes — removing the gateway would force every role to re-implement routing.
- **MFA contract:** the `mfa_auth` snippet (forward-auth to `authelia:9091`) is defined once in the gateway template and applied by default; exemptions are explicit `mfa: false` entries.
- **Migration:** move the existing blocks from `roles/silverbullet/templates/Caddyfile.j2` (the `wiki.`, `dash.`, `auth.` sites and the `mfa_auth` snippet) into the gateway module, leaving SilverBullet to only supply its upstream.
- **No new runtime dependency:** Caddy remains the ingress; the change is purely where the config is authored.

## Testing Decisions

- **What makes a good test:** test the *rendered Caddyfile's external behavior* — given a `gateway_routes` list, every route appears once, MFA is applied except where explicitly exempt, and unknown/missing fields fail. Do not test Jinja internals.
- **Modules tested:**
  - The route list → Caddyfile render: assert each declared route yields exactly one site block, and `mfa_auth` is present on MFA routes and absent on `mfa: false` routes.
  - Regression: the rendered Caddyfile for today's three routes (`wiki.`, `dash.`, `auth.`) is byte-equivalent to the current `Caddyfile.j2` output (guards against behavior change during the move).
  - Validation: a malformed route (missing `upstream`, or non-boolean `mfa`) fails fast at render.
- **Prior art:** mirror the repo's existing `--check --diff` dry-run (`tests/test_playbook.yml`) and top-level `assert` pre-flight pattern for gateway validation.

## Out of Scope

- Switching ingress adapters (Traefik/Nginx) — the data is adapter-agnostic, but only the Caddy adapter is built here.
- TLS / certificate sourcing beyond the current `tls internal` approach.
- The Hermes profile refactor (`02-hermes-profile-module`) — it only *consumes* the gateway by contributing a route.
- Authelia's own configuration (`authelia-configuration.yml.j2`); only its published upstream is referenced.

## Further Notes

- This is the **third** candidate and the first "worth exploring" one: it removes real cross-role leakage now, but the full payoff (easy multi-adapter ingress) only materializes if a second ingress appears.
- It directly resolves the architecture-review finding that SilverBullet's Caddyfile knows about Hermes and Authelia.
- Recommended as the **third** change, after the two `Strong` candidates land.
