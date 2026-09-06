# Ticket #05: OwnTracks secrets and UFW rules

**Blocked by:** #01–#03
**Blocks:** #05

## Description

Add OwnTracks secrets to the manifest and UFW rules for public HTTPS access.

1. **Secrets manifest** (`group_vars/all/secrets.yml`):
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

2. **UFW rule**: in `roles/tailscale/tasks/main.yml`, add rate-limiting for port 8448 (Caddy's public HTTPS port that now serves owntracks):
   - Add `8448` to the existing `limit` loop alongside 80 and 443
   - This ensures Caddy's HTTPS endpoint for owntracks is rate-limited (and Tailscale-only for Conduit)

## Acceptance criteria

- `secrets.yml` has `owntracks_admin_username`, `owntracks_admin_password`, `acme_email` entries
- UFW rate-limits ports 80, 443, **8448**
- `ansible-playbook --syntax-check` passes

## Notes

- OwnTracks is served via Caddy on port 8448 (same port as Matrix/Conduit). Caddy uses SNI-based routing to differentiate hostnames on the same port.
- The existing UFW loop `limit` for ports 80/443 needs 8448 added.
- `owntracks_admin_password` is plaintext — Ansible's `htpasswd` module hashes it for the htpasswd file.