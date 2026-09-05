# 01: Expand docker role with consolidated compose scaffolding

**What to build:** A tracer-bullet extension of the `docker` role that establishes the
consolidated Compose file as a side-by-side artifact — created but NOT yet deployed.
The existing per-role `docker-compose.yml` files remain the source of containers, so no
behavior changes for a running VPS.

The `docker` role gains:
- a Compose project directory (`docker_compose_dir`, default `/opt/hermes-vps`) and a
  flat `docker_enabled_services` list,
- standard networks `gateway` and `internal` (in addition to the existing `proxy_net`
  for the transition window),
- a `docker-compose.yml.j2` template that assembles each service's existing fragment
  via the `lookup('template', ...)` filter, so the rendered file is byte-equivalent to
  the union of the current per-role files,
- a single `docker compose config --quiet` validation task that runs on every deploy.

End-to-end behavior delivered:
- `docker_compose_dir`/`gateway`/`internal` exist on first run,
- `/opt/hermes-vps/docker-compose.yml` renders and passes `docker compose config`,
- `proxy_net`/`hermes_net` are untouched; no existing container is affected.

**Blocked by:** None (can start immediately). The ADR (`docs/adr/0002-consolidated-docker-stack.md`) is the design reference.

**Status:** ready-for-agent

- [ ] `docker` role creates `docker_compose_dir` and networks `gateway`/`internal`
  (kept alongside `proxy_net`/`hermes_net` during transition).
- [ ] `docker-compose.yml.j2` renders one site block per enabled service by inlining
  each role's existing compose fragment; services map to `gateway`/`internal` correctly.
- [ ] A `docker compose config` task validates the rendered file; fails the deploy if invalid.
- [ ] `check-config-render.sh`-style verification: rendered file validates with a stub
  Compose CLI (or `yamllint` in CI) without touching running containers.
