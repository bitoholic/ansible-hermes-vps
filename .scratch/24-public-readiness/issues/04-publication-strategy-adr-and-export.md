# 04: Publication strategy ADR and the export procedure

**What to build:** The way the repository would be published is decided, recorded and rehearsable: an ADR sets out the new-repository-with-fresh-history strategy, why an in-place history rewrite was rejected, whether the encrypted secrets file goes into the public export at all, and which commit identity (author name as well as email) the new repository uses; and a repeatable export procedure turns the scrubbed tree into a new repository whose history holds only the intended commits under that identity — without ever touching the current repository's history or visibility.

**Blocked by:** #02
**Blocks:** #05

**Status:** ready-for-agent

- [ ] A new ADR (ADR-0009) records the strategy — a new public repository with fresh history, the current private repository kept untouched as the archive — and the rejected alternatives (an in-place history rewrite and force-push; flipping this repository's visibility as it stands)
- [ ] **The ADR makes an explicit include-or-exclude decision on the encrypted secrets file:** (a) include it, accepting that ciphertext of every credential and identifying value becomes permanent and public, or (b) exclude it from the export and keep it in a private location while the public repository ships a names-only template; the trade-offs are weighed and the operator's decision is recorded (recommendation: (b) if the repository is made public)
- [ ] **The commit identity is decided and recorded:** every existing commit already uses a GitHub no-reply address, so that alone changes nothing — the ADR chooses an **author name** as well as an email for the new repository, since the operator's real full name is the author name on the large majority of existing commits
- [ ] The ADR's threat-model note covers: what a clean public repository still reveals (composition, versions, architecture; ciphertext and recipient public keys if included); that the no-reply address embeds the account handle, which matches a label of the operator's domain; and that certificate-transparency logs and DNS expose hostnames regardless of the repository
- [ ] The export procedure creates a fresh-history repository from the scrubbed tree under the chosen identity, honoring the include-or-exclude decision, and is deterministic and re-runnable into a scratch destination
- [ ] The procedure never modifies the current repository's history, refs or visibility
- [ ] Where development continues after publication, and what workstations and agent tooling must be repointed, is documented — including where the encrypted store lives under option (b)
- [ ] A fixture test shows the export produces a repository whose history contains only the intended commits, the chosen identity, and (per the decision) the store present or absent

## Notes

See epic 24 spec, "Implementation Decisions" (publication strategy; ciphertext in the public repository; threat-model note). This is the epic's biggest decision; the operator confirms it in review of the ADR.
