# Ticket #02: Migrate all dependent roles + regression guard

**Blocked by:** #01
**Blocks:** none (epic 14 completion)

## Description

Migrate every role currently hand-rolling an `llm_wiki`-owned directory task to call the new `wiki_volume` entrypoint (ticket #01) instead, and close the gap with a regression guard so the pattern can't quietly reappear.

1. **Migrate seven roles** — `backup`, `conduit`, `authelia`, `hermes`, `docker`, `owntracks`, `silverbullet` — each replacing its hand-written directory `file` task(s) with a call to the entrypoint from #01. Same resulting paths, owners, and modes as today; only the mechanism changes. `hermes` and `docker` both keep their own call sites (each still creates the Hermes home/signal-data/per-profile directories) — that duplication is a role-ordering constraint, not this ticket's to resolve (see epic 15) — but both now call the same shared implementation instead of two independently hand-written tasks.

2. **No new `meta/main.yml` dependencies needed**: all seven roles already declare `- role: wiki_volume` (verified directly against each role's `meta/main.yml`) — this ticket only changes what their tasks do, not their dependency graph.

3. **Extend the existing `wiki_volume` consumer-contract guard** (the one that already restricts `getent`/`key: llm_wiki` to the `wiki_volume` role alone) to also assert: no role outside `wiki_volume` contains a `file`-module task with `state: directory` and an owner/group referencing `llm_wiki` (literal or via the resolved facts). Every such task must now live inside the entrypoint, called by reference.

## Acceptance criteria

- All seven identified roles call the `wiki_volume` entrypoint for every directory they previously hand-rolled; no role outside `wiki_volume` contains its own `file`/`state: directory`/`owner: llm_wiki`-shaped task
- The extended consumer-contract guard fails if a hand-rolled directory task is reintroduced outside `wiki_volume`, and passes on the migrated tree
- Resulting filesystem state is unchanged: same directories, same paths, same owners, same modes as before migration
- `tests/lint.sh` passes end to end, including docker-compose render and the role skip-tags guard

## Notes

- This is the "contract" half of the expand-contract sequence started in #01.
- The `hermes`/`docker` duplicate call sites are intentionally left in place — removing one of them requires resolving the role-ordering constraint tracked as epic 15. This ticket only removes the duplicated *implementation*, not the duplicated *call site*.
- All seven migrations are small, mechanical, one-task-per-directory swaps — expected to fit comfortably in one pass; don't over-split into per-role tickets.
