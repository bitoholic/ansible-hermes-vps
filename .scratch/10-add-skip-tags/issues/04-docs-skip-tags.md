---
title: Document skip-tags usage in README
status: ready-for-agent
blocked_by: [01-tag-all-roles, 02-site-skip-validation]
depends_on: []
---

# #04 — Document skip-tags usage in README

Update `README.md` with clear documentation on how to use `--skip-tags` for selective deployments.
Include examples of common scenarios (fast config update, minimal API deploy, full deploy) and a
table of skippable vs. protected roles.

## What to build

- Add a new section in `README.md` (suggested location: after "Deployment" section, before "Known Limitations"):
  - **Title**: "Selective role skipping"
  - **Content**:
    - Brief explanation: "You can skip specific roles during deployment using Ansible's `--skip-tags` flag."
    - Protected roles table: `secrets`, `users`, `ssh_hardening`, `common` (cannot be skipped, explained why).
    - Skippable roles table: `tailscale`, `docker`, `conduit`, `hermes`, `authelia`, `gateway`, `silverbullet`, `backup`.
    - Example commands:
      - Fast path: `ansible-playbook -i inventory site.yml --skip-tags hermes,backup`
      - Minimal API: `ansible-playbook -i inventory site.yml --skip-tags tailscale,docker,authelia,gateway,silverbullet,backup`
      - Full deploy: `ansible-playbook -i inventory site.yml`
    - Note: "Use this to skip slow operations like Hermes skill installation when only updating config."

## Acceptance (Definition of Done)

- [ ] `README.md` has a "Selective role skipping" section.
- [ ] Section includes a table of protected vs. skippable roles.
- [ ] Section includes at least 3 example deployment commands.
- [ ] Section explains why certain roles are protected (bootstrap, secrets, etc.).
- [ ] Section is linked from the main deployment instructions.