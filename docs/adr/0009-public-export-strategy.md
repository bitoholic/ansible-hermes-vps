# Publishing a public version: a derived export to a separate repository, not an in-place rewrite

Epic 24 makes it possible to publish a public version of this repository without exposing the
operator's identifying values (CONTEXT.md: **public-readiness audit**). This ADR records *how*
publication itself works, once the audit is clean (epic 24 #01/#02/#03): a **derived export** — the
scrubbed tree, minus the encrypted secrets file and the SOPS recipient configuration, committed as a
snapshot into a **separate public repository** under an identity the operator supplies. This private
repository is unaffected: its history, visibility, and the encrypted store all stay exactly as they
are, forever, independent of whether or when a public export ever happens.

## The export, concretely

`scripts/export-public.py` (epic 24 #04) takes a destination and a required commit identity
(`--author-name`/`--author-email`; it refuses to run without both — see "Commit identity" below). It
copies every file this repository tracks at `HEAD`, **except** an explicit, named exclusion list
(`secrets/secrets.enc.env`, `.sops.yaml` — see "The encrypted store never goes public" below), into the
destination and commits it as one snapshot. Run again later, it adds another snapshot on top — the
destination's history is *only* ever these snapshots, never a copy of this repository's own commits.
It never touches this repository's own history, refs, visibility, or the encrypted store; it only
reads from here and writes to the destination.

**Why snapshots, not a copy of history**: the alternative — publish this repository's actual commits
— would publish every historical identifying value this epic exists to keep private (the operator's
real domain and tailnet addresses in old commits, the dead git-crypt key, the operator's real name as
author on the large majority of commits), none of which the scrub (epic 24 #02) can remove without
rewriting history (rejected below). A snapshot export sidesteps the problem entirely: the public
repository's history never contains anything this repository's own history does.

## Alternatives considered and rejected

- **Rewrite this repository's history in place and force-push.** Rejected: it invalidates every
  workstation's existing clone; GitHub-side artifacts (pull request references, cached forks, API
  responses) can outlive a force-push and are not reliably purgeable; and because the rewrite would
  need to find and remove *every* identifying value across the whole history, one missed pattern is a
  permanent, public leak with no way to un-publish it. The derived-export approach makes this risk
  moot: nothing from this repository's actual history is ever in the export's history to miss.
- **Flip this repository's visibility to public as it stands.** Rejected outright: it would publish
  every historical identifying value found during this epic's own audit (the real domain in 8 tracked
  files and 10 commits, tailnet addresses, the dead git-crypt key still live in history) and the
  encrypted secrets file itself — ciphertext of every credential this operator has, permanently,
  the moment it's public.
- **Move development to the new public repository.** Rejected: it would split tickets, history, and
  the encrypted store across two repositories for no benefit — this repository stays the one place
  development, the issue tracker, and the secrets store live; the public repository is export-only,
  never a place a new ticket gets filed or a change gets made directly (see "What stays where" below).

## The encrypted store never goes public

**Decided: the encrypted secrets file and the SOPS recipient configuration stay in this private
repository, during and after migration and publication; the export excludes both, by an explicit,
named list (not a wildcard or a heuristic).** This was reviewed and decided deliberately, not left to
"the store is encrypted so it's fine": publishing the store would publish ciphertext of *every*
credential and identifying value this operator has, permanently — a future leak of any one recipient's
age key would decrypt all of them at once, and rotating a credential afterward does not un-publish the
ciphertext or the fact that it once decrypted to something. Because the store never leaves this
private repository, the public repository's own recipient list needs no separate review; this
repository's existing recipient-management runbooks (`docs/secrets-runbooks.md`, ADR-0007) are
unchanged by any of this.

A fresh clone of the export has *neither* `.sops.yaml` nor the encrypted store. The structural guard
(`scripts/check_secrets_store.py`, epic 22 #03) already derives whether the store is mandatory from
`.sops.yaml`'s presence — neither present is an explicitly valid, passing state (its own docstring:
"before the migration, and in a fresh clone of a public export, which deliberately has neither") — so
the standard lint run passes unmodified in the export, with no special-casing needed anywhere.

## Commit identity: an operator input, not decided here

**This ADR does not choose the export's commit identity.** Every existing commit in this repository
already uses a GitHub no-reply address — that alone changes nothing new about this repository's
commits — but the large majority of them (180 of 186, per the epic's own 2026-09-20 scan) carry the
operator's real full name as the author name. Publishing commits authored under that name is
publishing that name. The export procedure therefore takes an author name **and** email as a required
parameter and refuses to run without both (a negative test proves this — see
`tests/check-export-public.sh`); it is never inferred, defaulted, or chosen by an agent. The operator's
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
costs nothing and changes nothing here. Once a real public repository exists and has been made public,
each export afterward is a new snapshot, not a replacement of history there either — the public
repository accumulates its own append-only history of *exports*, which is a different, deliberately
simpler object than this repository's actual development history. A mistake in one export (an
allowlist entry that was too broad, a future identifying value the audit's generic rules don't yet
catch) is visible in that export's snapshot permanently, which is exactly why epic 24 #05's go-live
checklist exists: audit the export's own tree and history, not just this repository's, before ever
flipping the public repository's visibility.
