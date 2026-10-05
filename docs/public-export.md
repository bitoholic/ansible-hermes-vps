# Public export

Epic 24 ticket #04. Turns this repository's current tree into one new commit in a *separate*
destination repository, under a commit identity the operator supplies. See `docs/adr/0009-public-
export-strategy.md` for why this is a derived export rather than an in-place history rewrite, why the
identity is an operator input, and the threat model. See `docs/public-readiness-audit.md` for the audit
that should already be clean (`scripts/deploy --script audit`) before any export is ever actually
pushed somewhere public.

## Development, tickets and the store stay here

This repository stays the one place development happens: tickets (`.scratch/`), ADRs, and the
encrypted secrets store (`secrets/secrets.enc.env`, `.sops.yaml`) all live only here, before and after
any export. The repository an export produces is **read-only output** — nobody files a ticket there,
edits code there, or clones it to make changes; it only ever receives new snapshots from a later run of
this procedure, from here.

A workstation that wants to publish needs only an **additional git remote** pointed at the public
repository, used solely to push the export's branch there after a run — every existing clone, remote
and workflow pointed at this private repository is unaffected.

## Running it

```
python3 scripts/export-public.py --dest DIR --author-name "NAME" --author-email "EMAIL" [--source DIR]
```

`--author-name` and `--author-email` are required; the command refuses to run (exit 2) without both —
there is no default identity (ADR-0009, "Commit identity: an operator input, not decided here"). The
actual identity to use is the operator's own call, recorded at go-live time (epic 24 #05), not chosen
by this script.

`--dest` is created if it doesn't exist and initialized as a fresh git repository on the first run; a
later run reuses it and adds one more commit on top. `--source` defaults to this repository; point it
elsewhere only for a test or a dry run against a scratch copy.

**What one run does:** reads `--source`'s HEAD tree via `git archive` (never the working tree — an
uncommitted local change is never exported), skips exactly `secrets/secrets.enc.env` and `.sops.yaml`
while extracting (their bytes are never written to `--dest`'s filesystem, not even transiently), and
commits the result with the supplied name and email as both author and committer. It never writes to
`--source` — only `git rev-parse` and `git archive` are run against it.

**Before ever pushing a real export somewhere public:** run the full audit against `--dest` itself
(`python3 scripts/public-readiness-audit.py --generic-only --tree-only --root DEST`, or the full,
key-backed audit pointed at it) — the export mechanism removes the two named secrets-tooling files, it
does not re-run the content-policy scrub, so a `--dest` built from a tree that was never scrubbed in
the first place is not retroactively made safe by exporting it.

## What a fresh clone of the export looks like

Neither `secrets/secrets.enc.env` nor `.sops.yaml` is present. `scripts/check_secrets_store.py` treats
this as a valid, passing state (its mandatory-store rule is derived from `.sops.yaml`'s presence; it is
explicitly documented to pass with neither present) — no special-casing is needed anywhere to make the
standard lint run pass in the export.

## Testing

`tests/check-export-public.sh` (wired into `tests/lint.sh`) builds a throwaway source repository and
proves: the two negative cases (no identity at all; name without email) refuse to run and create
nothing; a first export carries the tree but not the store or `.sops.yaml` (not even as an empty
directory); the source repository's refs, HEAD and working tree are unchanged by the run; a fresh clone
of the destination passes `check_secrets_store.py`; a second run against a changed source extends the
same destination with one more commit, built on top of the first, never rewriting it; and a destination
that resolves inside the source is refused outright (it would otherwise be cleared along with the
source's own tracked files).
