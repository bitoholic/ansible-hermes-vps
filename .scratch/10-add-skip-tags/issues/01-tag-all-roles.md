---
title: Tag all roles with their name
status: ready-for-agent
blocked_by: []
depends_on: []
---

# #01 — Tag all roles with their name

Add `tags: <role-name>` to each role's `tasks/main.yml` so they can be selectively skipped via
`ansible-playbook site.yml --skip-tags <role-name>`.

## What to build

- Add `tags: <role-name>` to the top of `roles/<role>/tasks/main.yml` for every role:
  - `roles/secrets/tasks/main.yml` → `tags: secrets`
  - `roles/users/tasks/main.yml` → `tags: users`
  - `roles/ssh_hardening/tasks/main.yml` → `tags: ssh_hardening`
  - `roles/common/tasks/main.yml` → `tags: common`
  - `roles/tailscale/tasks/main.yml` → `tags: tailscale`
  - `roles/docker/tasks/main.yml` → `tags: docker`
  - `roles/conduit/tasks/main.yml` → `tags: conduit`
  - `roles/hermes/tasks/main.yml` → `tags: hermes`
  - `roles/authelia/tasks/main.yml` → `tags: authelia`
  - `roles/gateway/tasks/main.yml` → `tags: gateway`
  - `roles/silverbullet/tasks/main.yml` → `tags: silverbullet`
  - `roles/backup/tasks/main.yml` → `tags: backup`
- Tags must be applied at the role level (top of `tasks/main.yml`), not at the task level.
- Tags must be valid YAML (single-quoted or double-quoted strings).

## Acceptance (Definition of Done)

- [ ] Every role's `tasks/main.yml` has `tags: <role-name>` at the top.
- [ ] `ansible-playbook --list-tags site.yml` lists all role tags.
- [ ] `ansible-playbook --check --diff site.yml --skip-tags tailscale` skips the tailscale role.
- [ ] `ansible-playbook --check --diff site.yml --skip-tags hermes` skips the hermes role.
- [ ] `ansible-playbook --check --diff site.yml --skip-tags backup` skips the backup role.