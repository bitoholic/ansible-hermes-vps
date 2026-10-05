# 04: Publication strategy ADR and the export procedure

**What to build:** The way a public version of the repository would be published is decided, recorded and rehearsable: an ADR sets out the derived-export strategy (a separate public repository whose history is only export snapshots; this private repository stays the working repository and the permanent home of the encrypted secrets file) and why an in-place history rewrite was rejected; and a repeatable export procedure turns the scrubbed tree — minus the encrypted secrets file and the recipient configuration — into snapshots in that repository under a commit identity **the operator supplies**, without ever touching this repository's history, visibility or store. The author name is the operator's to give; this ticket builds the mechanism that requires it and does not pick it.

**Blocked by:** #02
**Blocks:** #05

**Status:** done

- [x] A new ADR (ADR-0009) records the strategy — a separate public repository as a derived export whose history consists only of export snapshots — and the rejected alternatives (an in-place history rewrite and force-push; flipping this repository's visibility as it stands; moving development to the public repository)
- [x] **The ADR records the operator's decision that the encrypted secrets file and the recipient configuration stay in this private repository, during and after migration and publication, and are never part of the public export**, with the reasoning (publishing ciphertext of every credential and identifying value would be permanent, and a future recipient-key leak would expose them all)
- [x] **The commit identity is an operator input, not decided here:** the ADR explains that every existing commit already uses a GitHub no-reply address (so that alone changes nothing) and that the operator's real full name is the author name on the large majority of existing commits, and leaves the chosen author name and email as a field the operator fills in (recorded in #05); the export procedure takes the identity as a required parameter and **refuses to run without it**, shown by a negative test
- [x] The ADR's threat-model note covers: what a clean public repository still reveals (composition, versions, architecture); that the no-reply address embeds the account handle, which matches a label of the operator's domain; that certificate-transparency logs and DNS expose hostnames regardless of the repository; and what stays exposed in the *private* repository (ciphertext and recipient public keys), so its account security and access grants still matter
- [x] The export procedure creates or extends the public repository with a snapshot of the scrubbed tree under the supplied identity, excluding the encrypted secrets file, the recipient configuration and any other secrets-tooling state by an explicit list, and is deterministic and re-runnable into a scratch destination
- [x] The procedure never modifies this repository's history, refs, visibility or store
- [x] **The standard lint run passes in a fresh clone of the export** (which has no encrypted store and no recipient configuration), because the structural guard's mandatory state is derived from the recipient configuration's presence (epic 22 #03)
- [x] The documentation states that development, tickets and the encrypted store stay in this private repository and the public repository is export-only, and what (an optional extra remote for publishing) workstations need
- [x] A fixture test shows the export produces a repository whose history contains only the intended snapshots and the supplied identity, with the encrypted secrets file and the recipient configuration absent

## Notes

See epic 24 spec, "Implementation Decisions" (publication strategy; the encrypted store never goes public; export exclusions; threat-model note). The operator decided to keep the store in this private repository after reviewing the earlier include-or-exclude question.

**Built:**
- `docs/adr/0009-public-export-strategy.md`: the decision (derived export, separate repository, snapshot-
  only history), the three rejected alternatives, the encrypted-store-never-exported decision with
  reasoning, the operator-supplied-identity requirement (with the 180/186-commit real-name context),
  the threat-model note, a "what stays where" section, and consequences. Cross-referenced from — and
  cross-references back to — ADR-0007's existing "A private repository that may one day have a public
  export" preview section, reworded slightly so the two don't duplicate the same reasoning twice.
- `scripts/export-public.py`: `--dest`/`--author-name`/`--author-email` (all but `--source` required;
  argparse itself refuses to run without the identity, satisfying the negative-test AC). Reads
  `--source`'s HEAD tree via `git archive` (never the working tree), skips `secrets/secrets.enc.env`
  and `.sops.yaml` — an explicit, exact list, not a glob — while extracting, so their bytes never touch
  `--dest`'s filesystem even transiently; prunes the now-empty `secrets/` directory left behind by the
  excluded file's own tar entry. Commits with the supplied name/email as both author AND committer via
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*`, `--allow-empty` so a run always produces one new commit. Refuses to
  run (exit 2) if `--dest` resolves inside `--source`, since the destination's stale content is cleared
  before each run and clearing the source repository itself would be catastrophic. Only read-only git
  commands (`rev-parse`, `archive`) ever run against `--source`.
- `tests/check-export-public.sh` (wired into `tests/lint.sh`): a throwaway source fixture (its own
  minimal manifest + `scripts/generate-env.py` stub + `.gitignore`, needed for `check_secrets_store.py`
  to run meaningfully against the clone) proving: both negative cases refuse and create nothing; the
  first export carries the tree but not the store, `.sops.yaml`, or even an empty `secrets/` directory;
  the source repository's refs/HEAD/working tree are byte-for-byte unchanged after the run; a fresh
  clone of the destination passes `check_secrets_store.py` (the neither-present state); a second run
  against a changed source extends the destination with one more commit built on the first, never
  rewriting it; a destination nested inside the source is refused.
- `docs/public-export.md`: the operator-facing procedure doc — what stays private vs. export-only, the
  "additional remote" framing for workstations, how to run it, what a fresh clone looks like, and a
  reminder that the export mechanism does not re-run the content-policy scrub, so a `--dest` built from
  an unscrubbed source is not retroactively made safe.
- One-line cross-reference added to ADR-0007's existing public-export section, pointing at ADR-0009 for
  the full strategy, so the two documents don't restate the same reasoning independently.

**Fixed after independent review (two parallel fresh-context agents — Standards, Spec-conformance)**:
- Both independently caught the same real bug: every internal refusal (`sys.exit(f"...")` with a
  string) actually exited **1**, not the **2** the docstring and `docs/public-export.md` both claimed
  for "cannot run" — only argparse's own missing-required-argument path happened to exit 2. The test
  only asserted `RC -ne 0`, so it never caught the mismatch. Fixed with a `fail()` helper that always
  exits 2; every internal refusal now goes through it; the fixture test was tightened to assert the
  exact code (`-eq 2`), not just non-zero, on every negative case.
- Standards review additionally found and demonstrated a real gap: pointing `--dest` at a symlink
  whose target held pre-existing, unrelated content caused `clear_destination()` to wipe that target's
  content with no warning (`refuse_if_nested`'s realpath check correctly let it through, since the
  target genuinely wasn't nested inside `--source` — the bug was that a symlinked `--dest` was never
  refused at all). Fixed with a new `refuse_if_symlink()` check (exit 2) before anything is touched;
  added a negative-test case that plants real content behind a symlinked `--dest` and asserts it
  survives the refusal untouched.
- Spec review additionally flagged that AC #7's literal wording ("the standard lint run passes in a
  fresh clone") is tested more narrowly than written — the fixture test only runs
  `check_secrets_store.py` against the clone, not the real `tests/lint.sh` (which can't run
  meaningfully against the minimal fixture — it isn't a real Ansible repository). Addressed by actually
  running `scripts/export-public.py` against **this real repository** into a scratch destination,
  cloning that, and running the real `tests/lint.sh` there by hand: it passes end to end (exit 0,
  including ansible-lint and every check script). The fixture test's header comment now explains this
  split and points at this note rather than silently narrowing the AC.

Re-verified clean (fixture test, generic tree-only audit, full `tests/lint.sh`, and the by-hand real-
export-plus-full-lint-run above) after all three fixes.

**Unplanned discovery, fixed separately (not part of this ticket's own commit):** the generic tree-only
audit found one more leftover self-match predating this ticket — ticket #03's own fix commit (`4062e2b`)
described the bug in its ticket notes by writing the literal CGNAT address a third time, missed because
it landed in the same commit as the fix and wasn't re-scanned afterward. Fixed in a separate commit,
re-verified clean, before starting this ticket's own work.

Full `tests/lint.sh` passes end to end.

## Redesign: history-preserving export (2026-10-05)

After this ticket's original build (the flattened-snapshot export above) and the real-repository dry
run for #05, the operator rejected the snapshot design on review: the point of publishing was to show
this project's actual development history, not collapse it into one commit. Decided (operator, via
`AskUserQuestion`): rewrite a scrubbed **copy** of the full history instead (every commit, message and
diff preserved, minus identifying content and the secrets-tooling files), using `git filter-repo`'s
`--source`/`--target` split so the original repository is never touched; and open PR #111 for the
epic's tooling (tickets #01–#03) into `main` regardless of how this question resolved.

**Rebuilt:**
- `scripts/export-public.py`: rewritten from the `git archive HEAD` single-snapshot version to a
  `git filter-repo` pass over a clone of `--source`'s full history. `--author-name`/`--author-email`
  CLI flags replaced by required `EXPORT_AUTHOR_NAME`/`EXPORT_AUTHOR_EMAIL` environment variables (a
  real name contains a space, which the deploy wrapper's `SCRIPT_ARG_RE` injection defense rejects as a
  script-mode CLI argument — the same pattern already used for `TARGET_HOST`/`AUDIT_EXTRA_TERMS`, not a
  workaround). Removes `secrets/secrets.enc.env`, `.sops.yaml` and any `*-git-crypt.key` path from every
  commit via `--invert-paths`; scrubs every decrypted secret value, `AUDIT_EXTRA_TERMS` entry, tailnet
  CGNAT/ULA address and credential-shaped string from file content **and** commit/tag messages via
  shared `--blob-callback`/`--message-callback` logic; rewrites every commit's and tag's author and
  committer to the supplied identity unconditionally; re-audits the result in full before ever reporting
  success. Must run through `scripts/deploy --script export-public`, exactly like `--script audit`.
- `scripts/history_scrub.py` (new): the one shared `scrub_bytes(data, literal_pairs, generic_rules)`
  function both callbacks call, so file content and commit messages are scrubbed by identical logic,
  never two copies that could drift. Applies `literal_pairs` as **one single-pass combined regex**,
  never sequential `.replace()` calls — multiple secrets left at the same un-rotated default value
  (e.g. several `*_ADMIN_USERNAME` entries still saying "admin") would otherwise generate several
  substitution pairs sharing an identical `old`, and applying them one after another lets a later pair
  re-match text an earlier pair just wrote (every placeholder is itself English-ish and can contain a
  substring a later rule is still searching for), producing nested garbage like
  `<secret-a-<secret-b-admin>-admin>`. `export-public.py`'s `build_literal_pairs` groups the audit's own
  `build_denylist_terms()` output **by value**, not by secret name, before generating pairs — skipping
  the whole group if any sharing secret is `"*"`-allowlisted — mirroring the same dedup the audit's own
  `build_needle_rules()` already does for findings.
- `tests/support/export-fixture.sh` (new) / `tests/check-export-public.sh` (rewritten): a throwaway
  fixture repository with real, multi-commit history (an init commit, a canary-content commit, an
  encrypted-store-then-removed commit, a later real change carrying a commit-message canary) replaces
  the old minimal single-tree fixture. Proves: history is preserved (real commits survive; the
  now-empty secrets-only commit is correctly pruned by `git filter-repo` itself); every commit's
  identity is rewritten; the store/`.sops.yaml`/dead git-crypt key are absent from **every** commit, not
  just HEAD; a plain secret, a real tailnet address, a credential-shaped string and an
  `AUDIT_EXTRA_TERMS`-carried commit-message canary are all scrubbed from tree content and commit
  messages alike, while the functional CIDR constant and an allowlisted fixture address both survive;
  two secrets sharing an identical, un-rotated value collapse to one consistent placeholder instead of
  corrupting each other; `--source`'s refs/HEAD/working tree are unchanged; a fresh clone of the result
  passes `check_secrets_store.py`.
- `docs/adr/0009-public-export-strategy.md` / `docs/public-export.md`: rewritten to describe the
  history-preserving mechanism, with the snapshot design kept as a documented, explicitly rejected
  alternative (reason: lost real development history, the operator's stated objection) rather than
  silently dropped.
- Five rounds of `audit-allowlist.yml` fixes against the **real repository's** dry-run export (not the
  fixture): widening two admin-username secret entries and the GIT_USERNAME/GIT_EMAIL entries from
  `"commit:*"`/`"tree:*"` scope to `"*"`, since the full history-scan audit finds the same already-
  allowlisted content again under `history:FILE@SHA:LINE` locations, which the narrower scopes didn't
  cover; three further entries for the first-address-in-the-CGNAT-range fixture/mistake-coincidence
  collision (see ticket #03's own notes for the same recurring pattern), one of them a sha-pinned
  `commit:<sha>:message` entry (re-pinned twice as code changes shifted rewritten hashes).

**Debugging notes, fixture test (resolved):**
- "the commit-message canary survived unscrubbed" despite the export itself reporting a clean audit —
  root cause: the canary was arbitrary free text with no backing scrub rule at all (not a declared
  secret, not a generic-rule shape) — nothing in the design was ever going to scrub unlisted free text
  from a commit message. Fixed by routing the canary through `AUDIT_EXTRA_TERMS` (a real, existing
  mechanism `build_denylist_terms()` already folds in), which also gives the fixture explicit coverage
  of that pathway feeding into the history scrub, not just the audit.
- A later "nested/corrupted placeholder text found" failure was the test's own false positive: its
  blanket `grep` over the whole exported tree matched `scripts/history_scrub.py`'s own docstring (which
  quotes the corruption bug's shape as a worked example) and a `<<` bitshift operator in
  `scripts/hermes_secrets.py` — both are verbatim copies of this repository's real source, carried into
  the export because they aren't secrets. Fixed by scoping that check to `$DEST/notes` (the fixture's
  own planted canary content), not the whole tree.

Re-verified clean: the fixture test end to end, and the full `tests/lint.sh` (ansible-lint, every check
script, the rebuilt export-public guard) against the real repository.

**Not yet done, carried into #05:** re-running the real-repository dry-run export one more time with
this rebuilt mechanism (the real dry-run proofs above predate the `AUDIT_EXTRA_TERMS`/nested-placeholder
fixes, though neither fix changes the real export's own behavior — both were fixture-test-only issues);
independent review of this rework; redoing the push to `bitoholic/ansible-hermes-vps` (which currently
still holds the OLD single-snapshot push) with the history-preserving result.
