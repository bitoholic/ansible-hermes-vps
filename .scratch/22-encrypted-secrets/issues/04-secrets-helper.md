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

## Review round 1 (independent fresh-context subagent): CHANGES REQUIRED, fixed

Two genuine code defects found by direct testing (not by mutation — both existed in the code as shipped):

1. `cmd_edit` ran `sops edit` without capturing its output, so a decrypt/parse failure printed sops' own raw
   diagnostic text straight to the terminal — including, in one repro, a private key verbatim — bypassing the
   fixed-vocabulary mapping every other command already used. Fixed: stderr is now captured (stdin/stdout stay
   inherited so the interactive editor still works) and a failure is raised through the same `sops_failure()` path
   as `rotate`/`fill`/`import`.
2. `add-recipient`/`remove-recipient` wrote `.sops.yaml` to disk *before* confirming `sops updatekeys` succeeded; a
   failure partway through (permission error, full disk, a Ctrl-C in that window) left the config and the real
   ciphertext's recipients out of sync — for `remove-recipient` this could silently leave a "removed" key still able
   to decrypt while reporting success. Fixed: a shared `persist_config_rekeying()` helper writes the config, runs
   `updatekeys`, and rolls the config file back to its exact prior bytes (or removes it, if it didn't exist before)
   if `updatekeys` fails, so the two can never end up disagreeing.

Also addressed from the same round: a symlinked store is now refused outright at the point of use (`store_exists()`),
not only caught later by ticket #03's lint-time structural guard; `import` now refuses a source file that assigns
the same name more than once (the one class of data loss its round-trip check structurally cannot see, since both
sides of that check parse the same bytes through sops' own dotenv parser). New regression tests: `edit` leaking raw
sops text (including the exact "an age key file ends up at `HERMES_SECRETS_STORE`" scenario), the config/ciphertext
rollback-on-failure, a multi-rule `.sops.yaml` using the first match, a checksum-corrupted (but right-shaped) age
key, and the duplicate-name refusal — each verified to actually catch its regression when reverted.

Not changed: the reviewer's SOPS_AGE_KEY_CMD and "possibly unencrypted comment" coverage gaps are already exercised
against the same shared `hermes_secrets.py` functions by ticket #01's `check-deploy-wrapper.sh`; not duplicated here.

## Review round 2 (independent fresh-context subagent): CHANGES REQUIRED, fixed

Confirmed both round 1 fixes hold for the paths they cover, but found the bootstrap branch in `cmd_add_recipient`
(taken when `.sops.yaml` doesn't exist yet) bypassed round 1's rollback protection entirely — a real, high-severity
gap. Repro: delete `.sops.yaml` while a store still exists (a lost file, a bad merge), then have an identity that
was never a recipient run `add-recipient`; the bootstrap path wrote a brand-new single-recipient config and
reported success without ever running `updatekeys`, so `.sops.yaml` claimed sole ownership the identity never
actually had. Fixed by refusing outright: **`add-recipient` never bootstraps a fresh `.sops.yaml` for a store that
already exists**, full stop — not even a rollback-protected attempt, because (checked while fixing) even a
*legitimate* recipient bootstrapping a single-key config would silently narrow the real recipient set down to just
that one key, dropping every other current recipient with no confirmation. The operator is told to recreate
`.sops.yaml` by hand or restore it from version control instead.

Also fixed: `cmd_fill`'s happy path (via `hs.preflight()`) didn't go through the symlink guard, unlike every other
command; `cmd_edit` checked `sops edit`'s return code but never its stderr, so it could return success on a forged/
unencrypted comment line where every other command using `hs.decrypt_store()` refuses (factored the check into a
shared `hs.refuse_if_unencrypted_comment_warned()` used by both); the bootstrap `.sops.yaml`'s `path_regex` only
escaped literal `.`, not other regex metacharacters, so a custom store path with e.g. parentheses produced a rule
that couldn't match its own store; `load_sops_config()` could crash with a raw traceback on malformed YAML instead
of a clean message. Code-quality nits from the same round: an unused `stat` import removed, `yaml`/`re`/`json`/
`shutil` hoisted to the top of the file instead of imported locally per-function (ticket #01's convention). New
regression tests for all of the above (including the two ways a bootstrap-for-an-existing-store attempt is now
refused, `check`'s own missing-required report, and `fill` treating a present-but-empty required value as missing),
each verified to catch its bug when reverted. Not changed: the reviewer's "an editor can save an empty store" and
"import verifies via dict comparison rather than literally a digest" observations were explicitly flagged as
judgment calls, not stated-acceptance-criterion violations — left as accepted, documented behavior rather than
building a rollback layer under `sops edit` itself.

## Review round 3 (independent fresh-context subagent): PASS

No code defects. All three prior rounds' fixes were re-attacked empirically (not just re-read) and held: the
bootstrap refusal, `fill`'s unconditional symlink check, `edit`'s unencrypted-comment check firing on both rc=0 and
rc=200, the `re.escape`d bootstrap regex against a path with parens/spaces/multiple dots, and `remove-recipient`
inheriting the same rollback guarantee as `add-recipient` (it has no bootstrap branch of its own). 9 of 10 fresh
mutations were caught; the one miss (`write_atomic` made non-atomic) is the same already-documented, already-accepted
black-box-testing limit from the initial implementation notes, not a new gap. Two non-blocking observations, accepted
as documented behavior rather than fixed: a chmod-000 `.sops.yaml` is reported as "not valid YAML" (technically a
permissions error, but the underlying OS error text is still shown, so an operator can still diagnose it); and
`import` silently overwrites an existing store's full content on a re-run (consistent with its "one-time, attended
migration" framing — the round-trip check correctly verifies what it claims, this is a footgun for a habitual re-run,
not a false claim).

**Ticket #04 is closed.**
