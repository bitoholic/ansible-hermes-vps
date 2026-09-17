# 01: Build Caddy from a local Dockerfile with the Cloudflare DNS plugin

**What to build:** Caddy's container image switches from a stock pulled image to one built from this repo's own Dockerfile, using Caddy's official plugin-build mechanism to compile in the Cloudflare DNS module — with zero behavior change yet. This is a pure build-mechanism swap that sets up the next ticket's actual migration.

**Blocked by:** None (can start immediately)
**Blocks:** #02

**Status:** ready-for-agent

- [ ] Caddy's service definition builds from a local Dockerfile instead of pulling a pre-built image, with an explicitly pinned Caddy version (no floating `latest` tag) in both the build and runtime stages
- [ ] The built image includes the Cloudflare DNS plugin, compiled in via Caddy's own official builder mechanism, not a third-party pre-built plugin image
- [ ] Every existing route continues to work exactly as before — the plugin is present but unused; rendered Caddyfile output for every route is byte-identical to before this ticket
- [ ] Consolidated docker-compose render (`docker compose config`) passes with Caddy now building rather than pulling

## Notes

See epic 19 spec, "Solution" and the grilled decision on the Caddy-image approach: build our own via Caddy's official `xcaddy` builder (mirroring the existing `hermes-agent` locally-built-Dockerfile pattern), rejected a third-party pre-built plugin image, because Caddy is this stack's single TLS-termination point for every service, not just the two this epic changes.
