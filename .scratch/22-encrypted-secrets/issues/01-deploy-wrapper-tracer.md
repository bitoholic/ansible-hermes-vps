# 01: Deploy wrapper tracer — run a playbook (or a registered script) with decrypted secrets in its environment only

**What to build:** A single command that runs the repository's own playbook — and, in a separate script mode, registered operator scripts — with values from an encrypted secrets file injected into that process's environment and nowhere else, proven end to end against a fixture store and a throwaway age key generated at test time. It checks its prerequisites first, accepts only vetted invocation shapes, streams output live, and returns the child's exit status. It fixes the shape of the SOPS configuration (recipients scoped to the file's path) so later tickets and the migration slot in.

**Blocked by:** None (can start immediately)
**Blocks:** #02, #03, #04, #08, #09

**Status:** ready-for-agent

- [ ] A throwaway age key and a fixture encrypted store are generated at test time; no real key or secret is needed to run the test
- [ ] The wrapper decrypts into the child process's environment only; no plaintext file is created at any point (asserted)
- [ ] The `secrets` resolver receives the fixture values, proving the seam's contract works unchanged — the existing resolver test and the single-seam lint check pass untouched
- [ ] **Vetted invocation shapes only:** the wrapper runs only the repository's own playbook and passes through a fixed set of flags (check mode, diff, tags, skip-tags, limits, verbosity, start-at-task); it **refuses** extra-variable injection, ad-hoc modules, other playbooks and paths outside the repository, each shown by a negative test
- [ ] **Script mode:** the wrapper can run a registered operator script (an allowlist kept in one place) with the same decrypted environment and the same redaction, so scripts get the target host from the store; an unregistered script is refused
- [ ] The target host is read from the store
- [ ] The store is read from a configurable location that defaults to this repository's, so the working repository and the secrets' home can be split later without a rewrite (tested with the store at a non-default path)
- [ ] The exit status equals the child's, and output streams live rather than arriving at the end
- [ ] Preflight verifies: SOPS and age installed; the operator's key present and not group- or world-readable; the encrypted store valid; required manifest names present — failures name missing secrets by name only and exit non-zero before anything runs
- [ ] A committed SOPS configuration scopes recipients to the store's path and is shaped to accept one key per workstation plus a break-glass key; the key source is configurable so a hardware-backed key can be adopted later without a rewrite
- [ ] The standard lint run fails with a clear message if SOPS or age is missing (it does not skip silently)
- [ ] A leftover plaintext `.env` produces a warning

## Notes

See epic 22 spec, "Implementation Decisions" (tool choice; the seam's contract is untouched; recipients; deploy wrapper) and "Testing Decisions" (the one new seam). The invocation policy exists because passing arbitrary arguments through would make the wrapper a general code-execution path with the decrypted environment.
