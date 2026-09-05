# 08: Update documentation and triage labels for new docker role

**What to build:** Reflect the consolidated Docker role in project documentation and
adjust triage/issue tracking conventions to represent the new single source of truth.

- Update `.scratch/11-docker-consolidation/spec.md` with any implementation notes
  learned during the ticket execution.
- Add `docker` to the list of roles in the project README under "Architecture Overview".
- Ensure the triage label `ready-for-agent` can be applied to tickets in this epic.

End-to-end behavior delivered:
- Documentation matches the current state of the VPS.
- New contributors can discover the consolidated Compose project via the README.
- The issue tracker under `.scratch/11-docker-consolidation/issues/` is ready for agent pickup.

**Blocked by:** 07 (final cutover to consolidated compose).

**Status:** ready-for-agent

- [ ] `docs/architecture.md` updated with consolidated docker role diagram (or sentence).
- [ ] README.md mentions the single Compose project at `/opt/hermes-vps`.
- [ ] All tickets in `.scratch/11-docker-consolidation/issues/` have `ready-for-agent` label.