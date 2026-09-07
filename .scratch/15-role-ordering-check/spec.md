# Spec: Machine-Checked Role Ordering

> Status: ready-for-agent
> Source: Epic 15 — architecture review candidate "Make role ordering a checked constraint, not tribal knowledge" (hot-spot scan of git log)
> Related: `05-wiki-volume-ownership` (the one existing precedent for a machine-checked cross-role dependency — `wiki_volume` via `meta/main.yml`), `12-add-custom-services` (the epic whose ticket #08 Part B and the later OwnTracks HTTP-auth fix both required reordering `site.yml` by hand), `14-wiki-volume-directory-module` (sibling epic from the same architecture review, unrelated mechanism)
> Vocabulary: "seam", "deep module", "locality" — no existing ADR governs role ordering; `wiki_volume`'s `meta/main.yml` dependency is the closest existing precedent, not a formal decision record

## Problem Statement

Most cross-role ordering constraints in this repo are enforced only by a role's position in `site.yml`'s flat list — not by anything Ansible or the test suite actually checks. `wiki_volume` is the one exception: every role that needs its resolved `llm_wiki` uid/gid facts declares it as a real `meta/main.yml` dependency, so Ansible enforces the order regardless of list position. Nothing else in the repo gets that treatment.

Two concrete, currently-correct-but-unprotected edges illustrate the gap:

- **`owntracks` before `gateway`**: `gateway`'s Caddyfile render now reads htpasswd credentials that `owntracks`'s tasks generate as facts. This is correct in `site.yml` today (fixed as part of the OwnTracks HTTP-auth security fix), but nothing stops a future edit from moving `gateway` back above `owntracks` — exactly the kind of change that shipped silently once already before being caught.
- **`gateway` before `docker`**: the rendered Caddyfile must exist before `docker`'s consolidated compose stack starts the `caddy` container that mounts it. This has needed a dedicated historical fix (an earlier commit reordering `site.yml` for exactly this reason) and, like the edge above, is unprotected against a future reorder.

Both are currently correct by accident of list position, not by anything that would fail loudly if someone got the order wrong again.

## Solution

Where an ordering constraint is a clean, whole-role dependency, declare it as a real Ansible `meta/main.yml` dependency — the same mechanism `wiki_volume` already uses, so this isn't a new idiom, just a wider application of an existing one. Ansible then enforces the order structurally (a role's declared dependencies run before it, regardless of `site.yml` list position) instead of relying on the list staying correct by convention. Add a regression test proving the order holds even when the roles are deliberately listed in the wrong order, so the mechanism — not today's incidental list position — is what's actually verified.

## User Stories

1. As a VPS operator, I want `gateway` to declare `owntracks` as a real dependency, so that a future `site.yml` edit can't silently reorder them back into the broken configuration that shipped once already.
2. As a VPS operator, I want `docker` to declare `gateway` as a real dependency, so that the historical "Caddyfile must exist before the compose stack starts" fix can't silently regress.
3. As a maintainer, I want role-ordering constraints enforced the same way `wiki_volume`'s uid/gid dependency already is, so that this repo has one consistent idiom for "role A needs role B to have already run," not a mix of enforced-and-unenforced dependencies.
4. As a test author, I want a regression test that deliberately lists the dependent roles in the wrong order and asserts the correct execution order still holds, so that the test verifies the actual mechanism (Ansible's dependency resolution) rather than today's incidental list position in `site.yml`.
5. As a future epic author, I want a documented, working pattern for declaring a new role-ordering constraint, so that the next epic that introduces one (as several already have) reaches for a `meta/main.yml` dependency instead of just editing `site.yml`'s list and hoping.
6. As a reviewer, I want `site.yml`'s role list order to remain readable and roughly reflect execution order for human readers, so that this epic doesn't make ordering *only* legible to Ansible's dependency resolver — the list order stays a reasonable default even though it's no longer the sole enforcement mechanism.

## Implementation Decisions

- **`roles/gateway/meta/main.yml`** (does not exist today — `gateway` has no `meta/` directory at all) is created, declaring `owntracks` as a dependency.
- **`roles/docker/meta/main.yml`** (exists today, already declares `wiki_volume`) gains `gateway` as an additional dependency, alongside its existing one.
- **`site.yml`'s role list order is left as-is** — it already reflects the correct order (`owntracks` before `gateway` before `docker`). This epic makes that order enforced, not just conventionally correct; it does not need to change the list itself.
- **Mechanism choice**: `meta/main.yml` dependencies, not a `tests/lint.sh` assertion parsing `site.yml`'s list order. A lint check would only verify *today's* list happens to be in the right order — it wouldn't prevent a future edit from breaking it, and it would become the wrong thing to test once a real dependency exists (the list position stops being load-bearing). `meta/main.yml` is structural: Ansible auto-runs a declared dependency before the role itself, and skips re-running it if it already ran earlier in the same play — so this is safe to add without risking duplicate execution given `owntracks` and `gateway` are already listed once each in `site.yml`.

## Testing Decisions

- **What makes a good test**: verify actual execution order, not `site.yml`'s literal text. A test that greps `site.yml` for list position would test the wrong thing once a real dependency exists — the list stops being what determines order.
- **Modules tested**:
  - A throwaway test playbook (mirroring the isolated-playbook pattern already used by `tests/test_gateway_render.yml` and `tests/test_docker_compose.yml`) that deliberately lists `gateway` before `owntracks` (the wrong order) and asserts the actual task execution order still places `owntracks`'s tasks first — proving the `meta/main.yml` dependency, not list position, governs order. Same pattern for `docker` before `gateway`.
  - `roles/gateway/meta/main.yml` and `roles/docker/meta/main.yml` → assert the dependency declarations exist (a simple structural check, cheap regression guard against accidental deletion).
- **Prior art**: no exact prior art for "assert dependency-driven order regardless of list position" exists yet in this repo — the closest is `tests/check-wiki-volume.sh`'s consumer-contract guard, which checks that only one role owns a concern, not ordering specifically. This epic's test is the first of its kind; keep it in the same isolated-playbook style as the rest of the suite rather than inventing a new test format.

## Out of Scope

- **A general "declare every ordering constraint as a dependency" sweep.** This epic covers the two known, clean, whole-role-level edges (`owntracks`→`gateway`, `gateway`→`docker`). It does not attempt to audit and fix every ordering constraint in the repo.
- **The broader `docker`-starts-the-stack-before-other-roles-deploy-their-config-files pattern** (see Further Notes) — a real, currently-live gap found while grounding this spec, but structurally different from the two edges above (it isn't fixable by simple role reordering) and deserves its own epic, not to be silently bundled into this one.
- **Any change to what a role's tasks actually do** — this epic only adds dependency declarations and a regression test; no task logic changes.

## Further Notes

- This is the third of three deepening candidates surfaced by the architecture review that also produced epic 13 (gateway route schema, already spec'd and ticketed) and epic 14 (wiki_volume directory-bootstrap module, already spec'd and ticketed).
- **A significant, currently-unfixed finding surfaced while grounding this spec, flagged rather than folded in**: `docker`'s "start consolidated docker compose stack" task runs *before* `conduit`, `hermes`, `authelia`, and `silverbullet` — all listed after `docker` in `site.yml` — deploy their own config files, which their containers bind-mount (`conduit.toml` for Conduit; `config.yaml`/`SOUL.md`/`.env` per profile, and possibly a `Dockerfile` referenced by a compose `build:` context, for Hermes). On a genuinely fresh VPS bootstrap, this means those containers can start (or, for Hermes, potentially fail to *build*) before the files they depend on exist. Unlike the two edges this epic fixes, this one is not a simple "swap two roles in the list": `conduit`'s later tasks (bot registration, waiting for the container to accept connections) need the container *already running*, so `conduit`'s own tasks straddle `docker`'s stack-start point — no single whole-role ordering satisfies both halves. Resolving this likely requires splitting config-deployment from post-start provisioning (two phases, possibly two roles) for each affected role. This is real, but it's a distinct and harder problem than "add a `meta/main.yml` dependency" — recommend it become its own epic once someone verifies the actual failure mode (whether `docker compose up` hard-fails, silently mounts a phantom empty directory, or self-heals on a second playbook run) rather than guessing at the fix here.
- Both edges this epic *does* fix are currently correct by luck of list position — this epic changes nothing about runtime behavior on a correctly-ordered `site.yml` (today's), only what happens if the order is ever broken again.
