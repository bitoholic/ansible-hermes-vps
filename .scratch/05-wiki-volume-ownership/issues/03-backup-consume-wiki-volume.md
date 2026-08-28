---
title: backup consumes wiki_volume (drop duplicate file task)
status: ready-for-agent
blocked_by: [01-create-wiki-volume-role]
depends_on: [wiki_volume]
---

# #03 — `backup` consumes `wiki_volume`

`roles/backup/tasks/main.yml` currently creates `silverbullet_data_dir` (the duplicate `file`
task) before cloning. After this ticket, backup no longer owns the wiki store — it depends on
`wiki_volume`, which has already created/owned the directory. The rest of backup (module deploy,
credential helper, watcher units, git-crypt init, cron) is unchanged.

## What to build

- Remove from `roles/backup/tasks/main.yml` the `file` task that creates `silverbullet_data_dir`.
- Wire the dependency so `wiki_volume` runs before `backup` (`roles/backup/meta/main.yml`
  dependency, or playbook order in `site.yml`).

## Acceptance (Definition of Done)

- [ ] `roles/backup/tasks/main.yml` no longer contains a `file` task targeting `silverbullet_data_dir`.
- [ ] backup still deploys `backup_sync`, the credential helper, the watcher units, and the nightly
      cron; git-crypt init is unchanged.
- [ ] The clone/sync operate on a directory already owned `llm_wiki:llm_wiki` `0775` (via `wiki_volume`).
- [ ] `bash tests/lint.sh` stays green (consumer-contract grep in ticket #05 passes).
