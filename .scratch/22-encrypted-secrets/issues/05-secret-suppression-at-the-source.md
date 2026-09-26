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
`owner:` is treated the same as an API token), matching how the deploy wrapper's own redaction (ticket #02) already
treats every decrypted value the same way regardless of field. One functional finding and one real bug along the
way, both in code this ticket touched but neither literally in scope until found:
- `owntracks`'s htpasswd generation used `hash_scheme: bcrypt`. This ticket's own dynamic leak test hit an
  "unsupported parameter" error against it in its throwaway validation container — but round 1's independent
  review, checking the module's real source, found `hash_scheme` is actually the CANONICAL parameter name in
  current `community.general` (`crypt_scheme` is kept only as a backward-compat alias); the container's error was
  specific to the old, Debian-bundled collection version (`apt-get install ansible` on Debian 12 pulls
  community.general ~6.x, from before the rename) it happened to install. **Not a confirmed production bug** — a
  reasonably current collection already treated `hash_scheme: bcrypt` as correct. Kept as `crypt_scheme: bcrypt`
  anyway since that name works unmodified on both old and new collection versions, the more portable choice.
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
in each. This dynamic test is what actually found the `environment:` bug above — a genuine confirmation that "at
verbosity" was the right bar to test against, not a formality.

## Review round 1 (independent fresh-context subagent): CHANGES REQUIRED, fixed

Independently reproduced the `environment:`-bypasses-`no_log` claim from scratch (confirmed) and found a second,
real instance of the exact same underlying mechanism that this ticket's own sweep missed: **`become_user:` is
inlined into the shell commands Ansible's become plugin runs (`setfacl`, `chown`, `chmod`) exactly the way
`environment:` values are, printed verbatim by the connection plugin at high verbosity regardless of `no_log`** —
reproduced independently a second time in this round against real ansible-core. `roles/common/tasks/main.yml`'s two
git-identity tasks use `become_user: "{{ secrets.admin_username }}"` with `no_log: true`, which does not actually
protect it. Unlike the `environment:` case, this has no fix: `become_user` must always be a literal account name
(sudo/su act on it directly), so there is no file-reference redesign available the way there was for the GitHub
token. Accepted as a documented, undefended exception — an OS username is not a credential in the traditional
sense, knowing it grants no capability by itself — recorded at both call sites and as an explicit, narrow
`ACCEPTED_BECOME_USER_EXCEPTIONS` allowlist in the checker (matching (file, task name), not a blanket exemption for
`become_user` generally: any OTHER task using it with a secret is still a hard failure).

Also found and fixed two undisclosed soundness gaps in the checker itself, both confirmed via a working fixture
that passed cleanly when it should have failed: `vars:` and `loop:` were excluded from the scan, so a task computing
an intermediate name from a secret in its own `vars:` block, or looping directly over a secrets structure, passed
silently. Neither is currently exploited anywhere in this repo (confirmed by grep), but both are realistic Ansible
idioms; fixed by including both in the scan (removed from `DIRECTIVE_KEYS`) and no new false positives resulted
against the real repo. The checker now also gives `environment:`/`become_user:` their own always-fail check (never
accepting `no_log: true` as sufficient for either, with a message saying so explicitly) instead of folding them into
the generic "add no_log" path, which was itself misleading for exactly the reason this round exists.

Also corrected: this ticket's own original notes overclaimed the `owntracks` `hash_scheme`/`crypt_scheme` finding as
a confirmed production bug ("every real deployment has generated a hash Caddy's basic_auth cannot verify"). Round 1
checked the module's actual current source and found `hash_scheme` is the canonical parameter — `crypt_scheme` is
kept only as a backward-compat alias — so a reasonably current `community.general` install was already correct; the
error this ticket's own validation container hit was specific to the old, Debian-bundled collection version it
happened to install via a bare `apt-get install ansible`. Notes corrected above; the code change itself
(`crypt_scheme: bcrypt`, which works unmodified on both old and new collection versions) is kept as the more
portable choice, not reverted, but no longer described as fixing a proven production defect.

New regression tests added to `tests/check-secret-suppression.sh` for all four newly-caught classes (`environment:`
flagged even with `no_log: true` present, `become_user:` flagged when not on the accepted-exceptions list, a
`vars:`-computed intermediate, a `loop:` directly over a secret), each verified to actually fail before the fix and
pass after.

## Review round 2 (independent fresh-context subagent): CHANGES REQUIRED, fixed

Re-verified every round 1 fix independently (including reproducing the `become_user`-bypasses-`no_log` claim again,
against real ansible-core in a disposable container) — all held. Two new findings:

1. **CODE DEFECT (checker soundness):** `ACCEPTED_BECOME_USER_EXCEPTIONS` matched on `(file, task name)` only, never
   the actual `become_user:` expression. Repurposing one of the two allowlisted tasks to carry a DIFFERENT, genuinely
   dangerous secret through `become_user:` — same file, same task name, new expression — would have been silently
   waved through with zero warning, exactly the failure mode a narrow allowlist exists to prevent. Fixed: the
   allowlist is now keyed on `(file, task name, the exact expression)`; a repurposed task with a different expression
   is a hard failure again. A regression fixture proves this (had to be rewritten once: the first version's
   assertion was satisfied by an unrelated, already-present fixture's identical message text rather than by the new
   fixture itself — caught by manually re-running the exact mutation this round found and confirming the test
   initially passed when it should have failed, then tightening the assertion to the new fixture's own file+task
   line specifically).
2. **DOCUMENTATION gap, not a functional defect:** `site.yml`'s second play sets `ansible_user: "{{
   secrets.admin_username }}"` at the play level — the identical never-fixable-by-no_log mechanism as `become_user:`
   (Ansible's SSH connection plugin inlines it into every single task's connection trace for the whole play,
   regardless of any task's own `no_log`), independently reproduced by the reviewer against a real local sshd. This
   was already out of the checker's declared scope (`roles/*/tasks/` only) and doesn't violate the "no credential
   leak" goal under this ticket's own established reasoning (an OS username is not a credential; knowing it grants
   no capability by itself) — but was undocumented anywhere. Fixed: a comment at the call site mirroring
   `roles/common/tasks/main.yml`'s, plus a line in the checker's own "what this cannot verify" docstring section.

The full-playbook dynamic leak test was run for real again this round (a fresh disposable podman container, root,
python3-apt, a real Docker daemon, destroyed afterward) and passed clean; the round also confirmed `delegate_to` is
unused anywhere in the repo and that ordinary module arguments (`ansible.builtin.user`'s `password:`,
`community.general.git_config`'s own args) do NOT share this bypass class — they're JSON-embedded in the AnsiballZ
payload, not inlined into a printed shell command, so plain `no_log` correctly protects them.

## Review round 3 (independent fresh-context subagent): CHANGES REQUIRED, fixed

Re-verified round 2's allowlist fix by reverting it in a scratch copy and confirming the regression test genuinely
catches the revert (it does). Found one real, previously-undiscovered **code defect** in the checker's own core
pattern: `SECRET_RE` required zero whitespace between `secrets` and the following `.`/`[`, but real Jinja tolerates
whitespace there (`secrets .x`, `secrets. x`, `secrets ['x']` all render identically to `secrets.x`, confirmed with
a live Jinja render) — a reformatted expression could bypass detection completely, including bypassing the
`environment:`/`become_user:` hard-fail path, which shares the same regex. Not currently exploited anywhere in the
real repo, but a real, cheap-to-trigger gap in the exact class of soundness issue rounds 1 and 2 already found and
fixed twice in this same file. Fixed: `\s*` added around the dot/bracket; verified against all three bypass forms,
confirmed the fix is what makes the difference (reverting it and re-running the new fixture reproduces the miss).

Also closed three test-coverage gaps found by fresh mutation testing (the underlying code already handled all three
correctly — only the fixtures were missing, so a future regression in any of them would have shipped silently):
`contains_secret_ref`'s list recursion (a literal YAML list of secret-interpolated strings under `loop:`), the
`SECRET_RE` regex's `re.DOTALL` flag (an expression reflowed across multiple lines inside `{{ }}`), and
`walk_tasks`'s recursion into `rescue:` blocks (only `block:` had a fixture). Each new fixture was verified to
actually fail when its corresponding code path is reverted, not just added and trusted. Minor documentation
additions: a note on the allowlist's own fragility (a deliberate fail-safe, not a bug — reformatting an allowlisted
expression's internal whitespace turns back into a loud failure, by design), and `roles/*/handlers/` added to the
checker's "what this cannot verify" list (checked by hand: none currently reference `secrets.*`).

## Review round 4 (independent fresh-context subagent): CHANGES REQUIRED, fixed

Two more real code defects in the same soundness class rounds 1-3 already hammered on, both hand-built (not
mutations) against the real, unmutated checker:
- `DEFAULT_JINJA_RE` (used to resolve a `template:` task's `src:` through a `{{ ... | default('literal.j2') }}`
  expression) only accepted single quotes with zero whitespace before the `(` — real Jinja/Python grammar accepts
  double quotes and a space just as validly (`default ("x.j2")`), and the round's independent review built a real
  template leak using each unaccepted style and confirmed the checker said "OK" both times, while the exact same
  leak in the "expected" style was correctly flagged. Fixed: quotes and whitespace both now optional/either-style.
- The template-following logic only recognized the fully-qualified `ansible.builtin.template`, never Ansible's
  equally valid short name `template:` — a task written that way had its `src:` never resolved or scanned at all.
  Fixed: both spellings now checked.

Neither is currently exploited in the real repo (all real template tasks use the FQCN with the single-quote,
no-space `default()` form), but the same standard applied to round 3's whitespace-regex bug applies here too.

Also closed three test-coverage gaps found by fresh mutation testing (the code was already correct in all three —
only the fixtures were missing): `ansible.builtin.assert`'s scan-exemption widened to also strip `fail_msg`/
`success_msg` (no existing fixture used a GENUINELY interpolated fail_msg, only the always-prose one); `no_log`
accepting any truthy value instead of requiring the literal `True` the docstring already promised (no fixture used
a non-literal `no_log:` expression); and the recursive `tasks/**/*.yml` glob regressing to non-recursive (no fixture
used a nested tasks subdirectory). All three verified to actually fail their corresponding mutation when reverted.

## Review round 5 (independent fresh-context subagent, breaking the 5-round cap on the operator's own instruction):
CHANGES REQUIRED, fixed

One more real code defect in the same family, found by hand-built (not mutated-code) fixtures against the real
checker: the "does this template dynamically include another one" conservative heuristic
(`"lookup(" in text and "template" in text`) was a plain substring check, bypassed completely by `query()`/`q()`
(the built-in aliases for `lookup()` — same plugin, list-returning call form) and by a native Jinja
`{% include 'file.j2' %}` statement (which doesn't use `lookup()` at all, and — unlike the genuinely dynamic
per-service `lookup('template', 'services/' + name + '.yml.j2')` case this heuristic exists for — has a literal,
statically-resolvable target that was never actually followed). Neither exploited in the real repo today. Fixed:
`LOOKUP_TEMPLATE_RE` now matches `lookup`/`query`/`q` with any quoting/whitespace; a literal `{% include %}` target
is now resolved and checked recursively, exactly like a task's own `src:`; a non-literal (dynamic) `{% include %}`
gets the same conservative treatment as an unresolvable `lookup()`.

Also closed four test-coverage gaps found by the round's mutation testing (the underlying code was already correct
in all four — only fixtures were missing): the lookup/template detection was previously only caught incidentally
by an unrelated fixture's prose, not by a purpose-built one; a violation inside a task's `always:` section (only
`rescue:` had a fixture, from round 3); the short `assert:` module name (only the FQCN had a fixture); and a
genuinely interpolated `success_msg:` (only `fail_msg:` had one). The short-`assert:`-name fixture needed one
extra pass: the first version's leak came through `fail_msg:`, which the generic scan catches regardless of whether
`assert`'s short name is recognized for the `that:` exemption specifically — so it didn't actually discriminate the
mutation; replaced with a Jinja-string-wrapped bare `that:` entry, which does.

Also documented (not a functional defect): the checker's docstring only named `site.yml`'s `ansible_user` as an
out-of-scope reference, but its first play (bootstrapping the admin account, before `ansible_user` even applies)
also interpolates `secrets.admin_username` and `secrets.admin_ssh_public_key` several times, unsuppressed — not a
credential leak under this ticket's own established reasoning (a username and an SSH *public* key, not secrets),
but not individually disclosed. Docstring updated to say so.

This is the fifth real-defect-finding round in the same file, each narrower than the last. The operator was
consulted directly at this point (the protocol's own 5-round cap) and chose to fix this finding and run one more
review round rather than accept it as a documented limitation or close the ticket as-is.

## Review round 6 (independent fresh-context subagent, past the protocol's own cap at the operator's explicit
choice): CHANGES REQUIRED — accepted as a documented limitation, no further code change

Found one more real, reproduced bypass, but of a qualitatively different kind than rounds 1–5: Ansible's `vars`
magic variable (a dict of every variable in scope, including the resolved `secrets` fact) and the `vars` lookup
plugin render a secret identically via `{{ vars['secrets']['NAME'] }}`, `{{ vars['secrets'].NAME }}`, or
`{{ lookup('vars', 'secrets').NAME }}` — none of which contain the literal token `secrets` followed by `.`/`[`, so
none match `SECRET_RE`. This defeats both the generic no_log scan and the `environment:`/`become_user:` hard-fail
path the same way. Reproduced against real ansible-core and against the real, unmutated checker. Not currently
exploited anywhere in the real repo.

Unlike rounds 1–5 — each a specific, enumerable syntactic variant (whitespace, quoting, module short names, lookup
aliases, include forms) — this is an INDIRECTION mechanism, and Jinja/Ansible has an open-ended supply of those
(`vars`, `hostvars`, a dynamically-built attribute name, a custom or piped lookup, string concatenation
reconstructing the name `secrets` at render time...). Patching each one as found would not converge on a complete
static guard, only a longer list of enumerated special cases — a fundamentally different situation from rounds
1–5's genuinely closable gaps. Presented to the operator as an explicit strategic choice (fix this one instance and
continue the review loop, vs. accept the general class as a documented limit) rather than another automatic round;
the operator chose to accept it as a documented, honest limitation — the same treatment this ticket already gives
`environment:`/`become_user:`'s own undefended cases — rather than continue chasing individual indirection
techniques. The checker's own docstring now states this plainly, names the concrete `vars`/`lookup('vars', ...)`
example, and asks that any FUTURE task seen using `vars`/`hostvars`/a lookup plugin anywhere near `secrets` be
reviewed by hand, the same way `environment:`/`become_user:` already ask for manual judgment on their own cases. No
code change beyond the docstring; the checker's existing detection and all prior rounds' fixes are unaffected and
continue to hold for everything they were built to catch.

Two further minor, non-blocking observations from the same round (checker reports success on a nonexistent or
non-directory `--root`, and silently skips a YAML file whose top level isn't a task list) were noted but left
unaddressed at the operator's direction — not currently reachable by any real invocation of this checker (the one
test that uses it always passes either the correct real root or a `mktemp -d` result), and a file shaped that way
would fail `ansible-playbook --syntax-check` regardless.

**Ticket #05 is closed.** Six review rounds (five within protocol, one beyond it at the operator's explicit choice)
produced five real, fixed code defects plus one accepted, documented indirection limitation — all in
`scripts/check_secret_suppression.py`; the production role code itself (Tailscale, resolver, compose validation,
the `no_log` sweep, `owntracks`, `backup`) held up unchanged since round 0 across every round's fresh production-code
audits.
