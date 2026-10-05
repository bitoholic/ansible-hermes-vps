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

**2026-10-05 — export mechanism redesigned; dry run redone against the new mechanism.** The operator
rejected #04's original flattened-snapshot export after reviewing an earlier dry run (it collapsed the
entire repo's development history into one commit) and asked for a history-preserving rewrite instead
— see #04's "Redesign: history-preserving export" note and ADR-0009's revision note.
`scripts/export-public.py` and `scripts/history_scrub.py` were rebuilt accordingly, independently
reviewed (Standards + Spec-conformance), and all findings fixed (see #04's notes — a real tag-dropping
bug, a `main()`/duplication cleanup, one more self-matching leftover in these notes themselves).

**Every box above has now been re-run against the NEW mechanism and passes:** a real-repository dry
run into a scratch destination reports a clean audit (273 of 348 commits survive, the rest correctly
pruned as empty); the store and `.sops.yaml` are absent from the result; the real tag `v0.0.0-alpha1`
survives, pointing at its rewritten commit; every commit's identity is the single identity supplied
(`Jacek Jarosiewicz <173365972+bitoholic@users.noreply.github.com>`, per the operator's earlier
go-ahead — "use my identity for everything"), nothing from the original per-commit author names
survives; the full `tests/lint.sh` passes end to end in a fresh clone of that dry-run export. None of
this touched the real repository itself (only reads: `rev-parse`/`show-ref`/a read-only clone) or
anything outside a scratch destination under `$TMPDIR`.

**Still open, operator-only — nothing below this line should be done without the operator present:**
- GitHub secret-scanning/push-protection settings on the target repository (a `gh api -X PATCH
  .../security_and_analysis` call to enable them was denied by the permission classifier earlier in
  this epic — needs the operator directly, not a retry or a workaround).
- The licence file's "verified as intended" sign-off.
- Redoing the actual push to `bitoholic/ansible-hermes-vps`, which currently still holds the OLD
  single-snapshot push from before the redesign. This is a **history-replacing push** — the repository
  is still private and nothing has been fetched by anyone else, so it should be safe, but it replaces
  whatever is already there rather than extending it, and must be flagged as such before it happens,
  not just executed quietly.
- The operator re-confirming the threat model and identity choice still hold for the history-preserving
  result specifically (the earlier go-ahead — "read and accepted the threat model, so go ahead and
  migrate" — was given for the OLD snapshot design, before it was rejected).
- The actual visibility flip and the post-flip unauthenticated-fetch audit.
