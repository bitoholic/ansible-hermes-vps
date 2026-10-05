# 01: Public-readiness audit scanner, proven by a canary test

**What to build:** A single command that answers "is this repository safe to publish?" without the repository ever listing the values it hunts for: it derives its denylist at run time from the decrypted secret set, scans the working tree, the full history (binary-safe) and the commit metadata, reports where — never what — and fails on any finding.

**Blocked by:** Epic 22 #02 (output redaction, including script mode)
**Blocks:** #02

**Status:** done

- [x] The denylist is derived at run time from the decrypted secret set (through epic 22's wrapper in script mode), the audit extra-terms entry — the declared extra whose name epic 22 #03 fixed, read from the store, with its accepted format (terms separated by newlines or commas) documented — and the resolved address of the target host; nothing sensitive is committed to define the check, and an absent extra-terms entry is not an error
- [x] It scans every tracked file at the current commit, every blob in the full history across all refs, commit messages, and author and committer names and emails; values are matched literally and in JSON-escaped and URL-encoded forms, with the same minimum length as redaction
- [x] **History is read binary-safe:** the git-crypt key header is a binary blob that a text-only search silently skips, so blobs are inspected with a method that does not skip binary content
- [x] Generic rules cover credential shapes, host addresses in the tailnet CGNAT range (but **not** the range's own CIDR notation, a functional value), git-crypt key-file headers and age secret keys
- [x] Findings report file and line (or commit) plus the rule name, never the matched text; the audit runs under output redaction and exits non-zero on any finding
- [x] A minimal allowlist (path, rule and written reason) covers legitimate matches such as the encrypted store's own contents, and cannot silence a rule it does not name
- [x] A canary test builds a fixture repository with a throwaway key and store, plants canaries in the tree, in history, in commit metadata and in encoded forms, **plus a binary blob carrying a git-crypt key header**, and asserts every one is found, the report contains no canary text, a clean fixture passes, and the allowlist behaves
- [x] The audit's rules — what is scanned, what is allowlisted and why — are documented

## Notes

See epic 24 spec, "Implementation Decisions" (the audit derives its denylist at run time; what it scans; generic rules; output and exit behavior) and "Testing Decisions". Reuses epic 22's redaction and canary technique.

**Built:** `scripts/public-readiness-audit.py` (registered as `audit` in `scripts/registered-scripts.conf`,
run via `scripts/deploy --script audit`) + `scripts/audit_rules.py` (the generic, no-key rules, shared
with the lint-run entry point) + `audit-allowlist.yml` (empty by design — see its own header comment) +
`docs/public-readiness-audit.md` (the rules, write-up required by the last AC) +
`tests/check-public-readiness-audit.sh` / `tests/support/audit-fixture.sh` (the canary test, a real
throwaway git repository with history, a side branch never merged to main, and planted canaries in
every scanned surface) + a new `tests/lint.sh` entry (`--generic-only --tree-only`, no key).

**Known, deliberate, and left for ticket #02:** running the lint-wired generic check
(`python3 scripts/public-readiness-audit.py --generic-only --tree-only`) against *this* repository's
own tree right now reports ~20 real `tailnet-cgnat-address` findings (test fixtures using CGNAT-shaped
addresses, and real addresses in runbooks/scratch tickets). None are allowlisted here: the fixture
addresses are cosmetic noise ticket #02 can allowlist with a reason if it chooses to, but the runbook
and scratch-ticket hits are exactly the identifying values ticket #02's scrub exists to remove, not to
allowlist. Until #02 lands, `tests/lint.sh`'s new entry — and therefore the full lint run — fails on
this branch; this is the expected, intentional handoff between the two tickets, not a regression.
