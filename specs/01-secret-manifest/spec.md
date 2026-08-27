# Spec: Secret Manifest (single secret-resolution interface)

> Status: ready-for-agent (draft, not yet triaged via tracker)
> Source: Architecture review candidate #1 — "Secret manifest"
> Vocabulary note: no CONTEXT.md/ADRs exist yet; "secret", "profile", "Hermes agent", "gateway", and "wiki store" are the terms this review introduces.

## Problem Statement

Today, the set of secrets this stack requires is declared in **three places that have already drifted**:

- `setup-env.sh` carries a `REQUIRED_VARS` array (lines 5–29) that prompts the operator.
- `.env.template` carries a parallel list of expected variables.
- `group_vars/all/main.yml` resolves each secret inline with `lookup('env', …)` calls scattered through the file.

These three copies are maintained by hand and are out of sync. The concrete, already-present failure: `DASHBOARD_ADMIN_PASSWORD_HASH` is declared in `group_vars/all/main.yml` and `.env.template` but is **missing** from `setup-env.sh`'s `REQUIRED_VARS`, so a fresh operator who only runs `setup-env.sh` silently deploys a stack missing that secret — exactly the drift the README warns about ("`setup-env.sh` does not yet prompt for everything Ansible requires").

Adding, renaming, or marking a secret optional requires coordinated edits across three files, and "is this secret required?" is implicit in how each `lookup` is written. There is no single source of truth and no fail-fast contract for a missing required secret at provisioning time.

## Solution

Introduce **one secret manifest module** that owns the catalog of required secrets, and a **single resolver interface** that every other part of the stack consumes.

- The manifest is a single data structure declaring each logical secret, the environment variable it comes from, whether it is `required`, and an optional `default`.
- A resolver (a bootstrap task or a small `secrets` role) reads the manifest once, resolves each entry via `lookup('env', …)`, and **fails fast with a clear message** when a required secret is unset.
- The resolver exposes a resolved `secrets.<name>` dictionary as the one interface the rest of the stack uses.
- `setup-env.sh` and `.env.template` are generated from (or strictly validated against) the same manifest, so the three copies can no longer drift.
- Every role that today calls `lookup('env', …)` directly is changed to read `secrets.<name>` instead.

The benefit is concentrated **leverage**: a new secret becomes one manifest entry, not a three-file edit; and **locality**: "what secrets exist, and are they optional" lives in exactly one module.

## User Stories

1. As an operator, I want a single place that lists every secret the stack needs, so that I don't have to cross-check `setup-env.sh`, `.env.template`, and `group_vars`.
2. As an operator, I want `setup-env.sh` to prompt me for exactly the secrets the stack requires, so that I never deploy with a silently-missing secret.
3. As an operator, I want the play to fail fast with a clear message naming the missing required secret, so that I learn about a gap before any container is touched.
4. As an operator, I want optional secrets (those with a `default`) to be tolerated when unset, so that I'm not forced to supply values that have sane fallbacks.
5. As a developer adding a new integration (e.g. a new profile or a new MCP server), I want to declare its secret in one manifest entry, so that wiring it through the stack is a one-line change.
6. As a developer, I want `setup-env.sh` and `.env.template` to be derived from the manifest, so that they cannot drift from what Ansible actually reads.
7. As a developer, I want roles to read `secrets.<name>` rather than `lookup('env', …)`, so that the resolution logic is not duplicated across roles.
8. As a reviewer, I want to see required-vs-optional as explicit metadata on each secret, so that I can reason about provisioning preconditions at a glance.
9. As an operator running `--check --diff`, I want the resolver to behave identically in check mode (fail fast on missing required secrets, no writes), so that a dry run is a faithful pre-flight.
10. As a developer, I want the manifest to be machine-validatable (e.g. a schema or a test asserting `setup-env.sh` contains every required var), so that regressions in the three copies are caught in CI.
11. As an operator, I want the resolved `secrets` dict to be inspectable (e.g. via a preflight `debug`/`assert` summary of which secrets are present), so that I can sanity-check the environment before a full run.
12. As a developer, I want the manifest to support per-profile secrets (a secret scoped to one Hermes profile), so that profile-specific keys aren't flattened into global vars.
13. As an operator, I want the resolver to surface *which* environment variable maps to *which* logical secret, so that debugging "why is this empty" is trivial.
14. As a developer, I want the resolver to remain a thin adapter over `lookup('env', …)` (not a new external service), so that the stack keeps working in air-gapped / offline scenarios.
15. As a reviewer, I want adding a secret to require no change to role task files (only the manifest), so that secret growth does not increase role complexity.

## Implementation Decisions

- **Module introduced:** a `secrets` manifest — a single data file (e.g. under `group_vars/all/`) declaring each logical secret with `env`, `required`, and optional `default`.
- **Interface exposed:** a resolved `secrets` dictionary (e.g. a `set_fact`/vars dict built once in a bootstrap play or a small `secrets` role), consumable as `secrets.<name>` everywhere else.
- **Resolver contract:** reads the manifest, resolves each entry via `lookup('env', …)`, and fails fast (clear named message) when a `required` entry is unset. Optional entries fall back to `default` or empty.
- **Highest seam preserved:** the secret-resolution seam is consolidated to exactly one interface. Roles no longer call `lookup('env', …)` directly; the resolver is the single adapter between the environment and the rest of the stack.
- **Generator/validator for the edges:** `setup-env.sh` and `.env.template` are produced from, or validated against, the manifest. The drift between them is made impossible by construction rather than by convention.
- **Per-profile secrets:** the manifest supports scoping a secret to a specific Hermes profile (consumed by the Hermes profile module from architecture review candidate #2), so profile keys are not flattened into global vars.
- **No new runtime dependency:** the resolver stays a thin wrapper over Ansible's existing `lookup('env', …)`; no external secret store or service is introduced.
- **Check-mode safe:** the resolver's fail-fast behavior runs unchanged under `--check`, acting as a faithful pre-flight.
- **Migration:** existing inline `lookup('env', …)` calls in `group_vars/all/main.yml` and within role tasks are replaced by references to `secrets.<name>`. The manifest's keys should preserve today's logical names (e.g. `authelia_session_secret`, `dashboard_admin_password_hash`).

## Testing Decisions

- **What makes a good test:** test the resolver's *external behavior* — given an environment, it produces the correct `secrets` dict and fails fast exactly on the required-but-unset entries. Do not test Ansible internal plumbing.
- **Modules tested:**
  - The manifest itself: a schema/validation check (every `required` secret has a valid `env`; no duplicate names; `setup-env.sh` `REQUIRED_VARS` and `.env.template` are supersets of the manifest's required secrets).
  - The resolver: a unit-style assertion that, with a crafted environment, the resolved `secrets` dict matches expectations and that an unset required secret raises a clear, named failure.
- **Prior art:** the repo's existing `tests/lint.sh` and `tests/test_playbook.yml` are the natural home; the manifest-consistency check can run as a CI/lint step alongside them. The existing top-level `assert` pre-flight tasks in `site.yml` are the pattern to mirror for the fail-fast behavior.

## Out of Scope

- Moving secrets into an external vault / secret manager (the resolver intentionally stays a thin `lookup('env', …)` adapter).
- The Hermes profile module refactor (architecture review candidate #2) — this spec only *enables* it by supporting per-profile secrets; the profile render loop itself is a separate spec.
- The git-crypt / token-in-URL secret-leak issue from the README's Known Limitations — distinct concern, not solved here.
- Rewriting role logic beyond replacing direct `lookup('env', …)` calls with `secrets.<name>`.

## Further Notes

- This is the **highest-leverage** of the reviewed candidates: it touches every role, is low-risk (pure refactor of how vars resolve), and passes the deletion test — removing the manifest would force every role to re-implement env wiring, confirming genuine depth.
- It pairs naturally with candidate #2 (Hermes profile module): once secrets are a resolved manifest, the profile render loop can consume per-profile secrets cleanly.
- Recommended as the **first** architecture change to land.
