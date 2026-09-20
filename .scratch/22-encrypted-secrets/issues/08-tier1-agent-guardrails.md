# 08: Tier 1 agent guardrails and the honest-limit documentation

**What to build:** Project-scoped agent settings, committed with the repository, that let an agent run deployments through the wrapper but deny it reading the age key, the plaintext `.env`, and commands that decrypt the store or dump the environment; plus documentation that states plainly what this does and does not guarantee, and describes the Tier 2 upgrade path.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] Committed, project-scoped agent settings deny reading the operator's age key file and the plaintext `.env`, and deny direct decrypt commands and environment dumps, while allowing the deploy wrapper and the helper's non-decrypting subcommands
- [ ] The documentation states that these guardrails prevent accidents rather than a determined actor, because the key sits on the same machine
- [ ] The Tier 2 upgrade path (a hardware-backed or passphrase-gated key requiring a touch or unlock per decrypt) is documented, and the wrapper's configurable key source is shown to support it without a rewrite
- [ ] Verified and recorded: an agent session attempting each denied action is refused, and running the wrapper against the fixture is permitted
- [ ] The settings contain no secrets and no operator-specific paths beyond conventional key locations

## Notes

See epic 22 spec, "Implementation Decisions" (agent guardrails, Tier 1) and "Further Notes" (the honest limit).
