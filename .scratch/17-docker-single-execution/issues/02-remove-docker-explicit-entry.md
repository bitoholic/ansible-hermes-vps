# Ticket #02: Remove docker's explicit site.yml entry

**Blocked by:** none
**Blocks:** none (independent of #01 — see Notes)

## Description

`docker` is currently both an explicit `site.yml roles:` entry and a `meta/main.yml` dependency of `conduit`, `hermes`, `authelia`, and `silverbullet`. Ansible does not deduplicate an explicit `roles:` entry against another role's dependency on the same role (the same finding epic 15 ticket #01 already used to justify removing `owntracks`'s explicit entry) — removing `docker`'s explicit entry removes that one duplicate.

1. **Remove `docker`'s explicit entry** from `site.yml`'s `roles:` list. `docker` remains a dependency of `conduit`, `hermes`, `authelia`, and `silverbullet` — only its own separate top-level listing is removed. No other role's list position changes.

2. **Verify the resulting position shift is safe.** Once `docker` is dependency-only, its effective execution position becomes wherever its first remaining dependent (`conduit`) sits in `site.yml` — which happens to be exactly where `docker`'s own explicit entry used to be, since `conduit` was already the next role listed after `docker`. `gateway`'s tasks run in between `docker`'s old position and its new one; confirm via `--list-tasks` that this doesn't matter (`gateway`'s tasks — loading `gateway_publish` contributions, validating the route schema, deploying the Caddyfile — don't need `docker`'s engine, networks, or rendered compose file to exist).

3. **Ordering regression test**: assert (via `--list-tasks`, mirroring `tests/check-role-ordering.sh`'s and `tests/check-stack-start-ordering.sh`'s existing structural-proof pattern) that `docker`'s tasks still run before `conduit`'s, `hermes`'s, `authelia`'s, and `silverbullet`'s own config-phase tasks, and before epic 16's end-of-play "Start consolidated docker compose stack" step.

4. **Duplication regression test**: assert `docker`'s own task-execution count (e.g. count of "docker : Validate Docker role prerequisites" in `--list-tasks` output) is `<= 4` — the level Fix B achieves (down from the pre-existing baseline of 5). Not asserting `== 1`; see the epic spec for why full elimination isn't in scope.

5. **Tighten ticket #01's `wiki_volume` bound.** With both this ticket and #01 applied, `wiki_volume`'s execution count drops one further, from 8 to 7 (verified empirically in the epic spec). Update the `<= 8` bound from ticket #01's regression test to `<= 7` as part of this ticket, so the test suite reflects the actual combined result once both land — don't leave it at the looser, stale bound.

## Acceptance criteria

- `site.yml`'s `roles:` list no longer has an explicit `role: docker` entry; every other role's position is unchanged
- A regression test proves (via `--list-tasks`) that `docker`'s dependency-only tasks still run before `conduit`/`hermes`/`authelia`/`silverbullet`'s config-phase tasks and before the epic-16 end-of-play docker-start step
- A regression test asserts `docker`'s task-execution count in `--list-tasks` output is `<= 4`
- The `wiki_volume` bounding test (from ticket #01, wherever it lands relative to this one) asserts `<= 7`, not the looser `<= 8`, once both tickets are applied
- `ansible-playbook --syntax-check` passes on `site.yml`
- `tests/lint.sh` passes end to end
- No change to `docker_enabled_services`, any compose fragment, or any role's task content — only `site.yml`'s role list and the new/updated regression tests change

## Notes

- Matches the epic's Fix B exactly. Verified empirically before this ticket was written: removing `docker`'s explicit entry alone (ticket #01's changes not applied) drops `docker`'s count from 5 to 4 — **not to 1**. The four remaining dependency-driven pulls (from `conduit`, `hermes`, `authelia`, `silverbullet`) don't deduplicate against each other either, because each inherits a different merged tag-set from its own parent role (tag inheritance defeating Ansible's role-dedup — see the epic spec's Problem Statement for the full mechanism). This is expected, not a bug in this ticket's implementation — don't try to chase it down to 1 here.
- Independent of ticket #01 — no shared blocker, can land in either order or in parallel. If this ticket lands first, ticket #01's own `wiki_volume` bounding test should target `<= 7` directly rather than `<= 8` (skip the intermediate number).
- Full elimination (`docker` == 1) is explicitly out of scope for this epic — see the epic spec's Out of Scope and Further Notes for candidate approaches recorded for a future epic.
