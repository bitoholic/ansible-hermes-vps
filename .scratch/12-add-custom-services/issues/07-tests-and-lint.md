# Ticket #07: Tests and lint wiring

**Blocked by:** #05, #06
**Blocks:** none

## Description

Add tests for both OwnTracks and Syncplay services and wire them into the lint pipeline.

1. **Create `tests/check-custom-services.sh`**:
   - Verify rendered docker-compose.yml includes `owntracks` and `syncplay` services
   - Verify Caddyfile renders `owntracks.{{ secrets.silverbullet_domain }}:8448` block with `tls` directive (auto mode) and no `import mfa_auth`
   - Verify Caddyfile renders `matrix.{{ secrets.silverbullet_domain }}:8448` (not bare domain) — regression guard for the prefix bug
   - Verify UFW rules: 8448 rate-limit; 8999 allow-by-IP for syncplay_allowed_ips + rate-limit
   - Verify secrets manifest has both services' entries
   - Verify `syncplay_allowed_ips` is defined in `group_vars/all/main.yml`

2. **Wire into `tests/lint.sh`**: add `./tests/check-custom-services.sh` to the lint pipeline

3. **Gateway render test**: verify `gateway_routes` shape validation accepts `tls_mode` and `port` fields and fails fast on invalid values

4. **Docker compose render test**: verify `docker compose config` passes with both services enabled

## Acceptance criteria

- `tests/check-custom-services.sh` passes with both services configured
- `lint.sh` includes the new check and passes
- `tests/check-gateway-render.sh` verifies `tls_mode` and `port` fields in route schema
- Pre-flight asserts catch missing required secrets (`owntracks_admin_password`, `syncplay_password`)

## Notes

- Follow the exact same pattern as `tests/check-conduit.sh`, `tests/check-docker-compose-render.sh`, and `tests/check-gateway-render.sh`.
- Test the external behavior (rendered output), not Ansible internals.