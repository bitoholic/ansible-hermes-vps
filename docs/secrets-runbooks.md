# Secrets runbooks

Operational procedures for the SOPS + age encrypted secrets store (`secrets/secrets.enc.env`,
`.sops.yaml`). Background and the design decisions behind this model:
[ADR-0007](adr/0007-sops-age-encrypted-secrets.md). Day-to-day commands: `README.md`'s
"Local Secrets Workflow".

None of these procedures ever require writing a decrypted value to disk or printing one to a
terminal. If a step below seems to require that, stop — it's wrong, not necessary.

## Onboarding a workstation

**1. Install the tools.** `sops` and `age` must be on `PATH`.

| OS | `age` | `sops` |
|---|---|---|
| Debian / Ubuntu | `sudo apt install age` (may need `bookworm-backports`/`universe` on older releases) | No official package — [download the binary](https://github.com/getsops/sops/releases) for your architecture |
| Fedora | `sudo dnf install age` | No official package — [download the binary](https://github.com/getsops/sops/releases) |
| macOS | `brew install age` | `brew install sops` |

For `sops`, prefer a release at or above **v3.10.0**: earlier versions silently ignore
`SOPS_AGE_KEY_CMD` (the Tier 2 hardware-key hook — see ADR-0007) rather than erroring, which is
confusing to debug. Verify with `sops --version`.

**2. Generate this workstation's key**, on the new workstation:

```bash
scripts/secrets init-key
```

This creates `~/.config/sops/age/keys.txt` (mode `0600`) and prints **only the public key**
(`age1...`) — nothing else. Send that public key to yourself (it's not secret) however is
convenient.

**3. Add it as a recipient**, from any workstation that already has access:

```bash
scripts/secrets add-recipient <the-new-public-key>
```

This re-keys the store so the new workstation can decrypt it, and commit the resulting change to
`.sops.yaml`/`secrets/secrets.enc.env`.

**4. Verify**, on the new workstation, once the commit above is pulled:

```bash
scripts/secrets check   # should report no problems
scripts/deploy --check  # should reach a real preflight, not "key is missing"
```

## Retiring a workstation

Remove it as a recipient so it can no longer decrypt the store, from any *other* workstation:

```bash
scripts/secrets remove-recipient <the-retiring-workstation's-public-key>
```

This re-keys the store (a fresh data key wrapped for the remaining recipients only) and prints an
explicit reminder — **removing a recipient does not protect any version of the store already
committed to git history**. If the retiring workstation might have been compromised (not just
decommissioned in the ordinary course), treat it as a suspected key leak instead (below), not a
plain retirement.

Commit the resulting `.sops.yaml`/store changes. If the workstation itself still exists, delete its
local key (`~/.config/sops/age/keys.txt`) — the same overwrite-reliability limits noted under
["Removing the plaintext `.env`"](#plaintext-removal-limits-from-ticket-09) below apply to any local
key file too.

## Responding to a suspected key leak

A workstation's private key (or the break-glass key) may have been exposed — a stolen laptop, a
leaked backup, anything short of certainty that it's still exclusively controlled.

1. **Remove the recipient immediately**: `scripts/secrets remove-recipient <its-public-key>`. This
   re-keys the store's *data key*, so the compromised private key can no longer decrypt the
   *current* store — but see the git-history caveat above: every version already committed remains
   decryptable by that key forever, since the ciphertext itself doesn't change retroactively.
2. **Rotate the data key explicitly** as a second, independent step, even though step 1 already
   re-keys: `scripts/secrets rotate`. This generates a fresh data encryption key for the *same*
   remaining recipients, so even a leaked private key that was somehow still a recipient at some
   intermediate point gains nothing from continuing to hold old ciphertext.
3. **Rotate every credential the store actually holds.** Removing the recipient and rotating the
   data key only address *future* access to the encrypted values — they do nothing about a value an
   attacker already decrypted before you noticed. Every credential in the store (`scripts/secrets
   check` lists the names, never the values) must be treated as compromised and rotated at its
   source (Authelia password, API keys, the GitHub token, etc.), then written back with
   `scripts/secrets fill` or `edit`.
4. Generate a fresh key for the affected workstation (if it's still yours and trusted going
   forward) via the onboarding runbook above, rather than reusing the old one.

## Using the break-glass key

The break-glass key is a recipient whose **private** half is kept offline (never on a workstation),
specifically so losing every workstation doesn't lock the operator out permanently.

**To use it**: retrieve the offline private key file, point `HERMES_SECRETS_KEY_FILE` at it for a
one-off command (never copy it onto a workstation's normal disk long-term):

```bash
HERMES_SECRETS_KEY_FILE=/path/to/breakglass-key.txt scripts/secrets check
HERMES_SECRETS_KEY_FILE=/path/to/breakglass-key.txt scripts/deploy --check
```

Once a normal workstation key is available again, onboard it (above) and go back to using that —
don't leave the break-glass key mounted or copied anywhere routinely accessible.

**If the break-glass key itself is ever exposed**: treat it exactly as a suspected key leak (above),
then generate a brand-new break-glass key and store it offline again.

## Plaintext-removal limits (from ticket #09)

Whenever removing a plaintext copy of a credential (an old `.env`, a key file, anything that held a
value before it moved into the encrypted store):

- **Overwrite tools are not reliable** on SSDs and copy-on-write filesystems (Btrfs, ZFS, APFS) —
  a plain `rm` (or even `shred`) does not guarantee the underlying blocks are actually gone; wear
  leveling and copy-on-write both mean old data can persist in blocks the filesystem no longer
  references.
- **Plaintext copies may exist outside the workstation you're cleaning up**: backups, sync tools
  (Dropbox, iCloud, a NAS), shell history (`.bash_history`/`.zsh_history` if a value was ever typed
  or `export`ed on a command line), another machine entirely.
- **When in doubt, rotate.** If you can't positively rule out that a credential's plaintext exists
  somewhere you don't control, treat it the same as a suspected leak (above) and rotate it at its
  source, rather than relying on deletion alone.
