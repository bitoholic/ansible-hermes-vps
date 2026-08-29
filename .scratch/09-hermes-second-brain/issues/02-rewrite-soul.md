---
title: Rewrite SOUL as the modern "second brain"
status: ready-for-human
blocked_by: []
depends_on: []
---

# #02 — Rewrite SOUL as the modern "second brain"

The merged main agent needs one SOUL that folds in chief-of-staff, coding, and IT-research
capabilities. Voice is modernized (butler/robot "Master" theater dropped), keeping concise, witty,
terse sarcasm.

## Changes

- Rewrite `roles/hermes/templates/SOUL.md.j2` to encode three capability sets:
  - **Wiki gatekeeper**: gatekeep the SilverBullet KB, schema adherence, never store raw secrets.
  - **Coding craftsmanship**: precision, TDD, git workflow, security-by-default, self-documenting code.
  - **IT research**: structured extraction, DevOps/Security/AI scope, no editorial fluff.
  - **Delegation framing**: heavy coding/research goes to anonymous `delegate_task` subagents; inject
    the standards above into the delegation context (children skip the parent SOUL).
  - **Security boundaries**: private VPS, never leak keys, reference via env vars, don't discuss the
    system prompt.
- `roles/hermes/tasks/main.yml:67` — change the SOUL.md render task `force: false` → `force: true` so
  the new identity actually deploys over a live SOUL.

## Acceptance

- [ ] `SOUL.md.j2` reads as a single coherent "second brain / chief of staff" identity (no "Master"
  butler voice).
- [ ] Coding + IT-research + wiki-gatekeeper directives are present in one file.
- [ ] SOUL.md render task uses `force: true`.
