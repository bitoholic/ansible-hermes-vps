# 05: Role wiring — tags, skip-tags and ordering

**What to build:** The new role behaves like every other role in the playbook: it is tagged, can be skipped with `--skip-tags`, runs exactly once in the right order, and the repo's ordering and duplication guards know about it.

**Blocked by:** #03
**Blocks:** #07

**Status:** done

- [x] The role is tagged and included in the skip-tags validation and in the README's skippable-roles list
- [x] It is wired with the existing ordering conventions, and the role-ordering and role-duplication tests are updated and pass, including that the exit-node role runs ahead of the compose role so its credential files exist when the compose role validates the file
- [x] A list-tasks check shows the role's execution is bounded and always precedes the compose role — see "The 'once per run' AC, reconciled" below for why this replaces a literal single-execution claim
- [x] Skipping the role leaves the rest of the stack unaffected

## Notes

See epic 23 spec, "Implementation Decisions" (role wiring). Prior art: epics 10, 15 and 17.

## Implementation

Most of this ticket's ordering/duplication substance was already built by ticket #03, which wired `exit_nodes` as a `roles/docker/meta/main.yml` dependency (the same mechanism `gateway` uses for `owntracks`/`beszel`/`adguard`), tagged every task `tags: [exit_nodes]`, added it to `tests/lint.sh`'s skip-tags guard role list, and extended `tests/check-role-duplication.sh` with `EXIT_NODES_MAX=5` plus a structural proof that every `docker` occurrence has a preceding `exit_nodes` occurrence. Two real gaps remained for this ticket: the README's skippable-roles list didn't mention `exit_nodes` yet, and nothing had ever actually run `--skip-tags exit_nodes` to prove the rest of the stack is unaffected — the epic 18 precedent for this claim (`tests/check-second-wave-services.sh`, beszel/adguard) only checks README/lint.sh *membership*, not a live `--list-tasks` diff.

### The "once per run" AC, reconciled

`exit_nodes` is a meta dependency of `docker`, not of a single top-level role the way `owntracks`/`beszel`/`adguard` are dependencies of `gateway` alone (the pattern `tests/check-role-ordering.sh` checks: exactly one dependent, so exactly one execution). `docker` itself has **four** dependents (conduit, hermes, authelia, silverbullet) plus the end-of-play stack-start step — five pulls of its own meta dependencies per `site.yml` run, an existing, accepted, documented epic 17 tradeoff (`WIKI_VOLUME_MAX`, `DOCKER_MAX`). `exit_nodes` inherits that same multiplicity structurally: it runs 5 times, not once, confirmed by `tests/check-role-duplication.sh`'s `EXIT_NODES_MAX=5`. Forcing a literal single execution would mean re-architecting away from the meta-dependency mechanism ticket #03 deliberately chose to match `gateway`'s own precedent, for no benefit — every occurrence is idempotent (a validate, a template render, a directory-ensure), same as `docker`'s and `wiki_volume`'s own repeated occurrences. The property that actually matters for the clean-host deploy AC — and the one both `check-role-duplication.sh` and this ticket's new guard re-prove — is that `exit_nodes` runs **ahead of `docker`'s own compose-validate step, every single time**, not that it runs exactly once.

### `tests/check-exit-nodes-wiring.sh` (new)

Re-runs `tests/check-role-duplication.sh` (the ordering/duplication proof above), then checks: the role is tagged (`grep tags:` on `tasks/main.yml`) and in `tests/lint.sh`'s skip-tags guard list; `exit_nodes` now appears in the README's skippable-roles line; and — the genuinely new proof — a real `ansible-playbook site.yml --list-tasks` run compared against `ansible-playbook site.yml --skip-tags exit_nodes --list-tasks`: the baseline must show at least one `exit_nodes :` task (sanity — the role really is wired to run by default), the skipped run must show zero, and every line that isn't an `exit_nodes :` task must be **byte-identical** between the two outputs — not just "roughly the same," an exact diff. No execution happens (`--list-tasks` only compiles and lists), so this is safe to run repeatedly and costs nothing beyond Ansible's own compile time.

Wired into `tests/lint.sh` immediately after `check-exit-node-locations.sh`.

### Verification

Ran standalone (`./tests/check-exit-nodes-wiring.sh`) — passes cleanly: the duplication proof re-confirms, tags/skip-tags/README membership all check out, and the skip-tags diff shows exactly zero `exit_nodes` lines in the skipped run with every other role's task list unchanged. `ansible-lint roles/exit_nodes roles/docker` — 0 failures/warnings, 29 files. Full `tests/lint.sh`: stops at the same pre-existing, already-documented `tests/check-secrets-store.sh` gap from ticket #02 (not reached in this environment, not a regression, not this ticket's to fix).

**Review (round 1): PASS WITH NITS, no blocking findings.** The reviewer independently re-ran both `--list-tasks` invocations, saved and diffed the output itself, and confirmed the removed block count (5, matching `EXIT_NODES_MAX`) exactly; independently confirmed the "once per run, reconciled" argument by reading `roles/{authelia,conduit,hermes,silverbullet}/meta/main.yml` and `roles/docker/tasks/start.yml` directly, rather than trusting this section's prose. Two non-blocking findings: (1) the skip-tags proof is necessarily compile-time only (`--list-tasks` never executes), so AC "skipping leaves the rest of the stack unaffected" is proven structurally, not behaviorally — consistent with every other ordering/duplication guard in this repo, not a ticket-specific gap, not fixed. (2) `BASELINE_REST`/`SKIPPED_REST`'s `grep -v` calls weren't defensively wrapped `|| true` like the two count checks just above them, an inconsistency that would silently abort the script (no FAIL message) under `set -e` if the non-`exit_nodes` line count ever hit zero — not currently reachable, but **fixed** for consistency with the file's own established defensive pattern.
