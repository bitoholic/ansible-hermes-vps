# Ticket #04: Syncplay Docker service fragment

**Blocked by:** none
**Blocks:** #06–#07

## Description

Create the Syncplay server Docker service fragment for the consolidated compose stack.

1. **Service fragment** at `roles/docker/templates/services/syncplay.yml.j2`:
   - Image: `dnomd343/syncplay` (or `kayabe/syncplay-server`)
   - Container name: `syncplay`
   - Port: host `8999` → container `8999` (exposed to host for raw TCP access — UFW filters it)
   - Volume: named `syncplay_data` → `/syncplaydata` (MOTD, room state persistence)
   - Environment:
     - `PASSWORD={{ secrets.syncplay_password }}` (Syncplay server password)
     - `PORT=8999`
   - Networks: `gateway`
   - Restart policy: `unless-stopped`
   - User: `llm_wiki` (UID/GID 10000)

2. **Volume**: add `syncplay_data` to `docker_volumes` in `roles/docker/defaults/main.yml`

3. **Enable service**: add `syncplay` to `docker_enabled_services` in `roles/docker/defaults/main.yml`

## Acceptance criteria

- `roles/docker/templates/services/syncplay.yml.j2` renders a valid Docker Compose service fragment
- `syncplay` appears in `docker_enabled_services` list
- `syncplay_data` appears in `docker_volumes` list
- `docker compose config` validates successfully
- Host port `8999` is mapped for UFW IP filtering
- Environment includes `PASSWORD` from secrets

## Notes

- Syncplay uses a custom TCP protocol (not HTTP), so Caddy cannot reverse-proxy it.
- Access is controlled at the host level via UFW IP allowlist (ticket #05).
- The official Syncplay server has no built-in web panel — all configuration is via CLI args or env vars.