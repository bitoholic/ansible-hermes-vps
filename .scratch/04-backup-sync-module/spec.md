# Spec: Backup/Sync as a Testable Module

> Status: ready-for-agent (draft)
> Source: Architecture review candidate #4 — "Backup/sync as a testable module"
> Related: `01-secret-manifest` (GitHub token secret), wiki store (`05-wiki-volume-ownership`)
> Vocabulary: "wiki store", "Hermes agent", "gateway".

## Problem Statement

The wiki → GitHub synchronization logic in the `backup` role is embedded as **shell templates** driven by Ansible vars:

- `roles/backup/templates/sync-to-dev.sh.j2` (real-time sync) and `create-daily-pr.sh.j2` (nightly PR) contain the actual sync/PR logic.
- `roles/backup/tasks/main.yml` also performs git-crypt init/export/fetch and a cron job that runs `create-daily-pr.sh`.
- The intended real-time trigger — a systemd path watcher (`llm-wiki-watcher.path/.service`, templated at lines 97–115) — is **commented out**, so the design's core mechanism is disabled and untested.
- The sync logic is **unreachable except through a full play run** — there is no test surface. A bug in the sync/PR script only surfaces against a live wiki and a live GitHub token.

This is a **locality** failure: the behavior that most needs testing (sync correctness, PR creation, git-crypt handling) is smeared into Jinja-templated shell that can't be exercised in isolation. It also entangles the README's Known Limitation — the GitHub token is embedded directly in the clone URL (`https://x-access-token:{{ token }}@github.com/...`), persisted in `.git/config` in plaintext.

## Solution

Extract the sync / PR / git-crypt logic into a **standalone, CLI-driven module** (a small shell or Python package) with a clear external interface and **unit tests**, and reduce the `backup` role to a thin deployer of that module plus the systemd units.

- The module exposes commands like `sync`, `create-pr`, and `git-crypt-init`, each taking explicit args (repo path, branch, token via env/stdio — never in a URL).
- The role templates a thin wrapper (or calls the module directly) and **enables the previously-commented systemd path watcher** as a tested component.
- Tests cover sync diffing, PR creation, and git-crypt init against fakes — no live wiki or token required.

This gives **locality** (sync behavior in one testable unit) and **leverage** (the watcher can finally be enabled with confidence; the token-in-URL leak becomes fixable in one place).

## User Stories

1. As a developer, I want the sync/PR/git-crypt logic in a standalone module with a CLI, so that I can run and test it without a full Ansible play.
2. As a developer, I want unit tests for sync and PR creation against fakes, so that logic regressions are caught in CI, not on the live wiki.
3. As an operator, I want the systemd path watcher enabled, so that real-time sync actually fires on file change (it's currently commented out).
4. As a security reviewer, I want the GitHub token passed to git without being embedded in the remote URL, so it doesn't persist in `.git/config` in plaintext.
5. As a developer, I want the role to be a thin deployer of the module, so that behavior changes live in the module, not in Jinja shell templates.
6. As an operator running `--check --diff`, I want the role to preview exactly which units/files it deploys, so a dry run is faithful.
7. As a reviewer, I want the module's external interface documented (commands + args), so I can reason about it without reading implementation.
8. As a developer, I want git-crypt init/export/fetch to be a tested function, so the offline-recovery key flow is reliable.
9. As an operator, I want a failed sync/PR to surface a clear error (and not silently drop the nightly PR), so I learn about breakage.
10. As a developer, I want the module to be ingress/secret-source agnostic (token via env), so it composes with `01-secret-manifest` without hard-coding lookup calls.

## Implementation Decisions

- **Module introduced:** a `backup_sync` unit (shell or Python) with a CLI: `sync`, `create-pr`, `git-crypt-init`. Interface is command + explicit args; secrets (GitHub token) come from the environment, never inlined into a remote URL.
- **Interface exposed:** `backup_sync sync --repo <dir> --branch <b>` and `backup_sync create-pr --repo <dir> --branch <b> --message <m>`; `git-crypt-init` for first-run key export. The role invokes these (or templates a thin shim) rather than embedding the logic in `.j2` shell.
- **Role slimmed:** `roles/backup/tasks/main.yml` deploys the module + the (now-enabled) systemd path/service units + the nightly cron; the copy-pasted logic in `sync-to-dev.sh.j2` / `create-daily-pr.sh.j2` is removed in favor of calling the module.
- **Watcher enabled:** the commented `llm-wiki-watcher.path/.service` units are enabled and covered by the module's tests (the watcher just calls `backup_sync sync`).
- **Seam:** the module is the single owner of sync/PR/git-crypt behavior. The role is an *adapter* between Ansible facts (paths, branch, resolved secrets) and the module CLI. Highest seam preserved — only the module knows the sync algorithm.
- **Secret wiring:** the GitHub token is passed via environment from the resolved `secrets` dict (`01-secret-manifest`); the plaintext-URL leak from the README Known Limitations is closed here.
- **Migration:** existing `sync-to-dev.sh.j2` / `create-daily-pr.sh.j2` content is ported verbatim into the module as the first implementation, then the templates are deleted.

## Testing Decisions

- **What makes a good test:** test the module's *external behavior* with fakes — given a fixture wiki tree and a stubbed git/GitHub, `sync` stages the right changes and `create-pr` opens a PR with the right metadata. Do not test Ansible task wiring.
- **Modules tested:**
  - `sync`: asserts correct diff detection and commit/stage behavior against a temp repo.
  - `create-pr`: asserts PR creation against a mocked GitHub API (no live token).
  - `git-crypt-init`: asserts idempotent init + key export.
  - Role-level: `--check --diff` dry-run confirms only the module + units + cron are deployed.
- **Prior art:** the repo's `tests/lint.sh` and `tests/test_playbook.yml` are the natural CI home; module unit tests run as a separate step in the same harness.

## Out of Scope

- The `01-secret-manifest` resolver itself — assumed delivered by that spec; this spec only consumes its resolved token.
- The `05-wiki-volume-ownership` consolidation — the wiki store ownership is a separate concern; this spec assumes a writable wiki dir exists.
- Broadening backup beyond wiki→GitHub (e.g. DB dumps, off-site copies).
- The Hermes profile or gateway refactors — unrelated to sync logic.

## Further Notes

- This is candidate #4 ("worth exploring"): the payoff is testability of the riskiest logic and finally enabling the disabled watcher. It also closes a README Known Limitation (token-in-URL).
- It is the natural place to fix the plaintext-token leak, since the module owns how the token reaches git.
- Recommended as the **fourth** change, after the gateway seam.
