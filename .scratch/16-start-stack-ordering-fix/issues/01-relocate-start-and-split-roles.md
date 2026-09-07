# Ticket #01: Relocate stack start; split conduit/hermes into config+provision; delete silverbullet's redundant up call

**Blocked by:** none
**Blocks:** none (epic 16 completion)

## Description

This is deliberately one ticket, not several: relocating `docker`'s start step, splitting `conduit`, and splitting `hermes` are tightly coupled — landing any one alone without the others leaves the playbook in a worse state than today (either the config-timing bug stays open, or a role's provisioning tasks start running before its container exists). No safe intermediate state exists, so this ships as one atomic change.

1. **Extract `docker`'s "Start consolidated docker compose stack" task** into its own task file within the `docker` role, no longer run automatically as part of the role's default task sequence. Everything else in `docker`'s tasks (engine install, network setup, compose-file render/validate, the Hermes Dockerfile copy) stays exactly where it is today.

2. **Split `conduit`'s tasks into two files**: a config phase (prerequisite validation, directory creation, rendering `conduit.toml`) stays in the role's default sequence at its current `site.yml` position; a provisioning phase (resolving the container's IP, waiting for it to accept connections, registering the `@hermes` bot) moves into its own task file, no longer run automatically.

3. **Split `hermes`'s tasks the same way**: directory/profile-file/Dockerfile-copy tasks stay in the default sequence at the current position; the skill-install and gateway-restart tasks move into their own task file.

4. **Add an explicit step sequence to the end of the relevant play in `site.yml`**, after the existing role list completes: the relocated `docker` start step, then `conduit`'s provisioning phase, then `hermes`'s provisioning phase — invoked directly (not through the `roles:` shorthand) so their position isn't tied to where their owning role sits in the list.

5. **Delete `silverbullet`'s redundant second `docker compose up` call** entirely — fully subsumed by the single, correctly-positioned start step.

6. **No changes** to `docker_enabled_services`, any compose fragment, or `authelia`'s/`silverbullet`'s/`owntracks`'s/`gateway`'s task sequences beyond the deletion in step 5.

## Acceptance criteria

- `docker`'s compose-stack start happens after every role that renders a bind-mounted config file (`conduit`, `hermes`, `authelia`) has done so — verified by task-order assertion, not just code inspection
- `conduit`'s bot-registration and wait-for-connection tasks run only after the relocated start step, not at `conduit`'s normal `site.yml` position
- `hermes`'s skill-install and gateway-restart tasks run only after the relocated start step, not at `hermes`'s normal `site.yml` position
- `silverbullet`'s task file contains no `docker_compose_v2`/`docker compose up` invocation
- `site.yml`'s role list and every other role's position is unchanged
- `ansible-playbook --syntax-check` passes
- `docker compose config` render validation still passes unchanged (compose file content untouched)
- `tests/lint.sh` passes end to end

## Notes

- The relocated start step now runs after `backup` (the last role in today's list) rather than interleaved mid-list, since it's appended after the whole role list runs rather than threaded in at a specific point. `backup`'s tasks have no docker/container interaction (verified — no `docker`/`container` references anywhere in that role), so this is inert. Documented here as a deliberate, understood side effect, not something to "fix" further.
- Empirically confirming the exact pre-fix Docker Compose failure mode (hard failure vs. phantom-directory creation vs. silent no-op) is not required — the fix closes the gap regardless of which one it was.
- Open question, left to the implementer: whether the new end-of-play sequence lives inline in `site.yml` as a `tasks:` block or gets extracted to its own small include file. Either is fine; pick whichever keeps `site.yml` most readable top-to-bottom.
