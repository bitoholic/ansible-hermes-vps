---
title: Remove copy-vendored-skills method and vendored skill files
status: ready-for-human
blocked_by: []
depends_on: []
---

# #02 — Remove copy-vendored-skills method and vendored skill files

Drop the old mechanism now replaced by CLI installs.

## What to build

- Remove the `Deploy Hermes profile skill files` task from `roles/hermes/tasks/main.yml`.
- Remove `skills_src: profiles/coder/skills/` from the `coder` profile in `group_vars/all/main.yml`
  and update the surrounding comment.
- Delete `roles/hermes/files/profiles/*/skills/` (coder/intel/wiki vendored skills).

## Acceptance

- [x] No `skills_src` references remain in the role/templates/tests.
- [x] Vendored skill directories removed.
