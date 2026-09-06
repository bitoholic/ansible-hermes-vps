# Spec: Custom Docker Services (OwnTracks, Syncplay)

> Status: ready-for-agent (draft)
> Source: Epic 12 — "Add additional custom docker services to this VPS"
> Related: `03-gateway-reverse-proxy` (ingress seam), `11-docker-consolidation` (docker role), `07-tailscale-private-access` (UFW ownership)
> Vocabulary: "gateway", "service fragment", "gateway_publish", "tailscale subnet", "source-based MFA bypass", "OwnTracks recorder", "Syncplay server", "IP-restricted public access", "Tailscale interface", "tls_mode"

## Problem Statement

The VPS currently runs a fixed set of services (SilverBullet, Hermes, Authelia, Conduit, Caddy, signal-cli) managed through the consolidated docker role. There is no documented pattern for adding new custom services — each addition requires figuring out:
- Where to add the docker service fragment
- How to wire ingress via the gateway (for HTTP services) or UFW (for raw TCP services)
- How to handle UFW rules (the tailscale role owns the firewall)
- How to manage secrets via the single manifest
- Whether the service needs MFA (tailnet), password (public), or IP allowlist

The user wants to add **two custom services**:

### OwnTracks (location tracking)
- **OwnTracks Recorder** (HTTP API on port 8080) — receives location data from mobile apps
- **Storage** — SQLite via named Docker volume
- **Mobile app access** — requires public HTTPS (mobile clients on public net, not Tailscale)
- **Authentication** — HTTP basic auth (htpasswd file)

### Syncplay (watch-together)
- **Syncplay Server** (custom TCP protocol on port 8999) — synchronized media playback for watching with friends
- **Access model** — IP-restricted public access via UFW allowlist (friends don't share Tailscale, but we don't want full public exposure)
- **Authentication** — server password (Syncplay's env-var-based password)
- **No web panel** — official Syncplay server is CLI-only

Key difference from existing services: existing services (wiki, dash, auth, matrix) are **Tailscale-only** with source-based MFA bypass. These new services need different access models.

## Solution

Establish a **repeatable pattern** for adding custom Docker services, demonstrated by implementing OwnTracks and Syncplay. The pattern uses existing seams:

- **OwnTracks** (HTTP): new `owntracks` role with service fragment + `gateway_publish` contribution (public HTTPS, MFA-exempt, ACME TLS) + htpaswd generation + UFW rate-limit on 8448
- **Syncplay** (raw TCP): service fragment + UFW IP-allowlist on port 8999 (no gateway, no Caddy) + password secret + rate-limit

## User Stories

1. As a family member, I want to run the OwnTracks app on my phone and have it report my location to my private server over HTTPS, so that I don't rely on Google/Apple location history.
2. As a VPS operator, I want the OwnTracks recorder to be reachable via public HTTPS on `owntracks.<domain>`, so that phone apps on cellular/WiFi can connect without Tailscale.
3. As a VPS operator, I want OwnTracks to use HTTP basic auth (native to the recorder), so that I don't need Authelia forward-auth for this service (mobile apps can't handle it).
4. As a security reviewer, I want the UFW rule for Owntracks to be rate-limited (port 8448), so the default-deny posture is maintained and the public surface is visible.
5. As a VPS operator, I want the OwnTracks data to persist in a named Docker volume (SQLite), so that location history survives container restarts.
6. As a VPS operator, I want OwnTracks to be served via Caddy HTTPS on port 8448 with ACME, so mobile apps get valid TLS.
7. As a security reviewer, I want the OwnTracks gateway route to use `mfa: false` and `tls_mode: auto` explicitly, so it's clear this is a public HTTPS endpoint.
8. As a friend, I want to connect to the Syncplay server from anywhere without installing Tailscale, so that synchronized movie watching works with people outside my VPN.
9. As a VPS operator, I want Syncplay to be accessible from specific IP addresses (friends' home IPs) via UFW, so that the server isn't open to the entire public internet but is still accessible to my friends.
10. As a VPS operator, I want Syncplay to require a server password, so that even if someone's IP is somehow allowlisted, they can't join without the password.
11. As a security reviewer, I want the Syncplay port (8999) to be blocked by UFW default-deny except for explicitly allowed IPs, so the attack surface is minimized.
12. As a VPS operator, I want to add or remove friend IPs from the UFW allowlist by editing a single variable, so managing access doesn't require understanding UFW syntax.
13. As a VPS operator, I want Syncplay data (MOTD, room state) to persist across container restarts, so rooms and settings survive reboots.
14. As a VPS operator, I want to add a new custom Docker service by following a documented pattern (service fragment + gateway_publish or UFW + secrets), so that I don't have to reverse-engineer the stack each time.
15. As a reviewer, I want the OwnTracks and Syncplay services to appear in the consolidated `docker-compose.yml`, so the full service inventory is auditable in one place.
16. As a VPS operator, I want the existing services (wiki, dash, auth, matrix) to remain Tailscale-only with MFA bypass, so adding public services doesn't weaken the private services' posture.
17. As a future-proofing dev, I want the pattern documented so adding Grafana/Uptime Kuma/Home Assistant later follows the same steps without architectural changes.

## Implementation Decisions

### Caddyfile consolidation (critical change)

The current `roles/gateway/templates/Caddyfile.j2` has Conduit hardcoded as a separate block (not in the gateway loop):
```jinja2
{{ secrets.silverbullet_domain }}:8448 {  # ← missing "matrix." prefix
  tls internal
  reverse_proxy http://conduit:{{ conduit_port }}
}
```

This needs three changes:
1. **Fix the missing `matrix.` prefix**: change to `matrix.{{ secrets.silverbullet_domain }}:8448`
2. **Move Conduit into the gateway loop** by adding `host: matrix` to a `gateway_publish` contribution
3. **Port sharing via SNI**: multiple hostnames can share port 8448 (Caddy routes by Host header/SNI)

The Caddyfile template renders each route in the `gateway_routes` loop as:
```jinja2
{% for route in gateway_routes %}
{{ route.host }}.{{ secrets.silverbullet_domain }}{% if route.port %}:{{ route.port }}{% endif %} {
  log
  tls internal
...
```

Conduit becomes a standard route entry with `host: matrix`, `port: 8448`, and the hardcoded block is removed.

### Shared pattern (both services)

- **Docker service fragments**: `roles/docker/templates/services/owntracks.yml.j2` and `syncplay.yml.j2`
- **Secrets manifest**: entries for both services' credentials in `group_vars/all/secrets.yml`
- **UFW rules**: added to `roles/tailscale/tasks/main.yml` (single firewall owner)
- **Docker enablement**: add both to `docker_enabled_services`; add `owntracks_data` and `syncplay_data` to `docker_volumes`

### Service 1: OwnTracks

- **Role created**: `roles/owntracks/` with `tasks/main.yml`, `defaults/main.yml`, `templates/`
- **Service fragment** (`roles/docker/templates/services/owntracks.yml.j2`):
  - Image: `owntracks/recorder:latest` (or pinned version tag)
  - Port: 8080 (container), on `gateway` network only — no host port binding
  - Volume: named `owntracks_data` → `/store` (SQLite storage)
  - Env:
    - `OTR_HOST=[IP_ADDRESS]` (bind all interfaces)
    - `OTR_PORT=8080`
    - `OTR_AUTH_FILE=/store/htpasswd` (basic auth)
    - `OTR_STORAGE=/store` (SQLite database path)
  - Volumes bound: `owntracks_data` → `/store`, and htpasswd file from host → `/store/htpasswd:ro`
  - Networks: `gateway`
  - User: `llm_wiki` (UID/GID 10000), consistent with other services

- **htpasswd generation** (task in `roles/owntracks/tasks/main.yml`):
  - Use `community.general.htpasswd` module with `path: "{{ owntracks_htpasswd_path }}"`, `name: "{{ secrets.owntracks_admin_username }}"`, `password: "{{ secrets.owntracks_admin_password }}"`, `hash: bcrypt`
  - `owntracks_htpasswd_path`: `/opt/hermes-vps/owntracks/htpasswd` (host path)
  - Requires `passlib[bcrypt]` Python package on control node
  - File permissions: `0644` (readable by container)

- **Gateway route contribution** (new `roles/owntracks/defaults/main.yml`):
  ```yaml
  owntracks_gateway_publish:
    - host: owntracks
      upstream: owntracks:8080
      mfa: false
      tls_mode: "auto"
      port: 8448
  ```
  Port 8448 to share with matrix/conduit (Caddy SNI routing). `tls_mode: "auto"` for ACME.

- **Caddyfile template extension**:
  - Add optional `port` field support to gateway routes (renders `:8448` suffix if present)
  - Add `tls_mode` conditional: `tls` when `"auto"`, `tls internal` when `"internal"` or absent
  - Caddyfile template change (example):
    ```jinja
    {% if route.tls_mode == "auto" %}
    tls
    {% else %}
    tls internal
    {% endif %}
    ```

- **Gateway task loop update** (`roles/gateway/tasks/main.yml`):
  - Add `owntracks` and `conduit` to the `include_vars` loop (currently only loads silverbullet, authelia, hermes)
  - Move Conduit's `gateway_publish` from hardcoded block into the loop

- **Secrets manifest additions** (`group_vars/all/secrets.yml`):
  ```yaml
  owntracks_admin_username:
    env: OWNTRACKS_ADMIN_USERNAME
    required: false
    default: "admin"
  owntracks_admin_password:
    env: OWNTRACKS_ADMIN_PASSWORD
    required: true
  acme_email:
    env: ACME_EMAIL
    required: false
    default: "admin@{{ secrets.silverbullet_domain }}"
  ```

### Service 2: Syncplay

- **Service fragment** (`roles/docker/templates/services/syncplay.yml.j2`):
  - Image: `kayabe/syncplay-server` (or similar with env-var-based config)
  - Port: host `8999` → container `8999` (host port binding needed for UFW filtering)
  - Volume: named `syncplay_data` → `/syncplaydata` (MOTD, room state persistence)
  - Env:
    - `PASSWORD={{ secrets.syncplay_password }}` (Syncplay server password)
    - `PORT=8999`
  - Networks: `gateway` (future inter-service needs)
  - User: `llm_wiki` (UID/GID 10000)

- **No gateway contribution** — Syncplay uses raw TCP, not HTTP. Caddy can't proxy it.

- **UFW rules** (in `roles/tailscale/tasks/main.yml`):
  - Rate-limit port 8448 (Caddy HTTPS for OwnTracks + Matrix) added to existing 80/443 limit list
  - For each IP in `syncplay_allowed_ips`: `ufw allow from <IP> to any port 8999 proto tcp comment "Syncplay friend access"`
  - Rate-limit port 8999: `ufw limit 8999/tcp comment "Syncplay rate limit"`

- **Secrets manifest addition**:
  ```yaml
  syncplay_password:
    env: SYNCPLAY_PASSWORD
    required: true
  ```

- **`syncplay_allowed_ips`** in `group_vars/all/main.yml`:
  ```yaml
  syncplay_allowed_ips: []
  ```
  Operator populates with friend IPs/CIDRs. Empty list = port 8999 blocked (UFW default-deny).

- **Volume**: add `syncplay_data` to `docker_volumes` in `roles/docker/defaults/main.yml`

- **Env generation**: `syncplay_allowed_ips` must be referenced in `setup-env.sh` or `.env.template` (check existing scripts).

## Testing Decisions

- **What makes a good test**: Test external behavior — rendered docker-compose.yml includes both services, rendered Caddyfile includes owntracks route (no mfa_auth, tls auto), UFW rules for 8448 (rate-limit) and 8999 (IP allowlist + rate-limit) exist in tailscale tasks, secrets manifest has both services' entries. Do not test Ansible internals.

- **Modules tested**:
  - `roles/docker/templates/services/owntracks.yml.j2` → renders valid fragment with image, port 8080, volume, networks, env
  - `roles/docker/templates/services/syncplay.yml.j2` → renders valid fragment with image, port 8999:8999, volume, env password
  - `roles/owntracks/defaults/main.yml` → `owntracks_gateway_publish` with required fields (host, upstream, mfa: false, tls_mode: auto, port: 8448)
  - `roles/gateway/templates/Caddyfile.j2` → renders owntracks block with no `import mfa_auth`, `tls` directive (not `tls internal`), on port `:8448`
  - `roles/gateway/templates/Caddyfile.j2` → renders `matrix.<domain>:8448` (not the bare domain) — fixes the missing prefix bug
  - `roles/tailscale/tasks/main.yml` → 8448 in rate-limit list; 8999 has IP allowlist + rate-limit
  - `group_vars/all/secrets.yml` → owntracks and syncplay secrets present
  - `group_vars/all/main.yml` → `syncplay_allowed_ips` defined; `owntracks` and `syncplay` in `docker_enabled_services`; `owntracks_data` and `syncplay_data` in `docker_volumes`
  - Consolidated render: `docker compose config` passes
  - `setup-env.sh` — prompts for new secrets

- **Prior art**: Mirror `tests/check-conduit.sh`, `tests/check-docker-compose-render.sh`, `tests/check-gateway-render.sh`, `tests/check-tailscale.sh`. Add `tests/check-custom-services.sh` and wire into `tests/lint.sh`.

## Out of Scope

- **CouchDB/Postgres for OwnTracks** — SQLite is sufficient for family use
- **Bili-SyncPlay web admin panel** — standard Syncplay server is sufficient
- **Syncplay TLS** — raw TCP over UFW IP-filtered port is acceptable for friends-only access. Syncplay does support TLS via flags, but adds complexity; defer
- **Dynamic DNS / IP allowlist updates** — `syncplay_allowed_ips` is static; dynamic updates require separate mechanism (future enhancement)
- **Multiple instances** — single instance per service
- **OwnTracks extended storage** — SQLite is sufficient

## Further Notes

- This spec establishes the **pattern** for custom services. OwnTracks and Syncplay are the proof-of-concept. Future services (Grafana, Uptime Kuma, etc.) follow the same steps.

- **Three access models** are now established:
  1. **Tailscale-only + MFA** — wiki, dash, auth, matrix (existing)
  2. **Public HTTPS + basic auth** — owntracks (new)
  3. **IP-restricted raw TCP + password** — syncplay (new)

- The **tailscale role remains the single UFW owner** — critical architectural invariant. Public ports and IP allowlists must be added there.

- The **gateway remains the single Caddyfile writer** — HTTP services declare intent via `gateway_publish`; non-HTTP services (Syncplay) skip the gateway entirely.

- **Caddyfile fix**: Conduit must move from a hardcoded block into the gateway loop. The current hardcoded block is missing the `matrix.` prefix — an existing bug. This fix is a prerequisite (ticket #01).

- **Syncplay IP management**: `syncplay_allowed_ips` is a list of CIDR ranges or individual IPs. Starting with one example entry. Friends with dynamic IPs update their home router IP.

- **OwnTracks domain**: uses `secrets.silverbullet_domain` (e.g., `<secret-silverbullet-domain>`) → `owntracks.<secret-silverbullet-domain>`. No new domain secret.

- **Caddy ACME**: for `tls_mode: "auto"`, Caddy will attempt ACME for `owntracks.<domain>`. The `acme_email` secret is needed. Domain must be publicly resolvable and port 443 accessible (already UFW rate-limited).

- **Order of operations**: data directories (htpasswd, Syncplay data) must exist before containers start. The `owntracks` role creates its htpasswd file; Syncplay uses a named volume (auto-created by Docker).