# 10: Runbooks, README rewrite, standards update and ADR

**What to build:** The documentation matches reality, including the repository's own agent-facing standards: the README's secrets workflow is rewritten around the wrapper and the encrypted store, the two instruction files that currently tell agents to use Ansible Vault or an external manager and that the repository must hold no secrets are updated to describe the new model, the runbooks cover the situations the operator will actually meet, and an ADR records the choice and explicitly names the deviation from the written standards.

**Blocked by:** #09
**Blocks:** None

**Status:** ready-for-agent

- [ ] The README's local-secrets workflow is rewritten around the wrapper, the helper and the encrypted store
- [ ] **Both repository standards files are updated:** the general instruction stating the repository must not contain secrets now says *plaintext* secrets must never be committed and encrypted secrets live in the store; the Ansible instruction file's secret-management section describes the SOPS + age model instead of mandating Ansible Vault or an external manager
- [ ] Runbooks cover: onboarding a workstation (with per-OS tool installation), retiring a workstation, responding to a suspected key leak (remove the recipient, rotate the data key, and rotate the underlying credentials), and using the break-glass key
- [ ] The documentation states that removing a recipient does not protect secrets already in git history, and the plaintext-removal limits from #09
- [ ] A short procedure explains how a later epic adds a secret (one manifest entry plus one value, and a declared extra only if it is not a manifest credential)
- [ ] A new ADR (ADR-0007) records the SOPS + age choice against git-crypt and ansible-vault, the considerations of a private repository that may have a public export (the store stays in this private repository and is never exported; a random age key, not a password; visible names are acceptable), Tier 1 and its honest limit, the redaction design and its limits, and **names the deviation from the repository's previously written standards and why**
- [ ] The documentation is consistent with the generated environment template and the sync check

## Notes

See epic 22 spec, "Implementation Decisions" (runbooks; ADR and repository standards). The two standards files are agent-facing, so leaving them unchanged would make every future agent session start from the wrong rule.

## Implementation

**README.md**: the "Local Secrets Workflow" section was rewritten end to end around `scripts/deploy` and
`scripts/secrets` — the old `setup-env.sh`/plain-`.env`/`source .env`/`lookup('env', ...)` workflow it
described no longer exists (`setup-env.sh` was removed in ticket #04). New sections: first-time
workstation setup (with a link to the runbooks doc for per-OS tool install), store maintenance, running
deploys (unchanged flag examples, just via the wrapper instead of `ansible-playbook` + `source .env`),
and a short "Adding a new secret" procedure (manifest entry vs. declared extra, regenerate
`.env.template`, fill the value). Two other stale `.env` references were checked: the Beszel pairing
step (fixed — now points at `scripts/secrets edit`/`fill`) and the "delegated subagents share the
container filesystem" limitation (left unchanged — verified this refers to a *different*, real `.env`
the `hermes` role renders per-profile into the agent's own data directory, unrelated to this epic's
secrets store).

**Two agent-facing standards files** (criterion 2): `.github/copilot-instructions.md`'s blanket "MUST NOT
contain any secrets" is now "MUST NOT contain any *plaintext* secret" with the encrypted store named as
the deliberate exception, not an oversight. `.github/instructions/ansible.instructions.md`'s "Secret
Management" section no longer describes Ansible Vault's `vars`/`vault` file convention or a third-party
manager; it describes the manifest → store → wrapper flow and points at the resolver's single-seam rule
and the suppression-at-source static check, so an agent reading it wouldn't add a new `lookup('env',
...)` call or an unsuppressed secret-bearing task by following stale advice.

**`docs/secrets-runbooks.md`** (new, criteria 3–4): four runbooks — onboarding (with a per-OS `age`/`sops`
install table, and a note that `sops` ≥ v3.10.0 is preferred since older versions silently ignore
`SOPS_AGE_KEY_CMD` rather than erroring, per epic 22 #08's own finding), retiring a workstation,
responding to a suspected key leak (remove-recipient → rotate the data key → rotate the underlying
credentials themselves, in that order, matching what `scripts/secrets remove-recipient` already prints),
and using the break-glass key. A closing section states the git-history limit (removing a recipient
doesn't retroactively revoke a committed version) and the plaintext-removal limits from ticket #09
(SSD/copy-on-write overwrite unreliability; copies may exist in backups/sync tools/shell
history/other machines; rotate when exposure can't be ruled out) verbatim as that ticket's own notes
state them.

**ADR-0007** (criterion 5): records the SOPS+age-vs-Ansible-Vault-vs-git-crypt comparison (including the
git-crypt-with-GPG runner-up), the private-repo-with-possible-public-export considerations (the store is
excluded from epic 24's export entirely, not merely relying on encryption; why a random key and visible
names are still acceptable under that framing), Tier 1's honest limit including the network-namespace
gap epic 22 #08 found and its `dangerouslyDisableSandbox` workaround, the redaction design and its
documented limits (short-value non-redaction, encodings other than the three matched forms), and a
dedicated "Deviation from the written standards" section naming exactly what the two standards files
used to say and why this repository no longer follows that rule.

**Consistency with the generated template and sync check** (criterion 6): `.env.template` is generated
by `scripts/generate-env.py`, checked for drift by `tests/lint.sh` (`generate-env.py --check`) — verified
this mechanism already exists and needed no code change; the README's "Adding a new secret" procedure and
the ansible instructions file both point at it as the one names-only reference to regenerate, matching
what the sync check actually enforces.

**Verification**: `tests/lint.sh` re-run in full after all documentation changes — a pure documentation
ticket touches no code path the test suite exercises directly, but re-running confirms nothing was
broken and the sync check still passes.

## Review round 1 (independent fresh-context subagent): PASS, two cosmetic wording fixes applied

All 6 acceptance criteria verified PASS against the actual source (not just the new docs' own claims):
every command shown in README matched `scripts/secrets`/`scripts/deploy`'s real subcommands and flags;
both standards files' new claims (the single-seam lint check, the `EXTRA` list) verified against the
actual code; the runbooks' incident-response ordering verified to match `scripts/secrets
remove-recipient`'s own printed guidance verbatim; ADR-0007 cross-checked against `.claude/README.md`'s
already-reviewed account of the Tier 1 network gap with no overclaiming; the "delegated subagents share
the container filesystem" line confirmed to refer to a genuinely different, container-internal `.env`
(`roles/hermes/tasks/main.yml`), not a stale reference; no secret or operator-identifying value found in
any new/changed doc; both new anchors resolve correctly.

Two non-blocking wording nits: README claimed `setup-env.sh` "no longer exists" — it actually still
exists as a small redirect stub (prints a pointer to `scripts/secrets`, exits 1), so the literal
sentence was inaccurate even though the intended meaning (its old *behavior* is gone) was clear from
context. Fixed to say it "now only redirects to the tools below." Separately, the runbooks doc
described a pre-3.10.0 `sops` as "silently ignoring" `SOPS_AGE_KEY_CMD` — per ticket #08's own findings,
it actually fails with a misleading "not a recipient" error, not a silent no-op. Fixed to describe this
precisely. Both are wording-only; no factual claim about mechanism, command behavior, or file structure
was found wrong. Re-verified: full `tests/lint.sh` clean after both fixes.

**Ticket #10 is closed.** This is also the last ticket in epic 22 — every ticket (01 through 10) is now
implemented, reviewed, and closed, pending the operator's own full-epic review.
