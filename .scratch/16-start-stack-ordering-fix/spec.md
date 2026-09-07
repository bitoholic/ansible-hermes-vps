# Spec: Fix docker-starts-before-config-exists ordering

> Status: ready-for-agent
> Source: Epic 16 — real, currently-live gap found while grounding epic 15 (machine-checked role ordering); deliberately scoped out of that epic and tracked separately, as flagged in its Further Notes
> Related: `15-role-ordering-check` (sibling ordering-fragility epic; this one is not fixable by the same `meta/main.yml`-dependency mechanism), `11-docker-consolidation` (ADR-0002 — the consolidated compose stack this epic's "start" step belongs to), `14-wiki-volume-directory-module` (a different instance of the same "container needs a host artifact that doesn't exist yet" bug class, already fixed once for OwnTracks's storage directory)
> Vocabulary: "gateway_publish"/"gateway_routes" (unaffected, for reference only), "docker_enabled_services", "consolidated docker-compose.yml" — no existing ADR governs task-level ordering within a role; ADR-0002 covers the compose-file consolidation this epic's fix builds on top of, not this specific ordering gap

## Problem Statement

`docker`'s "Start consolidated docker compose stack" task brings up every service in `docker_enabled_services` — including `conduit`, `authelia`, and `hermes-agent` — in one call, positioned in `site.yml` *before* the `conduit`, `hermes`, `authelia`, and `silverbullet` roles ever run. Those roles are the ones that render the host-side config files those same containers bind-mount: `conduit.toml` for Conduit, `configuration.yml`/`users.yml` for Authelia, and per-profile `config.yaml`/`SOUL.md`/`.env` files for the Hermes agent.

On a genuinely fresh VPS bootstrap, this means containers can start before the files they depend on exist on the host. This is the same bug class already fixed at least twice elsewhere in this repo for other services (the OwnTracks recorder's storage directory needing to exist, owned correctly, before first container start; a stale Caddyfile directory needing to be cleared before rendering) — a missing bind-mount source can produce a host-side artifact (an empty directory where a file was expected) that then blocks the real file from ever landing correctly without manual intervention, even after the owning role later runs and tries to deploy it. Because the host-side artifact persists once created, this only bites on a *fresh* bootstrap — an already-provisioned host with the files already in place won't hit it on a routine re-run, which is why it's gone unnoticed.

There's already a partial, incomplete workaround in the codebase: the `silverbullet` role independently re-invokes `docker compose up`, scoped to `caddy`/`authelia`/`silverbullet`, positioned after Authelia's config renders. It doesn't help, for two reasons: it doesn't cover `conduit` or `hermes-agent` at all, and even for the services it does cover, a plain `up` call doesn't force a container to reload a bind-mounted file whose *content* changed after the container already started with whatever was there (Compose only recreates a container when the service *definition* changes, not when an external bind-mounted file's bytes change).

One related risk turns out to already be mitigated: `hermes-agent`'s compose service `build`s its image from a Dockerfile (not a pulled image), which would be a hard failure if missing at "up" time — but the `docker` role already independently copies that Dockerfile into place immediately before its own "start" task, so the build itself is not at risk. The per-profile Hermes files (bind-mounted at runtime, not part of the build) are still exposed.

## Solution

Move the actual "start the compose stack" step to run *after* every role that deploys a bind-mounted config file has done so, without disturbing the rest of `site.yml`'s role order. Split the two roles whose tasks currently straddle the stack-start point (`conduit`, `hermes`) into a config phase (stays where it runs today) and a provisioning phase (needs the container already running — moves to run after the relocated start step). Delete the `silverbullet` role's redundant, ineffective second `up` call now that a single, correctly-positioned start step covers everything.

## User Stories

1. As a VPS operator, I want the compose stack to start only after every service's bind-mounted config file already exists on the host, so that a fresh bootstrap can't produce a phantom empty directory where a config file belongs.
2. As a VPS operator, I want `conduit.toml` to exist before the Conduit container starts, so that Conduit boots with its real configuration on the first try, not an empty or missing file.
3. As a VPS operator, I want the Hermes agent's per-profile `config.yaml`/`SOUL.md`/`.env` files to exist before the `hermes-agent` container starts, so that profiles are correctly configured from the container's first boot.
4. As a VPS operator, I want Authelia's `configuration.yml`/`users.yml` to exist before its container starts, so that Authelia doesn't need a second, unreliable `up` call to pick up its real config.
5. As a maintainer, I want `conduit`'s bot-registration and wait-for-connection tasks to keep running only after the Conduit container is actually up, so that splitting the role doesn't break the provisioning half that already correctly assumes a running container.
6. As a maintainer, I want `hermes`'s skill-install and gateway-restart tasks to keep running only after the `hermes-agent` container is actually up, for the same reason.
7. As a maintainer, I want the `silverbullet` role's redundant second `docker compose up` call removed, so that there's exactly one place that starts the stack, not two invocations with unclear relative purpose.
8. As a maintainer, I want the relocated "start stack" step to stay a single call covering every enabled service (as it is today), so that this epic doesn't change *what* gets started, only *when*.
9. As a reviewer, I want `site.yml`'s existing role list and order left otherwise unchanged, so that this epic's diff is legible as "move one step, split two roles into two files each" rather than a wholesale restructuring.
10. As a test author, I want a regression test proving the relocated start step actually runs after every config-deploying role's relevant tasks, so that a future edit can't silently move it back to the wrong position.

## Implementation Decisions

- **`docker`'s "Start consolidated docker compose stack" task moves into its own task file within the `docker` role** (not run automatically as part of the role's normal task sequence), leaving the rest of `docker`'s tasks (engine install, network setup, compose-file render and validation, the Hermes Dockerfile copy) exactly where they are today, in their current `site.yml` position.
- **`conduit`'s tasks split into two files within the same role**: a config phase (prerequisite validation, directory creation, rendering `conduit.toml`) stays in the role's normal task sequence at its current `site.yml` position; a provisioning phase (resolving the container's IP, waiting for it to accept connections, registering the `@hermes` bot account) moves into its own task file, no longer run automatically as part of the role's default sequence.
- **`hermes`'s tasks split the same way**: directory/profile-file/Dockerfile-copy tasks stay in the normal sequence at the current position; the skill-install and gateway-restart tasks (which need the running container) move into their own task file.
- **A new, explicit step sequence is added to the end of the relevant play in `site.yml`**, running after the existing role list completes: the relocated `docker` start step, then the `conduit` provisioning phase, then the `hermes` provisioning phase, invoked directly rather than through the role-list shorthand (so their position isn't tied to where their owning role sits in the list).
- **`silverbullet`'s redundant second `docker compose up` call is deleted outright.** It becomes fully subsumed by the single, correctly-positioned start step — nothing else in `silverbullet`'s role needs it.
- **No change to `docker_enabled_services`, to what gets started, or to any compose fragment.** This epic changes *when* the stack starts, not *what* is in it — `authelia` and `silverbullet` (config-only roles, no post-start dependency) are unaffected beyond the deletion above.
- **The relocated start step now runs after `backup`** (the last role in today's list), since it's appended after the whole role list rather than threaded in at a specific mid-list point. Verified `backup`'s tasks have no docker/container interaction, so this reordering is inert — flagged here so it's a documented, deliberate side effect, not a silent one.

## Testing Decisions

- **What makes a good test**: verify actual task execution order (which task references which file, and whether that file exists on the host by the time the task runs), not `site.yml`'s literal structure.
- **Modules tested**:
  - A regression test (mirroring the isolated-playbook pattern used elsewhere in `tests/`) asserting the relocated `docker` start step's position is after `conduit`'s and `hermes`'s config-phase tasks and after `authelia`'s config render — e.g. via `ansible-playbook --list-tasks` output order, or an equivalent structural check.
  - A check that `conduit`'s and `hermes`'s provisioning-phase tasks are *not* part of their role's default task sequence (so they don't run at the role's normal `site.yml` position) and *are* invoked in the new end-of-play sequence.
  - A check that `silverbullet`'s task file no longer contains a `docker_compose_v2` "up" invocation.
  - Full `docker compose config` render validation (existing) must keep passing unchanged — this epic doesn't touch the compose file itself.
- **Prior art**: no exact prior art exists for "assert task-execution order within a single play" — closest is epic 15's dependency-order tests (a different mechanism, role-level meta dependencies, not applicable here since this is a task-level split within roles that stay in the same relative role-list position). Keep the new test in the same isolated-playbook style as the rest of the suite.

## Out of Scope

- **`authelia`, `silverbullet`, `owntracks`, `gateway`** — no task-level changes beyond deleting `silverbullet`'s redundant `up` call; none of these need a config/provision split.
- **Changing what services `docker_enabled_services` starts, or any compose fragment** — this epic is purely about timing, not content.
- **Verifying the exact Docker Compose failure mode** (hard failure vs. phantom-directory creation vs. silent no-op) on the specific Docker Engine version this VPS runs — the fix closes the gap either way; empirically confirming the precise pre-fix failure mode is not required to implement it.
- **epic 15's ordering edges** (`owntracks`→`gateway`, `gateway`→`docker`) — separate epic, separate mechanism (`meta/main.yml` dependencies), already spec'd.
- **Reworking `hermes`'s Dockerfile-copy duplication between the `hermes` and `docker` roles** — that duplication is real (flagged in epic 14) but already correctly ordered (the `docker`-role copy runs before the build that needs it) and not a live bug; left as epic 14's concern, not this one's.

## Further Notes

- This epic exists because epic 15's grounding surfaced a real, currently-live gap that wasn't fixable by that epic's mechanism (`meta/main.yml` role dependencies) — `conduit`'s and `hermes`'s tasks straddle the stack-start point, so no whole-role reordering satisfies both halves.
- The fix is deliberately minimal: move one task to its own file, split two roles into two files each, add a short explicit sequence at the end of the play, delete one redundant task. No wholesale conversion of `site.yml`'s role list into an explicit task sequence — everything not directly involved in this ordering problem stays exactly as it is today.
- Open question left to the implementer: whether the new end-of-play sequence should live inline in `site.yml` (as a `tasks:` block) or be extracted into its own small include file for readability. Either is fine; existing tests don't distinguish between the two — pick whichever keeps `site.yml` easiest to read as a top-to-bottom description of what happens.
