# 01: Gateway route schema — `tailnet_only` hard-block route type

**What to build:** A new route access model in the gateway's schema — a boolean field that, when set on a route, makes Caddy hard-refuse (404) any request from outside the Tailscale subnet, with no MFA challenge involved. This is a genuinely private route type, distinct from the existing MFA-bypass model (which is still publicly reachable, just challenged).

**Blocked by:** None (can start immediately)
**Blocks:** #02, #03, #04

**Status:** done

- [x] The gateway route schema declares the new boolean field, enforced automatically by the existing generic validation engine (no hand-written assert needed)
- [x] A malformed (non-boolean) value for the field fails fast via the same validate-then-rescue pattern as every other schema field
- [x] The Caddyfile template renders a hard-block directive for any route with the field set true, returning 404 to non-Tailscale sources, no forward-auth/MFA challenge involved
- [x] A route can be constructed with the field set true and verified: Tailscale-sourced requests reach the upstream, non-Tailscale-sourced requests get 404 (verified at the render level — no live Caddy/network in this environment, so this checks the generated Caddyfile's directives rather than an actual HTTP round-trip, consistent with how this repo's other gateway/tailscale tests scope live-behavior verification to the real VPS)
- [x] Every existing route's rendered Caddyfile output (wiki, dash, auth, matrix, the OwnTracks recorder, syncplay) is byte-identical to its pre-ticket rendering — proving this is additive, not a behavior change (wiki/dash previously only had a partial opening-line check, not a byte-exact block match like auth/matrix/owntracks already had; added during review so this AC is literally proven, not just inferred)

## Notes

See epic 18 spec, section "Gateway route schema addition: tailnet_only". This ticket has no dependency on any of the three new services — it's a self-contained prefactor they all build on. It corrects an error caught during the spec's own review: the existing `mfa` field does not make a route private, only MFA-gated-unless-Tailscale; the new field is what actually delivers "no public path at all."

## Implementation notes

Two review passes, both addressed:

**First pass:**
- The `tailnet_only` snippet's matcher is named `@not_tailscale_hard`, deliberately distinct from `mfa_auth`'s own `@not_tailscale` — caught in code review: the schema explicitly allows a route to set both `mfa: true` and `tailnet_only: true`, and reusing the same matcher name would have redefined it twice in one server block if a route ever did.
- One test assertion (checking `import mfa_auth` was absent from the tailnet_only route's block via a bounded regex) was caught as vacuous — `.*?` doesn't cross the `\n` before `\}` without a multiline/DOTALL flag, so it always matched an empty string. Removed; the adjacent exact byte-match assertion on the whole rendered block already proves the same thing correctly (any extra line would break that match).

**Second pass:**
- AC5 ("existing routes byte-identical") was only literally proven for auth/matrix/owntracks; wiki/dash had just a partial opening-line check. Added byte-exact block assertions for both, closing the gap so the AC is actually demonstrated, not inferred from the schema field-count check plus "the new conditional is false for these routes."
- The "both flags set" test's two matcher-definition assertions (`'@not_tailscale not remote_ip' in ...`, `'@not_tailscale_hard not remote_ip' in ...`) were caught as mislabeled: both named snippets are defined unconditionally at file scope, so those strings appear in *any* render regardless of the route under test — the assertion wasn't actually scenario-specific, and it can't detect a real Caddy-parser collision anyway (that only manifests when Caddy itself expands the imports, which Jinja rendering never shows — no `caddy` binary is available in this environment to verify that). Removed the two assertions and rewrote the surrounding comment to state plainly what the test can and can't prove: it confirms the `{% if %}` chain doesn't misrender when both flags are true (both imports land intact), not that Caddy accepts the combination at runtime.
- Added a one-line comment in `Caddyfile.j2` explaining why `tailnet_only`'s truthiness check needs an `is defined` guard while `mfa`'s doesn't (optional vs. required schema field) — flagged as a minor style inconsistency worth a comment rather than unifying the two checks, since the underlying reason they differ is real.
