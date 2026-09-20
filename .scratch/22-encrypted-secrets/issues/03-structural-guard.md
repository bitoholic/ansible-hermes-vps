# 03: Structural guard — a plaintext secrets file can't be committed

**What to build:** A check in the standard lint run that makes committing plaintext secrets structurally impossible to miss: the tracked encrypted store must be genuinely encrypted and match the manifest, no other tracked file may look like a plaintext secrets file, and `.env` must stay untracked.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] When the encrypted secrets file is tracked, the guard asserts it carries SOPS metadata, every value is encrypted, and its variable names equal the manifest's environment names
- [ ] No other tracked file matches a plaintext-secrets pattern; `.env` is untracked and ignored
- [ ] Negative fixtures demonstrate each failure: a cleartext value, a missing name, an extra name, and a tracked plaintext-secrets-looking file
- [ ] The guard tolerates the store not yet existing (before the migration) and becomes mandatory once the migration ticket (#09) completes
- [ ] The guard runs in the standard lint run and needs no key

## Notes

See epic 22 spec, "Implementation Decisions" (structural guard). Prior art: the sync and placeholder guards already in the standard lint run.
