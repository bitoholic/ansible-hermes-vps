# Spec: Custom Docker Services (OwnTracks, Syncplay)

> Status: ready-for-agent (draft)
> Source: Epic 12 — "Add additional custom docker services to this VPS"
> Related: `03-gateway-reverse-proxy` (ingress seam), `11-docker-consolidation` (docker role), `07-tailscale-private-access` (UFW ownership)
> Vocabulary: "gateway", "service fragment", "gateway_publish", "tailscale subnet", "source-based MFA bypass", "OwnTracks recorder", "Syncplay server", "IP-restricted public access", "Tailscale interface"

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
- **Storage** — SQLite (simple, zero-config)
- **Mobile app access** — requires public HTTPS (mobile clients on public net, not Tailscale)
- **Authentication** — basic auth (OwnTracks recorder supports HTTP basic auth natively via htpasswd)

### Syncplay (watch-together)
- **Syncplay Server** (custom TCP protocol on port 8999) — synchronized media playback for watching with friends
- **Access model** — IP-restricted public access via UFW allowlist (friends don't share Tailscale, but we don't want full public exposure)
- **Authentication** — server password (Syncplay's built-in `--password` flag)
- **No web panel** — official Syncplay server is CLI-only

Key difference from existing services: existing services (wiki, dash, auth, matrix) are **Tailscale-only** with source-based MFA bypass. These new services need different access models.

## Solution

Establish a **repeatable pattern** for adding custom Docker services, demonstrated by implementing OwnTracks and Syncplay. The pattern uses existing seams:

- **OwnTracks** (HTTP): docker fragment + `gateway_publish` contribution (public HTTPS, MFA-exempt) + UFW port 8080 (public) + basic auth secrets
- **Syncplay** (raw TCP): docker fragment + UFW IP-allowlist on port 8999 (no gateway, no Caddy) + password secret

This creates a template for future custom services (Grafana, Prometheus, Home Assistant, etc.).

## User Stories

### OwnTracks
1. As a family member, I want to run the OwnTracks app on my phone and have it report my location to my private server over HTTPS, so that I don't rely on Google/Apple location history.
2. As a VPS operator, I want the OwnTracks recorder to be reachable via public HTTPS on `owntracks.<domain>`, so that phone apps on cellular/WiFi can connect without Tailscale.
3. As a VPS operator, I want OwnTracks to use HTTP basic auth (native to the recorder), so that I don't need Authelia forward-auth for this service (mobile apps can't handle it).
4. As a security reviewer, I want the UFW rule for OwnTracks to be explicit and rate-limited, so the default-deny posture is maintained and the public surface is visible.
5. As a VPS operator, I want the OwnTracks data to persist in a named Docker volume (SQLite), so that location history survives container restarts.
6. As a VPS operator, I want OwnTracks to be served via Caddy HTTPS on port 8448, so mobile apps get valid TLS without trusting self-signed certs.
7. As a security reviewer, I want the OwnTracks gateway route to use `mfa: false` and `tls_mode: auto` explicitly, so it's clear this is a public HTTPS endpoint.

### Syncplay
8. As a friend, I want to connect to the Syncplay server from anywhere without installing Tailscale, so that synchronized movie watching works with people outside my VPN.
9. As a VPS operator, I want Syncplay to be accessible from specific IP addresses (friends' home IPs) via UFW, so that the server isn't open to the entire public internet but is still accessible to my friends.
10. As a VPS operator, I want Syncplay to require a server password, so that even if someone's IP is somehow allowlisted, they can't join without the password.
11. As a security reviewer, I want the Syncplay port (8999) to be blocked by UFW default-deny except for explicitly allowed IPs, so the attack surface is minimized.
12. As a VPS operator, I want to add or remove friend IPs from the UFW allowlist by editing a single variable, so managing access doesn't require understanding UFW syntax.
13. As a VPS operator, I want Syncplay data (MOTD, room state) to persist across container restarts, so rooms and settings survive reboots.

### Pattern (both services + future)
14. As a VPS operator, I want to add a new custom Docker service by following a documented pattern (service fragment + gateway_publish or UFW + secrets), so that I don't have to reverse-engineer the stack each time.
15. As a reviewer, I want the OwnTracks and Syncplay services to appear in the consolidated `docker-compose.yml`, so the full service inventory is auditable in one place.
16. As a VPS operator, I want the existing services (wiki, dash, auth, matrix) to remain Tailscale-only with MFA bypass, so adding public services doesn't weaken the private services' posture.
17. As a future-proofing dev, I want the pattern documented so adding Grafana/Uptime Kuma/Home Assistant later follows the same steps without architectural changes.

## Implementation Decisions

### Shared pattern (both services)

- **No new roles** — uses existing seams only (docker service fragments, gateway_publish, tailscale UFW, secrets manifest). Adapter-grade changes.
- **Docker service fragments**: `roles/docker/templates/services/owntracks.yml.j2` and `syncplay.yml.j2`
- **Secrets manifest**: entries for both services' credentials in `group_vars/all/secrets.yml`
- **UFW rules**: added to `roles/tailscale/tasks/main.yml` (single firewall owner)
- **Docker enablement**: add both to `docker_enabled_services`; add `owntracks_data` to `docker_volumes`

### Service 1: OwnTracks

- **Service fragment** (`owntracks.yml.j2`):
  - Image: `owntracks/recorder:latest` (or pinned version tag)
  - Port: 8080 (container), on `gateway` network (no host port needed — Caddy reaches it by container name)
  - Volume: named `owntracks_data` → `/store` (SQLite storage)
  - Env: `OTR_AUTH_FILE=/store/htpasswd` (basic auth), `OTR_PORT=8080`, `OTR_HOST=0.0.0.0`
  - Networks: `gateway`
  - **No host port binding** — Caddy on the gateway network reaches it by container name

- **htpasswd generation**: Ansible task generates the basic auth file at `/opt/hermes-vps/owntracks/htpasswd` (or mount point) before container starts, using the bcrypt password hash from secrets. Can run in a new `owntracks` role or as a task in the `docker` role. Pattern: use Ansible's `community.general.htpasswd` module or a shell command.

- **Gateway route contribution** (new `roles/owntracks/defaults/main.yml`):
  ```yaml
  owntracks_gateway_publish:
    - host: owntracks
      upstream: owntracks:8080
      mfa: false
      tls_mode: "auto"  # ACME for public domain
  ```

- **Caddyfile template extension** (small schema addition to `roles/gateway/templates/Caddyfile.j2`):
  - Existing template uses `tls internal` for all routes.
  - Add `tls_mode` field support: when `tls_mode == "auto"`, render `tls` (Caddy ACME); when `"internal"`, render `tls internal`.
  - Schema extension: add optional `tls_mode` field to gateway route validation (default `"internal"`).
  - For owntracks: `tls_mode: "auto"` — Caddy will attempt ACME for `owntracks.<domain>`.

- **UFW rule**: rate-limited allow for port 8080 (public) alongside existing 80/443 limits in `roles/tailscale/tasks/main.yml`. Note: port 8080 is the container port; since Caddy is on the gateway network, the host port mapping (if any) is separate. Actually: Caddy is on the gateway network and reaches owntracks:8080 directly. No host port needed. The UFW rule should allow port 8080 for the Caddy container to work... but wait, Caddy on the gateway network doesn't need host-level access to owntracks.

  **Clarification**: Caddy's container reaches owntracks on the gateway network directly (`http://owntracks:8080`). No host port exposure needed. The UFW rule for owntracks is for port 8448 (Caddy's external HTTPS port). So the UFW rule should be:
  - Rate-limit port 8448 (Caddy's public HTTPS) — already covered by the existing `limit 443` rule (Caddy handles all HTTPS).
  - No separate UFW rule for port 8080 needed — owntracks isn't directly accessible from the host.

  Wait — but the user said "exposed on a public IP". The public exposure is via Caddy on port 8448. UFW already rate-limits 443 (Caddy). Since Caddy listens on 8448 for owntracks... does UFW need a rule for 8448?

  Looking at the existing UFW rules in tailscale role: they rate-limit ports 80, 443. Conduit on 8448 is Tailscale-only (UFW default-deny). Owntracks on 8448 is public. We need a rule for 8448.

  Actually: the Caddyfile currently has `wiki.domain.com`, `dash.domain.com`, `auth.domain.com`, `matrix.domain.com:8448`. If we add `owntracks.domain.com:8448`, Caddy will listen on port 8448 for that too. The existing UFW rule only covers 80/443. We need to add 8448 to the rate-limit list.

  Revised UFW: rate-limit ports 80, 443, 8448.

- **Secrets manifest additions** (`group_vars/all/secrets.yml`):
  - `owntracks_admin_username` (env: `OWNTRACKS_ADMIN_USERNAME`, required: false, default: "admin")
  - `owntracks_admin_password_hash` (env: `OWNTRACKS_ADMIN_PASSWORD_HASH`, required: true) — bcrypt hash (Apache htpasswd format)
  - `acme_email` (env: `ACME_EMAIL`, required: false) — for Caddy ACME certificate issuance

### Service 2: Syncplay

- **Service fragment** (`syncplay.yml.j2`):
  - Image: `dnomd343/syncplay` or `kayabe/syncplay-server` (official syncplay-server packaging)
  - Port: 8999 (container), host port `8999:8999` (exposed to host for raw TCP access)
  - Volume: named `syncplay_data` → `/store` (MOTD, room state persistence)
  - Env: `PASSWORD={{ secrets.syncplay_password }}` (server password)
  - Networks: `gateway` (for future inter-service needs)
  - Host port binding: `8999:8999` — needed because UFW filters host-level connections

- **Gateway route contribution**: None — Syncplay is not an HTTP service, Caddy can't reverse-proxy it. Access is direct TCP.

- **UFW IP-allowlist rule** (in `roles/tailscale/tasks/main.yml`):
  - Add a new task block for Syncplay-specific rules.
  - For each IP in `syncplay_allowed_ips` list: `ufw allow from <IP> to any port 8999 comment "Syncplay friend access"`.
  - Also add rate-limiting: `ufw limit 8999/tcp comment "Syncplay rate limit"`.
  - The `syncplay_allowed_ips` list is a new variable (defined in `group_vars/all/main.yml` or a syncplay role).

- **Secrets manifest addition** (`group_vars/all/secrets.yml`):
  - `syncplay_password` (env: `SYNCPLAY_PASSWORD`, required: true) — plaintext password for Syncplay server

- **Data directory**: Syncplay data dir at `/opt/hermes-vps/syncplay` (or similar) owned by `llm_wiki`.

### ACME email decision

- Caddy ACME needs an email for certificate notifications. This is a new required-or-optional secret.
- Decision: make it required for any service with `tls_mode: "auto"`, but optional with a default. If not set, Caddy uses its built-in LE email or fails.
- For now: `acme_email` (env: `ACME_EMAIL`, required: false, default: `admin@{{ secrets.silverbullet_domain }}`). Simpler.

### OwnTracks htpasswd decision

- OwnTracks recorder reads htpasswd file for basic auth. The file is `username:bcrypt_hash` per line.
- `community.general.htpasswd` module can create/update entries. Input: password hash (already bcrypt) or plaintext (module hashes it).
- Decision: store the **bcrypt hash** in the secret (`owntracks_admin_password_hash`), write it directly to the htpasswd file via a `copy` or `lineinfile` task. This avoids needing the plaintext password in the environment.
- htpasswd file format: `admin:$2y$10$...` (bcrypt).

## Testing Decisions

- **What makes a good test**: Test external behavior — rendered docker-compose.yml includes both services, rendered Caddyfile includes owntracks route (no mfa_auth, tls auto), UFW rules for 8448 (rate-limit) and 8999 (IP allowlist) exist in tailscale tasks, secrets manifest has both services' entries. Do not test Ansible internals.

- **Modules tested**:
  - `roles/docker/templates/services/owntracks.yml.j2` → renders valid compose fragment with correct image, port, volume, networks, env
  - `roles/docker/templates/services/syncplay.yml.j2` → renders valid compose fragment with correct image, port, volume, networks, env, password env
  - `roles/owntracks/defaults/main.yml` → gateway_publish has required fields (host, upstream, mfa: false, tls_mode: auto)
  - `roles/gateway/templates/Caddyfile.j2` → renders owntracks block with no mfa_auth and `tls` directive when tls_mode is auto
  - `roles/tailscale/tasks/main.yml` → UFW rules for 8448 (rate-limit) and 8999 (IP allowlist for syncplay_allowed_ips) present
  - `group_vars/all/secrets.yml` → owntracks and syncplay secrets present with correct required/optional
  - `group_vars/all/main.yml` → `syncplay_allowed_ips` list defined, `owntracks` and `syncplay` in `docker_enabled_services`, `owntracks_data` and `syncplay_data` in `docker_volumes`
  - Consolidated render: `docker compose config` passes

- **Prior art**: Mirror `tests/check-docker-compose-render.sh`, `tests/check-gateway-render.sh`, `tests/check-tailscale.sh` patterns. Extend lint pipeline to verify new service fragments and gateway_publish schema.

## Out of Scope

- **CouchDB/Postgres for OwnTracks** — start with SQLite. Advanced storage is a separate fragment if needed.
- **Authelia forward-auth for OwnTracks** — mobile apps can't handle it; basic auth is the correct choice.
- **Bili-SyncPlay web admin panel** — standard Syncplay server is sufficient; web admin is future work.
- **Syncplay TLS** — Syncplay has a `--tls` flag, but raw TCP TLS over UFW IP-filtered port is acceptable for friends-only access. If TLS is needed later, add cert configuration.
- **Dynamic DNS / IP allowlist updates** — `syncplay_allowed_ips` is a static Ansible variable; dynamic updates require a separate mechanism (future work).
- **OwnTracks extended storage** (Postgres) — SQLite is sufficient for family use.
- **Multiple instances** — single instance per service.

## Further Notes

- This spec establishes the **pattern** for custom services. OwnTracks and Syncplay are the proof-of-concept. Future services (Grafana, Uptime Kuma, etc.) follow the same steps.

- **Three access models** are now established:
  1. **Tailscale-only + MFA** — wiki, dash, auth, matrix (existing)
  2. **Public HTTPS + basic auth** — owntracks (new)
  3. **IP-restricted raw TCP + password** — syncplay (new)

- The **tailscale role remains the single UFW owner** — this is a critical architectural invariant. Any public port or IP allowlist must be added there.

- The **gateway remains the single Caddyfile writer** — HTTP services declare intent via `gateway_publish`; non-HTTP services (Syncplay) skip the gateway entirely.

- **Syncplay IP management**: `syncplay_allowed_ips` is a list of CIDR ranges or IP addresses. Friends with dynamic IPs can use their home router's public IP (or a range). If a friend's IP changes, update the variable and re-run. No dynamic DNS needed.

- **OwnTracks domain**: uses `secrets.silverbullet_domain` (e.g., `<secret-silverbullet-domain>`) → `owntracks.<secret-silverbullet-domain>`. No new domain secret.

- **Caddy ACME**: for `tls_mode: "auto"`, Caddy will attempt ACME for `owntracks.<domain>`. The domain must be publicly resolvable and port 443 must be accessible. Rate-limited by UFW.

- **Order of operations**: data directories (owntracks htpasswd, syncplay data) must exist before containers start. Use `file` tasks with `owner: llm_wiki` (consistent with other service data dirs).

- **htpasswd generation for OwnTracks**: `community.general.htpasswd` module can write the htpasswd file. Since we store the bcrypt hash (not plaintext), use `mode: '0644'` on the htpasswd file (readable by the owntracks container). Actually: the owntracks container may run as a different user, so `0644` is correct.
