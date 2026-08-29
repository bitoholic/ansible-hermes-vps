# Spec: Hermes skill packs (superpowers + mattpocock/skills)

> Status: ready-for-human
> Source: Operator request to ship curated skill packs into Hermes so they are available
> on-demand to every profile, instead of the repo's old copy-vendored-skills method.
> Related: `CONTEXT.md` (Hermes agent, skills), `02-hermes-profile-module` (profile skill wiring).

## Problem Statement

The repo previously vendored a small set of local skills under
`roles/hermes/files/profiles/<name>/skills/` and copied them into each profile's `skills/`
directory at deploy time. That approach is not upgradeable (skills are frozen in the repo),
does not cover the curated community packs the operator wants, and bloats the role. The
operator wants **obra/superpowers** and **mattpocock/skills** available to all agents on
demand, installed through Hermes's own tooling so they can be upgraded with `hermes skills update`.

## Solution

Install skills at deploy time with `hermes skills install <source> --force` inside the
`hermes-agent` container, looping over a declarative `hermes_skills` list (one entry per
skill). The install is idempotent (exact-match guard on `hermes skills list`) and the gateway
is restarted so the skills load. The old copy-vendored-skills task and all vendored skill
directories are removed. Skills are **on-demand** for every profile (no auto-load), matching
the existing `default` profile's `skills_auto_load: [research/llm-wiki]` which is untouched.

## Implementation Decisions (from spike on Hermes v0.20.6)

- **`hermes skills install <source> --force` is the only reliable path.** Validated sources:
  - superpowers: per-skill raw GitHub URL
    `https://github.com/obra/superpowers/raw/main/skills/<name>/SKILL.md` (verdict SAFE).
  - mattpocock/skills: per-skill `skills-sh/mattpocock/skills/<cat>/<name>` (auto-resolves latest).
- **`hermes plugins install` is BLOCKED** by the v0.20.6 security scanner ("dangerous verdict,
  226 findings"; `--force` does not override) — so the plugin path is dead. The old plan that
  relied on `hermes plugins install` was discarded.
- **`specify init --integration hermes` (spec-kit) does NOT register its skills** — Hermes ignores
  `specify`-generated `speckit-*` SKILL.md files placed under `~/.hermes/skills`. Upgrading Hermes
  to the newest (0.20.6) did **not** fix this. **spec-kit is excluded** from this rollout.
- **Repo-level installs are unsupported** (`hermes skills install skills-sh/mattpocock/skills` and
  `.../obra/superpowers` both fail with "Could not fetch ... from any source"), so skills are
  enumerated per-skill from the actual GitHub trees.
- **Restart required**: after installs, `docker restart hermes-agent` reloads the gateway so the
  skills become usable.
- **Idempotency**: the install command first exact-matches the skill name in the first column of
  `hermes skills list` (awk + `grep -qx`); only absent skills are installed. This avoids substring
  false-positives (e.g. `implement` vs `implement-spec`, `handoff` vs `claude-handoff`).

## Testing Decisions

- **`tests/check-hermes-skills.sh`** (new) asserts every entry in `hermes_skills` is registered in
  the running `hermes-agent`; skipped automatically in CI where the container is absent. Wired into
  `lint.sh`.
- **`tests/test_hermes_profile.yml`** had its skills-copy task + skills assertions removed (the
  render loop no longer vendors skills).
- Operator validation: run the playbook on the VPS and confirm the check script passes plus a manual
  on-demand skill invocation per profile.

## Out of Scope

- **spec-kit**: blocked on Hermes's skill registration; revisit when Hermes supports `specify`.
- **Auto-loading packs**: intentionally left on-demand; the `default` profile keeps `research/llm-wiki`.
- **Pinning skill SHAs**: superpowers uses `main` (newest); mattpocock resolves latest via skills.sh.
  Can be pinned later for reproducibility.

## Tickets

Vertical slices under `.scratch/08-hermes-skill-packs/issues/`:

- **#01** `01-spike-and-mechanism.md` — spike on Hermes v0.20.6: validate install paths, discard
  plugin path, decide to skip spec-kit. *Done.*
- **#02** `02-remove-vendored-skills.md` — remove `Deploy Hermes profile skill files` task, drop
  `skills_src`, delete `roles/hermes/files/profiles/*/skills/`. *Done.*
- **#03** `03-install-cli-skills.md` — add `hermes_skills` var + idempotent `hermes skills install`
  loop with gateway restart in `roles/hermes/tasks/main.yml`. *Done.*
- **#04** `04-runtime-check-and-tests.md` — `tests/check-hermes-skills.sh` + `lint.sh` wiring +
  profile-test cleanup. *Done.*
