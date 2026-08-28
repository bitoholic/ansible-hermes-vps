---
title: Create wiki_volume role (sole owner of the wiki store)
status: ready-for-agent
blocked_by: []
depends_on: [users]
---

# #01 — Create `wiki_volume` role (sole owner of the wiki store)

The wiki data directory (`silverbullet_data_dir` = `hermes_home/wiki`) is currently created and
`chown`ed by both `roles/silverbullet` and `roles/backup`, and `llm_wiki` uid/gid are re-derived
via `getent` in two roles. Introduce a single **`wiki_volume`** role that owns the wiki store
end-to-end: it creates the directory, asserts `llm_wiki` ownership/mode, resolves the uid/gid
**once**, and exposes them as facts. This is the sole seam that touches the wiki directory.

## What to build

A new `roles/wiki_volume/tasks/main.yml` whose external behavior is:

- Resolve `llm_wiki` via `getent` (guarded, `failed_when: false`) and assert it was created by
  the `users` role (the role depends on `users`).
- `set_fact` `wiki_volume_uid` and `wiki_volume_gid` from the resolved passwd entry — resolved exactly once
  (repo convention: role-prefixed facts, e.g. `silverbullet_host_uid`).
- `ansible.builtin.file`: `path: "{{ silverbullet_data_dir }}"`, `state: directory`,
  `owner: llm_wiki`, `group: llm_wiki`, `mode: '0775'`. The deployed path, owner, and mode are
  **identical** to today — no behavior change.

## Acceptance (Definition of Done)

- [ ] `roles/wiki_volume/tasks/main.yml` exists and is the only role that calls `file` on
      `silverbullet_data_dir`.
- [ ] It `set_fact`s `wiki_volume_uid` and `wiki_volume_gid`; every other role consumes these instead of
      re-running `getent` for `llm_wiki`.
- [ ] Running the role twice is a no-op (`changed=false` on the second run) — idempotent.
- [ ] A `--check --diff` dry run previews the intended owner/mode (operator-validated on VPS).
- [ ] No behavior change: the deployed directory path, owner, and mode match the pre-refactor state.
