# 01: Build Caddy from a local Dockerfile with the Cloudflare DNS plugin

**What to build:** Caddy's container image switches from a stock pulled image to one built from this repo's own Dockerfile, using Caddy's official plugin-build mechanism to compile in the Cloudflare DNS module — with zero behavior change yet. This is a pure build-mechanism swap that sets up the next ticket's actual migration.

**Blocked by:** None (can start immediately)
**Blocks:** #02

**Status:** done

- [x] Caddy's service definition builds from a local Dockerfile instead of pulling a pre-built image, with an explicitly pinned Caddy version (`2.11.4` as of the live-deploy bugfix below; originally `2.8.4`, matching the prior pinned image tag — no floating `latest` tag) in both the build and runtime stages
- [x] The built image includes the Cloudflare DNS plugin, compiled in via Caddy's own official `xcaddy` builder mechanism (`caddy:<version>-builder` + `xcaddy build --with github.com/caddy-dns/cloudflare`), not a third-party pre-built plugin image
- [x] Every existing route continues to work exactly as before — the plugin is present but unused; this ticket touches only the compose fragment and the Dockerfile, not `Caddyfile.j2` at all, so route rendering is untouched by construction (not just verified unchanged)
- [x] Consolidated docker-compose render (`docker compose config`) passes with Caddy now building rather than pulling — verified directly with a real `docker compose config` invocation (CLI available in this environment; no daemon access needed for config validation), not just assumed

## Notes

See epic 19 spec, "Solution" and the grilled decision on the Caddy-image approach: build our own via Caddy's official `xcaddy` builder (mirroring the existing `hermes-agent` locally-built-Dockerfile pattern), rejected a third-party pre-built plugin image, because Caddy is this stack's single TLS-termination point for every service, not just the two this epic changes.

## Implementation notes

- The Dockerfile lives at `roles/gateway/files/Dockerfile` (not under `roles/docker/`) — mirrors `hermes-agent`'s convention of the Dockerfile source living near the role that conceptually owns the service (`gateway` owns Caddy's ingress behavior; the `docker` role only owns the consolidated compose file and copies the Dockerfile into its build context, exactly like it already does for `hermes-agent`'s own Dockerfile from `roles/hermes/files/`).
- Build context is a new dedicated directory (`{{ docker_compose_dir }}/caddy`), not `docker_compose_dir` itself — avoids accidentally handing Docker the whole compose-dir tree (which also holds the rendered `Caddyfile`, other services' data directories, etc.) as build context.
- Version pinned to `2.8.4` in both the builder and runtime stages — matches the exact tag the stock image was already pinned to, so this is genuinely a pure build-mechanism swap with no incidental version bump bundled in.
- No group_var/templating introduced for the version: since the compose fragment no longer references an `image:` tag at all (replaced by `build:`), the Dockerfile is now the *only* place Caddy's version is pinned — nothing to keep in sync, so a plain (non-templated) `Dockerfile` was sufficient; no need for a `Dockerfile.j2`.
- **Code review caught a real gap this ticket's own change introduced**: `roles/docker/tasks/start.yml`'s `docker_compose_v2` task used the module's default `build: policy`, which only builds an image if none exists yet under that project/service name — a future Dockerfile edit on an already-provisioned host would silently keep running the stale binary, with nothing surfacing that. This gap already existed for `hermes-agent`'s own `build:` stanza, but switching Caddy — the stack's single TLS-termination point — to `build:` too raises the stakes of it going unnoticed. Fixed by adding `build: always` (Docker's own layer-cache-backed rebuild — cheap when nothing actually changed, so this doesn't meaningfully slow down the common no-op-rebuild case), which benefits `hermes-agent`'s reliability too as a side effect. Added a regression check to `tests/check-stack-start-ordering.sh` and verified it by removing the setting and confirming the check fails, then restoring it.
- Verified `docker compose config` directly against the rendered fixture (the Docker CLI is available in this environment, and `config` validation doesn't require daemon access) rather than only trusting the existing conditional check in the test scripts — confirms the AC is genuinely met, not just structurally plausible.

## Live-deploy bugfix (post-merge)

The dev sandbox this epic was implemented in has no real Docker daemon, so `docker build`/`xcaddy build` itself was never actually exercised until the first real deploy to the live VPS — only `docker compose config` (syntax validation, no daemon needed) and Dockerfile-content assertions were possible pre-merge. That real deploy hit a genuine upstream incompatibility invisible to any of that: `caddy-dns/cloudflare` (every tagged release, v0.2.1 through the current v0.2.4) requires `certmagic` v0.23.0+ and `go.uber.org/zap/exp` v0.3.0, both API-incompatible with what Caddy 2.8.4's own core code was written against (confirmed via `xcaddy build --replace` attempts to pin either dependency back down individually — each just moved the compile error to a different file, since the plugin's `libdns` requirement had also moved on to the v1.x rewrite in the same window). No combination of `--replace` pins resolves all three simultaneously.

Fixed by bumping the pinned Caddy version to `2.11.4` (latest stable at fix time) — its own `go.mod` already requires `certmagic` v0.25.3 / `zap/exp` v0.3.0 / `libdns` v1.1.1, all compatible with the plugin's requirements, so the build resolves cleanly with zero `--replace` overrides. Verified with a real `xcaddy build` against `caddy:2.11.4-builder` on the VPS itself (not just Dockerfile syntax): compiles clean, and the resulting binary's `list-modules` output includes `dns.providers.cloudflare`. See `roles/gateway/files/Dockerfile`'s own updated comment for the full diagnostic trail.

This is a live-external-dependency-drift bug, not a logic error in the Dockerfile or the Ansible role — the exact same `xcaddy build --with github.com/caddy-dns/cloudflare` command against `caddy:2.8.4-builder` will keep failing for anyone building it fresh today, regardless of anything in this repo.
