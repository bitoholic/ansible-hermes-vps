# Public export

Epic 24 ticket #04 (reworked per the operator's request to preserve history — see ADR-0009's revision
note). Turns a **scrubbed copy of this repository's full history** — every commit, message and diff —
into a *separate* destination repository, under a commit identity the operator supplies. See
`docs/adr/0009-public-export-strategy.md` for why this rewrites a copy of history rather than
publishing either a flattened snapshot or this repository's own history in place, why the identity is
an operator input, and the threat model. See `docs/public-readiness-audit.md` for the audit this
export re-runs against its own result as a final gate.

## Development, tickets and the store stay here

This repository stays the one place development happens: tickets (`.scratch/`), ADRs, and the
encrypted secrets store (`secrets/secrets.enc.env`, `.sops.yaml`) all live only here, before and after
any export. The repository an export produces is **read-only output** — nobody files a ticket there,
edits code there, or clones it to make changes; re-running the export and pushing again **replaces**
whatever is there, it does not append to it (see "Re-running it" below).

A workstation that wants to publish needs only an **additional git remote** pointed at the public
repository, used solely to push the export's branch there after a run — every existing clone, remote
and workflow pointed at this private repository is unaffected.

## Running it

```
EXPORT_AUTHOR_NAME="NAME" EXPORT_AUTHOR_EMAIL="EMAIL" scripts/deploy --script export-public --dest DIR [--source DIR]
```

Must run through `scripts/deploy --script export-public`, exactly like `--script audit`: scrubbing
history needs the decrypted secret set to know what to replace, and the deploy wrapper is what decrypts
the store into the process's environment first. Running the script directly refuses (exit 2).

`EXPORT_AUTHOR_NAME` and `EXPORT_AUTHOR_EMAIL` are **required environment variables, not CLI flags** —
a real name needs a space, and the deploy wrapper's own injection defense (`SCRIPT_ARG_RE`) refuses any
script-mode CLI argument containing one. The command refuses to run (exit 2) without both set and
non-empty — there is no default identity (ADR-0009, "Commit identity: an operator input, not decided
here"). The actual identity to use is the operator's own call, recorded at go-live time (epic 24 #05),
not chosen by this script.

`--dest` is created if it doesn't exist. `--source` defaults to this repository; point it elsewhere
only for a test or a dry run against a scratch copy.

**What one run does:** clones `--source` (read-only; nothing is ever written back to it — verified by
comparing its refs and HEAD before and after), then runs one `git filter-repo` pass over every commit
reachable from every ref in that clone:
- removes `secrets/secrets.enc.env`, `.sops.yaml`, and any `*-git-crypt.key` path from **every**
  commit, not just HEAD;
- replaces every decrypted secret value, every `AUDIT_EXTRA_TERMS` entry, every tailnet CGNAT/ULA
  address and every credential-shaped string with a named placeholder, in file content **and**
  commit/tag messages, except whatever `audit-allowlist.yml` already names as deliberately public or a
  known-safe fixture value;
- rewrites every commit's and tag's author and committer to the supplied identity, unconditionally.

A commit that becomes empty once its only content was secrets-tooling state is pruned automatically
(`git filter-repo`'s own default behaviour) — this is expected, not a bug, and is covered directly by
`tests/check-export-public.sh`.

**Before the run is ever reported as done**, `--dest` is re-audited in full
(`scripts/public-readiness-audit.py`, whole history, same decrypted secret set) — a filtered result
that still has an unallowlisted finding makes the whole run exit 1 and print the finding (rule and
location, never matched text), never left sitting in `--dest` as if it were clean.

## Re-running it

Each run **replaces** `--dest`'s history from scratch, filtered fresh from `--source`'s current
(possibly longer) history — it is not an incremental append on top of a previous export. Pushing the
result of a second run to an already-public repository is a **history-replacing push**: anyone who
already cloned the previous export now has a history that has been rewritten out from under them. This
is fine before the repository is ever made public, and is exactly why epic 24 #05's go-live checklist
treats the actual visibility flip, and any push after it, as something only the operator decides to do.

## What a fresh clone of the export looks like

Neither `secrets/secrets.enc.env` nor `.sops.yaml` is present, at any commit. `scripts/check_secrets_
store.py` treats this as a valid, passing state (its mandatory-store rule is derived from
`.sops.yaml`'s presence; it is explicitly documented to pass with neither present) — no special-casing
is needed anywhere to make the standard lint run pass in the export.

## Testing

`tests/check-export-public.sh` (wired into `tests/lint.sh`), backed by `tests/support/export-
fixture.sh`'s throwaway multi-commit fixture repository (never the real repository), proves: the two
negative cases (no identity at all; name without email) refuse to run and create nothing; a symlinked
or source-nested `--dest` is refused outright; history is preserved (real commits survive; a commit
that becomes empty once the store/key are removed is correctly pruned); every commit's author and
committer is rewritten to the supplied identity; the encrypted store, `.sops.yaml` and the dead
git-crypt key are absent from every commit, not just HEAD; planted canaries (a plain secret value, a
real-looking tailnet address, a credential-shaped string, an `AUDIT_EXTRA_TERMS` value planted in a
commit message) are all scrubbed from both tree content and commit messages, while the functional CIDR
constant and an allowlisted fixture value both survive untouched; two secrets sharing an identical,
un-rotated value collapse into one consistent placeholder rather than corrupting each other (the
shared-value substitution-conflict regression); the source repository's refs, HEAD and working tree are
completely unchanged by the run; and a fresh clone of the destination passes `check_secrets_store.py`.
