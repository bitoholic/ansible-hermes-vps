# 02: Scrub the working tree to placeholders

**What to build:** Nothing in the current tree identifies the operator or their infrastructure: documentation, specs, ADRs, tickets and test fixtures use fixed placeholders, the documents stay readable and keep their reasoning, and the audit's tree scan is clean.

**Blocked by:** #01, Epic 22 #06 (domain de-hardcoded from code), Epic 22 #09 (the real store exists to derive the denylist from)
**Blocks:** #03, #04

**Status:** ready-for-agent

- [ ] Identifying values in documentation, specs, ADRs, tickets and test fixtures are replaced with fixed placeholders for the domain, hostnames, addresses, tailnet addresses and personal names
- [ ] The documents remain readable and preserve their reasoning; live-verification notes in tickets are kept, with real addresses and hostnames replaced
- [ ] The obsolete ignore entry for the dead git-crypt key file is removed or generalized so its identifying name is not left in the tree
- [ ] The audit's tree scan, run through the wrapper against the real store, is clean, with no allowlist entry that lacks a written reason
- [ ] All existing tests pass with their fixtures updated
- [ ] The full-history scan is run and its counts reported in this ticket's notes for the record; history is left untouched (it stays dirty in the private archive by design)

## Notes

See epic 24 spec, "Implementation Decisions" (scrub the working tree). Documentation that has merely drifted from later decisions is out of scope here.
