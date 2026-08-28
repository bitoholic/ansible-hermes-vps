---
title: hermes consumes wiki_volume facts (drop duplicate getent)
status: ready-for-agent
blocked_by: [01-create-wiki-volume-role]
depends_on: [wiki_volume]
---

# #04 — `hermes` consumes `wiki_volume` facts

`roles/hermes/tasks/main.yml` re-derives `llm_wiki` uid/gid via `getent` + `set_fact`
(`hermes_host_uid`/`hermes_host_gid`). Hermes does **not** create the wiki dir (it owns
`hermes_home` and `signal-data`), but it still duplicates the `getent` resolution. After this
ticket, hermes consumes `wiki_volume_uid`/`wiki_volume_gid` from `wiki_volume` and drops its own `getent`.

## What to build

- Remove from `roles/hermes/tasks/main.yml` the `getent`/`assert`/`set_fact` block for `llm_wiki`.
- Switch every reference to `hermes_host_uid`/`hermes_host_gid` to `wiki_volume_uid`/`wiki_volume_gid`.
- Wire the dependency so `wiki_volume` runs before `hermes` (`roles/hermes/meta/main.yml`
  dependency, or playbook order in `site.yml`).

## Acceptance (Definition of Done)

- [ ] `roles/hermes/tasks/main.yml` no longer contains a `getent` for `llm_wiki` nor a `set_fact`
      of `hermes_host_uid`/`hermes_host_gid`.
- [ ] hermes consumes `wiki_volume_uid`/`wiki_volume_gid` where it previously used host uid/gid.
- [ ] The Hermes container stack still deploys and starts as before.
- [ ] `bash tests/lint.sh` stays green (consumer-contract grep in ticket #05 passes).
