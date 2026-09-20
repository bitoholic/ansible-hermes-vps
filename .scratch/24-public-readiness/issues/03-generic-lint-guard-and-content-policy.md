# 03: Generic lint guard and content policy

**What to build:** The tree stays clean after this epic without needing anyone's key: a guard in the standard lint run catches tailnet host addresses and credential shapes — while deliberately leaving the range's own CIDR notation, a functional value used in variables and documents, alone — and a one-page content policy (placeholders only in committed prose) is linked from the repository's agent-facing documentation so agents follow it too.

**Blocked by:** #02
**Blocks:** #05

**Status:** ready-for-agent

- [ ] The standard lint run fails on a tailnet-range **host** address or a credential-shaped string in a tracked file, needing no key, with a negative case that proves it fires
- [ ] A negative case proves the guard does **not** flag the tailnet range's own CIDR notation in the shared variable or in the documents that describe it
- [ ] A one-page content policy states that committed prose uses placeholders only, and is linked from the agent-facing repository documentation
- [ ] An optional pre-commit hook that runs the guard is documented
- [ ] The guard passes on the scrubbed tree

## Notes

See epic 24 spec, "Implementation Decisions" (generic rules; content policy). Prior art: the placeholder guard in the standard lint run.
