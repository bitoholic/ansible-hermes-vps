---
title: Ensure skip-tags validation is idempotent
status: ready-for-agent
blocked_by: [01-tag-all-roles, 02-site-skip-validation]
depends_on: []
---

# #05 — Ensure skip-tags validation is idempotent

Verify that running `site.yml` multiple times with `--skip-tags` produces consistent results.
The protected-role validation should behave identically across repeated runs and must not
leave any state changes or partial side effects.

## What to build

- Test that the pre-flight assert in `site.yml` is purely declarative (no tasks that
  create files or make system changes before the assert runs).
- Verify that skipping protected roles fails on both first and second run (consistent behavior).
- Verify that skipping skippable roles produces `changed=0` on a subsequent run when the
  skipped roles are already deployed (idempotent).

## Acceptance (Definition of Done)

- [ ] Pre-flight assert runs before any state-changing tasks.
- [ ] `ansible-playbook site.yml --skip-tags secrets` fails identically on repeated runs.
- [ ] `ansible-playbook site.yml --skip-tags tailscale` shows `changed=0` on second run when tailscale is already deployed.
- [ ] No temporary files, locks, or state changes are created by the validation logic.
- [ ] `ansible-playbook --check site.yml --skip-tags tailscale` passes without errors.