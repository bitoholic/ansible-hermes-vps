# 05: Consolidate Hermes agent (signal-cli + hermes-agent) fragment

**What to build:** Migrate the Hermes agent (`signal-cli` + `hermes-agent`) from the
hermes role's Compose project into the consolidated `docker` role.

The hermes compose file has two services:
- `signal-cli` (on `hermes_net`, bind mount to `/opt/hermes/signal-data`),
- `hermes-agent` (on `hermes_net` + `proxy_net`, bind mounts to `/opt/hermes` and `/opt/wiki`,
  environment `GITHUB_TOKEN`, ports).

New fragments:
- `roles/docker/templates/services/signal-cli.yml.j2`,
- `roles/docker/templates/services/hermes-agent.yml.j2`.

`hermes-agent` needs to be on `internal` (to talk to `conduit` for Matrix) and
`gateway` (for any future external access). `signal-cli` stays on `internal`/`hermes_net`.
The `conduit_internal_url` (`http://conduit:8008`) must now work — Conduit must share
a network with Hermes Agent.

End-to-end behavior delivered:
- Both Hermes services run in the consolidated project.
- Hermes Agent can reach Conduit (`http://conduit:8008`) on a shared network.
- `hermes-agent` ports/patterns preserved; dashboard and MCP servers intact.

**Blocked by:** 03 (Hermes Agent talks to Conduit on Matrix transport; that must be proven).

**Status:** ready-for-agent

- [ ] Fragment `roles/docker/templates/services/signal-cli.yml.j2` created (binds mount,
  `internal` network).
- [ ] Fragment `roles/docker/templates/services/hermes-agent.yml.j2` created
  (`internal` + `gateway`, all environment + volumes preserved).
- [ ] Hermes Agent and Conduit share a network so `MATRIX_HOMESERVER=http://conduit:8008`
  resolves.
- [ ] `check-hermes-skills.sh` / `check-hermes-profile.sh` pass (agent config render intact).