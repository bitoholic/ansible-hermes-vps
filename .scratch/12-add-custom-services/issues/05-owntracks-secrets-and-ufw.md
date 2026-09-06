# Ticket #05: OwnTracks secrets and UFW rules

**Blocked by:** #01–#04
**Blocks:** #06

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

2. **UFW rule**: in `roles/tailscale/tasks/main.yml`, add 8448 to the existing `limit` loop (ports 80, 443 → **80, 443, 8448**):
   ```yaml
   - name: Rate-limit SSH, HTTP, HTTPS, and OwnTracks HTTPS
     community.general.ufw:
       rule: limit
       port: "{{ item }}"
       proto: tcp
       comment: "Rate-limit web traffic"
     loop:
       - "{{ common_ssh_port }}"
       - 80
       - 443
       - 8448
   ```

## Acceptance criteria

- `secrets.yml` has `owntracks_admin_username`, `owntracks_admin_password`, `acme_email` entries
- UFW rate-limits ports 80, 443, **8448**
- `ansible-playbook --syntax-check` passes

## Notes

- OwnTracks is served via Caddy on port 8448 (same port as Matrix/Conduit). Caddy uses SNI-based routing to differentiate hostnames.
- The existing UFW loop for rate-limiting ports 80/443 gets 8448 added.
- `owntracks_admin_password` is plaintext — Ansible's `community.general.htpasswd` module hashes it for the htpasswd file.
- `acme_email` is optional with a sensible default for Caddy ACME certificate issuance.