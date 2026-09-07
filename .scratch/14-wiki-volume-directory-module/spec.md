# Spec: wiki_volume Directory-Bootstrap Module

> Status: ready-for-agent
> Source: Epic 14 — architecture review candidate "Give wiki_volume a directory-bootstrap entrypoint" (hot-spot scan of git log)
> Related: `05-wiki-volume-ownership` (wiki_volume's origin — already established "single owner" for uid/gid resolution and the wiki data directory), `11-docker-consolidation` (the docker role's current directory tasks), `15-role-ordering-check` (the role-ordering constraint that causes the hermes/docker duplication described below — tracked separately, not this epic's scope)
> Vocabulary: "wiki_volume", "llm_wiki", "seam", "deep module", "locality", "leverage"

## Problem Statement

Every role that bind-mounts host storage for its container needs a directory that exists, on the VPS filesystem, owned by the `llm_wiki` user before the container starts — otherwise the container's non-root process can't write to it. `wiki_volume` already resolves `llm_wiki`'s uid/gid once, as the sole owner of that lookup (epic 05 deliberately closed off every other role re-resolving it independently). But it stops at resolving the facts: it doesn't own directory creation itself, so seven other role files (`backup`, `conduit`, `authelia`, `hermes`, `docker`, `owntracks`, `silverbullet`) each hand-roll their own near-identical "ensure directory exists, owned by `llm_wiki`" task — some using the resolved `wiki_volume_uid`/`wiki_volume_gid` facts, others hardcoding the literal `llm_wiki` username instead.

This is more than repeated boilerplate: `hermes` and `docker` currently create the *exact same three directories* (the Hermes home directory, its Signal data subdirectory, and its per-profile subdirectories) independently, byte-for-byte identical tasks in two different role files. A future ownership or mode fix made in one and forgotten in the other would silently reintroduce exactly the class of bug `wiki_volume` was created to prevent in epic 05.

## Solution

Extend `wiki_volume` with a second, reusable entrypoint — a directory-bootstrap task a dependent role calls with a path and a mode, instead of hand-writing its own `file` task. Every role identified above migrates its hand-rolled directory tasks to call this entrypoint. The `hermes`/`docker` duplicate *call sites* remain (removing them requires resolving a role-ordering constraint that's epic 15's scope, not this one's) — but the duplicated *implementation* is eliminated: a future ownership/mode fix becomes one edit to the shared entrypoint, not N independently-maintained file tasks scattered across role files.

## User Stories

1. As a VPS operator, I want every role that bind-mounts host storage to create its directory the same way, so that an ownership or mode bug fix lands once and is fixed everywhere, not once per role and hoped-for everywhere else.
2. As a maintainer, I want `wiki_volume` to be the single owner of both `llm_wiki` uid/gid resolution *and* directory creation, so that the module's existing "single owner" precedent (epic 05) extends naturally instead of stopping halfway.
3. As a future epic author adding a new service that bind-mounts host storage (the pattern this repo adds roughly once per epic — Conduit, OwnTracks, whatever's next), I want to call one shared entrypoint instead of copy-pasting a `file` task, so that I inherit correct ownership behavior for free.
4. As a security reviewer, I want every container-owned directory in this repo created through one audited code path, so that I can verify ownership correctness in one place instead of re-reading seven near-identical tasks.
5. As a maintainer, I want the shared entrypoint to use the already-resolved `wiki_volume_uid`/`wiki_volume_gid` facts for ownership, not the literal `llm_wiki` username string, so that the module's declared interface (the facts) is what dependents actually consume — closing the inconsistency where some roles use the facts and others hardcode the username.
6. As a maintainer, I want the `hermes`/`docker` duplicate directory-creation logic collapsed to one shared implementation (even though both roles still call it, due to a real ordering constraint), so that the two roles can no longer silently drift from each other.
7. As a maintainer, I want `wiki_volume`'s own task file (which today creates the SilverBullet wiki data directory directly, as a leftover from epic 05) to call its own new entrypoint too, so the module dogfoods its own interface rather than keeping a special-cased inline task alongside the reusable one.
8. As a test author, I want a regression guard asserting no role outside `wiki_volume` hand-rolls a directory-creation `file` task for an `llm_wiki`-owned path, so that a future role can't reintroduce the copy-paste pattern this epic removes — mirroring the existing guard that already does this for the `getent`/uid-gid-resolution half of `wiki_volume`'s contract.
9. As a maintainer, I want to rely on each migrated role's existing `meta/main.yml` dependency on `wiki_volume` for ordering, so that Ansible enforces "uid/gid facts resolved before the entrypoint is called" rather than incidental role-list position — this dependency already exists on all seven roles, so this epic changes no dependency graph, only what the tasks do.

## Implementation Decisions

- **New entrypoint in the `wiki_volume` role**: a task file dependents invoke (via Ansible's role-task-inclusion mechanism, passing a target path and mode as inputs) rather than writing their own `file` task. It uses the already-resolved `wiki_volume_uid`/`wiki_volume_gid` facts for ownership — standardizing on the facts-based idiom already used by the newest consumer (`owntracks`) rather than the literal-`llm_wiki`-username idiom used by older consumers (`hermes`, `docker`, and others). The facts are the module's actual declared interface; the literal username was always an implementation detail leaking across the seam.
- **Every identified dependent migrates**: `backup`, `conduit`, `authelia`, `hermes`, `docker`, `owntracks`, `silverbullet` each replace their hand-rolled directory `file` task(s) with a call to the new entrypoint — one call per directory they need.
- **`wiki_volume`'s own task file migrates too**: it currently creates the SilverBullet wiki data directory inline as a leftover from its epic-05 origin; this becomes a self-call to the new entrypoint, for consistency — the module shouldn't have a special-cased inline path alongside the reusable one it now offers everyone else.
- **The `hermes`/`docker` duplicate directories are not de-duplicated at the call-site level in this epic.** `docker` currently creates the Hermes home/signal-data/per-profile directories independently because, in today's role order, `docker` runs before `hermes` in `site.yml` and needs those directories to exist first for its compose stack to start. Both roles will call the new shared entrypoint independently — this closes the *implementation* duplication (one place to fix an ownership/mode bug) without touching the *ordering* duplication (still two call sites). Removing the redundant call site entirely is coupled to resolving the ordering constraint, which is epic 15's scope.
- **`meta/main.yml` dependency declarations**: no role needs a new dependency added for this epic, but the coverage isn't uniformly direct — `authelia`, `backup`, `docker`, `hermes`, `owntracks`, and `silverbullet` each declare `- role: wiki_volume` directly; `conduit` declares only `- role: docker`, which itself depends on `wiki_volume`, so `conduit` gets the resolved uid/gid facts transitively rather than directly. The ordering guarantee holds either way (Ansible resolves dependencies recursively) — this is a correction to an earlier "all seven declare it directly" claim in this spec, not a functional gap.

## Testing Decisions

- **What makes a good test**: verify external behavior — the entrypoint, called with a path and mode, produces a directory with the correct owner/group/mode — not the internals of how it resolves ownership (that's already covered by `wiki_volume`'s existing uid/gid tests).
- **Modules tested**:
  - The new `wiki_volume` entrypoint → called directly with a test path, asserts the resulting directory's owner/group/mode match the resolved facts and the requested mode.
  - A repo-wide regression guard, extending the existing pattern that already restricts `getent`/`key: llm_wiki` to `wiki_volume` alone: assert no role outside `wiki_volume` contains a `file`-module task with `state: directory` and an `owner`/`group` referencing `llm_wiki` (literal or via the facts) — every such task must now live inside `wiki_volume`'s entrypoint, called by reference, not duplicated inline.
  - Each migrated role's rendered behavior (directories created, docker-compose render, role skip-tags guard) — unchanged; this epic changes where the logic lives, not the resulting filesystem state.
- **Prior art**: mirror the existing consumer-contract guard for `wiki_volume`'s uid/gid resolution (which already asserts `getent`/`key: llm_wiki` appear only inside the `wiki_volume` role) — extend the same guard file to cover directory-creation tasks the same way, rather than writing a new test file from scratch.

## Out of Scope

- **Resolving the `hermes`/`docker` role-ordering constraint** that causes the duplicate call sites — tracked as epic 15.
- **Changing `site.yml`'s role order** — no ordering changes in this epic; only the *implementation* of directory creation is deduplicated, not the *number of call sites*.
- **Any directory or role not currently hand-rolling this pattern** — scope is limited to the seven identified roles plus `wiki_volume` itself.
- **Changing what gets mounted into which container, or any bind-mount paths** — this epic only touches how the host-side directory gets created, not the mount configuration itself.

## Further Notes

- This is the second of three deepening candidates surfaced by the architecture review that also produced epic 13 (gateway route schema, already spec'd and ticketed). The third, machine-checked role ordering, is epic 15.
- Epic 05 already established the precedent this epic extends: "single owner" for a cross-cutting concern (`llm_wiki` uid/gid resolution), enforced by a regression guard restricting `getent`/`key: llm_wiki` to the `wiki_volume` role alone. This epic applies the same discipline to directory creation, the concern `wiki_volume` resolves facts *for* but has never itself owned.
- Open question left to the implementer: whether the entrypoint should also accept an optional `recurse` flag (one existing hand-rolled task, the Hermes home directory, sets `recurse: true`) or whether that's rare enough to leave as a documented exception the migrated `hermes`/`docker` tasks call out explicitly rather than adding to the shared interface. Flagging rather than deciding — pick whichever keeps the entrypoint's interface simplest for the common case.
