# Spec: Encrypted secrets in the repo, and deployments that cannot leak them

> Status: ready-for-agent
> Source: Epic 22 — operator request. The list of environment variables has grown to 37, the operator works from several workstations and syncs a plaintext `.env` between them by hand, and wants the secrets in the repository, encrypted. Deployments must remain runnable by an AI agent without any secret value reaching a chat transcript, and the repository may one day become public.
> Related: `01-secret-manifest` (the single-seam resolver this epic deliberately leaves untouched), `04-backup-sync-module` (uses git-crypt for the *wiki* backup repository — a separate repository and key, unaffected), epic 24 (public readiness — depends on this epic), epic 23 (adds new manifest entries that land in whichever store exists).
> Vocabulary: see `CONTEXT.md` — **encrypted secrets file**, **recipient**, **break-glass key**, **deploy wrapper**, **output redaction**. Also: "the seam" = the `secrets` resolver role, the only reader of credentials.

## Problem Statement

Today every credential lives in a plaintext `.env` at the repository root that the operator `source`s before running Ansible. That has four problems the operator now feels:

1. **Syncing.** The operator uses several workstations. Getting the same `.env` onto each of them is manual, error-prone, and drifts. The list keeps growing (37 variables and rising).
2. **Plaintext at rest, in reach of tools.** The file sits in the working tree where any editor, script or agent can read it.
3. **Deployments leak by construction.** Running the playbook with `--diff` (the documented preview) or verbose flags prints rendered templates, several of which contain credentials (an API token in the compose file, a registration secret in the Matrix config, password hashes). The operator wants an AI agent to be able to run deployments; that output would put secrets into a chat transcript.
4. **Everything is secret, and the repo may go public.** The operator counts logins and their private domain as secrets, and may publish the repository later. The domain is also hardcoded in one place in the gateway template and in a test fixture, so even a perfect encrypted store would leave a plaintext copy behind.

## Solution

The credentials move into the repository as a single **encrypted secrets file** (SOPS + age, dotenv format, values only encrypted), decryptable by one age key per workstation plus an offline break-glass key. Only public keys are ever shared between machines. A **deploy wrapper** becomes the only way to run Ansible against the VPS: it decrypts the file into the playbook process's environment (never to disk), runs the playbook, and redacts every decrypted value from everything it prints. The `secrets` resolver role — which already reads credentials only from the environment — is not changed at all, so no role and no existing test has to change. Secret-bearing tasks suppress their diffs as a second layer; the operator's agent tooling is fenced away from the key and the plaintext with committed guardrails (Tier 1); the hardcoded domain becomes a template value; and a structural guard makes it impossible to commit a plaintext secrets file. The hardware-backed-key upgrade path (Tier 2) is documented but not built.

## User Stories

1. As the operator, I want all my credentials stored in the repository in encrypted form, so that a `git pull` on any workstation gives me every secret I need.
2. As the operator, I want each workstation to have its own key, so that I never copy secret material between machines.
3. As the operator, I want only public keys to be shared and committed, so that adding a workstation cannot expose anything.
4. As the operator, I want a new workstation onboarded by generating its key and having an existing workstation add its public key, so that onboarding is a two-minute procedure.
5. As the operator, I want a lost or retired workstation removed from the recipient list with one command, so that it stops being able to read future changes.
6. As the operator, I want documentation to say plainly that removing a recipient does not protect secrets already in git history, and that a compromised key means rotating the underlying credentials too, so that I respond to a leak correctly.
7. As the operator, I want an offline break-glass recipient, so that losing every workstation does not lock me out of my own infrastructure.
8. As the operator, I want a documented place to keep the break-glass private key, so that I actually do.
9. As the operator, I want a single command to run a deployment, so that I never have to remember the decrypt-and-run incantation.
10. As the operator, I want the deploy wrapper to pass through my normal Ansible flags (check mode, diff, tags, skip-tags, limits), so that every workflow I use today still works.
11. As the operator, I want the deploy wrapper to read the target host from the encrypted store, so that it is not a separate thing to set on each machine.
12. As the operator, I want the deploy wrapper to check its own prerequisites first (tools installed, my key present and not world-readable, the encrypted file valid, required secrets present), so that a mistake produces a clear message instead of a half-run playbook.
13. As the operator, I want the deploy wrapper to report which required secrets are missing by name only, so that the diagnosis never prints a value.
14. As the operator, I want decrypted values to exist only in the playbook process's environment, so that no plaintext file is ever created.
15. As the operator, I want every decrypted value replaced by a mask in everything the wrapper prints — standard output and standard error — so that I can run and share deployments without secrets appearing.
16. As the operator, I want redaction to cover values as they appear escaped in JSON and encoded in URLs, so that Ansible's own formatting can't slip a secret through.
17. As the operator, I want redaction to be applied even under maximum verbosity, so that debugging a deployment is safe too.
18. As the operator, I want the wrapper's output to stream live and its exit status to match the playbook's, so that redaction changes nothing about how a deploy behaves.
19. As the operator, I want a test that deliberately tries to print a canary secret through a debug message, a rendered diff and verbose task arguments and proves none of it appears, so that the redaction guarantee is verified rather than hoped for.
20. As the operator, I want tasks that render secret-bearing files to suppress their diff output regardless of the wrapper, so that the wrapper is not the only line of defense.
21. As the operator, I want a static check that flags a secret-bearing template task lacking diff suppression, so that a future service can't reintroduce the leak.
22. As the operator, I want a command to edit the encrypted store in my editor with the values decrypted only in memory, so that changing a secret is easy.
23. As the operator, I want a guided way to fill in missing secrets with hidden input, so that first-time setup is friendly and never echoes a value.
24. As the operator, I want a command that compares the encrypted store's variable names with the secret manifest and reports what is missing or extra, so that the store and the manifest can't drift.
25. As the operator, I want the generated names-only environment template to stay in sync with the manifest, so that it keeps documenting what is required.
26. As the operator, I want a structural guard proving the tracked secrets file is genuinely encrypted (encryption metadata present, no cleartext value), so that a committed plaintext file is impossible to miss.
27. As the operator, I want that guard to also fail if any other tracked file looks like a plaintext secrets file, so that a stray copy can't slip in.
28. As the operator, I want `.env` to stay git-ignored as a tripwire, so that a leftover plaintext file can't be committed by accident.
29. As the operator, I want my existing `.env` imported into the encrypted store without any value being printed, so that migration cannot itself leak.
30. As the operator, I want the migration to verify that the encrypted store decrypts to exactly the same set of names and values as the old file, so that I know nothing was lost or altered.
31. As the operator, I want a documented, secure removal of the plaintext `.env` on every workstation after migration, so that the old copies don't linger.
32. As the operator, I want my agent tooling denied direct access to my age key file, the plaintext `.env`, and commands that decrypt or dump the environment, while still allowed to run the deploy wrapper, so that an agent can deploy but cannot read secrets by accident.
33. As the operator, I want those guardrails committed with the project so they follow me to every workstation.
34. As the operator, I want the documentation to state honestly that these guardrails prevent accidents rather than a determined actor (the key is on the same machine), so that I don't over-trust them.
35. As the operator, I want a documented upgrade path to a hardware-backed key that requires a physical touch for each decrypt, and I want the wrapper designed so that switching to it needs no rewrite, so that I can raise the guarantee later.
36. As the operator, I want the gateway template's hardcoded domain replaced by the secret domain value, so that no plaintext copy of my domain remains in code.
37. As the operator, I want the legacy Caddyfile test fixture to use a placeholder domain, so that tests don't carry my real one.
38. As the operator, I want credential-bearing files on the VPS restricted to the users and containers that actually read them, so that a co-resident account can't read the compose file or the Matrix config.
39. As the operator, I want that tightening to keep the admin user able to run `docker compose` as they do today, so that the fix doesn't break my workflow.
40. As the operator, I want the README's secrets workflow rewritten around the wrapper and the encrypted file, so that the documentation matches reality.
41. As the operator, I want an ADR recording why SOPS + age was chosen over git-crypt and ansible-vault, the public-repository considerations, and the Tier 1 decision, so that the reasoning survives.
42. As a future maintainer, I want the single-seam lint check to keep passing untouched, so that only the resolver ever reads credentials from the environment.
43. As a future maintainer, I want tests to run without the operator's real key, using a throwaway key generated at test time, so that CI-like runs never need real secrets.
44. As a future maintainer, I want new manifest entries (like the exit-node credentials in epic 23) to work unchanged with the encrypted store, so that adding a secret is one manifest entry plus one value.

## Implementation Decisions

- **Tool choice: SOPS with age, dotenv format.** Values are encrypted; variable names stay visible — acceptable because the manifest and the names-only template already list every name in the repository. **Rejected:** ansible-vault (a single shared password to distribute — the exact syncing problem — and, with a human-chosen password, offline-crackable if the repo goes public; it would also force the resolver to change); git-crypt (leaves plaintext in the working tree once unlocked, where any tool can read it; whole-file opacity; history footgun if a file is committed before its filter is set; least maintained). Runner-up if SOPS is ever reconsidered: git-crypt with GPG.
- **One encrypted file holds everything.** It contains every value the resolver reads — including ones that would not be secret in a private repository (domain, usernames, the target host, git identity, admin SSH public key) — because the operator treats them all as secret. Moving non-secret values into plain variables is explicitly not done.
- **The seam is untouched.** The deploy wrapper injects the decrypted values as environment variables for the playbook process only; the `secrets` role remains the only reader; the manifest, the resolver, every role and every existing resolver test are unchanged. The single-seam lint check keeps passing as-is.
- **Recipients.** A committed SOPS configuration lists one age public key per workstation plus one offline break-glass key, scoped to the encrypted file's path so any future encrypted file inherits the rule. Adding or removing a recipient re-encrypts the file's data key for the new set.
- **Deploy wrapper.** The single entry point for running the playbook. Responsibilities: preflight (SOPS and age installed; the operator's key present with safe permissions; the encrypted file valid; required manifest names present, reported by name only); decrypt into the child process environment only; run the playbook with every extra argument passed through; read the target host from the store; stream output live through the redactor; return the playbook's exit status. A plaintext `.env` left in the tree produces a warning.
- **Output redaction.** The redaction set is every decrypted value at or above a minimum length (default four characters; configurable), matched literally and in their JSON-escaped and URL-encoded forms, masked in stdout and stderr. Over-redaction of a short common value is accepted as the safe failure mode; under-redaction of other encodings (for example base64) is a documented limit, covered instead by diff/log suppression at the task level.
- **Second layer: suppression at the source.** Any task that renders or writes a file containing secret values suppresses diff output (and log output where the module would echo it). A static check flags a task that renders a secret-bearing template without suppression. Redaction is defense in depth, not the only defense.
- **Secrets helper.** A companion command for maintenance: edit the store (decrypted only in memory), report names missing from or extra to the manifest, guided hidden-input fill of missing values, add and remove recipients, rotate the data key, and initialize a new workstation's key. It replaces the interactive environment-prompting script. The names-only environment template continues to be generated from the manifest, and the existing sync check keeps it honest.
- **Agent guardrails (Tier 1).** Project-scoped agent settings, committed with the repository, deny reading the operator's age key file and the plaintext `.env` and deny commands that decrypt the store or dump the environment, while allowing the deploy wrapper. Documented as accident prevention, not a security boundary. **Tier 2** (age key on a hardware token or passphrase-protected, requiring a touch or unlock for each decrypt) is documented as the upgrade path; the wrapper takes its key source from configuration so adopting Tier 2 needs no rewrite; building it is out of scope.
- **Domain de-hardcoding.** The one hardcoded domain in the gateway template's Authelia forward-auth URL becomes the secret domain value; the legacy Caddyfile test fixture uses a placeholder domain. The variable currently named for SilverBullet's domain continues to serve as the stack-wide domain (renaming it is out of scope).
- **Secrets at rest on the VPS (included by author decision; droppable).** An audit on the live host found the rendered compose file (holds API tokens and service passwords), the gateway Caddyfile (holds a Basic-auth hash), and the Matrix homeserver config (holds the registration secret) readable by every local account. Each is tightened to least privilege by reader — for example the compose file to root with the docker group (so the admin user can still run `docker compose`), container-read-only configs to the user or root the container actually runs as — verified not to break any container or the admin's own workflow.
- **Migration.** A one-time, attended import of the existing `.env` into the encrypted store on the first workstation, with an in-memory verification that the decrypted names and values equal the old file's (compared by digest, nothing printed), then documented secure removal of every plaintext copy. `.env` stays git-ignored.
- **Structural guard.** A static check asserts: the tracked secrets file carries SOPS metadata and every value is encrypted; no other tracked file matches a plaintext-secrets pattern; `.env` is untracked; the encrypted file's variable names equal the manifest's environment names.
- **Runbooks.** New-workstation onboarding (including per-OS tool installation), retiring a workstation, responding to a suspected key leak (remove the recipient, rotate the data key, rotate the credentials themselves), and using the break-glass key.
- **Wiki backup untouched.** The wiki backup repository's own git-crypt key and workflow are a separate concern; a dead key committed early in this repository's history is handled in epic 24.
- **ADR.** A new ADR (next available number) records the tool comparison, the public-repository considerations, the Tier 1 decision and the honest limit of the guardrails.

## Testing Decisions

- **What makes a good test here:** treat the deploy wrapper as a black box — run it, look only at what it prints, what it exits with, and what the child process received. Never assert on the wrapper's internals or on which redaction algorithm it uses.
- **Seams (existing seams preferred):**
  - The resolver seam stays where it is; the existing resolver test (`tests/check-resolver.sh`) and the single-seam lint check must keep passing *unchanged* — that unchanged pass is itself the proof the seam held.
  - **One new seam, at the highest level:** the deploy wrapper end to end, against a fixture. A throwaway age key is generated at test time; a fixture store holds canary values; a fixture playbook deliberately emits a canary through a debug message, a rendered diff and a verbose task argument. Assertions: no canary appears in the combined output; the resolver received the values; the exit status matches; output streamed. No real key or secret is ever needed.
  - The structural guard and the diff-suppression check are static checks added to the standard lint run, in the same style as its existing guards.
- **Tools required:** SOPS and age are treated like ansible-lint — the lint run fails clearly if they are missing rather than skipping silently.
- **Not testable in CI, operator-validated:** the real migration, and a real first `--check` deployment through the wrapper on the operator's workstation.
- **Prior art:** `tests/check-resolver.sh`; the `scripts/generate-env.py --check` sync guard and the single-seam and placeholder guards in `tests/lint.sh`; the "static guard with an honest what-it-doesn't-prove header" framing in `tests/check-tailnet-caddy-access.sh`; the rendered-file assertions in `tests/test_docker_compose.yml`.

## Out of Scope

- **Tier 2** (hardware-backed or passphrase-gated key) — documented as an upgrade path only.
- Moving non-secret values into plain group variables.
- Renaming the SilverBullet-domain secret to a stack-wide name.
- Generating secrets on the VPS instead of storing them.
- A hosted secrets manager, a password-manager integration, or any CI system.
- Proactively rotating existing credentials (only required if a key is ever suspected compromised).
- Making the repository public, scrubbing docs, and history (epic 24).
- The wiki backup's git-crypt key and workflow.
- Windows workstations.
- Agent guardrails beyond deployment (general command policy).

## Further Notes

- **The honest limit.** The age key lives on the same machine where the agent runs commands, so Tier 1 stops accidents (reading the file, dumping the environment, printing a diff) but not a determined actor. That trade-off was chosen deliberately; Tier 2 is the way to make it a cryptographic boundary.
- **The biggest leak vector today is output, not storage.** `--diff` and verbosity print rendered secrets whether the store is plaintext or encrypted; that is why redaction and diff suppression are part of this epic and not a nice-to-have.
- **Ordering.** Independent of epics 21 and 23 (which only add manifest entries). Epic 24 depends on this epic — its scanner uses the deploy wrapper and the decrypted secret set.
- **Compatibility note.** Because ciphertext in a public repository is permanent and harvestable, the design deliberately uses a random age key (never a human-chosen password) so there is nothing to brute-force offline; the practical risk is key leakage, not the cipher.
