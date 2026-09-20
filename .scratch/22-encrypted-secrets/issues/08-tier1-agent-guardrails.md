# 08: Tier 1 agent guardrails and the honest-limit documentation

**What to build:** Project-scoped agent settings, committed with the repository, that let an agent run deployments through the wrapper's vetted shapes but keep it from reading the age key, the plaintext `.env`, and anything that decrypts the store or dumps the environment — using the agent sandbox's filesystem read denial for the key's location and not only command-pattern rules, which can be sidestepped — plus documentation that states plainly what this does and does not guarantee and describes the Tier 2 upgrade path.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] Committed, project-scoped agent settings allow only the wrapper's vetted invocation shapes (playbook mode and registered script mode) and the helper's non-decrypting subcommands, and deny direct decrypt commands and environment dumps
- [ ] The agent sandbox's filesystem read denial covers the operator's age key location and the plaintext `.env`, so the protection does not rest on command patterns alone
- [ ] **Bypass attempts are tested and recorded**, not just the direct actions: reading the key or `.env` through a different file reader, an interpreter one-liner and a hex dumper is refused; running the wrapper against the fixture is permitted
- [ ] The documentation states that these guardrails prevent accidents rather than a determined actor, because the key sits on the same machine, and specifically that an agent which edits a role or playbook and then deploys can make the decrypted environment do anything (for example print a re-encoded value) — which only Tier 2 addresses
- [ ] The Tier 2 upgrade path (a hardware-backed or passphrase-gated key requiring a touch or unlock per decrypt) is documented, and the wrapper's configurable key source is shown to support it without a rewrite
- [ ] The settings contain no secrets and no operator-specific paths beyond conventional key locations

## Notes

See epic 22 spec, "Implementation Decisions" (agent guardrails, Tier 1) and "Further Notes" (the honest limit). Command-pattern deny rules match by prefix, which is why they alone are not accepted.
