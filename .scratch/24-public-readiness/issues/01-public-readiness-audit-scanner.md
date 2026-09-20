# 01: Public-readiness audit scanner, proven by a canary test

**What to build:** A single command that answers "is this repository safe to publish?" without the repository ever listing the values it hunts for: it derives its denylist at run time from the decrypted secret set, scans the working tree, the full history (binary-safe) and the commit metadata, reports where — never what — and fails on any finding.

**Blocked by:** Epic 22 #02 (output redaction, including script mode)
**Blocks:** #02

**Status:** ready-for-agent

- [ ] The denylist is derived at run time from the decrypted secret set (through epic 22's wrapper in script mode), the audit extra-terms entry — the declared extra whose name epic 22 #03 fixed, read from the store, with its accepted format (terms separated by newlines or commas) documented — and the resolved address of the target host; nothing sensitive is committed to define the check, and an absent extra-terms entry is not an error
- [ ] It scans every tracked file at the current commit, every blob in the full history across all refs, commit messages, and author and committer names and emails; values are matched literally and in JSON-escaped and URL-encoded forms, with the same minimum length as redaction
- [ ] **History is read binary-safe:** the git-crypt key header is a binary blob that a text-only search silently skips, so blobs are inspected with a method that does not skip binary content
- [ ] Generic rules cover credential shapes, host addresses in the tailnet CGNAT range (but **not** the range's own CIDR notation, a functional value), git-crypt key-file headers and age secret keys
- [ ] Findings report file and line (or commit) plus the rule name, never the matched text; the audit runs under output redaction and exits non-zero on any finding
- [ ] A minimal allowlist (path, rule and written reason) covers legitimate matches such as the encrypted store's own contents, and cannot silence a rule it does not name
- [ ] A canary test builds a fixture repository with a throwaway key and store, plants canaries in the tree, in history, in commit metadata and in encoded forms, **plus a binary blob carrying a git-crypt key header**, and asserts every one is found, the report contains no canary text, a clean fixture passes, and the allowlist behaves
- [ ] The audit's rules — what is scanned, what is allowlisted and why — are documented

## Notes

See epic 24 spec, "Implementation Decisions" (the audit derives its denylist at run time; what it scans; generic rules; output and exit behavior) and "Testing Decisions". Reuses epic 22's redaction and canary technique.
