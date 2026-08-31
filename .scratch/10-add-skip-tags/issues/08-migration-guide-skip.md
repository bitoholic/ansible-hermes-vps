---
title: Migration guide for skip-tags adoption
status: ready-for-agent
blocked_by: [04-docs-skip-tags]
depends_on: []
---

# #08 — Migration guide for skip-tags adoption

Write a migration guide for existing operators to adopt the new skip-tags mechanism.
This document explains how to update existing workflows and take advantage of selective
deployments without breaking current deployments.

## What to build

- Create `docs/skip-tags-migration-guide.md` containing:
  - Introduction explaining the new capability and backward compatibility guarantee.
  - Quick start: how to use `--skip-tags` for common workflows.
  - Migration steps for existing automation/scripts that run `ansible-playbook site.yml`.
  - Recommended patterns for CI/CD pipelines (fast test path, full deploy path).
  - Common pitfalls and how to avoid them (protecting critical roles).
  - Troubleshooting section for common errors.
  - FAQ: why are certain roles protected? What if I need to skip a protected role?
  - Versioning note: explain that this is additive and backward compatible.

## Acceptance (Definition of Done)

- [ ] `docs/skip-tags-migration-guide.md` exists and is populated.
- [ ] Quick start section includes at least 3 common workflow examples.
- [ ] CI/CD section explains how to modify existing pipeline scripts.
- [ ] FAQ answers "why are these roles protected?" and "what if I need to skip a protected role?".
- [ ] Document includes a note about backward compatibility with existing deployments.
- [ ] Link to the migration guide from `README.md`.
- [ ] Troubleshooting section covers common error messages from the validation logic.