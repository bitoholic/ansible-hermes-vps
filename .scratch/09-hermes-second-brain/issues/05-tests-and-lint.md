---
title: Update tests and confirm lint is green
status: done
blocked_by: []
depends_on:
  - 01-drop-profiles.md
  - 02-rewrite-soul.md
  - 03-delegation-config.md
  - 04-relocate-wiki.md
---

# #05 — Update tests and confirm lint is green

Removing `coder`/`intel` and relocating the wiki must not break the test harness.

## Changes

- `tests/test_playbook.yml:13,22` — the playbook test overrides `hermes_profiles` and
  `silverbullet_data_dir` (`/opt/llm-wiki`). Update the override to `default` only and
  `silverbullet_data_dir: /opt/wiki` so it no longer references removed profile templates.
- `tests/test_hermes_profile.yml` and `tests/test_config_render.yml` loop over `hermes_profiles`;
  confirm they still pass with a single `default` entry (the `length == hermes_profiles|length * 3`
  assertion remains valid).
- Run `tests/lint.sh` and confirm it exits 0.

## Acceptance

- [ ] `test_playbook.yml` no longer references `coder`/`intel` or the old wiki path.
- [ ] `tests/lint.sh` exits 0.
