---
title: Provision @hermes bot account via Conduit registration secret
status: ready-for-agent
blocked_by: [01-scaffold-conduit-role]
depends_on: [conduit]
---

# #02 — Provision `@hermes` bot account via Conduit registration secret

A task in the `conduit` role ensures the Hermes bot account (`@hermes:<homeserver>`) exists, using
the registration shared secret + a password from `secrets`. Hermes then authenticates with
`MATRIX_USER_ID` + `MATRIX_PASSWORD` (no access-token file passed across roles).

## What to build

- Task in `roles/conduit/tasks/main.yml`: call Conduit's `/_matrix/client/v3/register` with the
  shared secret to create `@hermes:<homeserver>` with `secrets.matrix_bot_password`.
- Idempotent: skip (or no-op) if the user already exists.

## Acceptance (Definition of Done)

- [ ] `@hermes:<homeserver>` exists after the play; re-running does not create duplicates or fail.
- [ ] The bot password is sourced from `secrets` (never hard-coded).
- [ ] `ansible-playbook --check --diff` pre-flight asserts `secrets.conduit_registration_secret` and
      `secrets.matrix_bot_password` are defined (single-seam contract).
