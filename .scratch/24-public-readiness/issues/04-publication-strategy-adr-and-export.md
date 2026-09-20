# 04: Publication strategy ADR and the export procedure

**What to build:** The way a public version of the repository would be published is decided, recorded and rehearsable: an ADR sets out the derived-export strategy (a separate public repository whose history is only export snapshots; this private repository stays the working repository and the permanent home of the encrypted secrets file) and why an in-place history rewrite was rejected; and a repeatable export procedure turns the scrubbed tree — minus the encrypted secrets file and the recipient configuration — into snapshots in that repository under a commit identity **the operator supplies**, without ever touching this repository's history, visibility or store. The author name is the operator's to give; this ticket builds the mechanism that requires it and does not pick it.

**Blocked by:** #02
**Blocks:** #05

**Status:** ready-for-agent

- [ ] A new ADR (ADR-0009) records the strategy — a separate public repository as a derived export whose history consists only of export snapshots — and the rejected alternatives (an in-place history rewrite and force-push; flipping this repository's visibility as it stands; moving development to the public repository)
- [ ] **The ADR records the operator's decision that the encrypted secrets file and the recipient configuration stay in this private repository, during and after migration and publication, and are never part of the public export**, with the reasoning (publishing ciphertext of every credential and identifying value would be permanent, and a future recipient-key leak would expose them all)
- [ ] **The commit identity is an operator input, not decided here:** the ADR explains that every existing commit already uses a GitHub no-reply address (so that alone changes nothing) and that the operator's real full name is the author name on the large majority of existing commits, and leaves the chosen author name and email as a field the operator fills in (recorded in #05); the export procedure takes the identity as a required parameter and **refuses to run without it**, shown by a negative test
- [ ] The ADR's threat-model note covers: what a clean public repository still reveals (composition, versions, architecture); that the no-reply address embeds the account handle, which matches a label of the operator's domain; that certificate-transparency logs and DNS expose hostnames regardless of the repository; and what stays exposed in the *private* repository (ciphertext and recipient public keys), so its account security and access grants still matter
- [ ] The export procedure creates or extends the public repository with a snapshot of the scrubbed tree under the supplied identity, excluding the encrypted secrets file, the recipient configuration and any other secrets-tooling state by an explicit list, and is deterministic and re-runnable into a scratch destination
- [ ] The procedure never modifies this repository's history, refs, visibility or store
- [ ] **The standard lint run passes in a fresh clone of the export** (which has no encrypted store and no recipient configuration), because the structural guard's mandatory state is derived from the recipient configuration's presence (epic 22 #03)
- [ ] The documentation states that development, tickets and the encrypted store stay in this private repository and the public repository is export-only, and what (an optional extra remote for publishing) workstations need
- [ ] A fixture test shows the export produces a repository whose history contains only the intended snapshots and the supplied identity, with the encrypted secrets file and the recipient configuration absent

## Notes

See epic 24 spec, "Implementation Decisions" (publication strategy; the encrypted store never goes public; export exclusions; threat-model note). The operator decided to keep the store in this private repository after reviewing the earlier include-or-exclude question.
