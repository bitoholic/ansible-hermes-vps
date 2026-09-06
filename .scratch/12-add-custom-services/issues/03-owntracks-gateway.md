# Ticket #03: OwnTracks gateway route contribution

**Blocked by:** #00
**Blocks:** #05

## Description

Wire the OwnTracks gateway route contribution into the Caddyfile render. The Caddyfile template changes (port suffix, tls_mode conditional) are handled by ticket #00 — this ticket just adds OwnTracks on top.

1. **Create `roles/owntracks/defaults/main.yml`**:
   ```yaml
   owntracks_gateway_publish:
     - host: owntracks
       upstream: owntracks:8080
       mfa: false
       tls_mode: "auto"
       port: 8448
   ```

2. **Update `roles/gateway/tasks/main.yml`**:
   - Add `owntracks` to the `include_vars` loop alongside `silverbullet`, `authelia`, `hermes`, `conduit`
   - Loop loads `*_gateway_publish` from each role's defaults into `gateway_routes`

3. **Update `group_vars/all/gateway.yml`**:
   - Add `owntracks_gateway_publish` to the `gateway_routes` concatenation:
     ```yaml
     gateway_routes: "{{ silverbullet_gateway_publish + hermes_gateway_publish + authelia_gateway_publish + conduit_gateway_publish + owntracks_gateway_publish }}"
     ```

## Acceptance criteria

- `roles/owntracks/defaults/main.yml` exports `owntracks_gateway_publish` with required fields
- Gateway task loop loads `owntracks_gateway_publish` from defaults
- `group_vars/all/gateway.yml` includes `owntracks_gateway_publish` in the concatenation
- Caddyfile template renders `owntracks.{{ secrets.silverbullet_domain }}:8448` block
- Block contains `tls` directive (not `tls internal`) when `tls_mode == "auto"`
- Block has no `import mfa_auth` (since `mfa: false`)

## Notes

- **Caddyfile template changes** (port suffix, tls_mode conditional) are already done by ticket #00 — this ticket just adds OwnTracks on top.
- **Sequential change**: this ticket adds `owntracks` to the include_vars loop AFTER #00 adds `conduit`. Do not work on both simultaneously.
- Port 8448 shared between `matrix.*` and `owntracks.*` via Caddy SNI-based routing.
- `mfa: false` means no `import mfa_auth` in the rendered block — mobile apps can't handle forward-auth.