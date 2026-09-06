# Ticket #00: Move Conduit from hardcoded Caddyfile block to gateway loop

**Blocked by:** none
**Blocks:** #01–#07

## Description

The current `roles/gateway/templates/Caddyfile.j2` has Conduit hardcoded as a separate block outside the `gateway_routes` loop:
```jinja2
{{ secrets.silverbullet_domain }}:8448 {  # BUG: missing "matrix." prefix
  tls internal
  reverse_proxy http://conduit:{{ conduit_port }}
}
```

This needs to be fixed before adding new services to the same loop.

1. **Create `roles/conduit/defaults/main.yml`** (or add to existing):
   ```yaml
   conduit_gateway_publish:
     - host: matrix
       upstream: conduit:{{ conduit_port }}
       mfa: false
       tls_mode: "internal"
       port: 8448
   ```

2. **Update `roles/gateway/tasks/main.yml`**:
   - Add `conduit` to the `include_vars` loop (currently: silverbullet, authelia, hermes)
   - Remove the hardcoded Matrix block from `Caddyfile.j2`

3. **Update `roles/gateway/templates/Caddyfile.j2`**:
   - Add `port` field support: `{{ route.host }}.{{ secrets.silverbullet_domain }}{% if route.port %}:{{ route.port }}{% endif %}`
   - Add `tls_mode` conditional: `tls` for `"auto"`, `tls internal` for `"internal"` (default)
   - Remove the hardcoded `{{ secrets.silverbullet_domain }}:8448` block entirely

4. **Add `tls_mode` validation** to `roles/gateway/tasks/validate.yml`:
   - Optional field, must be `"internal"` or `"auto"` if present
   - Default: `"internal"`

5. **Update `group_vars/all/gateway.yml`**:
   - Add `conduit_gateway_publish` to the `gateway_routes` concatenation:
     ```yaml
     gateway_routes: "{{ silverbullet_gateway_publish + hermes_gateway_publish + authelia_gateway_publish + conduit_gateway_publish }}"
     ```

## Acceptance criteria

- `matrix.{{ secrets.silverbullet_domain }}:8448` renders correctly in Caddyfile (not bare domain)
- Conduit route appears in `gateway_routes` loop output
- Caddyfile has no hardcoded Matrix block
- `tls_mode` validation accepts `"auto"` and `"internal"`, fails on other values
- `group_vars/all/gateway.yml` includes `conduit_gateway_publish` in the concatenation
- `ansible-playbook --syntax-check` passes

## Notes

- This is a prerequisite for OwnTracks (which also needs port 8448 with `tls_mode: "auto"`)
- Fixes an existing bug: the hardcoded block uses the bare domain without `matrix.` prefix
- Port sharing via SNI: Caddy handles multiple hostnames on port 8448 by Host header
- **Sequential change**: ticket #00 adds `conduit` to the `include_vars` loop; ticket #03 adds `owntracks` later. These are sequential, not parallel — do not work on both simultaneously.
- **Caddyfile template change is scoped to ticket #00**, NOT ticket #03. Ticket #03 just adds OwnTracks on top of the template changes made here.
- **Test file updates**: `tests/test_gateway_render.yml` must also include `conduit_gateway_publish` in its concatenation (see ticket #07).