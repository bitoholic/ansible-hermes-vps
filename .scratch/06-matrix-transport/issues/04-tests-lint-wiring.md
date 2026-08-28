---
title: Tests + lint wiring for matrix transport
status: ready-for-agent
blocked_by:
  - 01-scaffold-conduit-role
  - 02-provision-hermes-bot-account
  - 03-hermes-consume-conduit
depends_on: [conduit, hermes]
---

# #04 — Tests + lint wiring for matrix transport

CI-surfacesafe checks that the Conduit homeserver + bot provisioning behave and that Hermes is
wired, plus the pre-flight secret asserts. A live Element↔`@hermes` DM is operator-validated on the
VPS (needs Conduit + Tailscale, which CI lacks).

## What to build

- `tests/check-conduit.sh`: assert `conduit` container config renders with the shared secret; the
  `@hermes` registration is idempotent; no Matrix port is published; `hermes` `env_default.j2`
  contains the `MATRIX_*` vars and the gateway Caddyfile is unchanged by this epic.
- Pre-flight `assert` that `secrets.conduit_registration_secret`, `secrets.matrix_bot_password`,
  `secrets.matrix_allowed_users` are defined (mirror the epic-04/05 assert pattern).
- Wire `./tests/check-conduit.sh` into `tests/lint.sh`.

## Acceptance (Definition of Done)

- [ ] `tests/check-conduit.sh` exits non-zero on any contract violation.
- [ ] Invoked from `tests/lint.sh`; `bash tests/lint.sh` → exit 0.
- [ ] Live `ansible-playbook --check --diff` + Element↔`@hermes` DM operator-validated on VPS.
