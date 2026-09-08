# Ticket #02: docker depends on gateway

**Status: NOT IMPLEMENTED AS SPECIFIED — deferred, see "Decision" below.**

**Blocked by:** none
**Blocks:** none (parallel with #01)

## Decision (made during implementation, not by the original ticket author)

**This ticket's approach is unsafe given a fact not known when it was written, and was not implemented.** While implementing ticket #01 ("gateway depends on owntracks"), it was discovered that `docker`'s own tasks already run **five times** per `site.yml` execution on `main`, unrelated to epic 15 — `conduit`, `hermes`, `authelia`, and `silverbullet` each declare `docker` as a `meta/main.yml` dependency (for the transitive `wiki_volume` chain, established in epic 14/earlier), while `docker` is *also* explicitly listed in `site.yml`, and Ansible does not deduplicate an explicit `roles:` entry against another role's dependency on it (see ticket #01's Notes for the full empirical finding).

Verified directly (temporarily edited `roles/docker/meta/main.yml` to add `gateway` as a dependency, ran `ansible-playbook site.yml --list-tasks`, then reverted): with this ticket implemented exactly as specified, `gateway`'s tasks run **6 times** per playbook execution, and `owntracks`'s tasks (pulled in transitively through `gateway`'s own dependency from ticket #01) *also* run **6 times** — up from 1. This isn't a corner case; it reproduces on the real `site.yml` every time.

Fixing this properly — so `docker` itself runs exactly once regardless of how many roles depend on it, freeing this ticket to add `gateway` safely — would require removing `docker`'s own explicit `site.yml` entry, which shifts *where* `docker`'s dependency chain runs (to wherever the first of `conduit`/`hermes`/`authelia`/`silverbullet` sits in the list — currently *after* `docker`'s current position, and before three of the four). That reordering risk is entirely outside this ticket's scope and this epic's problem statement.

**Additionally**, epic 16 (already spec'd, next in the implementation queue after this epic) independently fixes the actual underlying problem this ticket exists to address — "the Caddyfile must exist before `docker`'s compose stack starts" — by relocating `docker`'s "start stack" task to run after every config-deploying role (including `gateway`), via an explicit end-of-play sequence rather than a `meta/main.yml` dependency. Once epic 16 lands, this ordering is structurally guaranteed by a mechanism that doesn't have this ticket's duplication problem at all, making a `docker`→`gateway` dependency unnecessary on top of it.

**Recommendation for a human to decide, not assumed here**: leave this ticket un-implemented as specified. If the `docker`-runs-5x problem is ever fixed properly (its own future epic), reconsider whether a `docker`→`gateway` dependency is still worth adding on top of epic 16's fix, or whether epic 16 alone already covers it.

## Description (original, as written — see Decision above for why this was not carried out)

`docker`'s consolidated compose stack starts the `caddy` container, which bind-mounts the rendered Caddyfile — so `gateway` must have already run. This is correct in `site.yml` today only by list position, and has needed a dedicated historical fix once already (an earlier commit reordering `site.yml` for exactly this reason). Nothing currently stops a future edit from breaking it again.

1. **Extend `roles/docker/meta/main.yml`** (exists today, already declares `wiki_volume` as a dependency) to also declare `gateway` as a dependency.

2. **Regression test**: same shape as ticket #01 — a throwaway test playbook that deliberately lists `docker` before `gateway` and asserts `gateway`'s tasks still execute first.

3. Do not change `site.yml`'s existing role list order — it's already correct; this ticket makes that correctness enforced, not just conventional.

## Acceptance criteria

- `roles/docker/meta/main.yml` declares both `wiki_volume` (unchanged) and `gateway` as dependencies
- A test deliberately orders `docker` before `gateway` in a role list and asserts `gateway`'s tasks still execute first
- `ansible-playbook --syntax-check` passes on `site.yml`
- `site.yml`'s role list is unchanged
- No duplicate execution of `gateway`'s tasks when both the explicit `site.yml` listing and the new dependency are present in the same play

## Notes

- Matches the existing `wiki_volume` `meta/main.yml` dependency pattern — not a new idiom, a wider application of one already in the repo.
- Independent of ticket #01 — no shared blocker, can be implemented in either order or in parallel.
