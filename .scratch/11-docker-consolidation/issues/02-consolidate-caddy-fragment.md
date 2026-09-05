# 02: Consolidate Caddy + Caddyfile fragment into docker role

**What to build:** Move the Caddy service definition and its Caddyfile rendering from the
silverbullet role into the docker role as a Service Fragment. The silverbullet role will
continue to exist with the old compose file for a transition period, but it will no longer
be the primary definition of Caddy. 

The new fragment (`roles/docker/templates/services/caddy.yml.j2`) renders a service entry
using the consolidated networks (`gateway`, `internal`) and the existing `Caddyfile.j2`
template. The silverbullet Caddyfile template is updated to reference `caddy` from the
consolidated compose file instead of its local file.

End-to-end behavior delivered:
- The `docker-compose.yml` includes a `caddy` service from the new fragment.
- Caddy listens on the `gateway` network and can resolve backend services (e.g., `conduit`)
  via their container names on that same network.
- Silverbullet's local `Caddyfile` rendering is preserved temporarily; the new template
  overrides the legacy file with the consolidated one.

**Blocked by:** 01 (expand docker role with scaffolding).

**Status:** ready-for-agent

- [ ] Fragment file `roles/docker/templates/services/caddy.yml.j2` created.
- [ ] `roles/docker/templates/services/caddy.yml.j2` uses `{% include %}` or `lookup`
  to render from the existing Caddyfile.j2 template (without redefining all the config).
- [ ] Silverbullet's `tasks/main.yml` start task renders to the new consolidated path,
  preserving backward compatibility.
- [ ] `check-config-render.sh`-style verification: Caddy resolves and reachable on `gateway`
  network with a stubbed Compose config (or syntax check only).