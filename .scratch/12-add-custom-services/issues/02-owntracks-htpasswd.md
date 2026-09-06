# Ticket #02: OwnTracks htpasswd generation

**Blocked by:** #00
**Blocks:** #05

## Description

Generate the basic auth htpasswd file for the OwnTracks recorder.

1. **Create `roles/owntracks/` role** with `tasks/main.yml`, `defaults/main.yml`, `templates/`:
   - `tasks/main.yml`: htpasswd generation task
   - `defaults/main.yml`: `owntracks_image`, `owntracks_htpasswd_path`, etc.
   - `templates/`: (none yet — fragment is in docker role)

2. **Ansible task** in `roles/owntracks/tasks/main.yml`:
   - Use `community.general.htpasswd` module
   - `path: "{{ owntracks_htpasswd_path }}"`
   - `name: "{{ secrets.owntracks_admin_username }}"`
   - `password: "{{ secrets.owntracks_admin_password }}"`
   - `hash: bcrypt`
   - Creates `/opt/hermes-vps/owntracks/htpasswd` on the host

3. **Data directory**: create `/opt/hermes-vps/owntracks/` with `owner: llm_wiki`, `mode: 0755`

4. **File permissions**: htpasswd file readable by container (`mode: 0644`)

## Acceptance criteria

- htpasswd file exists at `/opt/hermes-vps/owntracks/htpasswd`
- File contains `admin:<bcrypt_hash>` entry (plaintext password from secrets is hashed by the module)
- File is readable by container (`0644`)
- Data directory exists with correct ownership
- `community.general.htpasswd` module is used (requires `passlib[bcrypt]` on control node)

## Notes

- `owntracks_admin_password` is plaintext in secrets manifest. The `htpasswd` module hashes it.
- Requires `passlib[bcrypt]` Python library installed on control node.
- The htpasswd file is bind-mounted into the container at `/store/htpasswd` (see ticket #01).