# 07: Tighten credential-bearing files on the VPS to least privilege (droppable)

**What to build:** Rendered files on the VPS that contain credentials are readable only by whoever actually needs them, while the admin user can still run `docker compose` as today. The live audit found the rendered compose file, the gateway Caddyfile and the Matrix homeserver config readable by every local account. **Droppable:** removing this ticket affects no other ticket.

**Blocked by:** None (can start immediately)
**Blocks:** None

**Status:** ready-for-agent

- [x] An audit lists every rendered file that contains credentials, who actually reads it (an operator, the docker group, a specific container user), and the chosen owner and mode
- [x] The compose file is readable by root and the docker group only, so the admin user's `docker compose` usage keeps working
- [x] Files read only by a container are restricted to the user or root that container runs as
- [x] Render-level assertions pin the owners and modes
- [x] No container fails to start because of the change (verified at render level; the attended check happens at the next real deploy and is noted here)

## Notes

See epic 22 spec, "Implementation Decisions" (secrets at rest on the VPS). Included by author decision — the operator may drop it.

## Implementation

**Audit** (every rendered file that bakes in a `secrets.*` value, its actual reader, and its resulting permissions):

| File | Reader | Before | After |
|---|---|---|---|
| `docker-compose.yml` | `docker compose` CLI (as the admin user, client-side) + dockerd (root) | no owner set (root), `0644` | `root:docker`, `0640` |
| gateway `Caddyfile` | the `caddy` container — confirmed via its own Dockerfile's comment: no `USER` directive, still runs as root | no owner set (root), `0644` | `root:root`, `0600` |
| `conduit.toml` (Matrix homeserver) | the `conduit` container — `user: "{{ wiki_volume_uid }}:{{ wiki_volume_gid }}"`, i.e. `llm_wiki` | `llm_wiki:llm_wiki`, `0644` | `llm_wiki:llm_wiki`, `0600` |
| `llm-wiki-watcher.service` (systemd unit) | systemd itself (root); found during this ticket's own audit, not in the three files the live audit named | no owner set (root), `0644` | `root:root`, `0600` |
| `authelia/configuration.yml`, `authelia/users.yml` | the `authelia` container (`wiki_volume_uid:wiki_volume_gid` = `llm_wiki`) | `llm_wiki:llm_wiki`, `0600` | unchanged — already correctly scoped |
| AdGuard `AdGuardHome.yaml` | the `adguard` container | `llm_wiki:llm_wiki`, `0600` | unchanged — already correctly scoped |
| hermes profile `config.yaml`/`.env` | the `hermes-agent` container (own baked-in `hermes` user, not `wiki_volume_uid`) | `llm_wiki:llm_wiki`, `0640` | unchanged — pre-existing, working scheme; not touched (no confirmed problem, and the container's actual UID doesn't match `llm_wiki` at all, so re-deriving its correct ownership is a bigger, separate question outside this ticket's four confirmed at-rest violations) |

Four files fixed: the three the live audit named (compose file, gateway Caddyfile, Conduit config) plus the
systemd unit found independently while building this audit — its `Environment=GITHUB_TOKEN=...` line was baked in
at `0644` under `/etc/systemd/system/`, the conventional (and here, actually-applied) mode for a systemd unit,
meaning any local account could read a real GitHub token with a plain `cat`. systemd itself always runs as root
and reads a unit file regardless of its mode, so tightening it to `root:root 0600` costs nothing.

**Render-level assertions**: `tests/test_docker_compose.yml`, `tests/test_gateway_render.yml`, and
`tests/test_conduit.yml` each render their file with the same mode the real role task now uses and assert the
rendered file's `stat.mode` matches (owner/group aren't asserted in these local, unprivileged test runs — setting
`group: docker` would fail on a test host without a `docker` group; the real role task's `become: true` on the
actual VPS is what a real deploy exercises). `tests/check-backup-role.sh` (whose own suite is entirely static, no
Ansible render) instead asserts the systemd unit's task literally contains `mode: '0600'` and `owner: root`.

**Container-start risk**: verified at render level only, as the criterion itself anticipates — every file's target
mode was derived from its container's own actual `user:` directive (or, for root-run containers, confirmed via the
image/Dockerfile), not guessed, and every existing render/structural test for the affected files
(`check-docker-compose-render.sh`, `check-gateway-render.sh`, `check-conduit.sh`, `check-custom-services.sh`,
`check-cloudflare-proxied-ingress.sh`, `check-second-wave-services.sh`, `check-tailnet-caddy-access.sh`,
`check-backup-role.sh`, `check-backup-sync.sh`) still passes. Whether the actual running containers on the live VPS
tolerate the tightened permissions (in particular: does `docker compose` truly work for the admin user via group
membership alone, does Caddy's own bind-mount read succeed at 0600 root-owned) is confirmed only by an attended
real deploy, not by anything in this repo's test suite — noted here per the criterion's own framing, not treated
as done.
