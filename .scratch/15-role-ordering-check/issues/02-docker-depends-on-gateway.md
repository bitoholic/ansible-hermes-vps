# Ticket #02: docker depends on gateway

**Blocked by:** none
**Blocks:** none (parallel with #01)

## Description

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
