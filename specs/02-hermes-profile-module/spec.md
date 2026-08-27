# Spec: Hermes Profile Module (profile-driven render loop)

> Status: ready-for-agent (draft)
> Source: Architecture review candidate #2 — "Hermes profile module"
> Depends on: `01-secret-manifest` (the resolved `secrets` dict, including per-profile secrets)
> Vocabulary: "Hermes agent", "profile" (Jack-O-Rama / Compile-O-Rama / Intel Scraper), "gateway", "wiki store".

## Problem Statement

The `hermes` role collapses three distinct logical agents — the chief-of-staff **Jack-O-Rama** (default profile), the coding **Compile-O-Rama** (`coder`), and the news-scraping **Intel Scraper** (`intel`) — into a single 173-line linear task script (`roles/hermes/tasks/main.yml`).

Each profile differs in tool-enablement, MCP servers, and secrets, but the role treats them as one flat body of work:

- The default profile's `.env` content block (lines 120–139) is **copy-pasted** for every profile (lines 76–92), with only the interpolated values changed.
- Per-profile `config.yaml`, `SOUL.md`, and `skills/` are emitted by separate template files under `roles/hermes/templates/profiles/<name>/`.
- The interface (a flat 173-line role) is nearly as complex as its implementation — a **shallow** module: understanding one profile means bouncing between the role body and three template subtrees, and the duplication means a change to the shared `.env` shape must be edited in two places.

Adding a fourth agent today means editing the role body *and* adding a template subtree by hand. There is no single place that says "here is what the coder profile is."

## Solution

Model a **`hermes_profile` entity** — one data structure that carries everything that makes a profile distinct: its name, enabled tools, MCP servers, secrets (fed by the `01-secret-manifest` resolver), SOUL persona, and skills. Then drive the entire role from a **single render loop** over the profile list:

- One loop emits `config.yaml` + `SOUL.md` + `.env` + `skills/` for each profile from that structure.
- The shared `.env` shape lives in **one** template (parameterized by the profile's resolved secrets), eliminating the copy-paste.
- The default "Jack-O-Rama" profile is just another entry in the same list, not a separate code path.

This gives **locality** (a profile's full behavior — tools, secrets, persona — lives in one map entry) and **leverage** (a new subagent is a data entry, not a code edit).

## User Stories

1. As a developer adding a new subagent, I want to declare it as one `hermes_profile` entry, so that I don't edit the role body or create template files by hand.
2. As a developer, I want the shared `.env` shape to live in a single template, so that changing it doesn't require editing two copy-pasted blocks.
3. As a reviewer, I want each profile's tools, secrets, and persona visible in one place, so that I can understand an agent without reading the whole role.
4. As an operator, I want every profile's config/SOUL/`.env`/skills deployed consistently, so that no profile silently misses a file.
5. As a developer, I want per-profile secrets resolved via the `secrets` dict from `01-secret-manifest`, so that profile keys aren't flattened into global vars.
6. As an operator running `--check --diff`, I want the render loop to behave identically in check mode (no writes), so that a dry run previews every profile file.
7. As a developer, I want the `coder` profile's extra MCP servers (context7, github, playwright) expressed as data, so that enabling/disabling a tool is a one-line change.
8. As a developer, I want the `intel` profile's disabled tools (`terminal`, `filesystem`, `git` explicitly off) expressed as data, so that the security-relevant scoping is obvious and reviewable.
9. As a reviewer, I want the profile list to be the single source of truth for "which agents exist", so that I'm not surprised by a profile hidden in template paths.
10. As a developer, I want adding a profile to require no change to the role's task file (only the data), so that profile growth doesn't increase role complexity.
11. As an operator, I want failed profile renders to name the offending profile, so that debugging a bad entry is fast.
12. As a developer, I want the default profile (Jack-O-Rama) to flow through the same loop as the others, so there's no special-cased code path to maintain.
13. As a security reviewer, I want the `intel` profile's reduced capability to be enforceable in its data entry (not just documented), so that the sandbox-isolation gap from the README is at least declared at the profile layer.

## Implementation Decisions

- **Module deepened:** `roles/hermes` — its task body is replaced by a single loop over a `hermes_profiles` list (which already exists in `group_vars/all/main.yml` and points the way).
- **Interface:** each profile is described by a `hermes_profile` data structure: `{ name, tools_enabled, mcp_servers, secrets: <subset of manifest>, soul, skills }`. The role consumes this; it does not hard-code per-profile logic.
- **Single render loop:** for each profile, render `config.yaml` + `SOUL.md` + `.env` + `skills/` from templates parameterized by the profile entry. The default profile is the first list entry, not a separate task block.
- **One `.env` template:** the two currently copy-pasted `.env` content blocks are merged into a single template driven by the profile's resolved `secrets` subset (from `01-secret-manifest`), removing the duplication at `roles/hermes/tasks/main.yml:76-92` and `:120-139`.
- **Secrets wiring:** profile-specific secrets are read from the resolved `secrets` dict (per-profile support introduced in `01-secret-manifest`); the role no longer calls `lookup('env', …)` directly.
- **MCP servers as data:** the `mcp_servers` block (context7/github/playwright for `coder`) is part of the profile entry, rendered into `config.yaml.j2` rather than duplicated per template file.
- **Highest seam preserved:** the role's *interface to the rest of the stack* (it still produces the same deployed files under `hermes_home`) is unchanged; only its internal depth improves. No new cross-role seam is introduced.
- **Migration:** existing per-profile template subtrees under `roles/hermes/templates/profiles/<name>/` are consolidated where they are purely the shared shape; profile-specific content (SOUL, enabled tools) becomes data.

## Testing Decisions

- **What makes a good test:** test the *external behavior* — given a `hermes_profiles` list, the role produces the correct set of files per profile with correct ownership/mode and correct interpolated secrets. Do not assert on Ansible task internals.
- **Modules tested:**
  - The render loop: an assertion that, for N profiles, exactly N `config.yaml`/`SOUL.md`/`.env`/`skills/` sets exist under `hermes_home/profiles/`, and the default profile is among them.
  - The `.env` template: a unit-style render check that the consolidated template produces identical output to the previous two blocks for the default and `coder` profiles (guards against regression of the de-duplication).
  - Per-profile secrets: verify the `intel` profile receives only its scoped secrets and the `coder` profile receives context7/github tokens from the `secrets` dict.
- **Prior art:** mirror the repo's existing top-level `assert` pre-flight pattern in `site.yml` (and the `tests/test_playbook.yml` `--check --diff` dry-run) for profile-render verification.

## Out of Scope

- The actual sandbox isolation fix for Compile-O-Rama (README Known Limitation: shared container / bind mount, no `ALLOWED_DIRECTORIES`). This spec only makes the capability gap *declarable* at the profile layer.
- The `01-secret-manifest` resolver itself — assumed delivered by that spec.
- The gateway / reverse-proxy change (candidate #3); the `dash.` route stays as-is here.
- Container build specifics in `roles/hermes/files/Dockerfile` (voice mode, ffmpeg layers) — untouched.

## Further Notes

- This is the **second-highest-leverage** candidate and pairs with `01-secret-manifest`: once secrets are a resolved manifest, the profile render loop can consume per-profile secrets cleanly.
- The deletion test passes — removing the role would concentrate the three agents' logic, confirming real depth rather than a thin wrapper.
- Recommended as the **second** architecture change to land, right after the secret manifest.
