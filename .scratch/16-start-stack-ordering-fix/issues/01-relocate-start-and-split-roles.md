# Ticket #01: Relocate stack start; split conduit/hermes into config+provision; delete silverbullet's redundant up call

**Blocked by:** none
**Blocks:** none (epic 16 completion)

## Description

This is deliberately one ticket, not several: relocating `docker`'s start step, splitting `conduit`, and splitting `hermes` are tightly coupled — landing any one alone without the others leaves the playbook in a worse state than today (either the config-timing bug stays open, or a role's provisioning tasks start running before its container exists). No safe intermediate state exists, so this ships as one atomic change.

1. **Extract `docker`'s "Start consolidated docker compose stack" task** into its own task file within the `docker` role, no longer run automatically as part of the role's default task sequence. Everything else in `docker`'s tasks (engine install, network setup, compose-file render/validate, the Hermes Dockerfile copy) stays exactly where it is today.

2. **Split `conduit`'s tasks into two files**: a config phase (prerequisite validation, directory creation, rendering `conduit.toml`) stays in the role's default sequence at its current `site.yml` position; a provisioning phase (resolving the container's IP, waiting for it to accept connections, registering the `@hermes` bot) moves into its own task file, no longer run automatically.

3. **Split `hermes`'s tasks the same way**: directory/profile-file/Dockerfile-copy tasks stay in the default sequence at the current position; the skill-install and gateway-restart tasks move into their own task file.

4. ~~Add an explicit step sequence to the end of the relevant play in `site.yml`... each invoked via `ansible.builtin.import_role` (or `include_role`)...~~ **Amended during implementation — see "Implementation finding" below.** `docker`'s start step uses `import_role`/`tasks_from` as originally specified. `conduit`'s and `hermes`'s provision steps use a bare `include_tasks` instead — the opposite of what this ticket originally asked for those two, for a concrete reason found while implementing, not a shortcut.

   (Epic 15 context, for why `docker`'s step still needs `import_role`: `roles/docker/meta/main.yml` was NOT extended with a `gateway` dependency — epic 15's ticket #02 was deferred as unsafe, see `.scratch/15-role-ordering-check/issues/02-docker-depends-on-gateway.md`. So the specific "epic 15's `docker`→`gateway` protection" this step originally guarded doesn't currently exist. `import_role` is still used for `docker`'s step regardless, per this ticket's own Notes ("costs nothing extra now, avoids a footgun for whoever lands epic 15 afterward") — ordering here is achieved simply by this being the first entry in the end-of-play sequence, after `gateway` already ran earlier in the normal role list.)

5. **Delete `silverbullet`'s redundant second `docker compose up` call** entirely — fully subsumed by the single, correctly-positioned start step.

6. **No changes** to `docker_enabled_services`, any compose fragment, or `authelia`'s/`silverbullet`'s/`owntracks`'s/`gateway`'s task sequences beyond the deletion in step 5.

## Acceptance criteria

- `docker`'s compose-stack start happens after every role that renders a bind-mounted config file (`conduit`, `hermes`, `authelia`) has done so — verified by task-order assertion, not just code inspection
- `docker`'s compose-stack start also runs after `gateway`'s Caddyfile render, and is invoked via `import_role`/`include_role` (not a bare `include_tasks`) — regression test asserts both the order and the invocation mechanism. (The specific "so `roles/docker/meta/main.yml`'s dependency on `gateway` still fires" reason no longer applies — that dependency doesn't exist, epic 15 ticket #02 was deferred — but the mechanism requirement stands per this ticket's own Notes.)
- `conduit`'s bot-registration and wait-for-connection tasks run only after the relocated start step, not at `conduit`'s normal `site.yml` position — via `include_tasks`, not `import_role` (see Implementation finding)
- `hermes`'s skill-install and gateway-restart tasks run only after the relocated start step, not at `hermes`'s normal `site.yml` position — via `include_tasks`, not `import_role` (see Implementation finding)
- `silverbullet`'s task file contains no `docker_compose_v2`/`docker compose up` invocation
- `site.yml`'s role list and every other role's position is unchanged
- `ansible-playbook --syntax-check` passes
- `docker compose config` render validation still passes unchanged (compose file content untouched)
- `tests/lint.sh` passes end to end

## Notes

- **Implementation finding: `import_role`/`include_role` was tried for all three relocated steps (`docker` start, `conduit` provision, `hermes` provision) as originally specified, and it broke `docker` for the latter two.** `conduit` and `hermes` both declare `docker` as a `meta/main.yml` dependency (established before this epic, for the transitive `wiki_volume` chain — see epic 14). Calling `ansible.builtin.import_role: name: conduit, tasks_from: provision` (or `include_role`, same result) re-triggers `conduit`'s full dependency resolution, which re-runs `docker`'s **entire default task sequence** — apt installs, network creation, compose-file render, the lot — a second time, right there at the end of the play. Confirmed via `ansible-playbook site.yml --list-tasks`: with `import_role` used for all three, `docker`'s own tasks (e.g. "Validate Docker role prerequisites") jumped from their pre-existing baseline count to one more per role calling `import_role` on `conduit`/`hermes`. Switching `conduit`'s and `hermes`'s provision steps to a bare `include_tasks` (pointing at `roles/<role>/tasks/provision.yml`, resolved relative to `site.yml`'s own directory, i.e. the repo root — verified this resolves correctly) fixed it: `include_tasks` splices in a task list directly, with no role/meta machinery involved, so it can't retrigger anything. Neither provision file needs its role's meta dependencies to fire at this point — both only touch facts/state already established during the config phase, earlier in the same play — so this isn't a compromise, it's the correct mechanism for these two specifically. `docker`'s own start step keeps `import_role`, since preserving its meta-dependency-firing behavior is exactly what that step (uniquely) might need in the future.
- **If epic 15's ticket #02 (`docker`→`gateway`) is ever implemented after this ticket**, whoever does it needs to be aware `docker` is now invoked via `import_role` from `site.yml`'s end-of-play `tasks:` in addition to its own `roles:` entry earlier in the same play — i.e., a third invocation site instead of two. The same "Ansible doesn't dedupe an explicit entry against a dependency" finding from epic 15 ticket #01 applies here too; verify with `--list-tasks` before assuming it's safe, don't take it on faith from either ticket's text.
- The relocated start step now runs after `backup` (the last role in today's list) rather than interleaved mid-list, since it's appended after the whole role list runs rather than threaded in at a specific point. `backup`'s tasks have no docker/container interaction (verified — no `docker`/`container` references anywhere in that role), so this is inert. Documented here as a deliberate, understood side effect, not something to "fix" further.
- Empirically confirming the exact pre-fix Docker Compose failure mode (hard failure vs. phantom-directory creation vs. silent no-op) is not required — the fix closes the gap regardless of which one it was.
- Open question, left to the implementer: whether the new end-of-play sequence lives inline in `site.yml` as a `tasks:` block or gets extracted to its own small include file. Either is fine; pick whichever keeps `site.yml` most readable top-to-bottom.
