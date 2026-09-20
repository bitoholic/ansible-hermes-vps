# 05: Go-live checklist and dry run — ends at "ready to flip"

**What to build:** The rehearsal that makes publishing an informed, low-risk decision: the whole export is dry-run into a scratch private repository, the audit is run over its full history and over a fresh clone, the platform protections are turned on, and the operator is handed a checklist that ends with them flipping visibility by hand. This epic never publishes the repository itself.

**Blocked by:** #03, #04
**Blocks:** None

**Status:** ready-for-human

- [ ] The export is dry-run into a scratch private repository; the audit over its full history is green; a fresh clone in an empty directory is audited and is green
- [ ] The standard lint run passes in the fresh clone of the export
- [ ] The export is confirmed to contain **neither the encrypted secrets file nor the SOPS recipient configuration**, in the dry run and again on the fresh clone (the audit fails the export if either is present)
- [ ] Secret scanning and push protection are enabled on the target repository, and the licence file is verified as intended
- [ ] **The operator supplies the public repository's author name and email** (recorded in the ADR's identity field from #04), and the dry-run repository's commits are checked to carry exactly that identity and nothing from the existing history's author names
- [ ] The operator has read the threat-model note and decides whether to publish
- [ ] If the operator publishes, they flip visibility manually, and an unauthenticated fetch of the public repository is audited afterwards
- [ ] Results are recorded; if the operator does not publish, the epic ends at ready-to-flip

## Notes

Needs the operator: repository creation, their key for the audit, GitHub settings, the decision itself. See epic 24 spec, "Implementation Decisions" (go-live checklist).
