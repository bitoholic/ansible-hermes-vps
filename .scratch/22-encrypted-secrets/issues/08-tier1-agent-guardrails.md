# 08: Tier 1 agent guardrails — with the wrapper explicitly exempted from the sandbox — and the honest-limit documentation

**What to build:** Project-scoped agent settings, committed with the repository, that keep an agent from reading the age key, the plaintext `.env`, and anything that decrypts the store or dumps the environment, **while still letting it run deployments** through the wrapper. Denying sandboxed processes read access to the key would also stop the wrapper when the agent runs it (and the sandbox may block the SSH connection to the VPS), so the wrapper is deliberately exempted from the sandbox, and the design states what protects it once exempt. Plus documentation stating plainly what this does and does not guarantee, and the Tier 2 upgrade path.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] The agent's mechanism for excluding a named command from its sandbox is identified from the **current** agent documentation, and its exact name and behavior are recorded in this ticket (the setting names may change, so this is verified, not assumed)
- [ ] The wrapper — and only the wrapper's vetted invocation shapes (playbook mode and registered script mode) — is exempted from the sandbox, so an agent-run wrapper can read the age key and open the SSH connection to the VPS; everything else stays sandboxed
- [ ] The sandbox's filesystem read denial covers the operator's age key location and the plaintext `.env` for everything that is not the exempted wrapper, so the protection does not rest on command patterns alone
- [ ] Permission rules allow only the wrapper's exact vetted shapes (and the helper's non-decrypting subcommands) and deny direct decrypt commands and environment dumps
- [ ] **What protects the exempt wrapper is documented as a list:** the exact-shape permission rules; the wrapper's own refusals (extra variables, ad-hoc modules, foreign playbooks); the pinned Ansible configuration and cleared environment (#01); output redaction (#02); and the fact that an agent editing the wrapper itself or a role and then running it is **not** protected against — the documented Tier 1 limit
- [ ] **An end-to-end check under the real sandbox is recorded:** an agent-run playbook check through the wrapper succeeds (decrypts the store, reaches the VPS over SSH), while the same agent's attempts to read the key or `.env` directly — through a different file reader, an interpreter one-liner and a hex dumper — are refused
- [ ] The documentation states that these guardrails prevent accidents rather than a determined actor, because the key sits on the same machine
- [ ] The Tier 2 upgrade path (a hardware-backed or passphrase-gated key requiring a touch or unlock per decrypt) is documented, and the wrapper's configurable key source is shown to support it without a rewrite
- [ ] The settings contain no secrets and no operator-specific paths beyond conventional key locations

## Notes

See epic 22 spec, "Implementation Decisions" (agent guardrails, Tier 1, including the sandbox conflict) and "Further Notes" (the honest limit). Without the explicit exemption, ticket #09's last acceptance criterion cannot pass.
