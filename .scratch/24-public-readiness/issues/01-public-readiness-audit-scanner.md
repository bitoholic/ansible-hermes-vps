# 01: Public-readiness audit scanner, proven by a canary test

**What to build:** A single command that answers "is this repository safe to publish?" without the repository ever listing the values it hunts for: it derives its denylist at run time from the decrypted secret set, scans the working tree, the full history and the commit metadata, reports where — never what — and fails on any finding.

**Blocked by:** Epic 22 #02 (output redaction)
**Blocks:** #02

**Status:** ready-for-agent

- [ ] The denylist is derived at run time from the decrypted secret set (through the deploy wrapper's environment), an optional extra-terms entry held in the same encrypted store, and the resolved address of the target host; nothing sensitive is committed to define the check
- [ ] It scans every tracked file at the current commit, every blob in the full history across all refs, commit messages, and author and committer names and emails; values are matched literally and in JSON-escaped and URL-encoded forms, with the same minimum length as redaction
- [ ] Generic rules cover credential shapes, addresses in the tailnet CGNAT range, git-crypt key-file headers and age secret keys
- [ ] Findings report file and line (or commit) plus the rule name, never the matched text; the audit runs under output redaction and exits non-zero on any finding
- [ ] A minimal allowlist (path, rule and written reason) covers legitimate matches such as the encrypted store's own contents, and cannot silence a rule it does not name
- [ ] A canary test builds a fixture repository with a throwaway key and store, plants canaries in the tree, in history, in commit metadata and in encoded forms, and asserts every one is found, the report contains no canary text, a clean fixture passes, and the allowlist behaves
- [ ] The audit's rules — what is scanned, what is allowlisted and why — are documented

## Notes

See epic 24 spec, "Implementation Decisions" (the audit derives its denylist at run time; what it scans; generic rules; output and exit behavior) and "Testing Decisions". Reuses epic 22's redaction and canary technique.
