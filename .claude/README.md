# Agent guardrails (Tier 1) — epic 22 ticket #08

`.claude/settings.json` is committed with this repository so any agent working in it — on any
workstation — gets the same guardrails automatically. This file records the design decisions, what
was actually verified, and the honest limit of what this protects against.

## The mechanism (verified against the current Claude Code documentation, not assumed)

Claude Code's Bash sandbox (`sandbox.enabled: true`) applies OS-level filesystem and network
isolation to every Bash/Monitor command it runs, enforced by the kernel (Linux: bubblewrap/seccomp;
macOS: Seatbelt) — a command cannot read a denied path by switching to a different reader, since the
denial happens below the tool layer entirely.

`sandbox.excludedCommands` is the documented mechanism for letting one specific, named command run
completely outside the sandbox (full filesystem and network access) while every other command stays
sandboxed. Verified directly against `https://code.claude.com/docs/en/sandboxing` (fetched during
this ticket's implementation, 2026-09): *"Add `excludedCommands` for any organization-approved tools
that must run without isolation"*; entries are matched as literal command names (the docs' own
examples: `"excludedCommands": ["docker", "kubectl"]`). This is the only mechanism that lets a
command reach an outbound SSH connection at all — the sandbox's network layer is a domain-based HTTP
allowlist/proxy, not something an arbitrary SSH target can be added to. This exact tradeoff — and the
requirement to identify and record the mechanism from *current* documentation rather than assume it,
since setting names can change — is why this file exists rather than a one-line settings change.

`scripts/deploy` is the only entry in `excludedCommands`. Both of the wrapper's own invocation shapes
(`scripts/deploy [FLAGS]` and `scripts/deploy --script NAME [ARGS]`, epic 22 #01) are covered by the
same entry — the exemption is by command name, not by argument shape; argument-shape vetting is a
*separate* layer (see below).

## What's denied, for everything except the exempted wrapper

`sandbox.filesystem.denyRead`:
- `~/.config/sops/age/**` — the conventional age identity location (`hermes_secrets.py`'s
  `DEFAULT_KEY_FILE`). An operator using `HERMES_SECRETS_KEY_FILE` to point elsewhere isn't covered by
  this — criterion #18 asks for conventional locations only, not every possible override, and no
  setting here can predict an override that doesn't exist yet.
- `~/.ssh/**` — the conventional SSH key location the wrapper's own SSH connection to the VPS uses.
- `./.env` — the plaintext leftover from before the encrypted store existed (epic 22 #03's structural
  guard keeps it git-ignored; this keeps it unreadable to a sandboxed agent too).

`permissions.deny` (Bash command-shape rules — defense in depth *alongside* the filesystem denial
above, not instead of it, precisely because a command-pattern rule can be sidestepped by an
equivalent command the pattern didn't anticipate):
- `sops decrypt`/`sops exec`, `env`, `printenv` — direct decrypt/environment-dump attempts.
- `scripts/secrets fill|edit|rotate|add-recipient|remove-recipient|import` — every subcommand of the
  secrets helper (epic 22 #04) that needs to read the age key to decrypt or re-encrypt the store.

`permissions.allow` — the wrapper's own invocation, and the secrets helper's two subcommands that
never touch the key at all: `check` (reads only the store's ciphertext structure) and `init-key`
(creates a *new* identity; never reads an existing one, and `age-keygen` itself already refuses to
overwrite one — see epic 22 #04's own notes).

## Why `allowWrite` is scoped to `~/.ansible/tmp/**`, not all of `~/.ansible`

The sandbox denies writes outside a small allowlist by default. A *sandboxed* (non-exempted)
`ansible-playbook` invocation — any of this repo's own local test playbooks (`tests/test_*.yml`,
run directly by `tests/lint.sh`, never through `scripts/deploy`) or a throwaway fixture copy of the
wrapper invoked by absolute path (`tests/support/deploy-fixture.sh`, deliberately outside
`excludedCommands` — a fixture copy must not inherit the real wrapper's trust) — has no scratch
directory pinned for it the way the exempted wrapper pins its own (`ANSIBLE_LOCAL_TEMP` under a
private, wrapper-owned directory; see below), so it falls back to Ansible's own default local-temp
location, `~/.ansible/tmp`. Without write access there, any such run fails outright
(`Read-only file system: '~/.ansible/tmp/...'`), which is why this entry exists at all.

It is **not** `~/.ansible/**`, because `~/.ansible/collections` is one of exactly two paths (`scripts/deploy`'s own `CFG_PATH_VALUES`, the other being `/usr/share/ansible/collections`) the exempted wrapper
explicitly trusts and loads Ansible collections from on its real, unsandboxed run
(`effective_collections_path()` → `ANSIBLE_COLLECTIONS_PATH`). Granting sandboxed write access to that
same tree would let an untrusted sandboxed command plant or overwrite a collection there — invisible to
`git diff`, since nothing under `~/.ansible` is part of this repository — that the *next real deploy*
would then load with the full decrypted secrets environment. That is a strictly worse bypass than the
documented Tier 1 limit below (which at least requires editing a tracked file), so `allowWrite` is
scoped to exactly the subdirectory the observed failure needed, `~/.ansible/tmp/**`, leaving
`~/.ansible/collections` (and everything else under `~/.ansible`) outside the sandboxed write surface.
Found by epic 22 #08's own round 1 review, not the original design — recorded here per that review's
own finding.

One residual noted by round 2's review: `~/.ansible/tmp` is not in `denyRead`, so stale `ansible-tmp-*`
residue left behind by a killed or crashed non-exempted `ansible-playbook` run could later be read back
by any sandboxed Bash command. This never holds a real secret — the exempted wrapper's own runs never
write there at all (see above), so anything that could ever land there comes only from this repo's own
local test fixtures and their canary values, not the real store.

## What actually protects the exempted wrapper, once exempted (the list this ticket's own
acceptance criteria ask for)

Being exempted from the sandbox is not "safe by default" — the wrapper is trusted specifically
*because* of everything below, not because it was let out of the sandbox:

1. **The permission rules above** — only `scripts/deploy`'s own invocation is allowed to run
   unsandboxed at all; nothing else is.
2. **The wrapper's own refusals** (epic 22 #01) — it parses its own arguments and refuses extra
   variables, ad-hoc modules, foreign playbooks, other inventories/connections, and anything outside
   its fixed flag set, regardless of what an agent asks it to do. This applies to *playbook mode*.
   *Registered-script mode* (`scripts/deploy --script NAME`) has a narrower protection here: the
   wrapper only checks that `NAME` resolves, inside the repository, to an existing, executable file
   listed in the committed `scripts/registered-scripts.conf` — it does not vet, hash, or sign the
   script's own contents. See the Tier 1 limit below for what this means in practice.
3. **The pinned Ansible configuration and cleared environment** (epic 22 #01) — inherited
   `ANSIBLE_*` settings are cleared, the effective configuration is refused if it would make Ansible
   write a log, a callback's output, or a persistent fact cache to disk, and Ansible's own local temp
   lives in a private, wrapper-owned directory removed when the run ends.
4. **Output redaction** (epic 22 #02) — every decrypted value is scrubbed from the wrapper's combined
   stdout/stderr as it streams, regardless of which task or how a value is encoded.

## What this does NOT protect against — the documented Tier 1 limit

An agent that edits the wrapper itself, a role, or the playbook, and then runs the (now-modified)
wrapper is **not** protected against by anything above — the modified code runs with the full
decrypted environment and can do anything with it, including printing a re-encoded value past the
redactor. This is a deliberate, accepted limit, not an oversight: the age key lives on the same
machine the agent runs commands on, so Tier 1 stops *accidents* (reading the key file, dumping the
environment, an unredacted diff) but not a *determined actor* with edit access to this repository's
own code. Closing this gap is exactly what Tier 2 is for.

**Registered-script mode is exactly as unprotected, and easier to reach.** `scripts/deploy`'s registry
loader (`hermes_secrets.load_registry`) does no integrity checking at all — no checksum, no signature —
on either `scripts/registered-scripts.conf` or the script file a registered name points to; it only
checks that the resolved path stays inside the repository, exists, and is executable. An agent can
`Write` a brand-new script anywhere under this repo, add one line to `registered-scripts.conf`
registering it, and run it via `scripts/deploy --script <name>` — which is excluded from the sandbox by
command name exactly like every other `scripts/deploy` invocation, and pre-approved by
`permissions.allow: ["Bash(scripts/deploy:*)"]` with no prompt. Unlike playbook mode, a registered
script has none of the fixed-flag-set or Ansible-configuration constraints — it can do anything a shell
script can do with the fully decrypted secrets environment. This is not a narrower case of the wrapper-
editing limit above; it is the *same* limit reached by a smaller edit (one new file plus one registry
line, vs. patching the wrapper's own argument-parsing/refusal logic), and is called out separately here
because it would be easy to read the "wrapper's own refusals" protection as covering both invocation
shapes equally — it does not.

## Tier 2 upgrade path (documented, not built — out of scope for this epic)

A hardware-backed or passphrase-gated age key (a token requiring a physical touch, or a passphrase
prompt, for each decrypt) turns the Tier 1 accident-prevention boundary into an actual cryptographic
one: even a fully compromised wrapper can't silently decrypt without that per-use interaction. The
wrapper already supports this with **no rewrite required** — `hermes_secrets.sops_env()` honours
`SOPS_AGE_KEY_CMD` (a command that supplies the key on demand) whenever it's set, in preference to the
plain key-file path, and `scripts/deploy`'s own docstring already documents this: *"SOPS_AGE_KEY_CMD
is honoured for a hardware-backed key (Tier 2) with no change here."* Adopting Tier 2 is a matter of
provisioning the hardware/passphrase-gated key and setting that one environment variable — not a code
change to the wrapper or these settings.

## End-to-end check under the real sandbox (recorded, not just claimed)

Verified live, in this session, with these exact settings active (not a simulation):

- `cat ~/.config/sops/age/keys.txt`, `python3 -c "print(open('.../.env').read())"` (a different
  reader — an interpreter one-liner), and `xxd .env` (a hex dumper) were all refused. The Python and
  `xxd` attempts against the real, existing `.env` file returned a genuine OS-level
  `PermissionError`/`Permission denied` — not a "file not found" or a tool-level message — proving
  the denial is enforced below the command layer, and survives switching readers, exactly as the
  acceptance criterion asks.
- `scripts/deploy --check` ran to completion with no sandbox friction at all, reaching its own
  preflight checks (which reported the real, expected state of this workstation: `sops`/`age` not on
  `PATH`, no store yet, no key yet at the conventional location) — the same clean preflight output it
  would produce unsandboxed. This is the sharpest proof available that the exemption works: the
  wrapper could freely check for `.env`'s existence and the age key's location, the exact two things
  every other command was just denied.
- `scripts/secrets check` (non-decrypting) ran without a permission prompt; `scripts/secrets fill`
  (decrypting) and a bare `env` were both refused at the permission layer before ever reaching the
  sandbox.
- **Not verified here, by design**: an agent-run playbook actually reaching a real VPS over SSH. This
  epic's own hard rule (enforced throughout every review round) is that no automated step in this
  repository's own tooling work ever connects to a real host. That specific check — an agent-run
  `scripts/deploy --check` genuinely opening an SSH connection to the real VPS while unsandboxed — is
  operator-validated at the next real deploy, the same treatment this epic already gives every other
  real-VPS-touching concern (the migration, the reboot drill, the live verification script).

## No secrets, no operator-specific paths (criterion #18)

Every path in this file is a conventional location (`~/.config/sops/age`, `~/.ssh`, `.env`) or a
repo-relative script path (`scripts/deploy`, `scripts/secrets`) — nothing here names this operator's
actual username, home directory, hostname, or any secret value.
