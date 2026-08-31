---
title: Integration test for skip scenarios
status: ready-for-agent
blocked_by: [01-tag-all-roles, 02-site-skip-validation]
depends_on: []
---

# #06 — Integration test for skip scenarios

Add an integration test that runs `site.yml` in `--check` mode with various `--skip-tags` combinations
and verifies the correct roles are skipped. This catches regressions in the tag wiring and validation logic.

## What to build

- Create `tests/test_skip_tags.yml` (or extend `tests/test_playbook.yml`) that:
  - Runs `ansible-playbook --check site.yml --skip-tags <combination>` for each test case.
  - Asserts the exit code is 0 for valid skip combinations.
  - Asserts the exit code is non-zero for protected-role skip attempts.
  - Uses `assert` tasks or a wrapper script to validate behavior.
- Test cases:
  - `--skip-tags hermes` → succeeds, hermes role is skipped.
  - `--skip-tags tailscale,backup` → succeeds, both roles skipped.
  - `--skip-tags secrets` → fails with clear error.
  - `--skip-tags users,ssh_hardening` → fails with clear error.
  - No skip (default) → succeeds, all roles run.

## Acceptance (Definition of Done)

- [ ] `tests/test_skip_tags.yml` (or equivalent) tests at least 5 skip scenarios.
- [ ] Test asserts protected-role skips fail with non-zero exit code.
- [ ] Test asserts skippable-role skips succeed with zero exit code.
- [ ] Test runs in CI without requiring a live VPS (uses `--check` mode).
- [ ] Test is integrated into `tests/lint.sh` or equivalent CI pipeline.