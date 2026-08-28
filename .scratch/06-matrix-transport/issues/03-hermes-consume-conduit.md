---
title: Hermes consumes conduit (MATRIX_* env)
status: ready-for-agent
blocked_by: [01-scaffold-conduit-role]
depends_on: [conduit, wiki_volume]
---

# #03 — `hermes` consumes `conduit` (MATRIX_* env)

`hermes` depends on `conduit` and gains `MATRIX_*` environment wired like the existing `SIGNAL_*`
block (default profile only). No new transport abstraction — a parallel copy of the Signal pattern.

## What to build

- `roles/hermes/meta/main.yml`: add `dependencies: [conduit]` (alongside existing `wiki_volume`).
- `roles/hermes/templates/env_default.j2`: add `MATRIX_HOMESERVER` (Conduit container URL),
  `MATRIX_USER_ID`, `MATRIX_PASSWORD`, `MATRIX_ALLOWED_USERS`, `MATRIX_ALLOWED_ROOMS`, and E2EE on.
  Default profile only, mirroring Signal.
- Add `secrets.matrix_bot_password` (already provisioned by #02), `secrets.matrix_allowed_users`,
  `secrets.matrix_allowed_rooms` to the secret manifest / `group_vars/all/secrets.yml` (epic-01
  single-seam contract: read from env).

## Acceptance (Definition of Done)

- [ ] `hermes` `env_default.j2` renders with the `MATRIX_*` vars; the agent starts and connects to Conduit.
- [ ] Matrix is wired to the default profile only (matches Signal scope).
- [ ] `ansible-playbook --check --diff` asserts the new `secrets.*` are defined before applying.
