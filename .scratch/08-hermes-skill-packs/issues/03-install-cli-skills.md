---
title: Install skill packs via Hermes CLI (idempotent loop)
status: ready-for-human
blocked_by: []
depends_on: [02-remove-vendored-skills]
---

# #03 — Install skill packs via Hermes CLI (idempotent loop)

Replace the removed copy method with a declarative, upgradeable install.

## What to build

- `group_vars/all/hermes_skills.yml`: list of `{name, source}` for all 14 superpowers + 37
  mattpocock skills (51 total), derived from the actual GitHub trees.
- In `roles/hermes/tasks/main.yml`, after the container starts: pause for the gateway, then loop
  `docker exec hermes-agent hermes skills install {{ item.source }} --force`, guarded by an exact-match
  check against `hermes skills list` (awk first column + `grep -qx`). Restart `hermes-agent` only when
  something changed.

## Acceptance

- [x] `hermes_skills` installs only absent skills; re-run is a no-op.
- [x] Gateway restarted after installs so skills load.
