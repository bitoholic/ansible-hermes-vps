# Ticket #01: Remove redundant wiki_volume dependencies

**Blocked by:** none
**Blocks:** none (independent of #02 — see Notes)

## Description

`authelia`, `hermes`, and `silverbullet` each currently declare dependencies on both `wiki_volume` and `docker` in their own `meta/main.yml`. Since `docker` already transitively depends on `wiki_volume`, and Ansible fact resolution persists as global host facts for the rest of the play regardless of which dependency path resolved them first, the direct `wiki_volume` entry in all three is redundant.

1. **Remove the direct `wiki_volume` dependency** from `authelia`'s, `hermes`'s, and `silverbullet`'s `meta/main.yml`, keeping only their existing `docker` dependency (which still provides the same `wiki_volume_uid`/`wiki_volume_gid` facts transitively, before any of the three roles' own tasks run).

2. **No other role's meta dependencies change** — `backup`, `conduit`, `owntracks`, and `docker` itself keep their existing dependency declarations unchanged. `backup` and `owntracks` depend on `wiki_volume` directly and legitimately (they don't depend on `docker`); `conduit` depends only on `docker` already (no redundancy there).

3. **Regression test**: assert `wiki_volume`'s own task-execution count (e.g. count of "wiki_volume : Lookup llm_wiki passwd entry" in `ansible-playbook site.yml --list-tasks` output) is `<= 8` — the level this ticket alone achieves (down from the pre-existing baseline of 11). Not asserting `== 1`; see the epic spec for why full elimination isn't in scope.

## Acceptance criteria

- `roles/authelia/meta/main.yml`, `roles/hermes/meta/main.yml`, and `roles/silverbullet/meta/main.yml` no longer declare `wiki_volume` as a dependency — each declares only `docker`
- `roles/backup/meta/main.yml` and `roles/owntracks/meta/main.yml` are unchanged (still depend on `wiki_volume` directly)
- `roles/conduit/meta/main.yml` and `roles/docker/meta/main.yml` are unchanged
- A regression test asserts `wiki_volume`'s task-execution count in `ansible-playbook site.yml --list-tasks` output is `<= 8`
- `ansible-playbook --syntax-check` passes on `site.yml`
- `tests/lint.sh` passes end to end
- No change to `docker_enabled_services`, any compose fragment, or `site.yml`'s role list — only the three roles' `meta/main.yml` files change

## Notes

- Matches the epic's Fix A exactly. Verified empirically before this ticket was written: removing these three redundant declarations (with nothing else changed) drops `wiki_volume`'s execution count from 11 to 8, with `docker`'s own count unaffected (stays at 5 until ticket #02 also lands).
- Independent of ticket #02 — no shared blocker, can land in either order or in parallel. If ticket #02 lands first or afterward, its own regression test tightens this ticket's `<= 8` bound to `<= 7` (the level both fixes combined achieve) — that tightening is ticket #02's responsibility, not this one's, but is called out here so the bound doesn't accidentally stay stale at the looser number once both tickets are done.
