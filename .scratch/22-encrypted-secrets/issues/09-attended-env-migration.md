# 09: Attended migration of `.env` into the encrypted store

**What to build:** The operator's real credentials move into the encrypted store, verified lossless, and every plaintext copy is removed as far as that can be guaranteed. After this, a deployment run through the wrapper — including one run by an agent — works with no secret ever appearing in a transcript.

**Blocked by:** #01, #02, #03, #04, #05, #08
**Blocks:** #10, Epic 24 #02

**Status:** ready-for-human

- [ ] The operator's workstation key and an offline break-glass key are generated (the break-glass private key stored offline, per the runbook), and both public keys are added as recipients
- [ ] The existing `.env` is imported; the digest-based round-trip verification passes; nothing is printed
- [ ] The structural guard (#03) is switched from tolerant to mandatory and passes
- [ ] A first real check-mode deployment through the wrapper succeeds on the operator's workstation, and the operator confirms no sensitive value appeared in its output
- [ ] Any other workstation is onboarded by generating its own key and having an existing workstation add its public key
- [ ] The plaintext `.env` is removed from every workstation, **with the limits stated**: overwriting tools are unreliable on SSDs and copy-on-write filesystems, and hand-synced copies may exist elsewhere (backups, sync tools, shell history, other machines) — the operator lists where copies may have gone and rotates any credential whose exposure can't be ruled out
- [ ] An agent-run deployment through the wrapper is confirmed to complete without any secret in the transcript

## Notes

Needs the operator: their keys, an offline place for the break-glass key, every workstation. See epic 22 spec, "Implementation Decisions" (migration).
