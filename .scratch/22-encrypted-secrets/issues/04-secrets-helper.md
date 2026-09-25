# 04: Secrets helper — maintain the encrypted store without ever writing plaintext

**What to build:** A companion command for everyday secret maintenance that replaces the interactive environment-prompting script: edit the store with values decrypted only in memory, see what is missing or extra under the name-set rule, fill in missing values with hidden input, manage recipients, rotate the data key, initialise a new workstation's key, and import an existing plaintext environment file with a verified round trip.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [x] Editing the store opens the decrypted values in the operator's editor with plaintext held only in memory and re-encrypts on save
- [x] A check reports names missing (required) or undeclared, per the name-set rule, by name only
- [x] The audit extra-terms entry (a declared extra) can be edited and checked like any other name, including being absent
- [x] A guided fill prompts for missing required values with hidden input, echoes nothing, and writes no plaintext file
- [x] Recipients can be added and removed, and the data key rotated
- [x] A new workstation's key can be initialised with safe permissions, printing only its public key
- [x] An existing plaintext environment file can be imported — including the case where optional manifest entries are absent from it and where it holds declared extras — and the helper verifies that the decrypted names and values equal the source by digest without printing anything
- [x] The names-only environment template is still generated from the manifest and its sync check passes; **the generator, whose own check refers to the prompt script being removed, is updated** so nothing refers to a script that no longer exists; the old prompt script is removed or reduced to a pointer to this helper
- [x] Everything is tested against a fixture store and throwaway keys

## Notes

See epic 22 spec, "Implementation Decisions" (secrets helper; name-set rule; migration).

## Implementation

`scripts/secrets`: a new CLI with 8 subcommands (`check`, `fill`, `edit`, `add-recipient`, `remove-recipient`,
`rotate`, `init-key`, `import`). None of them ever write plaintext to disk:

- `edit` delegates to `sops edit` with `TMPDIR` pinned to a private, freshly-created 0700 scratch directory (sops's
  own temp file is 0600 and self-removed on exit; the scratch dir is removed in a `finally`).
- `fill` decrypts to memory, prompts only for the still-missing required names via `getpass.getpass()` (hidden,
  non-interactive callers are refused), and re-encrypts the merged result.
- `add-recipient`/`remove-recipient` edit `.sops.yaml` and run `sops updatekeys -y` (ciphertext-only re-wrap; values
  are never touched). Removing the last recipient is refused. Removing a key prints a fixed warning that this does
  not protect anything already committed to git history.
- `rotate` runs `sops rotate -i` (new data key, same recipients and values).
- `init-key` runs `age-keygen`, chmods 0600, and prints only the derived public key.
- `import` reads a plaintext source file and proves nothing was lost using sops itself as the oracle on both sides:
  it encrypts the source bytes to a throwaway single-recipient (the operator's own key) ciphertext in a directory
  with no `.sops.yaml` ancestor, decrypts that back, and compares the result against `decrypt_store()` of the real
  (possibly multi-recipient) written store — reporting only missing/extra/differing **names**, never values.
- Every sops failure is mapped through the same fixed-vocabulary reason (`hermes_secrets._sops_failure_reason`,
  extended this ticket to recognise real sops MAC-failure wording) so raw sops diagnostic text — which can echo a
  path or a plaintext line — is never surfaced.
- `write_atomic()` writes to a temp file in the same directory as the store (same filesystem) and `os.replace()`s
  over it, so a crash mid-write can't leave a corrupt store in place.

Shared library changes: `valid_age_recipient` and its bech32/regex helpers moved from `check_secrets_store.py` into
`hermes_secrets.py` (the structural guard now imports them instead of duplicating them); added `store_names()` for
the keyless `check` path. `generate-env.py` and `setup-env.sh` no longer talk to each other — the old interactive
prompt script is now a short pointer to `scripts/secrets`.

Tested as a black box (`tests/check-secrets-helper.sh` + `tests/support/secrets-fixture.sh`) against a throwaway
fixture repo, two separate workstation identities, and a break-glass key — never a real key, host, or secret.
Interactive hidden input is driven through a genuine pseudo-terminal (`pty.fork()`), not a monkeypatch, so the real
`getpass`/`isatty` code path is exercised. Hardened against a 17-mutation self-check before the first review round;
two mutations are accepted as not real gaps rather than fixed further:
- `init-key` overwriting an existing key: `age-keygen -o` itself already refuses to overwrite (verified empirically),
  so the helper's own `os.path.exists` guard only improves the error message, not the safety guarantee.
- A non-atomic direct write that still succeeds without a crash is indistinguishable from an atomic one by black-box
  testing alone (no fault injection at the syscall level); `write_atomic()`'s use of `mkstemp` + `os.replace` is
  verified by code inspection instead.
