---
title: Site-level skip-tags validation
status: ready-for-agent
blocked_by: [01-tag-all-roles]
depends_on: []
---

# #02 — Site-level skip-tags validation

Add pre-flight validation in `site.yml` that prevents skipping protected roles (`secrets`,
`users`, `ssh_hardening`, `common`) via `--skip-tags`. The pre-flight should parse the skip-tags
argument, check for protected role attempts, and fail with a clear error message.

## What to build

- Add a pre-flight `assert` task at the top of Play 1 in `site.yml` that:
  - Reads `ansible_skip_tags` (Ansible's internal variable populated from `--skip-tags`)
  - Defines a protected roles list: `["secrets", "users", "ssh_hardening", "common"]`
  - Asserts that no protected role is in `ansible_skip_tags`
  - Fails with a clear error message listing the protected roles if validation fails
- The error message should explain: "Cannot skip protected role(s) {roles}. These are mandatory for system bootstrap and safety."
- Apply the assertion to both Play 1 and Play 2 (use a pre-task or include role to make it DRY).

## Acceptance (Definition of Done)

- [ ] `site.yml` has a pre-flight assert that prevents skipping `secrets`, `users`, `ssh_hardening`, `common`.
- [ ] `ansible-playbook site.yml --skip-tags secrets` fails immediately with clear error.
- [ ] `ansible-playbook site.yml --skip-tags users` fails immediately with clear error.
- [ ] `ansible-playbook site.yml --skip-tags tailscale,secrets` fails immediately (secrets is protected).
- [ ] `ansible-playbook site.yml --skip-tags tailscale` succeeds (tailscale is skippable).
- [ ] `ansible-playbook site.yml` (no skip) succeeds.
- [ ] Error message lists which protected role(s) cannot be skipped.