# Ticket #01: wiki_volume directory-bootstrap entrypoint

**Blocked by:** none
**Blocks:** #02

## Description

Give `wiki_volume` a second, reusable entrypoint for directory creation, alongside its existing uid/gid-resolution entrypoint. This ticket only builds and dogfoods the entrypoint — it does not yet migrate the other seven roles that currently hand-roll their own directory tasks (that's ticket #02).

1. **New task file in the `wiki_volume` role**, invoked by dependents (via Ansible's role-task-inclusion mechanism, not a raw `include_tasks` file path — matches how the role is already consumed as a `meta/main.yml` dependency). It accepts a directory path and a mode as inputs and creates that directory owned by the already-resolved `wiki_volume_uid`/`wiki_volume_gid` facts (not the literal `llm_wiki` username string — the facts are the module's actual declared interface).

2. **Migrate `wiki_volume`'s own inline directory task** (the SilverBullet wiki data directory, currently created directly in `wiki_volume`'s main task file) to call the new entrypoint instead of hand-writing the `file` task inline. No behavior change — same path, same owner, same mode — just routed through the new interface the module now offers everyone else.

3. Do not touch any other role in this ticket.

## Acceptance criteria

- `wiki_volume` exposes a directory-bootstrap entrypoint taking a path and a mode, producing a directory owned by `wiki_volume_uid`/`wiki_volume_gid`
- `wiki_volume`'s own SilverBullet wiki data directory task now calls this entrypoint instead of a hand-written inline `file` task, with identical resulting path/owner/mode
- A test calls the entrypoint directly with a test path and mode, and asserts the resulting directory's owner/group/mode match the resolved facts and the requested mode
- `ansible-playbook --syntax-check` passes
- No role other than `wiki_volume` is touched by this ticket

## Notes

- This is the "expand" half of an expand-contract sequence — ticket #02 is "contract" (migrate the other seven consumers).
- Open question from the spec, left to this ticket's implementer: whether the entrypoint accepts an optional `recurse` flag (one existing hand-rolled task — the Hermes home directory, migrated in #02 — sets `recurse: true`) or whether that stays a documented exception in the caller. Pick whichever keeps the interface simplest for the common case; note the choice here once decided, since #02 depends on it.
