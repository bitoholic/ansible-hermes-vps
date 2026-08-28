---
title: silverbullet consumes wiki_volume (drop duplicate file + getent)
status: ready-for-agent
blocked_by: [01-create-wiki-volume-role]
depends_on: [wiki_volume]
---

# #02 — `silverbullet` consumes `wiki_volume`

`roles/silverbullet/tasks/main.yml` currently creates `silverbullet_data_dir` (the duplicate
`file` task) and re-derives `llm_wiki` uid/gid via `getent` + `set_fact` (`silverbullet_host_uid`/
`silverbullet_host_gid`). After this ticket, silverbullet no longer owns the wiki store and no
longer resolves the user — it depends on `wiki_volume` and consumes `wiki_volume_uid`/`wiki_volume_gid`.

## What to build

- Remove from `roles/silverbullet/tasks/main.yml`: the `file` task that creates `silverbullet_data_dir`
  and the `getent`/`assert`/`set_fact` block for `llm_wiki`. (`silverbullet_compose_dir` creation
  stays in silverbullet — only the wiki *data* dir moves to `wiki_volume`.)
- Wherever silverbullet referenced `silverbullet_host_uid`/`silverbullet_host_gid`, switch to
  `wiki_volume_uid`/`wiki_volume_gid` (or drop if unused).
- Wire the dependency so `wiki_volume` runs before `silverbullet` (`roles/silverbullet/meta/main.yml`
  dependency, or playbook order in `site.yml`).

## Acceptance (Definition of Done)

- [ ] `roles/silverbullet/tasks/main.yml` no longer contains a `file` task targeting
      `silverbullet_data_dir` nor a `getent` for `llm_wiki`.
- [ ] silverbullet consumes `wiki_volume_uid`/`wiki_volume_gid` instead of its own `set_fact`.
- [ ] The SilverBullet stack still deploys and starts; the wiki dir is owned `llm_wiki:llm_wiki`
      `0775` (now via `wiki_volume`).
- [ ] `bash tests/lint.sh` stays green (consumer-contract grep in ticket #05 passes).
