---
title: Runtime check script + profile-test cleanup
status: ready-for-human
blocked_by: []
depends_on: [03-install-cli-skills]
---

# #04 — Runtime check script + profile-test cleanup

Make the installed skill set verifiable in CI/operator runs.

## What to build

- `tests/check-hermes-skills.sh`: asserts every `hermes_skills` entry is registered in the running
  `hermes-agent` (skips automatically when the container is absent). Wire into `tests/lint.sh`.
- `tests/test_hermes_profile.yml`: remove the skills-copy task and the skills stat/assert block (the
  render loop no longer vendors skills).

## Acceptance

- [x] Check script passes against a populated `hermes-agent` and skips in CI.
- [x] Profile render test still passes (config/SOUL/.env only).
