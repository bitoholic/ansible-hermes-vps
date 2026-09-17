# 04: AdGuard Home — admin UI and ad-blocking engine over Tailscale

**What to build:** AdGuard Home running as a new service, its admin UI reachable only over Tailscale, fully configured (admin account, core settings) before first boot so no interactive setup wizard is required. DNS serving to the tailnet is explicitly deferred to the next ticket — this ticket delivers the dashboard, not yet a working resolver.

**Blocked by:** #01
**Blocks:** #05, #06

**Status:** done

- [x] A new role renders AdGuard's config (admin account from a securely-stored password hash, not plaintext) and bind-mounts it before the container's first start, so the interactive setup wizard never appears — minimal shape verified against AdGuard's own official Configuration wiki
- [x] The admin UI is published via a tailnet-only gateway route (no MFA, no public path), on a port that doesn't collide with any existing published port (3001, vs. SilverBullet's 3000)
- [x] The admin UI's raw container port is also published directly and added to the firewall's Tailscale-only restricted-port class
- [x] The admin UI's port is recorded in the port-class comment block alongside the other Tailscale-only-restricted ports
- [x] The secrets manifest has entries for the admin username/password-hash, following this repo's existing bcrypt-hash-secret pattern (matches `authelia_admin_password_hash`'s shape exactly — operator-precomputed, `required: true`, no chicken-and-egg problem the way Beszel's pairing credential had)
- [x] The new role's tasks are tagged and included in the skip-tags guard, and the role is wired in as a dependency of the gateway role rather than a fresh top-level entry
- [x] From a Tailscale-connected client, the admin UI is reachable and the pre-seeded login works; from outside Tailscale, the route returns the hard-block response (verified at the render level — no live Caddy/network in this environment)
- [x] Consolidated docker-compose render passes with the new service enabled

## Notes

See epic 18 spec, section "AdGuard Home". DNS-serving (port 53, firewall rules, the host-level systemd-resolved change) is out of scope for this ticket — see #05. The role's data/config directories should be bootstrapped the same way OwnTracks's storage directory is (a host bind-mount owned by the shared application uid), not a Docker-initialized named volume, so the non-root container doesn't fail to write on first boot.

## Implementation notes

- **Verified against AdGuard's own official Configuration wiki before writing any config** (not memory/inference): confirmed the minimal `AdGuardHome.yaml` shape that skips the setup wizard (`users[].name`/`password`, `http.address`, `dns.bind_hosts`/`port` — no `schema_version` needed; the only `schema_version` example found upstream belongs to an explicitly experimental "next-gen" config rewrite, not the stable format this image uses), the bcrypt password format (matches this repo's existing `community.general.htpasswd`/`hash_scheme: bcrypt` output), and that the official image always runs as root with no documented non-root support — so no `user:` override, same reasoning already applied to Beszel, and it's also why binding port 53 (ticket #05) needs no extra capability configuration.
- **Correction, unlike OwnTracks's role**: the ticket text's suggestion to bootstrap directories "the same way OwnTracks's storage directory is" (implying ownership is load-bearing for container write access) doesn't actually hold for AdGuard — since the container runs as root, ownership of the bind-mounted directories isn't load-bearing here the way it is for OwnTracks's non-root recorder. Directories are still bootstrapped via the same `wiki_volume` `ensure_directory` pattern for consistency with every other service, but the note is corrected here so a future reader doesn't assume a write-permission dependency that isn't real.
- **Password hash is operator-precomputed, not Ansible-generated**: unlike OwnTracks's role (which generates its htpasswd hash via a live `community.general.htpasswd` task), AdGuard's `adguard_admin_password_hash` follows the Authelia/dashboard pattern — the operator runs `htpasswd -B -C 10 -n -b` themselves and pastes the hash into `.env`. This is what the spec's Implementation Decisions specified, and unlike Beszel's pairing credential it has no chicken-and-egg problem (the hash doesn't depend on this playbook or AdGuard ever having run), so `required: true` is safe here without risking the deploy-deadlock ticket #03 hit.
- **Port choice**: admin UI published as host `3001` → container `3000` (AdGuard's own unchanged default). Only the host-side mapping changes to avoid the SilverBullet collision; Caddy's route still targets the container's actual port (`adguard:3000`) since container-to-container traffic on the `gateway` network is unaffected by host-side port remapping.
- Extended the existing `test_docker_compose.yml` and `test_gateway_render.yml` per the epic's established per-ticket testing convention, plus added a dedicated render test for `AdGuardHome.yaml.j2` itself (not just the compose fragment), since the config file's exact shape is what actually delivers this ticket's core "no interactive wizard" requirement.
- Epic 17's role-duplication regression bound raised again (8 → 9, `wiki_volume` execution count) — `adguard` is a third `wiki_volume`-dependent role via `gateway`'s meta chain (after `owntracks` and `beszel`), the same anticipated shift as ticket #03's.
