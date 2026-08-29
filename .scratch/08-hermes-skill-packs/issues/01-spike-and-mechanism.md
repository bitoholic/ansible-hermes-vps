---
title: Spike Hermes skill install mechanisms (v0.20.6)
status: ready-for-human
blocked_by: []
depends_on: []
---

# #01 — Spike Hermes skill install mechanisms (v0.20.6)

Validate how to install obra/superpowers, mattpocock/skills, and github/spec-kit into Hermes on the
VPS, then decide the rollout mechanism.

## Findings

- `hermes skills install <source> --force` is the reliable path (per-skill). superpowers via raw
  GitHub URL (`.../raw/main/skills/<name>/SKILL.md`, verdict SAFE); mattpocock via
  `skills-sh/mattpocock/skills/<cat>/<name>`.
- `hermes plugins install` is **blocked** by the 0.20.6 security scanner (dangerous verdict; `--force`
  does not override). Plugin path discarded.
- `specify init --integration hermes` generates `speckit-*` SKILL.md files but Hermes does not register
  them. Upgrading to 0.20.6 did not fix it. **spec-kit excluded.**
- Repo-level installs unsupported; enumerate per-skill from GitHub trees.

## Acceptance

- [x] Mechanism chosen and documented in `spec.md`.
- [x] VPS returned to clean baseline after spike.
