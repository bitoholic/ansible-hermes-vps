# Agent guardrails (Tier 1) — epic 22 ticket #08

`.claude/settings.json` is committed with this repository so any agent working in it — on any
workstation — gets the same guardrails automatically. This file records the design decisions, what
was actually verified, and the honest limit of what this protects against.

## The mechanism (verified against the current Claude Code documentation *and* empirically — the docs alone overstate what it delivers)

Claude Code's Bash sandbox (`sandbox.enabled: true`) applies OS-level filesystem and network
isolation to every Bash/Monitor command it runs, enforced by the kernel (Linux: bubblewrap/seccomp;
macOS: Seatbelt).

`sandbox.excludedCommands` is documented as letting one named command run "completely outside the
sandbox" (`https://code.claude.com/docs/en/sandboxing`: *"Add `excludedCommands` for any
organization-approved tools that must run without isolation"*; entries matched as literal command
names, e.g. `["docker", "kubectl"]`). **In practice, on Claude Code 2.1.283, this claim does not hold
without extra configuration, and one part of it does not hold at all.** Ticket #08 originally closed
on the documented claim alone, verified only against an *absent* key/store (see "End-to-end check"
below for why that test didn't catch this). Once a real key and store existed (ticket #09), four real
gaps surfaced, three fixable and one not:

1. **`sandbox.filesystem.denyRead` overrides the exemption.** A path listed in `denyRead` stayed
   unreadable to `scripts/deploy` even though it's the excluded command — confirmed with a synthetic
   throwaway key and deny rule (never the real one), reproduced identically after a full session
   restart and after moving the exclusion to trusted (user-level) settings, ruling out caching or the
   trusted-tier restriction as the cause. **Fix**: the age key and SSH key paths were removed from
   `denyRead` entirely (see "What's denied" below for what this costs).
2. **`permissions.deny` `Read(...)` rules *also* override the exemption**, despite being documented
   (and originally recorded in this file) as scoped only to Claude's own `Read` tool, not Bash. Removing
   `Read(~/.config/sops/age/**)` and `Read(~/.ssh/**)` from `permissions.deny` was necessary before the
   wrapper could see either file — confirmed by testing with them present (blocked) and absent (worked).
3. **Unix-domain-socket creation is blocked by a separate seccomp filter, independent of exclusion.**
   SSH's own connection-multiplexing feature (`ControlMaster`) failed with
   `muxclient: socket(): Operation not permitted` even after fixes 1–2. **Fix**:
   `sandbox.network.allowAllUnixSockets: true` (found via the CLI binary's own settings schema strings,
   since the fetched docs didn't surface this cleanly) — `allowUnixSockets` alone is macOS-only and
   silently ignored on Linux.
4. **Raw network reachability is NOT lifted by exclusion, and there is no fix for this in settings.**
   After fixes 1–3, the wrapper could decrypt the store and reach the point of opening an SSH
   connection, but failed with `ssh: connect to host ... port 22: Network is unreachable` — confirmed
   against the VPS's real public IP (not a private/overlay address, ruling out a routing-only
   explanation). Traced into the CLI binary's own sandboxing code: Linux network confinement
   (`--unshare-net`, bubblewrap's network-namespace flag) is gated by a `needsNetworkRestriction`
   computation derived purely from `sandbox.network.allowedDomains`/`denyAllNetwork` — **nothing in that
   computation references `excludedCommands` at all**. Adding the VPS's own domain/IP to
   `sandbox.network.allowedDomains` did not help, consistent with this finding: that setting governs
   the HTTP/SOCKS proxy layer, which plain SSH (not HTTP traffic) never uses. There is no setting that
   lifts network-namespace isolation for an excluded command specifically. This is a genuine platform
   gap, not a configuration mistake, and feedback describing it has been filed with Anthropic.

**What this means in practice**: an agent can run `scripts/deploy` and have it correctly decrypt the
store and prepare everything (fixes 1–3 are real, working, permanent fixes) — but the final network
hop to the real VPS cannot complete through the exemption alone. The only way an agent can complete a
real deployment is the documented `dangerouslyDisableSandbox` escape hatch (see "Reaching the VPS as
an agent" below), which is deliberately *not* a standing, low-friction capability.

`scripts/deploy` is the only entry in `excludedCommands`. Both of the wrapper's own invocation shapes
(`scripts/deploy [FLAGS]` and `scripts/deploy --script NAME [ARGS]`, epic 22 #01) are covered by the
same entry — the exemption is by command name, not by argument shape; argument-shape vetting is a
*separate* layer (see below).

## What's denied, for everything except the exempted wrapper

**`sandbox.filesystem.denyRead` now covers only `./.env`** — the plaintext leftover from before the
encrypted store existed (epic 22 #03's structural guard keeps it git-ignored; this keeps it unreadable
to a sandboxed agent too, at the OS level, unconditionally). The wrapper only ever checks whether this
file *exists* (a warning, never a content read — confirmed by reading every reference to `.env` in
`scripts/deploy`), so denying it costs the wrapper nothing.

**`~/.config/sops/age/**` and `~/.ssh/**` are deliberately *not* in `denyRead` any more** — the
opposite of the original design. As documented above, `denyRead` overrides the exemption entirely, so
keeping these paths there would make `scripts/deploy` unable to decrypt the store or open its own SSH
connection — defeating this ticket's whole purpose. Their protection is now the weaker
`permissions.deny` layer below, plus the `Read()` tool-deny for `.env` only (the two `Read()` entries
for the key paths were also removed, since — surprisingly — they *also* overrode the exemption; see
above). **This is a real, accepted downgrade**: an OS-level, reader-independent wall over these two
paths is not achievable while also letting the exempted wrapper use them, on this Claude Code version.
Command-pattern rules can be sidestepped by an equivalent command the pattern didn't anticipate (a text
editor, an uncommon utility, a one-off script) — this was exactly the risk the original filesystem-level
design was chosen to avoid, and it no longer can be, for these two specific paths.

`permissions.deny` (Bash command-shape rules — the primary defense now for the age key and SSH key,
not merely defense-in-depth alongside an OS-level wall):
- `sops decrypt`/`sops exec`, `env`, `printenv` — direct decrypt/environment-dump attempts.
- `scripts/secrets fill|edit|rotate|add-recipient|remove-recipient|import` — every subcommand of the
  secrets helper (epic 22 #04) that needs to read the age key to decrypt or re-encrypt the store.
- `cat` against `~/.config/sops/age/*`, `~/.ssh/*`, `.env` and `./.env` — the single most likely
  "quick look" command for each of the three sensitive paths. Cheap, reasonable defense-in-depth for
  the most common accidental read; **explicitly not exhaustive** — `head`, `tail`, `less`, `xxd`, a
  Python one-liner, or any other reader not in this list is not blocked. Tier 1 has always been framed
  as accident prevention, not a security boundary (see the Tier 1 limit below); for these two paths
  that framing is now load-bearing rather than a backstop.

`permissions.allow` — the wrapper's own invocation, and the secrets helper's two subcommands that
never touch the key at all: `check` (reads only the store's ciphertext structure) and `init-key`
(creates a *new* identity; never reads an existing one, and `age-keygen` itself already refuses to
overwrite one — see epic 22 #04's own notes).

## Why `allowWrite` is scoped to `~/.ansible/tmp/**`, not all of `~/.ansible`

The sandbox denies writes outside a small allowlist by default. A *sandboxed* (non-exempted)
`ansible-playbook` invocation — any of this repo's own local test playbooks (`tests/test_*.yml`,
run directly by `tests/lint.sh`, never through `scripts/deploy`) or a throwaway fixture copy of the
wrapper invoked by absolute path (`tests/support/deploy-fixture.sh`, deliberately outside
`excludedCommands` — a fixture copy must not inherit the real wrapper's trust) — has no scratch
directory pinned for it the way the exempted wrapper pins its own (`ANSIBLE_LOCAL_TEMP` under a
private, wrapper-owned directory; see below), so it falls back to Ansible's own default local-temp
location, `~/.ansible/tmp`. Without write access there, any such run fails outright
(`Read-only file system: '~/.ansible/tmp/...'`), which is why this entry exists at all.

It is **not** `~/.ansible/**`, because `~/.ansible/collections` is one of exactly two paths (`scripts/deploy`'s own `CFG_PATH_VALUES`, the other being `/usr/share/ansible/collections`) the exempted wrapper
explicitly trusts and loads Ansible collections from on its real, unsandboxed run
(`effective_collections_path()` → `ANSIBLE_COLLECTIONS_PATH`). Granting sandboxed write access to that
same tree would let an untrusted sandboxed command plant or overwrite a collection there — invisible to
`git diff`, since nothing under `~/.ansible` is part of this repository — that the *next real deploy*
would then load with the full decrypted secrets environment. That is a strictly worse bypass than the
documented Tier 1 limit below (which at least requires editing a tracked file), so `allowWrite` is
scoped to exactly the subdirectory the observed failure needed, `~/.ansible/tmp/**`, leaving
`~/.ansible/collections` (and everything else under `~/.ansible`) outside the sandboxed write surface.
Found by epic 22 #08's own round 1 review, not the original design — recorded here per that review's
own finding.

One residual noted by round 2's review: `~/.ansible/tmp` is not in `denyRead`, so stale `ansible-tmp-*`
residue left behind by a killed or crashed non-exempted `ansible-playbook` run could later be read back
by any sandboxed Bash command. This never holds a real secret — the exempted wrapper's own runs never
write there at all (see above), so anything that could ever land there comes only from this repo's own
local test fixtures and their canary values, not the real store.

## What actually protects the exempted wrapper, once exempted (the list this ticket's own
acceptance criteria ask for)

Being exempted from the sandbox is not "safe by default" — the wrapper is trusted specifically
*because* of everything below, not because it was let out of the sandbox:

1. **The permission rules above** — only `scripts/deploy`'s own invocation is allowed to run
   unsandboxed at all; nothing else is.
2. **The wrapper's own refusals** (epic 22 #01) — it parses its own arguments and refuses extra
   variables, ad-hoc modules, foreign playbooks, other inventories/connections, and anything outside
   its fixed flag set, regardless of what an agent asks it to do. This applies to *playbook mode*.
   *Registered-script mode* (`scripts/deploy --script NAME`) has a narrower protection here: the
   wrapper only checks that `NAME` resolves, inside the repository, to an existing, executable file
   listed in the committed `scripts/registered-scripts.conf` — it does not vet, hash, or sign the
   script's own contents. See the Tier 1 limit below for what this means in practice.
3. **The pinned Ansible configuration and cleared environment** (epic 22 #01) — inherited
   `ANSIBLE_*` settings are cleared, the effective configuration is refused if it would make Ansible
   write a log, a callback's output, or a persistent fact cache to disk, and Ansible's own local temp
   lives in a private, wrapper-owned directory removed when the run ends.
4. **Output redaction** (epic 22 #02) — every decrypted value is scrubbed from the wrapper's combined
   stdout/stderr as it streams, regardless of which task or how a value is encoded.

## What this does NOT protect against — the documented Tier 1 limit

An agent that edits the wrapper itself, a role, or the playbook, and then runs the (now-modified)
wrapper is **not** protected against by anything above — the modified code runs with the full
decrypted environment and can do anything with it, including printing a re-encoded value past the
redactor. This is a deliberate, accepted limit, not an oversight: the age key lives on the same
machine the agent runs commands on, so Tier 1 stops *accidents* (reading the key file, dumping the
environment, an unredacted diff) but not a *determined actor* with edit access to this repository's
own code. Closing this gap is exactly what Tier 2 is for.

**Registered-script mode is exactly as unprotected, and easier to reach.** `scripts/deploy`'s registry
loader (`hermes_secrets.load_registry`) does no integrity checking at all — no checksum, no signature —
on either `scripts/registered-scripts.conf` or the script file a registered name points to; it only
checks that the resolved path stays inside the repository, exists, and is executable. An agent can
`Write` a brand-new script anywhere under this repo, add one line to `registered-scripts.conf`
registering it, and run it via `scripts/deploy --script <name>` — which is excluded from the sandbox by
command name exactly like every other `scripts/deploy` invocation, and pre-approved by
`permissions.allow: ["Bash(scripts/deploy:*)"]` with no prompt. Unlike playbook mode, a registered
script has none of the fixed-flag-set or Ansible-configuration constraints — it can do anything a shell
script can do with the fully decrypted secrets environment. This is not a narrower case of the wrapper-
editing limit above; it is the *same* limit reached by a smaller edit (one new file plus one registry
line, vs. patching the wrapper's own argument-parsing/refusal logic), and is called out separately here
because it would be easy to read the "wrapper's own refusals" protection as covering both invocation
shapes equally — it does not.

**A separate, unrelated limit**: even where nothing above is at issue, an *agent*-run real deployment
cannot complete the network hop to the VPS through the exemption alone — see "The mechanism" above
(gap 4) and "Reaching the VPS as an agent" below. This is a platform gap, not a trust question about
the wrapper's own code.

## Tier 2 upgrade path (documented, not built — out of scope for this epic)

A hardware-backed or passphrase-gated age key (a token requiring a physical touch, or a passphrase
prompt, for each decrypt) turns the Tier 1 accident-prevention boundary into an actual cryptographic
one: even a fully compromised wrapper can't silently decrypt without that per-use interaction. The
wrapper already supports this with **no rewrite required** — `hermes_secrets.sops_env()` honours
`SOPS_AGE_KEY_CMD` (a command that supplies the key on demand) whenever it's set, in preference to the
plain key-file path, and `scripts/deploy`'s own docstring already documents this: *"SOPS_AGE_KEY_CMD
is honoured for a hardware-backed key (Tier 2) with no change here."* Adopting Tier 2 is a matter of
provisioning the hardware/passphrase-gated key and setting that one environment variable — not a code
change to the wrapper or these settings.

## End-to-end check under the real sandbox (recorded, not just claimed — twice, before and after a real key/store existed)

**Ticket #08's original verification** (no real key or store existed yet): `cat`/`python3`/`xxd`
against `.env` were all refused with a genuine OS-level `PermissionError`, and `scripts/deploy --check`
reached a clean preflight reporting no key/store/tools present — proof the exemption ran without
friction *when there was nothing sensitive to actually read yet*. This was a real but incomplete test:
it could not have caught gaps 1–2 above, since a `denyRead`/`Read()` rule that blocks a file which
doesn't exist yet is indistinguishable, from this test's perspective, from one that would also block a
file that does.

**Ticket #09's real migration** (a real key and store now exist) is what actually exercised the
exemption fully, and is what surfaced gaps 1–4 above. After fixes 1–3:
- `scripts/deploy --check`, run by the agent, correctly decrypted the real store and resolved every
  secret (`secrets: Resolve secrets from the manifest into a single secrets dict` — every item
  `(censored due to no_log)`, confirming redaction held under real content, not just canaries).
- The identical command still failed to reach the VPS at all (`Network is unreachable`) purely from the
  sandbox's network-namespace isolation, confirming gap 4 is real and not an artifact of the filesystem
  fixes.
- `cat`/`head`/`tail`-style direct reads of the age key and SSH key by a *non-exempted* command remain
  refused via the `permissions.deny` `cat` patterns above (verified with a synthetic key at a synthetic
  path, never the real one) — narrower than the original OS-level wall, but still real.
- `scripts/secrets check` (non-decrypting) still runs without a prompt; `scripts/secrets fill`
  (decrypting) and a bare `env` are still refused at the permission layer.

## Reaching the VPS as an agent (the escape hatch, not a standing capability)

Gap 4 has no settings-based fix. The only way an agent-run `scripts/deploy` can complete a real
deployment — actually opening the SSH connection — is Claude Code's own documented
`dangerouslyDisableSandbox` retry mechanism: when a sandboxed command fails from a sandbox restriction,
the harness may retry it fully unsandboxed, subject to the normal permission flow (a prompt, or the
auto-mode classifier). **Verified working**: an agent-run `scripts/deploy --check`, retried with
`dangerouslyDisableSandbox: true`, successfully decrypted the store, connected to the real VPS, and
completed a full check-mode play (exit 0) — the first genuine agent-run deployment in this epic.

This is **deliberately not a smooth or standing capability**, and should not be treated as one:
- The flag's own guidance is explicit that each use is evaluated individually — *"Treat each command
  you execute with `dangerouslyDisableSandbox: true` individually... default to running future commands
  within the sandbox"* — there is no settings rule that pre-approves it as routine.
- In this same session, the auto-mode classifier allowed the deploy run itself but then separately
  blocked a follow-up attempt to re-read that run's own saved output, reasoning it was "pursuing the
  same [flagged] outcome." The two decisions were inconsistent in a way that isn't fully predictable in
  advance.
- Practically: an agent can still attempt a real deployment when explicitly asked, and it can work (it
  did), but every attempt carries this same case-by-case uncertainty rather than a guaranteed outcome.
  The operator remains the reliable way to run a real deployment; the agent path is a supervised,
  best-effort option on top of that, not a replacement for it.

## No secrets, no operator-specific paths (criterion #18)

Every path in this file is a conventional location (`~/.config/sops/age`, `~/.ssh`, `.env`) or a
repo-relative script path (`scripts/deploy`, `scripts/secrets`) — nothing here names this operator's
actual username, home directory, hostname, or any secret value.
