# 04: Publication strategy ADR and the export procedure

**What to build:** The way the repository would be published is decided, recorded and rehearsable: an ADR sets out the new-repository-with-fresh-history strategy and why an in-place history rewrite was rejected, and a repeatable export procedure turns the scrubbed tree into a new repository whose history holds only the intended commits under a privacy-preserving identity — without ever touching the current repository's history or visibility.

**Blocked by:** #02
**Blocks:** #05

**Status:** ready-for-agent

- [ ] A new ADR (next available number) records the strategy — a new public repository with fresh history, the current private repository kept untouched as the archive — the rejected alternatives (an in-place history rewrite and force-push; flipping this repository's visibility as it stands), the threat-model note on what a clean public repository still reveals, and the go-live checklist
- [ ] The export procedure creates a fresh-history repository from the scrubbed tree, authored under a privacy-preserving identity, and is deterministic and re-runnable into a scratch destination
- [ ] The procedure never modifies the current repository's history, refs or visibility
- [ ] Where development continues after publication, and what workstations and agent tooling must be repointed, is documented
- [ ] A fixture test shows the export produces a repository whose history contains only the intended commits and identity

## Notes

See epic 24 spec, "Implementation Decisions" (publication strategy; dry run; threat-model note). This is the epic's biggest decision; the operator confirms it in review of the ADR.
