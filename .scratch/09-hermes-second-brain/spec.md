# Spec: Hermes single-agent consolidation (second brain)

> Status: ready-for-human
> Source: Operator decision to stop running Hermes as multiple profiles (coder/intel were
> dormant — no gateway, no bot token) and instead run one main "second brain" agent that can
> code, research, and gatekeep the wiki itself, and spins up anonymous delegation subagents for
> heavy parallel work. Related: `CONTEXT.md` (Hermes agent), `02-hermes-profile-module`,
> `05-wiki-volume-ownership`, `08-hermes-skill-packs`.

## Problem Statement

The repo deploys Hermes as three profiles — `default` (The Robot, chief of staff / wiki
gatekeeper), `coder` (coding sandbox), and `intel` (IT research scraper). In practice only
`default` runs (`docker-compose.yml.j2` starts a single `hermes-agent` gateway; `coder`/`intel`
have no gateway or bot token). Meanwhile the operator's real plan is to point the main agent at a
code repo and have *it* spin up a coding team via `delegate_task`. Because delegated children are
anonymous clones of the parent that **skip the parent SOUL** (identity belongs to the parent), the
`coder`/`intel` SOULs were never going to drive delegated workers anyway. The multi-profile baggage
also buries the wiki data inside the agent's home volume (`/opt/hermes/wiki`), coupling the second
brain to the agent's state.

## Solution

Run exactly **one** Hermes agent (the `default` profile) reimagined as a generalist "second brain /
chief of staff". Drop `coder` and `intel` entirely. Merge their capabilities into the single SOUL
(modernized voice, no butler theater). Enable delegation `worktree_isolation` and raise
`max_concurrent_children` to 5 so the main agent can orchestrate a parallel coding team with isolated
git worktrees. Move the wiki data to a dedicated `/opt/wiki` volume that follows the repo's
`/opt/<service>` layout convention, automatically carrying the `wiki_volume` and `backup` roles.

## Implementation Decisions

- **Single profile.** `hermes_profiles` keeps only `default`. Delete
  `roles/hermes/templates/profiles/` (coder + intel SOULs) and
  `roles/hermes/templates/env_profile.j2` (dead once no non-default profile exists). The render loop
  in `roles/hermes/tasks/main.yml` is simplified so the env-template default is `env_default.j2`.
- **Merged SOUL voice.** `roles/hermes/templates/SOUL.md.j2` is rewritten as a modern "second brain
  / chief of staff": concise, witty, terse sarcasm (butler theater dropped). It encodes three
  capability sets — wiki gatekeeper (schema adherence, no raw secrets), coding craftsmanship
  (precision, TDD, git workflow, security primitives), and IT research (structured extraction,
  DevOps/Security/AI scope). Delegation is framed as handing heavy coding/research to anonymous
  `delegate_task` subagents, with standards injected into the delegation context (children do not
  inherit the SOUL).
- **SOUL must actually deploy.** The SOUL.md render task currently uses `force: false`
  (`roles/hermes/tasks/main.yml:67`), so a changed template never overwrites a live SOUL. Flip it to
  `force: true` for this rollout (the SOUL becomes a managed identity artifact).
- **Delegation config** (`config.yaml.j2:56-59`):
  ```
  delegation:
    max_concurrent_children: 5
    worktree_isolation: true
    provider: nous
    model: qwen/qwen3-coder-flash
  ```
- **Wiki relocation** (`/opt/hermes/wiki` → `/opt/wiki`):
  - `group_vars/all/main.yml:10`: `silverbullet_data_dir: /opt/wiki`. This automatically carries the
    `wiki_volume` role (creates/owns `/opt/wiki`) and the `backup` role (git-crypt init + sync) — both
    consume `silverbullet_data_dir`.
  - `roles/hermes/templates/docker-compose.yml.j2:41`: add
    `- "{{ silverbullet_data_dir }}:/opt/data/wiki"` so the agent still sees the wiki at the **same
    container path** (`default.terminal_cwd: /opt/data/wiki` stays valid). Silverbullet's `/space`
    mount already follows the var, so no change there.
  - **Migration runbook** (deploy-time only — the VPS is left untouched this session):
    `cp -a /opt/hermes/wiki/. /opt/wiki/`, verify the wiki loads, then optionally `rm -rf
    /opt/hermes/wiki`. Also delete the live `/opt/hermes/SOUL.md` so it re-renders (or rely on the
    `force: true` change above).

## Testing Decisions

- `tests/test_playbook.yml` overrides `hermes_profiles` (line 13) and `silverbullet_data_dir`
  (line 22, currently `/opt/llm-wiki`); update it to `default` only and `/opt/wiki` so it no longer
  references removed profile templates. `test_hermes_profile.yml` / `test_config_render.yml` loop
  over `hermes_profiles`, so they remain valid with a single entry.
- `tests/lint.sh` must pass (syntax + the profile/config render tests).

## Out of Scope

- **Named agent profiles for delegation**: Hermes's `agent_profiles` per-`delegate_task` is an open,
  unmerged upstream proposal (issue #9459). We rely on anonymous children + explicit context instead.
- **Per-child model routing**: a single global `delegation.model` applies to all children (no
  per-child model in 0.20.x). Acceptable for now.
- **Committing / deploying**: this epic is spec + plan only this session; the VPS is not touched.

## Tickets

Vertical slices under `.scratch/09-hermes-second-brain/issues/`:

- **#01** `01-drop-profiles.md` — remove `coder`/`intel` from `hermes_profiles`; delete profile
  SOUL templates + `env_profile.j2`; simplify the render loop's env-template default.
- **#02** `02-rewrite-soul.md` — rewrite `SOUL.md.j2` as the modern second brain; flip the SOUL
  render task to `force: true`.
- **#03** `03-delegation-config.md` — add `worktree_isolation: true` and `max_concurrent_children: 5`
  to `config.yaml.j2`.
- **#04** `04-relocate-wiki.md` — repoint `silverbullet_data_dir` to `/opt/wiki`, add the Hermes
  container mount, and document the deploy-time migration runbook.
- **#05** `05-tests-and-lint.md` — update `test_playbook.yml` profile/wiki overrides; confirm
  `lint.sh` is green.
