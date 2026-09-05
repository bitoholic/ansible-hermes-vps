# 07: Contract - remove legacy per-role compose files, enforce single project

**What to build:** Final migration step that removes all per-role `docker-compose.yml`
files and their start tasks, leaving the consolidated Compose project as the sole
source of containers.

After all services are running from `/opt/hermes-vps/docker-compose.yml`, remove:
- `roles/silverbullet/templates/docker-compose.yml.j2` and the silverbullet start task.
- `roles/conduit/templates/docker-compose.yml.j2` and the conduit `docker_compose_v2` start task.
- `roles/hermes/templates/docker-compose.yml.j2` and the hermes `docker_compose_v2` start task.

Update `site.yml` so the `docker` role renders and brings up ALL services. Each service role's
tasks reduce to: create directories/volumes (with ownership), render config files, write fragments.

End-to-end behavior delivered:
- Single, authoritative `docker-compose.yml` at `/opt/hermes-vps`.
- `docker compose -f /opt/hermes-vps/docker-compose.yml ps` shows all services across the VPS.
- No orphan `conduit` / `silverbullet` Compose projects; clean `docker compose ls` output.

**Blocked by:** 06 (all fragments exist, tests validate the render).

**Status:** ready-for-agent

- [ ] All per-role `docker-compose.yml.j2` templates removed.
- [ ] All per-role `docker_compose_v2` start tasks replaced with directory/config tasks only.
- [ ] `site.yml` `docker` role brings up the full stack (start task in docker role).
- [ ] `docker compose -f /opt/hermes-vps/docker-compose.yml up -d` reproduces a clean stack.
- [ ] All `check-*.sh` scripts still pass (gateway render, config render, conduit, hermes).