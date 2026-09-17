# 04: AdGuard Home — admin UI and ad-blocking engine over Tailscale

**What to build:** AdGuard Home running as a new service, its admin UI reachable only over Tailscale, fully configured (admin account, core settings) before first boot so no interactive setup wizard is required. DNS serving to the tailnet is explicitly deferred to the next ticket — this ticket delivers the dashboard, not yet a working resolver.

**Blocked by:** #01
**Blocks:** #05, #06

**Status:** ready-for-agent

- [ ] A new role renders AdGuard's config (admin account from a securely-stored password hash, not plaintext) and bind-mounts it before the container's first start, so the interactive setup wizard never appears
- [ ] The admin UI is published via a tailnet-only gateway route (no MFA, no public path), on a port that doesn't collide with any existing published port
- [ ] The admin UI's raw container port is also published directly and added to the firewall's Tailscale-only restricted-port class — an independent enforcement layer from the Caddy-level route, so a raw-port connection is blocked the same way a Caddy-routed one is
- [ ] The admin UI's port is recorded in the port-class comment block alongside the other Tailscale-only-restricted ports, so a future addition (including this epic's own AdGuard DNS port, ticket #05) doesn't collide with it
- [ ] The secrets manifest has entries for the admin username/password-hash, following this repo's existing bcrypt-hash-secret pattern
- [ ] The new role's tasks are tagged and included in the skip-tags guard, and the role is wired in as a dependency of the gateway role rather than a fresh top-level entry
- [ ] From a Tailscale-connected client, the admin UI is reachable and the pre-seeded login works; from outside Tailscale, the route returns the hard-block response
- [ ] Consolidated docker-compose render passes with the new service enabled

## Notes

See epic 18 spec, section "AdGuard Home". DNS-serving (port 53, firewall rules, the host-level systemd-resolved change) is out of scope for this ticket — see #05. The role's data/config directories should be bootstrapped the same way OwnTracks's storage directory is (a host bind-mount owned by the shared application uid), not a Docker-initialized named volume, so the non-root container doesn't fail to write on first boot.
