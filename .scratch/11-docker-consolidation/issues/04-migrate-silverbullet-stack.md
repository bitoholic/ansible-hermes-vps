# 04: Migrate SilverBullet stack (Authelia + SilverBullet) to consolidated compose

**What to build:** Migrate the Authelia and SilverBullet services from the
silverbullet role's Compose project into the consolidated `docker` role.

The `silverbullet` role currently manages three services (`caddy`, `authelia`,
`silverbullet`) via a local `docker-compose.yml` with a `public` network. The
new fragment files:
- `roles/docker/templates/services/authelia.yml.j2`,
- `roles/docker/templates/services/silverbullet.yml.j2`.

These render as services on the `gateway` network (Caddy-facing) and the
`public` network is replaced by the `gateway` network.

End-to-end behavior delivered:
- Authelia and SilverBullet run in the consolidated project via the gateway network.
- Caddy can reach both services on the `gateway` network (previously broken
  due to separate compose networks).
- Silverbullet's public port `[IP_ADDRESS]:3000` is preserved.
- The silverbullet role's `tasks/main.yml` no longer renders its own compose file;
  it still provides the config and data volumes.

**Blocked by:** 02 (Caddy fragment), 03 (Conduit on gateway network confirms Caddy
proxy config works).

**Status:** ready-for-agent

- [ ] Fragment `roles/docker/templates/services/authelia.yml.j2` created.
- [ ] Fragment `roles/docker/templates/services/silverbullet.yml.j2` created.
- [ ] `gateway_routes` in the gateway role references the new `caddy` service name
  from the consolidated compose file; gateway validation tests pass.
- [ ] Silverbullet's existing compose file is stopped after the consolidated project
  is up (graceful cutover).
- [ ] `check-gateway-render.sh` passes after migration.