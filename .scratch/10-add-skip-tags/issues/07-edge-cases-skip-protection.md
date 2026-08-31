---
title: Edge cases for skip-tags protection
status: ready-for-agent
blocked_by: [01-tag-all-roles, 02-site-skip-validation]
depends_on: []
---

# #07 — Edge cases for skip-tags protection

Test edge cases in the skip-tags system: role dependencies, partial skips, and
ambiguous skip combinations. Ensure the system is robust against common operator
mistakes.

## What to build

- Document and test the following edge cases:
  - **Role dependencies**: `docker` is a prerequisite for `conduit`. If operator skips
    `conduit` but `docker` is not deployed yet, what happens? (Expected: docker still runs
    because it's not skipped; conduit skips cleanly.)
  - **Partial skips with wildcards**: `--skip-tags "hermes,*"`. Does the wildcard skip all roles?
    (Expected: Ansible's `--skip-tags` is exact-match only; wildcards don't work. Document this.)
  - **Empty skip list**: `--skip-tags ""` or no `--skip-tags` flag. (Expected: behaves like no skip, all roles run.)
  - **Protected role in skip list with other valid skips**: `--skip-tags tailscale,secrets`.
    (Expected: fails immediately due to protected role.)
  - **Case sensitivity**: `--skip-tags Tailscale` vs `--skip-tags tailscale`. (Expected: case-sensitive match; only lowercase `tailscale` is skipped.)
  - **Special characters in tag values**: tags with spaces, hyphens, or special chars. (Expected: validated as exact strings; no special parsing.)

## Acceptance (Definition of Done)

- [ ] Edge cases are documented in `README.md` or a new `docs/skip-tags-edge-cases.md`.
- [ ] Integration tests cover at least 4 of the edge cases listed above.
- [ ] Tests verify role dependencies still run when their dependents are skipped.
- [ ] Tests verify protected role in a mixed skip list causes failure.
- [ ] Tests verify case-sensitivity of skip-tags matching.