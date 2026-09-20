# 03: Structural guard — a plaintext secrets file can't be committed

**What to build:** A check in the standard lint run that makes committing plaintext secrets structurally impossible to miss: the tracked encrypted store must be genuinely encrypted and satisfy the name-set rule, no other tracked file may look like a plaintext secrets file, and `.env` must stay untracked.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] The **name-set rule** is defined once and used by this guard: every *required* manifest name is present in the store; every name present is a manifest name or a *declared extra*; declared extras are listed in exactly one place (initially the target host); optional manifest entries with defaults may be absent
- [ ] When the encrypted secrets file is tracked, the guard asserts it carries SOPS metadata, every value is encrypted, and its names satisfy the name-set rule
- [ ] No other tracked file matches a plaintext-secrets pattern; `.env` is untracked and ignored
- [ ] Negative fixtures demonstrate each failure: a cleartext value, a missing required name, an undeclared extra name, and a tracked plaintext-secrets-looking file; a fixture proves an absent *optional* name and a declared extra both pass
- [ ] The guard tolerates the store not yet existing (before the migration) and becomes mandatory once the migration ticket (#09) completes
- [ ] The guard runs in the standard lint run and needs no key

## Notes

See epic 22 spec, "Implementation Decisions" (name-set rule; structural guard). Note the generated template already treats the target host as an extra outside the manifest, and 19 of the manifest's entries are optional — a plain "names equal the manifest" check would be wrong.
