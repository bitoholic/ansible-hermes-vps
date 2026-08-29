---
title: Drop coder/intel profiles, keep single default agent
status: ready-for-human
blocked_by: []
depends_on: []
---

# #01 — Drop coder/intel profiles, keep single default agent

The `coder` and `intel` Hermes profiles are dormant (no gateway, no bot token); only
`default` runs. Remove them so the repo deploys exactly one agent.

## Changes

- `group_vars/all/main.yml:56` — remove the `coder` and `intel` entries from `hermes_profiles`;
  keep only `default`. Update the comment block (lines 43–55) to describe a single agent.
- Delete `roles/hermes/templates/profiles/` (coder + intel `SOUL.md.j2`).
- Delete `roles/hermes/templates/env_profile.j2` (unreferenced once no non-default profile exists).
- `roles/hermes/tasks/main.yml:72` — change the env-template default from `env_profile.j2` to
  `env_default.j2` (the `default` entry already overrides it, so this just removes the dead branch).

## Acceptance

- [ ] `hermes_profiles` contains only `default`.
- [ ] `roles/hermes/templates/profiles/` and `env_profile.j2` no longer exist.
- [ ] `ansible-playbook --syntax-check` passes.
