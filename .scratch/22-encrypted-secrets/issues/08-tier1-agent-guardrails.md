# 08: Tier 1 agent guardrails — with the wrapper explicitly exempted from the sandbox — and the honest-limit documentation

**What to build:** Project-scoped agent settings, committed with the repository, that keep an agent from reading the age key, the plaintext `.env`, and anything that decrypts the store or dumps the environment, **while still letting it run deployments** through the wrapper. Denying sandboxed processes read access to the key would also stop the wrapper when the agent runs it (and the sandbox may block the SSH connection to the VPS), so the wrapper is deliberately exempted from the sandbox, and the design states what protects it once exempt. Plus documentation stating plainly what this does and does not guarantee, and the Tier 2 upgrade path.

**Blocked by:** #01
**Blocks:** #09

**Status:** ready-for-agent

- [ ] The agent's mechanism for excluding a named command from its sandbox is identified from the **current** agent documentation, and its exact name and behavior are recorded in this ticket (the setting names may change, so this is verified, not assumed)
- [ ] The wrapper — and only the wrapper's vetted invocation shapes (playbook mode and registered script mode) — is exempted from the sandbox, so an agent-run wrapper can read the age key and open the SSH connection to the VPS; everything else stays sandboxed
- [ ] The sandbox's filesystem read denial covers the operator's age key location and the plaintext `.env` for everything that is not the exempted wrapper, so the protection does not rest on command patterns alone
- [ ] Permission rules allow only the wrapper's exact vetted shapes (and the helper's non-decrypting subcommands) and deny direct decrypt commands and environment dumps
- [ ] **What protects the exempt wrapper is documented as a list:** the exact-shape permission rules; the wrapper's own refusals (extra variables, ad-hoc modules, foreign playbooks); the pinned Ansible configuration and cleared environment (#01); output redaction (#02); and the fact that an agent editing the wrapper itself or a role and then running it is **not** protected against — the documented Tier 1 limit
- [ ] **An end-to-end check under the real sandbox is recorded:** an agent-run playbook check through the wrapper succeeds (decrypts the store, reaches the VPS over SSH), while the same agent's attempts to read the key or `.env` directly — through a different file reader, an interpreter one-liner and a hex dumper — are refused
- [ ] The documentation states that these guardrails prevent accidents rather than a determined actor, because the key sits on the same machine
- [ ] The Tier 2 upgrade path (a hardware-backed or passphrase-gated key requiring a touch or unlock per decrypt) is documented, and the wrapper's configurable key source is shown to support it without a rewrite
- [ ] The settings contain no secrets and no operator-specific paths beyond conventional key locations

## Notes

See epic 22 spec, "Implementation Decisions" (agent guardrails, Tier 1, including the sandbox conflict) and "Further Notes" (the honest limit). Without the explicit exemption, ticket #09's last acceptance criterion cannot pass.

## Implementation

**Mechanism identified from current documentation, not assumed** (criterion #1): `sandbox.enabled: true` turns on
OS-level (bubblewrap/Seatbelt) filesystem+network isolation for every Bash/Monitor command. `sandbox.excludedCommands`
is the documented mechanism for letting one named command run completely outside the sandbox — verified directly
against `https://code.claude.com/docs/en/sandboxing` (fetched during this ticket, 2026-09): *"Add `excludedCommands`
for any organization-approved tools that must run without isolation"*; matched by literal command name (the docs'
own examples: `"docker"`, `"kubectl"`). Full rationale recorded in `.claude/README.md`.

**Files added/changed**:
- `.claude/settings.json` (new, committed): `sandbox.enabled: true`; `excludedCommands: ["scripts/deploy"]`
  (criterion #2 — both of the wrapper's invocation shapes match, since the exemption is by command name, not
  argument shape); `filesystem.denyRead` for `~/.config/sops/age/**`, `~/.ssh/**`, `./.env` (criterion #3);
  `filesystem.allowWrite` for `/run/user/**`, `/dev/shm/**`, `~/.ansible/tmp/**` (see "Sandbox-caused regression"
  below — needed for any non-exempted Ansible run to create its own scratch/temp state, not part of the original
  design; narrowed from an initial, too-broad `~/.ansible/**` by round 1's review, see that section);
  `permissions.allow`/`deny` for the wrapper's own invocation and the secrets helper's non-decrypting subcommands
  vs. its decrypting ones, plus direct `sops`/`env`/`printenv` (criterion #4).
- `.claude/README.md` (new, committed): the verified mechanism, the full deny/allow rationale, what protects the
  exempted wrapper as an explicit list (criterion #5), the honest Tier 1 limit (criterion #6), the Tier 2 upgrade
  path with no wrapper rewrite required (criterion #7), the end-to-end verification actually performed (criterion
  #8 in part — see below), and confirmation of no secrets/operator-specific paths (criterion #8).

**Rollout sequencing**: writing `sandbox.enabled: true` into a committed, project-shared settings file changes the
*current* session's own operating constraints immediately on write — this was flagged to the user as a
hard-to-reverse, environment-affecting action before writing anything (per this assistant's own operating
guidelines), and the user chose to enable and test live rather than stage the rollout.

**End-to-end verification under the real, live sandbox** (criterion #5's acceptance-criterion phrasing, adapted —
see "What was NOT verified" below for the one deliberately deferred piece):
- `cat ~/.config/sops/age/keys.txt`, a Python one-liner reading `.env`, and `xxd .env` were all refused against the
  real, existing files on this workstation, each with a genuine OS-level permission error, not a tool-level message
  — proving the denial holds below the command layer and survives switching readers.
- `scripts/deploy --check` ran to completion with no sandbox friction, reaching its own real preflight checks.
- `scripts/secrets check` (non-decrypting) ran without a permission prompt; `scripts/secrets fill` and a bare `env`
  were both refused at the permission layer.
- The full pre-existing fixture suites this change must not regress — `tests/check-deploy-wrapper.sh` (ticket #01,
  a black-box harness that never touches a real key or host) and the whole-repo `tests/lint.sh` — were run to a
  clean pass under the live sandbox settings (see "Sandbox-caused regressions found and fixed" below for what that
  took).

**What was NOT verified, by design**: an agent-run playbook actually opening an SSH connection to the real VPS.
This epic's own hard rule, held throughout every ticket, is that no automated step in this repository's own
tooling work connects to a real host. That specific piece of criterion #5 is operator-validated at the next real
deploy, the same treatment this epic already gives the migration, the reboot drill and the live-verification
script.

### Sandbox-caused regressions found and fixed (genuine, caused by `sandbox.enabled: true`)

1. **`~/.ansible` write restriction.** A fixture-triggered Ansible run not matching `excludedCommands` (a throwaway
   copy of the wrapper invoked by absolute path, deliberately outside the exemption — a fixture copy must not
   inherit the real wrapper's trust) failed with `Read-only file system: '/home/jacek/.ansible/tmp/...'`: Ansible's
   own local-temp fallback, and `scripts/deploy`'s own `private_scratch()` preference order
   (`XDG_RUNTIME_DIR`/`/dev/shm`/`/tmp`), both hit the sandbox's baseline write restrictions, none of which this
   ticket had configured. **Originally fixed** (before round 1 review) by adding `/run/user/**`, `/dev/shm/**`,
   `~/.ansible/**` to `sandbox.filesystem.allowWrite` — **round 1's review correctly flagged `~/.ansible/**` as too
   broad**: it also grants sandboxed write access to `~/.ansible/collections`, one of exactly two paths
   `scripts/deploy`'s own `effective_collections_path()`/`CFG_PATH_VALUES` explicitly trusts and loads collections
   from on its real, exempted run — a sandboxed process could plant a malicious collection there, invisible to
   `git diff`, for the next real deploy to load with full secrets access. **Re-fixed** by narrowing to
   `~/.ansible/tmp/**` only, the exact subdirectory the observed failure needed (see `.claude/README.md`'s new "Why
   `allowWrite` is scoped to `~/.ansible/tmp/**`" section for the full reasoning); re-verified via a clean rerun of
   both `tests/check-deploy-wrapper.sh` and the full `tests/lint.sh`.

2. **Hardcoded `/tmp/...` paths in the pre-existing test suite.** After fix 1, `tests/lint.sh` failed at
   `ansible-playbook --syntax-check site.yml >/tmp/hermes-syntax.log`: `Read-only file system`. Bare `/tmp` (as
   opposed to `$TMPDIR`, which the sandbox does allow) is correctly not in the write allowlist — widening
   `allowWrite` to cover all of `/tmp` would have defeated much of the point of restricting writes at all, so the
   real fix is in the test code, not the settings. Six pre-existing files (none touched by tickets #01–#07) turned
   out to hardcode `/tmp/<name>` instead of honoring `$TMPDIR`, a latent portability bug nothing had previously
   exercised because nothing had previously run these tests under write restrictions: `tests/lint.sh` (2 log
   redirects) and five Ansible test playbooks — `tests/test_conduit.yml`, `tests/test_config_render.yml`,
   `tests/test_hermes_profile.yml`, `tests/test_docker_compose.yml`, `tests/test_gateway_render.yml` (each renders
   real files under a `/tmp/<fixed-name>` directory or file and reads them back for assertions). **Fixed** by
   switching every one to `${TMPDIR:-/tmp}` (bash) or `{{ lookup('ansible.builtin.env', 'TMPDIR') | default('/tmp',
   true) }}` (Ansible), the same convention `tests/support/deploy-fixture.sh` already uses elsewhere in this repo.
   Two callers in `test_docker_compose.yml` and `test_gateway_render.yml` that duplicated their directory as a
   second hardcoded literal instead of referencing the already-defined var were also pointed at the var, removing
   the duplication rather than patching each literal separately.
   **Not a code defect in the deploy wrapper, the roles, or the sandbox settings** — it is a test-only portability
   gap (which scratch directory a test uses to render and re-read its own throwaway output), not a defect in any
   production template, task, or the security boundary this ticket adds. Proceeding is safe: the fix changes only
   *where* inert test-render output lives, not any comparison or secrets-handling logic, and both
   `tests/check-deploy-wrapper.sh` and the full `tests/lint.sh` were re-run to a clean pass afterward.

### A local-tooling gap found, NOT a sandbox regression and NOT a repository code defect

While investigating a `check-deploy-wrapper.sh` failure on the `SOPS_AGE_KEY_CMD` (Tier 2 hook) assertion (`rc=78`,
`your key is not a recipient of this store`), root-caused to: this session's validation `sops` binary was v3.9.4,
and `SOPS_AGE_KEY_CMD` was only added to `sops` in v3.10.0 (confirmed via `strings` on the binary — the string is
entirely absent from 3.9.4's compiled age keyservice — and via the upstream PR, getsops/sops#1811). `sops` silently
fell back to its hardcoded default identity-file path instead, which doesn't exist on this workstation, producing
the misleading "not a recipient" error. **Fixed** by fetching `sops` v3.10.2 into the local validation toolchain
(not part of the repository; this binary is never committed). **Not a code defect**: `hermes_secrets.py` and
`scripts/deploy` already correctly pass `SOPS_AGE_KEY_CMD` straight through to `sops` unmodified, exactly per the
Tier 2 design this ticket's own README section documents (`sops` itself, not this repo's code, is what has to
understand the variable). **Not sandbox-caused**: reproduced identically with the fixture's own key-file logic
run directly, independent of any Bash sandbox restriction — the string literally isn't compiled into the older
binary, so no permission setting could have changed the outcome. Proceeding is safe: after the binary upgrade, the
exact same test (`tests/check-deploy-wrapper.sh`'s `SOPS_AGE_KEY_CMD` assertion) passes cleanly, confirming the
wrapper's Tier 2 passthrough design already worked correctly and only the local validation tool was stale.

## Review round 1 (independent fresh-context subagent): CHANGES REQUESTED — both findings fixed

All 9 checklist items independently verified as PASS against the actual settings/README content (not just the
ticket's own claims) — including a second, independent re-fetch of the sandboxing docs, independent enumeration of
all 8 `scripts/secrets` subcommands against the allow/deny lists, a direct text comparison of the Tier 2 docstring
claim, and independent confirmation of the sops 3.10.0/`SOPS_AGE_KEY_CMD` changelog claim. Two blocking findings:

1. **A genuine, undisclosed security regression**: `sandbox.filesystem.allowWrite: ["~/.ansible/**"]` (added to fix
   the write-restriction regression described above) also grants sandboxed write access to
   `~/.ansible/collections`, a path the exempted wrapper explicitly trusts for collection loading on its real run —
   letting a sandboxed process plant a malicious collection there for the next real deploy to load, unprotected by
   anything in the wrapper's own `PLUGIN_DIR_NAMES` scan (which only walks the repo tree) and invisible to
   `git diff`. **Fixed**: narrowed to `~/.ansible/tmp/**`, the exact subdirectory the original failure needed;
   `.claude/README.md` gained a new section explaining why the broader form was wrong and what the narrower form
   still permits. Re-verified: full `tests/check-deploy-wrapper.sh` and `tests/lint.sh` reruns both clean.
2. **An incomplete sweep**: four `check-*.sh` scripts (`check-tailnet-caddy-access.sh`,
   `check-second-wave-services.sh`, `check-cloudflare-proxied-ingress.sh`, `check-custom-services.sh`) still
   hardcoded `/tmp/docker_compose_test/docker-compose.yml` — now mismatched with `test_docker_compose.yml`'s fixed
   `${TMPDIR:-/tmp}/docker_compose_test` render location — and `check-resolver.sh` hardcoded
   `/tmp/hermes-resolver-fail.log` in the identical pattern this ticket otherwise fixed everywhere else. **Fixed**:
   all five switched to the same `${TMPDIR:-/tmp}` convention. A repo-wide re-sweep after the fix found no further
   occurrences — the remaining `/tmp/...` literals in `tests/check-secret-suppression.sh` (inert fixture text
   scanned only by a static analyzer) and in `test_boot_ordering.yml`/`test_docker_user_rules.yml` (usage-comment
   examples whose real callers already pass a `mktemp -d` path) were independently confirmed as non-issues by the
   same review.

Both findings are code/config defects (not test-only): finding 1 is a real gap in the security boundary this
ticket exists to build; finding 2 is a real test-suite correctness gap that would silently validate stale or
missing output under exactly the write-restricted conditions this ticket introduces. Both are fixed and
re-verified; proceeding to round 2.

## Review round 2 (independent fresh-context subagent): PASS — two non-blocking cleanups applied anyway

Round 1's two fixes independently re-derived from scratch and confirmed sound, including the `~/.ansible/cp`
question the round 1 fix didn't explicitly rule out: nothing in this repo ever opens a real SSH connection from a
sandboxed, non-exempted process (every test playbook and fixture uses `connection: local`), so `~/.ansible/tmp/**`
alone is sufficient. No blocking findings. Two cheap, non-blocking cleanups were suggested and applied:

1. `roles/tailscale/tasks/main.yml` hardcoded `/tmp/tailscale-install.sh` for a production role task (not a test
   fixture) — reachable only via `tests/check-tailscale.sh`'s opt-in `TAILSCALE_LIVE=1` path, which this epic's own
   hard rule keeps out of automated testing (operator-validated on the real VPS). Non-blocking (a portability gap,
   not a leak), fixed anyway by switching to `ansible_env.TMPDIR` with the same `/tmp` fallback.
2. The ticket's own "Implementation / Files added/changed" summary (line 37) still named the pre-round-1, too-broad
   `~/.ansible/**` value instead of the fixed `~/.ansible/tmp/**` — a stale cross-reference in this file's own
   narrative, not in the enforced settings. Corrected.

Also added a documentation-only residual note to `.claude/README.md` (stale `ansible-tmp-*` fixture residue isn't
covered by `denyRead`, but never holds a real secret) per round 2's informational (non-defect) observation.
Re-verified: full `tests/check-deploy-wrapper.sh` and `tests/lint.sh` reruns both clean. Proceeding to round 3.

## Review round 3 (independent fresh-context subagent): CHANGES REQUESTED — one documentation gap fixed

One blocking (documentation-only) finding: `.claude/README.md`'s Tier 1 limit section and its "what protects the
exempted wrapper" list were written entirely in terms of *playbook* mode's protections (fixed flag set, pinned
Ansible config) and never named *registered-script* mode as an equally — arguably more easily — reachable path to
the same limit. `scripts/deploy`'s registry loader (`hermes_secrets.load_registry`) does no integrity checking on
`scripts/registered-scripts.conf` or a registered script's own contents (only path-containment, existence, and the
executable bit), so an agent can add a small new script plus one registry line and reach the full decrypted
environment with no sandbox, no argument-shape constraints, and no config pinning at all — a real gap in
criterion #14's "documented as a list" requirement, since a reader of the README alone would come away with a
too-narrow picture of the wrapper's attack surface. **Fixed**: added an explicit caveat to list item 2 and a new
paragraph under the Tier 1 limit section naming `registered-scripts.conf` and registered scripts specifically as
reaching the identical limit by a smaller edit. Documentation-only — no settings or code change, no
re-verification of live sandbox behavior needed. Independent review also confirmed the round-2 `tailscale` fix is
correct (site.yml's tailscale play sets `gather_facts: true` and `become: true`, so `ansible_env.TMPDIR` is
populated in the same execution context that consumes it, and the fallback degrades to the exact prior behavior
when unset) and found no further hardcoded `/tmp` paths anywhere in the repository.

**Ticket #08 is closed** after 3 review rounds — round 3 found only a documentation completeness gap (no code or
settings defect), now fixed. All 9 acceptance criteria hold: mechanism verified from current docs; both wrapper
invocation shapes exempted by command name; filesystem denyRead covers the key/`.env` for everything but the
wrapper; permission rules allow only vetted shapes; what protects the exempted wrapper is documented as a list,
now including registered-script mode's narrower protection; an end-to-end check under the real sandbox is
recorded (with the real-VPS-SSH portion deliberately operator-deferred, consistent with this epic's standing rule);
the accidents-not-a-determined-actor framing is stated; the Tier 2 upgrade path is documented with no wrapper
rewrite required; no secrets or operator-specific paths appear in the settings or documentation.
