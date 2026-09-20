# 10: Runbooks, README rewrite, standards update and ADR

**What to build:** The documentation matches reality, including the repository's own agent-facing standards: the README's secrets workflow is rewritten around the wrapper and the encrypted store, the two instruction files that currently tell agents to use Ansible Vault or an external manager and that the repository must hold no secrets are updated to describe the new model, the runbooks cover the situations the operator will actually meet, and an ADR records the choice and explicitly names the deviation from the written standards.

**Blocked by:** #09
**Blocks:** None

**Status:** ready-for-agent

- [ ] The README's local-secrets workflow is rewritten around the wrapper, the helper and the encrypted store
- [ ] **Both repository standards files are updated:** the general instruction stating the repository must not contain secrets now says *plaintext* secrets must never be committed and encrypted secrets live in the store; the Ansible instruction file's secret-management section describes the SOPS + age model instead of mandating Ansible Vault or an external manager
- [ ] Runbooks cover: onboarding a workstation (with per-OS tool installation), retiring a workstation, responding to a suspected key leak (remove the recipient, rotate the data key, and rotate the underlying credentials), and using the break-glass key
- [ ] The documentation states that removing a recipient does not protect secrets already in git history, and the plaintext-removal limits from #09
- [ ] A short procedure explains how a later epic adds a secret (one manifest entry plus one value, and a declared extra only if it is not a manifest credential)
- [ ] A new ADR (ADR-0007) records the SOPS + age choice against git-crypt and ansible-vault, the public-repository considerations (a random age key, not a password; visible names are acceptable), Tier 1 and its honest limit, the redaction design and its limits, and **names the deviation from the repository's previously written standards and why**
- [ ] The documentation is consistent with the generated environment template and the sync check

## Notes

See epic 22 spec, "Implementation Decisions" (runbooks; ADR and repository standards). The two standards files are agent-facing, so leaving them unchanged would make every future agent session start from the wrong rule.
