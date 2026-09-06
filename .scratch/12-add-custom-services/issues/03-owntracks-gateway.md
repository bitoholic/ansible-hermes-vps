# Ticket #03: OwnTracks gateway route contribution

**Blocked by:** #01
**Blocks:** #05

## Description

Wire the OwnTracks gateway route contribution into the Caddyfile render.

1. **Create `roles/owntracks/defaults/main.yml`**:
   ```yaml
   owntracks_gateway_publish:
     - host: owntracks
       upstream: owntracks:8080
       mfa: false
       tls_mode: "auto"
   ```

2. **Gateway task loop** in `roles/gateway/tasks/main.yml`:
   - Add `owntracks` to the `include_vars` loop alongside `silverbullet`, `authelia`, `hermes`
   - The gateway aggregates all `*_gateway_publish` contributions into `gateway_routes`

3. **Gateway route validation** in `roles/gateway/tasks/validate.yml`:
   - Add `tls_mode` field validation: optional, must be `"internal"` or `"auto"` if present
   - Default is `"internal"` when `tls_mode` is not specified

4. **Caddyfile template extension** in `roles/gateway/templates/Caddyfile.j2`:
   - Existing template uses `tls internal` for all routes
   - Add conditional: `{{ '  tls\n' if route.tls_mode == "auto" else '  tls internal\n' }}`
   - When `tls_mode == "auto"`, Caddy will attempt ACME for the hostname
   - When `tls_mode == "internal"` (or missing), render `tls internal` (self-signed)

## Acceptance criteria

- `roles/owntracks/defaults/main.yml` exports `owntracks_gateway_publish` with required fields
- Gateway task loop loads `owntracks_gateway_publish` from defaults
- `gateway_routes` shape validation accepts `tls_mode` field
- Caddyfile template renders `owntracks.{{ secrets.silverbullet_domain }}` block
- Block contains `tls` directive when `tls_mode == "auto"` (no `import mfa_auth`)
- `gateway_routes` validation fails fast on malformed entries

## Notes

- The existing Caddyfile has `{{ secrets.silverbullet_domain }}:8448` for Matrix/Conduit and route blocks for wiki/dash/auth on port 80.
- Adding `owntracks.{{ secrets.silverbullet_domain }}` to the route loop renders it on port 80 by default.
- For port 8448 sharing with Caddy, Caddy uses SNI-based routing (same port, different hostnames). The route block can be on port 8448 via a separate entry or the `tls_mode: "auto"` path handles this automatically.
- `mfa: false` means no `import mfa_auth` in the rendered block — mobile apps can't handle forward-auth.