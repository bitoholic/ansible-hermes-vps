# Ticket #02: OwnTracks basic auth file generation

**Blocked by:** #01
**Blocks:** #05

## Description

Generate the basic auth htpasswd file for the OwnTracks recorder before the container starts.

1. **Ansible task** in `roles/owntracks/tasks/main.yml` (or inline in `roles/docker/tasks/main.yml`):
   - Use `community.general.htpasswd` module or `copy` + shell command
   - Generate `/opt/hermes-vps/owntracks/htpasswd` containing `admin:<bcrypt_hash>`
   - Input: `secrets.owntracks_admin_username` and `secrets.owntracks_admin_password` (plaintext)
   - The `htpasswd` module hashes the plaintext password with bcrypt

2. **Data directory**: create `/opt/hermes-vps/owntracks/` with `owner: llm_wiki`, `mode: 0755`

3. **File permissions**: htpasswd file readable by container (`mode: 0644`)

## Acceptance criteria

- htpasswd file exists at `/opt/hermes-vps/owntracks/htpasswd`
- File contains `admin:<bcrypt_hash>` entry
- File is readable by container (`0644`)
- Data directory exists with correct ownership

## Notes

- `owntracks_admin_password` is a plaintext password stored in `secrets.yml` manifest.
- The `community.general.htpasswd` module requires `passlib[bcrypt]` Python library.
- Alternative: pre-generate bcrypt hash externally and use `copy` task to write it to the file.
- The htpasswd file is mounted into the container at `/store/htpasswd` (see ticket #01).