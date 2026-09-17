# 02: OwnTracks frontend — browser UI over Tailscale

**What to build:** A browser-based UI for OwnTracks location history, reachable only over Tailscale (no MFA needed — Tailscale membership alone is trusted), added as a second route within the existing OwnTracks role. The existing mobile app's public ingest endpoint and its basic-auth requirement are provably unaffected.

**Blocked by:** #01
**Blocks:** #06

**Status:** done

- [x] The OwnTracks frontend image is added as a new service in the consolidated compose stack, configured to reach the existing recorder over the internal docker network
- [x] A second gateway route is published for the frontend, using the new tailnet-only route type, with no basic-auth fields and no MFA
- [x] The existing recorder route (public, basic-auth, mobile app's ingest endpoint) is unchanged — byte-identical Caddyfile rendering, same fields, same values
- [x] From a Tailscale-connected client, the frontend UI loads and can query the recorder's data; from outside Tailscale, the frontend's route returns the hard-block response (verified at the render level — Caddyfile directives, not a live HTTP round-trip; no live Caddy/network in this environment, consistent with how this repo scopes live-behavior verification to the real VPS)
- [x] Consolidated docker-compose render (`docker compose config`) passes with the new service enabled (verified via `ansible-playbook tests/test_docker_compose.yml`; `docker compose config` itself is skipped in this environment where Docker isn't available, same as the existing `check-custom-services.sh` pattern)

## Notes

See epic 18 spec, section "OwnTracks frontend". No new role, no new secrets — this extends the existing `owntracks` role. The frontend image proxies only its own API/websocket calls to the recorder; it never touches the recorder's mobile-ingest path, which is why the two can stay on separate routes with separate access models.
