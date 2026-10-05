# Public-readiness audit

Epic 24 ticket #01. Answers "is this repository safe to publish?" without ever writing down what it
hunts for. See the epic spec (`.scratch/24-public-readiness/spec.md`) for the full design rationale and
`CONTEXT.md` for the term's canonical definition.

## Running it

```
scripts/deploy --script audit                                            # full audit: denylist + generic rules, tree + history + metadata
python3 scripts/public-readiness-audit.py --generic-only --tree-only     # the lint-run scope: generic rules, tree only, no key needed
```

The full audit must run through `scripts/deploy --script audit`: that is the only way this process
receives the decrypted secret set, and script-mode children never receive the key source or store
location itself (see `scripts/deploy`'s docstring) — this script has no way to decrypt the store on its
own. `deploy`'s own preflight proves every required secret is present before the script ever starts.

Exit status: `0` clean, `1` finding(s) printed (never the matched text), `2` cannot run (a malformed
allowlist, or the target directory is not a git repository).

## What it scans

- Every tracked file at HEAD (the working tree).
- Every blob reachable from any ref (`git rev-list --all --objects` + `git cat-file --batch`), read as
  raw bytes — never decoded as text, so a non-UTF-8 blob (the git-crypt key header the wiki backup's
  dead key left in history) is still searched instead of silently skipped.
- Every commit's message, author name/email and committer name/email, across every ref.

## The denylist (full audit only)

Derived at run time, never committed:

- every name the name-set rule (`scripts/hermes_secrets.py`) allows the encrypted store to hold, read
  from this process's own environment (the deploy wrapper put the decrypted values there) — at least
  `hermes_redact.MIN_REDACT_LEN` characters;
- `AUDIT_EXTRA_TERMS`, the declared extra epic 22 ticket #03 reserved for this: a comma- and/or
  newline-separated list of extra identifying terms (hostnames, names, emails) held in the same
  encrypted store; absent is not an error;
- the address(es) `TARGET_HOST` resolves to (best effort — a DNS failure just means one fewer term, it
  never fails the audit).

Each term is matched literally and in every JSON-escaped/URL-encoded/`repr()`-escaped form
`hermes_redact.variants()` produces — the exact same forms epic 22's output redaction masks, by reusing
that function directly.

## Generic rules (no operator data, safe to commit; also run with `--generic-only`)

`scripts/audit_rules.py`:

- credential shapes: GitHub tokens (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_`), Tailscale auth
  keys (`tskey-auth-…`/`tskey-client-…`), OpenRouter keys (`sk-or-v1-…`), AWS access keys
  (`AKIA…`/`ASIA…`), Google API keys (`AIza…`), Slack tokens (`xox[baprs]-…`), Stripe live keys
  (`sk_live_…`/`rk_live_…`), PEM private-key headers, age secret keys (`AGE-SECRET-KEY-1…`);
- a host address in the tailnet CGNAT range (`100.64.0.0/10`) or Tailscale's IPv6 ULA prefix
  (`fd7a:115c:a1e0::/48`) — but **not** either range's own CIDR notation, which is a functional value
  (`group_vars/all/main.yml`'s `tailscale_subnet`/`tailscale_subnet_v6`, and several ADRs) and must
  never be scrubbed or flagged;
- the git-crypt key file's magic header (`\0GITCRYPTKEY`), found even inside a binary blob.

These rules, scoped to the working tree only, are what `tests/lint.sh` runs on every CI pass (no key
available there, and the real history already carries the dead git-crypt key on purpose — see "What
this does not do" below): `python3 scripts/public-readiness-audit.py --generic-only --tree-only`.

## Output and the allowlist

A finding is one line: `FINDING <rule-name> <location>`. `<location>` is `tree:<path>:<line>`,
`history:<path-hint>@<short-sha>:<line>`, or `commit:<sha>:<field>` — never the matched text. Running
the full audit through `scripts/deploy --script audit` also passes this output through epic 22's
redactor as a second guard, independent of the audit's own discipline of never printing a match.

`audit-allowlist.yml` at the repository root holds a minimal, reasoned allowlist:

```yaml
allowlist:
  - path: "tree:secrets/secrets.enc.env:*"
    rule: "secret:SOME_ENV_NAME"
    reason: "why this exact match at this exact location is not a leak"
```

`path` is matched with shell-glob semantics against the finding's location; `rule` is matched EXACTLY —
never a glob — so one entry can never silence a rule it does not name. Every entry needs `path`, `rule`
and `reason`; a malformed file makes the audit refuse to run (exit 2) rather than silently pass.

## What this does not do (yet)

Ticket #01 ships the scanner and proves it against a fixture repository with planted canaries
(`tests/check-public-readiness-audit.sh`). It does not scrub this repository's own tree or history —
that is epic 24 ticket #02 — so running the full audit against the real repository today is expected to
report real findings (the operator's domain, tailnet addresses, the dead git-crypt key) until that
ticket lands.
