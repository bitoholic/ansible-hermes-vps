# Ticket #01: gateway depends on owntracks

**Blocked by:** none
**Blocks:** none (parallel with #02)

## Description

`gateway`'s Caddyfile render reads htpasswd credentials that `owntracks`'s tasks generate as facts. This is correct in `site.yml` today only by list position (`owntracks` happens to be listed before `gateway`) — nothing stops a future edit from reordering them back into the broken configuration that shipped once already during the OwnTracks HTTP-auth security fix.

1. **Create `roles/gateway/meta/main.yml`** (the `gateway` role has no `meta/` directory today) declaring `owntracks` as a dependency.

2. **Regression test**: a throwaway test playbook (mirroring the isolated-playbook pattern already used elsewhere in `tests/`) that deliberately lists `gateway` before `owntracks` — the wrong order — and asserts the actual task execution order still places `owntracks`'s tasks first. This proves the dependency, not list position, governs order.

3. Do not change `site.yml`'s existing role list order — it's already correct; this ticket makes that correctness enforced, not just conventional.

## Acceptance criteria

- `roles/gateway/meta/main.yml` exists and declares `owntracks` as a dependency
- A test deliberately orders `gateway` before `owntracks` in a role list and asserts `owntracks`'s tasks still execute first
- `ansible-playbook --syntax-check` passes on `site.yml`
- `site.yml`'s role list is unchanged
- No duplicate execution of `owntracks`'s tasks when both the explicit `site.yml` listing and the new dependency are present in the same play

## Notes

- Matches the existing `wiki_volume` `meta/main.yml` dependency pattern — not a new idiom, a wider application of one already in the repo.
- Ansible skips re-running a role that already ran earlier in the same play, so this is safe to add without risking `owntracks` running twice given it's already listed explicitly in `site.yml`.
