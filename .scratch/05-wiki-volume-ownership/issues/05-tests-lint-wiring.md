---
title: Tests + lint wiring for wiki_volume and consumer contract
status: ready-for-agent
blocked_by:
  - 01-create-wiki-volume-role
  - 02-silverbullet-consume-wiki-volume
  - 03-backup-consume-wiki-volume
  - 04-hermes-consume-wiki-volume
depends_on: [wiki_volume]
---

# #05 — Tests + lint wiring (wiki_volume + consumer contract)

Add a CI-surfacesafe test that the wiki store has a single owner and that no consumer re-creates
or re-derives it. A live `ansible-playbook site.yml --check --diff` of `wiki_volume` is
operator-validated on the VPS (needs the `llm_wiki` user, which doesn't exist in CI), so the
runnable equivalent is a static consumer-contract guard plus an idempotency/owner assertion that
can run where `llm_wiki` exists.

## What to build

- `tests/check-wiki-volume.sh`:
  - **Consumer contract (grep):** assert `roles/backup/tasks/main.yml` and
    `roles/silverbullet/tasks/main.yml` do **not** contain a `file` task with
    `path: "{{ silverbullet_data_dir }}"`, and that `getent`/`key: llm_wiki` appears only in
    `roles/wiki_volume` and `roles/users` (no other role re-resolves the user). This prevents the
    duplication from regressing.
  - **Idempotency/owner assertion:** where the `llm_wiki` user is available, run the `wiki_volume`
    role once, assert `silverbullet_data_dir` is owned `llm_wiki:llm_wiki` mode `0775`, run it again
    and assert `changed=false`.
  - **Single-owner assertion:** assert `roles/wiki_volume` is the only role with a `file` task for
    `silverbullet_data_dir`.
- Wire `./tests/check-wiki-volume.sh` into `tests/lint.sh` so a regression fails CI (mirror the
  epic-04 wiring of `check-backup-sync.sh` / `check-backup-role.sh`).

## Acceptance (Definition of Done)

- [ ] `tests/check-wiki-volume.sh` exists, is executable, and exits non-zero on any contract
      violation (a consumer re-creating or re-deriving the wiki store).
- [ ] It is invoked from `tests/lint.sh`; `bash tests/lint.sh` exits 0 on the consolidated tree.
- [ ] A `--check --diff` of `wiki_volume` is operator-validated on the VPS and shows the intended
      owner/mode (no change from today).
