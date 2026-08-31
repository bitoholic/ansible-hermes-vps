---
title: Add lint tests for skip-tags
status: ready-for-agent
blocked_by: [01-tag-all-roles]
depends_on: []
---

# #03 — Add lint tests for skip-tags

Add lint validation to `tests/lint.sh` that verifies all roles have tags and the protected role
list is correct. This ensures tags are never accidentally removed and the validation logic stays in sync.

## What to build

- Add lint checks to `tests/lint.sh`:
  - For each role in `roles/` (excluding templates/helpers), assert `tags: <role>` appears in `roles/<role>/tasks/main.yml`.
  - Assert that `site.yml` contains the protected roles list: `["secrets", "users", "ssh_hardening", "common"]`.
- Use `grep -qE` patterns consistent with the existing `check-*.sh` guard scripts in `tests/`.
- Follow the existing pattern: `echo "FAIL: ..."` and `exit 1` on violation.
- Name the new guard section clearly: `## Role skip-tags guard`.

## Acceptance (Definition of Done)

- [ ] `tests/lint.sh` has a guard that asserts all roles have `tags: <role-name>`.
- [ ] `tests/lint.sh` has a guard that asserts protected roles list is present in `site.yml`.
- [ ] Running `bash tests/lint.sh` passes with all guards green.
- [ ] Removing a tag from any role causes `bash tests/lint.sh` to fail with a clear message.