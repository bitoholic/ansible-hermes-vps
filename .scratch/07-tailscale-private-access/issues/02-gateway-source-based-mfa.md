---
title: Gateway source-based MFA matcher
status: ready-for-agent
blocked_by: [01-scaffold-tailscale-role]
depends_on: [tailscale, authelia]
---

# #02 — `gateway` source-based MFA matcher

Keep `authelia`; modify the Caddyfile `mfa_auth` snippet so Authelia applies to non-Tailscale
clients and is skipped for Tailscale clients (per ADR-0001). The Tailscale subnet is encoded once.

## What to build

- `roles/gateway/templates/Caddyfile.j2` (or its `mfa_auth` snippet): wrap the Authelia forward-auth
  in a matcher such as `match / { not remote_ip <tailscale-subnet> }` so VPN clients bypass MFA and
  public clients hit it. Existing `mfa: true` routes keep working.
- Use the single Tailscale subnet constant (shared with the `tailscale` role's ufw allow).

## Acceptance (Definition of Done)

- [ ] The Caddyfile renders `mfa_auth` inside the source-IP bypass matcher.
- [ ] `authelia` role is unchanged; MFA still applies to public-net requests.
- [ ] VPN clients reach Caddy-routed services without an Authelia prompt; public clients are challenged.
