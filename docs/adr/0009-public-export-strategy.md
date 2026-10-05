# Publishing a public version: a history-preserving, scrubbed export to a separate repository

Epic 24 makes it possible to publish a public version of this repository without exposing the
operator's identifying values (CONTEXT.md: **public-readiness audit**). This ADR records *how*
publication itself works, once the audit is clean (epic 24 #01/#02/#03): a **history-preserving
export** — every commit, message and diff this repository has ever had, rewritten in place (on a copy)
to scrub identifying content and drop the secrets-tooling files from every commit, then committed into
a **separate public repository** under an identity the operator supplies. This private repository is
unaffected: its history, visibility, and the encrypted store all stay exactly as they are, forever,
independent of whether or when a public export ever happens.

**Revision note (2026-10-05):** this ADR originally chose a single flattened snapshot instead (see
"Rejected: a flattened snapshot" below) — rejected after the fact by the operator, who wanted the
public copy to preserve the actual commit-by-commit development history, not collapse it into one
commit. The mechanism below (`git filter-repo` rewriting a copy) replaces that snapshot approach
entirely; nothing from the snapshot design survives except the parts that didn't depend on it (the
encrypted store's exclusion, the operator-supplied identity, the audit-as-final-gate).

## The export, concretely

`scripts/export-public.py` (epic 24 #04) takes a destination and a required commit identity
(`EXPORT_AUTHOR_NAME`/`EXPORT_AUTHOR_EMAIL`, environment variables — see "Commit identity" below). It
clones `--source` (default: this repository), then runs a single `git filter-repo --source ... --target
DEST` pass over *every* commit reachable from *every* ref in that clone:

- `secrets/secrets.enc.env`, `.sops.yaml`, and any `*-git-crypt.key` path are removed from every
  commit, not just HEAD, via `--invert-paths`/`--path`/`--path-glob`;
- every decrypted secret value, every `AUDIT_EXTRA_TERMS` entry, every tailnet CGNAT/ULA-range address
  and every credential-shaped string is replaced with a named placeholder, in file content **and**
  commit/tag messages alike, via `--blob-callback`/`--message-callback` sharing one substitution
  function (`scripts/history_scrub.py`'s `scrub_bytes`) — except whatever `audit-allowlist.yml` already
  names as deliberately public or a known-safe test-fixture value, left untouched by the same reasoning
  that already keeps the audit from flagging it;
- every commit's and tag's author and committer are rewritten to the supplied identity, unconditionally,
  via `--name-callback`/`--email-callback` — nothing from the source history's own author names survives;
- a commit that becomes empty once its only content was secrets-tooling state is pruned by
  `git filter-repo` itself (its default behaviour), not specially handled here.

The destination is then re-audited in full (`scripts/public-readiness-audit.py`, same decrypted set,
whole history) before the run is ever reported as done — a filtered export that still has an
unallowlisted finding is refused, never left sitting in `--dest` as if it were clean. `--source` itself
is read-only throughout: `git filter-repo`'s own `--source`/`--target` split never writes to the thing
it reads from, and the export double-checks `--source`'s refs and HEAD are unchanged before finishing.

**Why history-preserving, not a snapshot**: the public repository should read as the same project's
actual development, not a single opaque drop — the operator's explicit reason for rejecting the
snapshot design this ADR originally chose. Rewriting a *copy* of history (never the original) makes
this possible without publishing anything the scrub is supposed to remove: every commit still exists,
but every identifying value and every secrets-tooling file is gone from all of them, not just the tip.

## Alternatives considered and rejected

- **Rewrite this repository's history in place and force-push.** Rejected: it invalidates every
  workstation's existing clone; GitHub-side artifacts (pull request references, cached forks, API
  responses) can outlive a force-push and are not reliably purgeable. The chosen approach gets the same
  scrubbed history without any of that cost, because it is always a rewrite of a disposable *copy* —
  the operator's own clone, and this repository's own history, are never touched.
- **Flip this repository's visibility to public as it stands.** Rejected outright: it would publish
  every historical identifying value found during this epic's own audit (the real domain in 8 tracked
  files and 10 commits, tailnet addresses, the dead git-crypt key still live in history) and the
  encrypted secrets file itself — ciphertext of every credential this operator has, permanently,
  the moment it's public.
- **Move development to the new public repository.** Rejected: it would split tickets, history, and
  the encrypted store across two repositories for no benefit — this repository stays the one place
  development, the issue tracker, and the secrets store live; the public repository is export-only,
  never a place a new ticket gets filed or a change gets made directly (see "What stays where" below).
- **Rejected: a flattened snapshot** (this ADR's original choice). A derived export that copies only
  `--source`'s HEAD tree into one new commit each run, never any of this repository's actual commits.
  It sidesteps ever having to scrub history at all — nothing historical is ever in the export's history
  to leak — at the cost of publishing no development history whatsoever: every past commit, message and
  diff is simply gone from the public copy. Abandoned once the operator clarified that preserving real
  history was the point of publishing at all; a rewritten-copy approach removes the same risk (nothing
  this repository's own history has stays reachable from the export unscrubbed) without that cost, once
  the scrub itself is proven correct — which is what `tests/check-export-public.sh` and the final
  re-audit of `--dest` both exist to do.

## The encrypted store never goes public

**Decided: the encrypted secrets file and the SOPS recipient configuration stay in this private
repository, during and after migration and publication; the export excludes both, from every commit,
by an explicit, named list (not a wildcard or a heuristic).** This was reviewed and decided
deliberately, not left to "the store is encrypted so it's fine": publishing the store would publish
ciphertext of *every* credential and identifying value this operator has, permanently — a future leak
of any one recipient's age key would decrypt all of them at once, and rotating a credential afterward
does not un-publish the ciphertext or the fact that it once decrypted to something. Because the store
never leaves this private repository — not even in an old, superseded commit of the export, since the
removal runs across all of history, not just HEAD — the public repository's own recipient list needs no
separate review; this repository's existing recipient-management runbooks
(`docs/secrets-runbooks.md`, ADR-0007) are unchanged by any of this.

A fresh clone of the export has *neither* `.sops.yaml` nor the encrypted store, at any commit.
`scripts/check_secrets_store.py` (epic 22 #03) already derives whether the store is mandatory from
`.sops.yaml`'s presence — neither present is an explicitly valid, passing state (its own docstring:
"before the migration, and in a fresh clone of a public export, which deliberately has neither") — so
the standard lint run passes unmodified in the export, with no special-casing needed anywhere.

## Commit identity: an operator input, not decided here

**This ADR does not choose the export's commit identity.** Every existing commit in this repository
already uses a GitHub no-reply address — that alone changes nothing new about this repository's
commits — but the large majority of them (180 of 186, per the epic's own 2026-09-20 scan) carry the
operator's real full name as the author name. Publishing commits authored under that name is
publishing that name. The export procedure therefore takes an author name **and** email as required
environment variables (`EXPORT_AUTHOR_NAME`/`EXPORT_AUTHOR_EMAIL` — not CLI flags, since the deploy
wrapper's own injection defense rejects any script-mode argument containing a space, which a real name
needs) and refuses to run without both (a negative test proves this — see
`tests/check-export-public.sh`); it is never inferred, defaulted, or chosen by an agent. Every commit
and tag in the filtered history is rewritten to this one identity, unconditionally — the export does
not attempt to preserve or selectively scrub individual historical authors' names, since doing so
would mean deciding, per commit, whether that author's name was itself identifying. The operator's
actual choice of name and email is recorded in epic 24 #05, at go-live time, not here — this ticket
only builds the mechanism that requires it.

## Threat model

What a clean, scrubbed public export still reveals, even with every identifying value removed:
- **The stack's composition, versions and architecture** — which services run, which images, roughly
  how they're wired together. This is inherent to publishing infrastructure-as-code at all; the audit
  and scrub remove *identifying* detail, not the fact of what software is deployed.
- **The no-reply address embeds the account handle**, and that handle matches a label of the
  operator's own domain (the same relationship the scrub otherwise removes from prose) — GitHub's own
  no-reply format makes this unavoidable without choosing a *different* account identity for
  publishing, which is a separate decision from this epic's scope.
- **Certificate-transparency logs and DNS already expose every hostname that has ever received a
  public certificate**, regardless of anything in this repository. Scrubbing prose cannot hide what a
  public CT-log search already shows; this is accepted as pre-existing exposure the repository itself
  did not create and cannot undo.
- **Commit timing metadata** (author/committer dates) is preserved by the rewrite — only names, emails
  and content are substituted — so the export still reveals *when* historical development happened,
  even though *who* did it is replaced throughout.

What stays exposed in the **private** repository specifically, and therefore still matters even though
it is never published: the encrypted store's **ciphertext** (of every credential) and the **recipient
public keys** (age1... values, naming which workstations can decrypt). Neither is secret-shaped in the
information-theoretic sense SOPS was chosen for (ADR-0007), but this repository's own access controls
— who has clone access, account security on every recipient's workstation — remain exactly as load-
bearing after publication as before it, because the private repository keeps holding this.

## What stays where

Development, the issue tracker (`.scratch/`), ADRs, and the encrypted secrets store all stay in this
private repository, unchanged by publication — this ADR does not move any of them. The public
repository that results from an export is a **read-only artifact**: nobody files a ticket there, edits
code there, or treats it as a working checkout. A workstation that wants to publish needs only an
*additional* git remote pointed at the public repository (used solely by the export procedure); every
existing workflow, clone, and tool continues to point at this private repository exactly as before.

## Consequences

Publishing is additive and reversible up to the point the operator actually flips visibility (epic 24
#05's own gate) — running the export into a scratch destination, inspecting it, and throwing it away
costs nothing and changes nothing here. Because the rewrite is always of a fresh clone, never
`--source` itself, a mistake in one run (an allowlist entry that was too broad, a future identifying
value the audit's generic rules don't yet catch) is caught by the final re-audit before the run ever
reports success, and even a run that somehow produced a bad `--dest` leaves nothing in this repository
to clean up — only `--dest` is ever touched. Once a real public repository exists and has been made
public, **re-running the export and pushing again replaces its history** (the rewrite starts over from
`--source`'s current history each time, not an incremental append onto the previous export) — this is
a deliberate, visible history-replacing push, not a silent one, and is exactly why epic 24 #05's go-live
checklist exists: audit the export's own tree and history, not just this repository's, before ever
flipping the public repository's visibility, and treat any push after that point as something that
rewrites a public history other people may have already fetched.
