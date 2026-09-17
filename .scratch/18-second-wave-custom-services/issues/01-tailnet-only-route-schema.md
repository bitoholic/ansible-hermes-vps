# 01: Gateway route schema — `tailnet_only` hard-block route type

**What to build:** A new route access model in the gateway's schema — a boolean field that, when set on a route, makes Caddy hard-refuse (404) any request from outside the Tailscale subnet, with no MFA challenge involved. This is a genuinely private route type, distinct from the existing MFA-bypass model (which is still publicly reachable, just challenged).

**Blocked by:** None (can start immediately)
**Blocks:** #02, #03, #04

**Status:** ready-for-agent

- [ ] The gateway route schema declares the new boolean field, enforced automatically by the existing generic validation engine (no hand-written assert needed)
- [ ] A malformed (non-boolean) value for the field fails fast via the same validate-then-rescue pattern as every other schema field
- [ ] The Caddyfile template renders a hard-block directive for any route with the field set true, returning 404 to non-Tailscale sources, no forward-auth/MFA challenge involved
- [ ] A route can be constructed with the field set true and verified: Tailscale-sourced requests reach the upstream, non-Tailscale-sourced requests get 404
- [ ] Every existing route's rendered Caddyfile output (wiki, dash, auth, matrix, the OwnTracks recorder, syncplay) is byte-identical to its pre-ticket rendering — proving this is additive, not a behavior change

## Notes

See epic 18 spec, section "Gateway route schema addition: tailnet_only". This ticket has no dependency on any of the three new services — it's a self-contained prefactor they all build on. It corrects an error caught during the spec's own review: the existing `mfa` field does not make a route private, only MFA-gated-unless-Tailscale; the new field is what actually delivers "no public path at all."
