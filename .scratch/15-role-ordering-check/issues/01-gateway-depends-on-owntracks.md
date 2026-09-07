# Ticket #01: gateway depends on owntracks

**Blocked by:** none
**Blocks:** none (parallel with #02)

## Description

`gateway`'s Caddyfile render reads htpasswd credentials that `owntracks`'s tasks generate as facts. This is correct in `site.yml` today only by list position (`owntracks` happens to be listed before `gateway`) — nothing stops a future edit from reordering them back into the broken configuration that shipped once already during the OwnTracks HTTP-auth security fix.

1. **Create `roles/gateway/meta/main.yml`** (the `gateway` role has no `meta/` directory today) declaring `owntracks` as a dependency.

2. **Regression test**: a throwaway test playbook (mirroring the isolated-playbook pattern already used elsewhere in `tests/`) that deliberately lists `gateway` before `owntracks` — the wrong order — and asserts the actual task execution order still places `owntracks`'s tasks first. This proves the dependency, not list position, governs order.

3. ~~Do not change `site.yml`'s existing role list order~~ **Superseded during implementation — see the "Implementation finding" note below.** `site.yml` DOES change: `owntracks`'s explicit `roles:` entry is removed, because Ansible does not deduplicate it against gateway's new dependency.

## Acceptance criteria

- `roles/gateway/meta/main.yml` exists and declares `owntracks` as a dependency
- A test proves `owntracks`'s tasks execute before `gateway`'s own tasks, driven purely by the meta dependency (not list position)
- `ansible-playbook --syntax-check` passes on `site.yml`
- ~~`site.yml`'s role list is unchanged~~ **Cannot hold simultaneously with the no-duplication criterion below — see Implementation finding.** `site.yml`'s role list changes in exactly one way: `owntracks`'s explicit entry is removed.
- No duplicate execution of `owntracks`'s tasks when both the explicit `site.yml` listing and the new dependency are present in the same play — verified against the compiled task list of the real `site.yml`, not just a toy example

## Notes

- Matches the existing `wiki_volume` `meta/main.yml` dependency pattern — not a new idiom, a wider application of one already in the repo.
- **Implementation finding (this ticket's original assumption was wrong): Ansible does NOT skip re-running a role that already ran earlier in the same play, if one occurrence is an explicit `roles:` entry and the other is another role's `meta/main.yml` dependency on it.** Verified empirically with `ansible-playbook site.yml --list-tasks`, in multiple orderings, with and without matching `tags:` on the dependency declaration: keeping `owntracks`'s own `roles:` entry in `site.yml` alongside `gateway`'s new dependency on it caused `owntracks` (and its `wiki_volume`/`users` chain) to run **twice** per playbook execution — confirmed on the actual `site.yml`, not a toy reproduction. Ansible's automatic role deduplication only suppresses a dependency when it matches *another role's* dependency on the same role (the reason `wiki_volume` correctly runs once despite six roles depending on it) — it does not compare a dependency against a sibling explicit `roles:` entry.
- **Resolution**: `owntracks`'s explicit `site.yml` entry was removed. `gateway`'s dependency declaration carries `tags: [owntracks]` (matching `owntracks`'s own former entry) so `--skip-tags owntracks` still works correctly — verified with `--list-tasks --skip-tags owntracks`. The effective runtime order is unchanged (`owntracks` still runs immediately before `gateway`, still before `docker`), and single execution is now structurally guaranteed rather than incidental.
- **A second, larger, pre-existing instance of this exact bug class was discovered as a side effect and is explicitly out of scope for this ticket**: `docker`'s own tasks (including "Start consolidated docker compose stack") already run **five times** per `site.yml` execution on the current `main` branch, unrelated to anything in epic 13-16 — `conduit`, `hermes`, `authelia`, and `silverbullet` each declare `docker` as a `meta/main.yml` dependency (for the `wiki_volume`-via-`docker` transitive chain — see epic 14), while `docker` is *also* explicitly listed in `site.yml`. This predates epic 15 and is not this ticket's to fix; flagging prominently for a future epic. **This finding directly changes the plan for ticket #02** ("docker depends on gateway"): naively adding `gateway` as a further `docker` dependency would compound this pre-existing problem, running `gateway` (and transitively `owntracks`) up to five times instead of once — see ticket #02's own Notes for the resulting decision.
