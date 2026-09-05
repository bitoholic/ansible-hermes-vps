# 03: Migrate Conduit to consolidated compose (with data volume preservation)

**What to build:** Migrate Conduit from its own Compose project (`conduit`) to the
consolidated project managed by the `docker` role, ensuring Zero Data Loss and Zero Downtime.

The existing Conduit compose file renders to `/opt/conduit/docker-compose.yml` with a bind
mount to `/opt/conduit/data` and its config file. The new fragment in the docker role will:
- Use a named volume for persistence (optional; bind mount also works),
- Define the container on the `internal` network only (Conduit is private, Tailscale users
  reach it via the VPS host IP),
- Keep the `conduit` container name to avoid service disruption,
- Migrate the data directory creation and ownership (UID 1000) to the docker role's task, or
  keep it in the conduit role's pre-tasks for the expand phase.

At migration, the old `conduit` project is stopped AFTER the consolidated project is up
and healthy. The volume is switched from `/opt/conduit/data` bind mount to a named volume
(`conduit_data`), preserving data safely.

End-to-end behavior delivered:
- `docker compose -f /opt/hermes-vps/docker-compose.yml up -d` starts `conduit`.
- Conduit writes to its data volume; `conduit_ip` fact can still be computed via container
  introspection on the new network.
- The `@hermes` bot provisioning flow (conduit role task) works after migration.

**Blocked by:** 02 (Caddy fragment is first service; Conduit needs Caddy to proxy).

**Status:** ready-for-agent

- [ ] Fragment `roles/docker/templates/services/conduit.yml.j2` created; uses named volume
  or bind mount to `/opt/conduit/data`.
- [ ] Conduit runs on `gateway` network (so Caddy can proxy to it) and `internal` network
  (so Hermes Agent can reach it); host port still exposed for Tailscale access.
- [ ] Conduit deployment path preserved; migrate with zero data loss.
- [ ] Test `ansible-playbook -i tests/test_conduit.yml` passes after migration.