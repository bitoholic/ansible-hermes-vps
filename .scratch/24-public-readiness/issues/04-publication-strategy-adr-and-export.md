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

**Unplanned discovery, fixed separately (not part of this ticket's own commit):** the generic tree-only
audit found one more leftover self-match predating this ticket — ticket #03's own fix commit (`4062e2b`)
described the bug in its ticket notes by writing the literal CGNAT address a third time, missed because
it landed in the same commit as the fix and wasn't re-scanned afterward. Fixed in a separate commit,
re-verified clean, before starting this ticket's own work.

Full `tests/lint.sh` passes end to end.
