# 03: Structural guard — a plaintext secrets file can't be committed

**What to build:** A check in the standard lint run that makes committing plaintext secrets structurally impossible to miss: the tracked encrypted store must be genuinely encrypted and satisfy the name-set rule, no other tracked file may look like a plaintext secrets file, and `.env` must stay untracked.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] The **name-set rule** is defined once and used by this guard: every *required* manifest name is present in the store; every name present is a manifest name or a *declared extra*; **declared extras are listed in exactly one place — the generator's existing operator-extras list** — and this ticket adds the audit extra-terms entry there (its name fixed here and used by epic 24's audit) alongside the target host; optional manifest entries with defaults may be absent
- [ ] When the encrypted secrets file is tracked, the guard asserts it carries SOPS metadata, every value is encrypted, and its names satisfy the name-set rule
- [ ] No other tracked file matches a plaintext-secrets pattern; `.env` is untracked and ignored
- [ ] Negative fixtures demonstrate each failure: a cleartext value, a missing required name, an undeclared extra name, and a tracked plaintext-secrets-looking file; a fixture proves an absent *optional* name and a declared extra both pass
- [ ] **The mandatory state is derived, not switched by hand:** when the SOPS recipient configuration is present the store must be present and valid, and a missing store is a failure; when neither is present (before the migration, and in a fresh clone of a public export, which deliberately has neither) the guard applies only its store-independent checks — no plaintext secrets file tracked, `.env` untracked — and the standard lint run passes; the migration ticket (#09) therefore needs no manual flip, and a negative case shows that deleting the store while the recipient configuration remains fails
- [ ] The guard runs in the standard lint run and needs no key

## Notes

See epic 22 spec, "Implementation Decisions" (name-set rule; structural guard). Note the generated template already treats the target host as an extra outside the manifest, and 19 of the manifest's entries are optional — a plain "names equal the manifest" check would be wrong.
