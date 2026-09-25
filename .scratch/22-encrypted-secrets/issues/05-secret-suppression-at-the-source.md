# 05: Keep secrets out of arguments, results and diffs at the source, with a guard

**What to build:** No task leaks a credential through its arguments, its result, its registered output or its diff, regardless of the wrapper — covering not only file-rendering tasks but the other known leaks — and a static check stops a future task from omitting the suppression. This is the second layer under output redaction.

**Blocked by:** None (can start immediately)
**Blocks:** #09

**Status:** ready-for-agent

- [x] Every task that renders or writes a file containing secret values suppresses diff output (and log output where the module would echo the content)
- [x] **The Tailscale login no longer puts the auth key in the process arguments** (Tailscale accepts a file reference for its auth key, so the value never appears in the command line, the task result or a process listing) and the task's output is suppressed
- [x] **The auth-key file has a defined lifecycle:** created immediately before the login step, mode 0600 and owned by root, never logged, and removed after the step whether it succeeded or failed (verified for both outcomes, including that no key file remains); a key file left over from an interrupted run is removed before a new one is written
- [x] **The minimum Tailscale version that supports the file-reference form is established** from Tailscale's documentation and recorded, and a preflight fails clearly on an older installed version rather than silently falling back to the argument form
- [x] **The resolver's accumulation loop suppresses its output**, so verbose runs no longer print the whole secrets structure — its contract (environment in, the same secrets structure out) is unchanged and the existing resolver test passes untouched
- [x] **The compose validation task no longer registers or prints the fully rendered, secret-bearing compose file** (quiet validation or suppressed output), while still failing loudly and usefully on an invalid file
- [x] A static check in the standard lint run flags a task that renders or passes a secret without suppression, with negative fixtures for a rendered template, a command argument and a registered result
- [x] A full-playbook check-mode run with fixture secret values **at verbosity, and** with diff enabled, shows none of them in output or process arguments
- [x] Existing render tests pass unchanged

## Notes

See epic 22 spec, "Implementation Decisions" (second layer: suppression at the source) and "Problem Statement" item 3. Verified against the current roles: the Tailscale auth key is passed as a command argument, and neither the resolver, tailscale nor docker roles use output suppression anywhere.

## Implementation

**Tailscale.** `roles/tailscale/tasks/main.yml`: a version preflight (`tailscale version`, compared against
`tailscale_min_version: "1.16.0"` in defaults — the minimum release containing `file:` support for `--auth-key`,
confirmed from tailscale/tailscale's own source history: commit `b822b5c79` "let up --authkey be of form
file:/path/to/secret", 2021-09-29, first shipped in v1.16.0). The login task is now a `block`: writes the key to
`tailscale_authkey_file` (`/run/hermes-vps/tailscale-authkey`, tmpfs, 0600, root) after removing any leftover from
an earlier interrupted run, logs in with `--authkey=file:...`, and an `always:` removes the file whether the login
succeeded or failed. Both the write and the login task carry `no_log: true`.

**Resolver.** `roles/secrets/tasks/main.yml`'s accumulation loop (`set_fact: secrets: ...`) and its own debug
summary both carry `no_log: true`. The fact's value and every consumer of it are unchanged — verified by the
existing `tests/check-resolver.sh` passing untouched.

**Docker compose validation.** `roles/docker/tasks/main.yml`'s validate task now runs `docker compose ... config
--quiet` (validates without printing the resolved, secret-bearing config; still writes a real error to stderr and
exits non-zero on an invalid file — verified against `docker/compose`'s own source history, present since at least
v2.16.0, 2023-02). The render task itself also carries `no_log: true` (defense in depth for the file's diff).

**Suppression sweep.** Every task across `roles/*/tasks/` whose own arguments (module args, a template's rendered
content followed through `src:`, or the `environment:` directive) reference a `secrets.*` value now carries
`no_log: true` — applied uniformly regardless of whether the specific field felt "sensitive" (a username used for
`owner:`/`become_user:` is treated the same as an API token), matching how the deploy wrapper's own redaction
(ticket #02) already treats every decrypted value the same way regardless of field. Two bugs found and fixed along
the way, both in code this ticket touched but neither literally in scope until found:
- `owntracks`'s htpasswd generation used `hash_scheme: bcrypt`, not a real parameter of
  `community.general.htpasswd` (the real one is `crypt_scheme`) — silently ignored by older Ansible, so every real
  deployment has generated an `apr_md5_crypt` hash, which Caddy's `basic_auth` (bcrypt-only) cannot verify. Found
  only because this ticket's own dynamic leak test is the first thing to have ever actually EXECUTED this task.
  Fixed: `crypt_scheme: bcrypt`.
- `backup`'s git-clone task passed the GitHub token via the `environment:` directive. Ansible inlines `environment:`
  values into the literal shell command it runs, and its connection plugin prints that command verbatim at high
  verbosity (`-vvv+`) — **regardless of the task's own `no_log: true`**, which only redacts a task's arguments and
  result, not that separate connection-level trace. This is invisible to any static check (the YAML looks identical
  either way) and was found only by running the dynamic leak test at `-vvv`. Fixed the same way as the Tailscale key:
  the token is now written to a private file (`/run/hermes-vps/backup-github-token`, 0600, root, same
  create-immediately-before/remove-in-`always`-lifecycle) and only its PATH (not the value) is passed through
  `environment:` (`GITHUB_TOKEN_FILE`); `roles/backup/files/git-credential-env` reads the token from that file
  instead of from `$GITHUB_TOKEN`. Documented as an explicit, checked-for-by-hand limit in the static checker's own
  docstring, since a static check cannot see this class of leak.

**Static checker.** `scripts/check_secret_suppression.py` (+ `tests/check-secret-suppression.sh`): walks every
`roles/*/tasks/**/*.yml`, and for each task, checks whether its own arguments (recursively, including
`environment:`; `assert`'s `that:` is exempt as a boolean check, but its `fail_msg`/`success_msg` are scanned)
contain a REAL Jinja interpolation of a `secrets.*` value (`{{ ... secrets.NAME ... }}` — a bare textual mention,
as several `fail_msg`s deliberately have, is not flagged). A `template:` task's `src:` is followed to the .j2 file
(resolving a `{{ ... | default('literal.j2') }}` expression via its literal default) and searched the same way; a
template that itself dynamically includes another one via `lookup('template', ...)` (this repo's own
docker-compose.yml.j2, assembling per-service fragments) is flagged conservatively rather than resolved. Negative
fixtures for all three named classes (rendered template, command argument, registered result), each with a
suppressed counterpart that must NOT be flagged, plus a nested-block case and a malformed-YAML case. The checker's
own docstring states plainly what it cannot verify: the `environment:`-bypasses-no_log class above, and any leak
that doesn't literally interpolate `secrets.*` in the leaking task's own YAML (this repo has exactly one such case,
`roles/owntracks/tasks/parse_htpasswd.yml`'s `slurp` of a file a PRIOR task wrote from a secret — fixed by hand,
three tasks given `no_log: true`, not something a pattern-based checker can find on its own).

**Full-playbook dynamic leak test.** `tests/check-playbook-secret-leak.sh` runs `tests/test_playbook.yml` (extended
with a `profiles.default.context7_api_key` entry the hermes template needs) via `ansible-playbook --check --diff
-vvv`, grepping the combined output for any of the stub's distinctive `LEAK-CANARY-*` values. Needs a real,
disposable, root-owned, Debian-family control host with a reachable Docker daemon (skips with a clear message
otherwise — `ansible.builtin.apt` needs the python3-apt binding on the CONTROL node too, which most dev sandboxes
won't have; this repo's own sandbox for this session didn't). Verified for real in a throwaway `podman` Debian 12
container (built, provisioned, and destroyed for this ticket only — nothing kept): pre-seeds the `llm_wiki`/`admin`
system accounts and the transient `tests/roles`/`tests/backup_sync` symlinks two tasks need (their `playbook_dir`
-relative paths assume the real entry point is `site.yml` at the repo root, not `tests/test_playbook.yml`) — none
of this is committed, all created and removed by the test script itself. Scoped to the six roles that can actually
complete a `--check` run end-to-end (`common`, `docker`, `authelia`, `silverbullet`, `hermes`, `backup`);
`owntracks`/`adguard`/`conduit`/`gateway` hit unrelated check-mode/module limitations (owntracks's own htpasswd
module doesn't declare check-mode support, so a later real file read fails for a reason having nothing to do with
suppression) and are covered instead by the static checker and by hand for the specific tasks this ticket touched
in each. This dynamic test is what actually found both bugs above — a genuine confirmation that "at verbosity" was
the right bar to test against, not a formality.
