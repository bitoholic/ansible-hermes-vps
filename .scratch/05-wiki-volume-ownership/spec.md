# Spec: Wiki-Volume Ownership Seam

> Status: ready-for-agent
> Source: Architecture review candidate #5 — "Wiki-volume ownership seam"
> Related: `04-backup-sync-module` (consumes the wiki store), `02-hermes-profile-module` (also touches it)
> Vocabulary: "wiki store", "Hermes agent".

## Problem Statement

The wiki data directory (`silverbullet_data_dir`, i.e. `hermes_home/wiki`) is **created and ownership-asserted by two different roles**:

- `roles/backup/tasks/main.yml:2-9` creates it and `chown`s it to `llm_wiki`.
- `roles/hermes/tasks/main.yml:141-147` also creates it and `chown`s it to `llm_wiki`.

Additionally, the `llm_wiki` uid/gid are **re-derived per role** via `getent` (Hermes at `:17-28`; Backup implicitly relies on the user existing). Two roles assert ownership of the same directory — a **leaking seam** with no single owner. The risk: if ownership semantics ever need to change (mode, group, ACLs), the edit must be made in two places that aren't obviously related, and a divergence is silent.

This is **speculative** depth: the duplication is small today, so this only pays off if the wiki store gains more consumers or more complex ownership rules.

## Solution

Introduce a single **`wiki_volume` module/role** that owns the data directory end-to-end: it creates the directory, asserts `llm_wiki` ownership/mode, performs git-crypt init (the backup role's current concern), and **exposes the resolved uid/gid as facts**. Both `backup` and `hermes` depend on `wiki_volume` instead of re-creating or re-deriving anything.

This gives **locality** (one module owns the wiki store) and removes the duplicated `file` tasks and repeated `getent`. The deletion test is weak here (deleting it would just move the two `file` tasks back) — hence *speculative*, only worth doing if the store gains consumers.

## User Stories

1. As a developer, I want one module to own the wiki directory and its ownership, so that I don't edit two roles to change a permission.
2. As a developer, I want the `llm_wiki` uid/gid resolved once and exposed as facts, so that roles don't each re-run `getent`.
3. As a reviewer, I want a single owner of the wiki store, so that "who owns the wiki data?" has one answer.
4. As an operator, I want idempotent creation/ownership regardless of which role runs first, so ordering between backup and hermes doesn't matter.
5. As a developer adding a third consumer of the wiki store, I want to depend on `wiki_volume` rather than re-create the directory, so the store stays single-owned.
6. As an operator running `--check --diff`, I want the ownership assertion to be previewable, so a dry run shows the intended mode/owner.
7. As a developer, I want git-crypt init to live with the volume it protects, so the encryption setup and the data dir aren't owned by different roles.

## Implementation Decisions

- **Module introduced:** a `wiki_volume` role that is the sole owner of the wiki data directory — creation, `llm_wiki` ownership/mode, (optionally) git-crypt init, and a `set_fact` exposing `wiki_volume_uid`/`wiki_volume_gid`.
- **Interface exposed:** other roles depend on `wiki_volume` and consume its facts; they no longer call `file` on `silverbullet_data_dir` nor `getent` for `llm_wiki`.
- **Seam:** `wiki_volume` is the single adapter between "the data dir exists and is owned" and the rest of the stack. Highest seam preserved — only one module touches the directory.
- **Consumers:** `backup` and `hermes` both gain a dependency on `wiki_volume` and drop their duplicated `file`/`getent` tasks. The migration removes `roles/backup/tasks/main.yml:2-9` and `roles/hermes/tasks/main.yml:141-147` (and the Hermes `getent` at `:17-28` if not otherwise needed).
- **git-crypt placement:** the git-crypt init/export currently in `backup` can move into `wiki_volume` since it protects the store itself; this is optional and noted as a follow-on to `04-backup-sync-module`.
- **No behavior change:** the deployed directory path, owner, and mode stay identical to today — this is a pure ownership-consolidation refactor.

## Testing Decisions

- **What makes a good test:** test the *external behavior* — after the role, the wiki dir exists with the correct owner/mode and the uid/gid facts are set; idempotency holds on a second run. Do not assert on Ansible task internals.
- **Modules tested:**
  - `wiki_volume`: assert directory owner/group/mode, and that re-running is a no-op (changed=false).
  - Consumer contract: assert `backup` and `hermes` no longer contain `file` tasks targeting `silverbullet_data_dir` (a grep/static check preventing regression of the duplication).
- **Prior art:** mirror the repo's existing `--check --diff` dry-run and top-level `assert` pre-flight pattern for ownership verification.

## Out of Scope

- The `01-secret-manifest` resolver — unrelated, though git-crypt key handling may later consume it.
- The `04-backup-sync-module` logic — this spec only consolidates *ownership*, not sync behavior (git-crypt init relocation is optional/follow-on).
- Changing the actual ownership model (e.g. per-profile dedicated users) — out of scope; today keeps `llm_wiki`.
- Hermes profile or gateway refactors — unrelated.

## Further Notes

- This is the **speculative** candidate: the duplication is currently only two small `file` tasks, so the leverage is low unless the wiki store gains consumers or richer ownership rules.
- Recommended as the **fifth / last** change — or skipped until a third consumer of the wiki store appears. The spec is recorded so a future review doesn't re-suggest it without cause.
- If rejected as not worth it now, consider recording that decision as an ADR (e.g. "wiki store ownership stays duplicated until a 3rd consumer exists") so future architecture reviews don't re-raise it.

## Tickets

Consolidation approved (not skipped). Five vertical slices under `.scratch/05-wiki-volume-ownership/issues/`:

- **#01** `01-create-wiki-volume-role.md` — introduce `wiki_volume` role (sole owner of `silverbullet_data_dir`; create + `llm_wiki` ownership/mode `0775`; resolve uid/gid once via `getent`; `set_fact` `wiki_volume_uid`/`wiki_volume_gid`). Depends on `users`.
- **#02** `02-silverbullet-consume-wiki-volume.md` — `silverbullet` drops its duplicate `file` + `getent`; consumes `wiki_volume_uid`/`wiki_volume_gid`. *Blocked by #01.*
- **#03** `03-backup-consume-wiki-volume.md` — `backup` drops its duplicate `file` task; rest unchanged. *Blocked by #01.*
- **#04** `04-hermes-consume-wiki-volume.md` — `hermes` drops its `getent` + `set_fact`; consumes `wiki_volume_uid`/`wiki_volume_gid`. *Blocked by #01.*
- **#05** `05-tests-lint-wiring.md` — `tests/check-wiki-volume.sh` (consumer-contract grep + idempotency/owner assertion) wired into `tests/lint.sh`. *Blocked by #01–#04.*

> Note: spec line refs (`backup:2-9`, `hermes:141-147`) were stale at ticket time — the actual
> duplication is `silverbullet_data_dir` created by `roles/silverbullet` **and** `roles/backup`,
> and `getent` for `llm_wiki` duplicated in `roles/silverbullet` **and** `roles/hermes`. git-crypt
> init stays in `backup` (moved there by epic 04), so `wiki_volume` owns only directory
> creation/ownership + uid/gid facts, per the spec's "optional follow-on" note.
