# Encrypted secrets in the repository: SOPS + age, not Ansible Vault or an external manager

Every credential this playbook needs used to live in a plaintext `.env`, sourced into the shell
before running Ansible and kept out of git entirely by convention. That meant the operator's real
values existed as plaintext on every workstation with no record of who had a copy, syncing a new
workstation meant manually copying that file over some other channel, and this repository's own
written standards (`.github/copilot-instructions.md`, `.github/instructions/ansible.instructions.md`)
told any agent working in it that the repository must hold no secrets at all and that Ansible Vault
or a third-party manager was the way to store one — a rule this repository no longer follows, on
purpose (see "Deviation from the written standards" below).

We chose **SOPS with age, dotenv format**: every credential the `secrets` resolver role reads is
encrypted, in this repository, permanently. Variable *names* stay visible in the ciphertext file —
the manifest (`group_vars/all/secrets.yml`) and the generated names-only template (`.env.template`)
already list every name in the repository regardless, so hiding them in the store would add no real
opacity, only friction.

## Alternatives considered and rejected

- **Ansible Vault**: a single shared password distributed out of band to every workstation — the
  exact syncing problem this change exists to solve, not a fix for it. A human-chosen password is
  also offline-crackable if the repository is ever made public (see below), and adopting it would
  force the `secrets` resolver's own seam to change, which every other design here was chosen to
  avoid touching.
- **git-crypt**: transparently decrypts files in the working tree once unlocked, meaning any tool
  running in that tree — including an agent — can read the plaintext the moment the repository is
  checked out and unlocked, which is a materially weaker boundary than SOPS's per-value encryption
  decrypted only into a wrapper's child process. It also encrypts whole files opaquely (no diff-level
  visibility into *what* changed), and has a well-known history footgun: a file committed before its
  git-crypt filter is configured is committed in plaintext, permanently, with no warning. It's also
  the least actively maintained of the three options considered.
- **Runner-up, if SOPS is ever reconsidered**: git-crypt with GPG, which at least fixes Vault's
  single-shared-password problem (each recipient has their own GPG key) — not chosen because it
  still inherits git-crypt's transparent-decryption and whole-file-opacity properties above.

## A private repository that may one day have a public export

Epic 24 builds a public-readiness export of this repository with the operator's identifying values
scrubbed. The encrypted store is **never part of that export** — it stays in the private repository
permanently, and the export process excludes both `secrets/secrets.enc.env` and `.sops.yaml`
entirely, rather than relying on the encryption alone to make a public copy safe. This matters for
two choices above that would otherwise look inconsistent with "might go public someday":

- **A random age key, not a human-chosen password**, specifically because Ansible Vault's rejection
  above (offline-crackable if public) doesn't apply to age's own key material — but the store isn't
  exported publicly regardless, so this is defense in depth, not the only thing standing between a
  public export and a leak.
- **Visible variable names are acceptable** in the encrypted file even under a "might go public"
  lens, because the same names are already public via the manifest and the generated template — a
  public export gains nothing by additionally hiding them, and the store itself is excluded from
  that export regardless.

## Agent guardrails: Tier 1, and its honest limit

An agent working in this repository needs to run real deployments without ever being able to read
the age key or the plaintext store — but the deploy wrapper it runs *does* need exactly that access.
Claude Code's own sandbox is configured (`.claude/settings.json`, `.claude/README.md`) to deny the
key's conventional location to every command except `scripts/deploy` itself, which is named in
`sandbox.excludedCommands`.

**The honest limit, stated plainly**: this is accident prevention, not a security boundary. An agent
that edits the wrapper, a role, or the playbook, and then runs the modified code, is not protected
against — the modified code runs with the full decrypted environment and can do anything with it,
including printing a re-encoded value past the redactor below. The age key lives on the same machine
the agent runs commands on; Tier 1 stops *accidents* (reading the key file directly, dumping the
environment, an unredacted diff), not a *determined actor* with edit access to this repository's own
code. Epic 22 ticket #08's own implementation additionally found, empirically, that the underlying
platform's exemption mechanism does not lift *network*-namespace isolation the way its documentation
implies — an agent-run deployment can decrypt the store correctly but cannot complete the SSH
connection to the VPS through the exemption alone; the only path is Claude Code's own
`dangerouslyDisableSandbox` escape hatch, deliberately evaluated case by case rather than a standing
capability (`.claude/README.md` has the full detail). **Tier 2** — a hardware-backed or
passphrase-gated age key, requiring a physical touch or unlock for every decrypt — is the documented
upgrade path that turns this into an actual cryptographic boundary; the wrapper already supports it
via `SOPS_AGE_KEY_CMD` with no code change required. Building Tier 2 is out of this epic's scope.

## Output redaction, and its limits

Every value decrypted by the wrapper is masked in its combined stdout/stderr as it streams — literal
form, JSON-escaped form (including non-ASCII escapes), and URL-encoded form — so a deployment can be
run and watched, including by an agent, without a secret reaching a terminal transcript. This is
defense in depth, not the only defense: a second layer (epic 22 #05) statically flags any task whose
arguments, registered result, or rendered output could contain a secret without `no_log: true`,
because redaction alone can't help with a value Ansible never streams to the wrapper's own output in
the first place (a file written to disk with no diff shown, for instance).

**Documented limits**: values shorter than a fixed minimum length are accepted as unmasked, since
redacting very short common strings would over-redact unrelated text constantly — the safe failure
mode is over-redaction of a *long* value, never under-redaction, and this tradeoff is made
explicitly in that direction. Encodings other than the three listed above (base64, for instance) are
not pattern-matched by the redactor at all; suppression at the source (the second layer) is what
covers those cases, not redaction.

## Deviation from the written standards

This repository's own agent-facing instructions (`.github/copilot-instructions.md`,
`.github/instructions/ansible.instructions.md`) previously stated, respectively, that the repository
must hold no secrets at all, and that Ansible Vault or a third-party manager was the way to store
one. Both are now updated to describe the model this ADR records: **encrypted** secrets are expected
and belong in the committed SOPS + age store — that is the design, not an exception being quietly
carved out — while a **plaintext** secret remains just as forbidden as before. This is a deliberate,
recorded deviation from what this repository told every prior agent session to do, not an oversight;
an agent reading the old wording alone, without this ADR, would have argued against committing
`secrets/secrets.enc.env` at all.

**Consequences**: every future workstation needs `sops` and `age` installed (`docs/secrets-runbooks.md`
covers per-OS installation) before it can do anything with this repository's secrets, where previously
only a text editor was needed for `.env`. Recipient management is now an explicit step
(`scripts/secrets add-recipient`/`remove-recipient`) rather than implicit file-sharing, which is the
point, but does mean onboarding and retiring a workstation are now named procedures instead of "copy
the file." The encrypted store's ciphertext is permanent in git history the moment it's committed;
removing a recipient or rotating the data key protects future access but never retroactively revokes
a version already pushed, which is why every incident-response runbook ends in rotating the
underlying credential itself, not just the encryption around it.
