# Spec: Add Role Skip Tags (Selective Deployment)

> Status: ready-for-agent
> Source: Need for faster, targeted deployments without stopping slow sub-tasks
> Related: `hermes-skills` (currently runs skills install sequentially for each skill), `conduit`, `tailscale`, `authelia`, `gateway`, `silverbullet`, `backup` roles
> Vocabulary: "skip-tags" = Ansible tags that allow selective role skipping during `ansible-playbook site.yml`

## Problem Statement

The hermes-vps deployment currently runs ALL roles every time using `ansible-playbook site.yml`, even for minor changes that don't require updating certain components. This is particularly problematic for the Hermes skills installation step, which can take 15+ minutes and pulls hundreds of skill definitions over network from GitHub - unnecessarily for simple configuration updates.

Operators cannot selectively skip roles during redeployments, leading to:
- Unnecessary long deployment times for minor changes  
- Risk of rolling back changes when only specific services need updates
- Inefficient use of compute resources during CI/CD pipelines
- Inability to perform fast "safe mode" deployments for non-production updates

## Solution

Implement an Ansible-based role skipping mechanism using tags to allow operators to selectively skip entire roles during deployment. This will enable targeted deployments where operators can skip slow or unnecessary roles while maintaining system safety through protected roles that can never be skipped.

## User Stories

1. As a deployment operator, I want to skip the Hermes skills installation step when only updating the Hermes agent configuration, so that I can complete rapid configuration changes within minutes instead of 15+ minutes.

2. As a system administrator, I want to skip the entire tailscale role when only updating the web application stack, so that I don't need to trigger unnecessary VPN reconfigurations.

3. As a CI/CD pipeline maintainer, I want to selectively run only the conduit and hermes roles for API-only changes, so that I can validate API changes without rebuilding the entire infrastructure.

4. As an operator, I want to prevent accidental skipping of critical bootstrap roles, so that the system remains reliably bootstrappable even with non-expert users.

5. As a maintenance engineer, I want to skip the backup role when only testing configuration changes, so that I can validate new settings without triggering file transfers or git operations.

6. As a developer, I want to skip the silverbullet (wiki) role when only working on application code, so that I don't need to interact with the wiki system during application updates.

7. As a deployment operator, I want to skip the authelia role when only updating the gateway configuration, so that I can change Caddy routing without triggering redundant Authelia config regenerations.

8. As an operator, I want to skip the conduit role during maintenance windows, so that I can upgrade other components without modifying the Conduit personal homeserver.

9. As a CI/CD pipeline maintainer, I want to skip Docker and tailscale roles in test environments where they don't apply, so that I can reduce test infrastructure costs.

10. As a developer, I want to skip the gateway role when only making changes to the hermes agent, so that I don't need to rebuild and restart the reverse proxy.

## Implementation Decisions

### Module Architecture
- **site.yml** - Updated to use `tags: <role-name>` on every role and add a pre-flight validation step that checks for protected role skips and aborts with clear error messages
- **Protected Roles Module** - Core bootstrap roles that cannot be skipped: `secrets`, `users`, `ssh_hardening`, `common`, and any role in Play 1 (admin user/bootstrap setup)
- **Skippable Roles Module** - All other roles (`tailscale`, `docker`, `conduit`, `hermes`, `authelia`, `gateway`, `silverbullet`, `backup`) can be individually tagged and skipped
- **Skip Validation Logic** - Pre-flight assert that parses `--skip-tags` values from command line and validates against protected role list

### Interface Design
- **CLI Integration** - Operators use `--skip-tags <role-name>` with standard Ansible CLI
- **Tag Pattern** - Every role gets a descriptive tag matching its directory name (e.g., `tags: tailscale`, `tags: hermes`)
- **Validation Format** - Clear error messages showing which roles are protected and why
- **Documentation** - Updated README with examples of selective deployment scenarios

### Architectural Decisions
- **Ansible Native Solution** - Uses built-in Ansible tagging mechanism for maximum compatibility and no custom code paths
- **Hard Safety Approach** - Protected roles cannot be skipped, period. No configuration or flags to override this safety measure.
- **Backward Compatibility** - Existing deployments continue to work unchanged; skip mechanism is purely additive.
- **Granular Control** - Operators can skip individual roles independently, not just all-or-nothing.

### API Contracts
- **Pre-flight Validation** - Command-line parsing before playbook execution
- **Error Reporting** - Clear, actionable error messages when skip attempts occur
- **Documentation** - Updated README with skip examples and best practices

### Technical Clarifications
- Skipped roles will be completely omitted from the play run, not just their tasks
- Skipped roles will still have any prerequisite dependencies run (e.g., `docker` is required for `conduit`)
- Role skipping is evaluated at the top-level role inclusion level in site.yml, not within individual role tasks

## Testing Decisions

### What Makes a Good Test
- **External Behavior** - Tests validate the external behavior: that specified roles are skipped, protected roles cannot be skipped, and deployment succeeds/fails appropriately
- **Tag Validation** - Ensure tags are correctly applied and parsed
- **Pre-flight Validation** - Test that protected role skips are properly detected and rejected
- **Integration Testing** - Run actual Ansible deployments with various skip combinations to ensure correct behavior

### Modules to Test
- **site.yml** - Pre-flight validation logic and tag application
- **Protected Role Tests** - Validate that attempts to skip `secrets`, `users`, `ssh_hardening`, `common` roles fail appropriately
- **Skippable Role Tests** - Verify that roles like `tailscale`, `hermes`, `conduit`, etc. can be successfully skipped
- **Edge Case Tests** - Test combinations like skipping specific tasks within roles (currently not supported - skip at role level only)

### Prior Art for Testing
- **Existing CI Guard Scripts** - `tests/check-hermes-skills.sh`, `tests/check-conduit.sh`, `tests/check-tailscale.sh` provide patterns for testing role behavior
- **Ansible Lint** - `tests/lint.sh` ensures proper syntax and structure
- **Unit Test Patterns** - `tests/test_playbook.yml` shows how to stub secrets for local testing

## Out of Scope

1. **Sub-task Granularity** - Feature does not support skipping specific tasks within a role. If you need to skip only the skills install portion of the hermes role, you must skip the entire hermes role.
2. **Role Dependencies** - Does not automatically handle role dependencies. Skipped roles may still have prerequisites that get run (e.g., `docker` still runs even if `conduit` is skipped).
3. **Dynamic Role Configuration** - Cannot add role-skipping configuration to `group_vars/all/main.yml` (e.g., `skipped_roles: []`). Skip is purely CLI-based.
4. **Special Skip Exceptions** - No "ignore protected role for this deployment" bypass. Protected roles are always mandatory.
5. **Runtime Role Detection** - Cannot auto-detect when a role should be skipped based on file changes. Skip is purely operator-specified.
6. **Interactive Skip Prompts** - No role-by-role prompts during deployment. Skip decisions are made upfront on the command line.

## Further Notes

### Deployment Scenarios
```bash
# Fast path: Skip slow roles when only updating hermes configuration
ansible-playbook -i inventory site.yml --skip-tags tailscale,hermes,backup

# Minimal API deployment: Skip everything except conduit and hermes
ansible-playbook -i inventory site.yml --skip-tags tailscale,docker,authelia,gateway,silverbullet,backup

# Full deployment (default, no skips)
ansible-playbook -i inventory site.yml
```

### Benefits
- **Faster Deployments** - Operators can skip slow, unnecessary roles
- **Targeted Updates** - Only redeploy services that actually changed
- **CI/CD Efficiency** - Pipelines can run minimal deployments for testing
- **Safety First** - Critical bootstrap roles can never be accidentally skipped
- **Backward Compatible** - Existing workflows continue to work unchanged

### Migration Path
1. Update all roles with `tags: <role-name>` in their `tasks/main.yml`
2. Add pre-flight validation to site.yml
3. Document skip usage in README with examples
4. Test all skip scenarios in CI
5. Gradually adopt: operators start with `--skip-tags hermes` for faster development deployments

This feature enables targeted deployments while maintaining system safety through protected critical roles. The simple CLI-based approach ensures maximum compatibility and clear operational boundaries.

## Tickets

Vertical slices under `.scratch/10-add-skip-tags/issues/` (blockers-first):

- **#01** `01-tag-all-roles.md` — add `tags: <role-name>` to each role's `tasks/main.yml`. Update CI guard scripts to validate tags exist (e.g., `grep -qE "tags: tailscale" roles/tailscale/tasks/main.yml`).
- **#02** `02-site-skip-validation.md` — pre-flight assert in site.yml: parse `--skip-tags`, list protected roles (`secrets`, `users`, `ssh_hardening`, `common`), abort if any attempt to skip them.
- **#03** `03-lint-skip-tags.md` — `lint.sh` lint step: `ansible-playbook site.yml --list-tags` should list all roles with tags matching expected names.
- **#04** `04-docs-skip-tags.md` — update README with skip usage examples and best practices.
- **#05** `05-rollback-skip-validation.md` — ensure `--skip-tags` parsing and validation are idempotent across multiple runs (no state changes, only validation).
- **#06** `06-integration-test-skip-scenarios.md` — integration test: run `site.yml` with various `--skip-tags` combinations, assert correct roles ran/skipped (use `ansible-playbook --check` to validate without side effects).
- **#07** `07-edge-cases-skip-protection.md` — ensure role dependencies still respected (e.g., `docker` runs even if `conduit` is skipped). Test that skipping a protected role (e.g., `secrets`) fails with clear error.
- **#08** `08-migration-guide-skip.md` — document migration path for existing users, examples of gradual adoption.

## Issue Blockers

Blockers should be tracked based on implementation order:

1. **Blockers for #01** - None (just file edits)
2. **Blockers for #02** - `#01` (tags need to be applied first)
3. **Blockers for #03** - `#01` (need tags to list)
4. **Blockers for #04** - `#01, #02` (content to document)
5. **Blockers for #05** - `#01` (needs tags for parsing)
6. **Blockers for #06** - `#01, #02` (need tags + validation logic)
7. **Blockers for #07** - `#01, #02` (need tags + validation for dependencies)
8. **Blockers for #08** - `#01, #02, #04` (need content to document)

## Implementation Dependencies

- **Required:** Site.yml modification, tag addition to roles
- **Optional:** Update README, add lint tests
- **External:** None (uses standard Ansible CLI)

## Technical Risks

- **Risk:** Operators accidentally skip critical roles causing system breakage
  **Mitigation:** Hard safety with clear error messages and examples
- **Risk:** Tag parsing issues with complex `--skip-tags` values
  **Mitigation:** Use standard Ansible tag parsing, validate against known list
- **Risk:** Incomplete tag coverage (some roles missing tags)
  **Mitigation:** CI lint validation ensures all roles have proper tags

## Monitoring & Alerting

- **Current State:** No monitoring of role skipping behavior
- **Recommendations:**
  - Log skip attempts in deployment logs
  - Add metric for skipped deployments vs. full deployments
  - Consider alerting if protected role skip attempts occur (with clear explanation)