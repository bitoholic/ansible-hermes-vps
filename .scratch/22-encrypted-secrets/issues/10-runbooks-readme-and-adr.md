# 10: Runbooks, README rewrite and ADR

**What to build:** The documentation matches reality: the README's secrets workflow is rewritten around the wrapper and the encrypted store, the runbooks cover the situations the operator will actually meet, and an ADR records the choice and its reasoning.

**Blocked by:** #09
**Blocks:** None

**Status:** ready-for-agent

- [ ] The README's local-secrets workflow is rewritten around the wrapper, the helper and the encrypted store
- [ ] Runbooks cover: onboarding a workstation (with per-OS tool installation), retiring a workstation, responding to a suspected key leak (remove the recipient, rotate the data key, and rotate the underlying credentials), and using the break-glass key
- [ ] The documentation states that removing a recipient does not protect secrets already in git history
- [ ] A short procedure explains how a later epic adds a secret (one manifest entry plus one value)
- [ ] A new ADR (next available number) records the SOPS + age choice against git-crypt and ansible-vault, the public-repository considerations (a random age key, not a password; visible names are acceptable), Tier 1 and its honest limit, and the redaction design and its limits
- [ ] The documentation is consistent with the generated environment template and the sync check

## Notes

See epic 22 spec, "Implementation Decisions" (runbooks; ADR).
