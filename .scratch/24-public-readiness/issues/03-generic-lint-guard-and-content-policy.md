# 03: Generic lint guard and content policy

**What to build:** The tree stays clean after this epic without needing anyone's key: a guard in the standard lint run catches tailnet host addresses and credential shapes — while deliberately leaving the range's own CIDR notation, a functional value used in variables and documents, alone — and a one-page content policy (placeholders only in committed prose) is linked from the repository's agent-facing documentation so agents follow it too.

**Blocked by:** #02
**Blocks:** #05

**Status:** done

- [x] The standard lint run fails on a tailnet-range **host** address or a credential-shaped string in a tracked file, needing no key, with a negative case that proves it fires
- [x] A negative case proves the guard does **not** flag the tailnet range's own CIDR notation in the shared variable or in the documents that describe it
- [x] A one-page content policy states that committed prose uses placeholders only, and is linked from the agent-facing repository documentation
- [x] An optional pre-commit hook that runs the guard is documented
- [x] The guard passes on the scrubbed tree

## Notes

See epic 24 spec, "Implementation Decisions" (generic rules; content policy). Prior art: the placeholder guard in the standard lint run.

**Most of this ticket's guard already landed with ticket #01** (`tests/lint.sh`'s `--generic-only
--tree-only` entry + `tests/check-public-readiness-audit.sh`'s canary test, which already proved the
CGNAT-CIDR negative case). This ticket's own new work:

- **Closed a real gap ticket #02 flagged**: the generic rules had an IPv4-only CGNAT rule
  (`tailnet-cgnat-address`) but nothing for Tailscale's IPv6 ULA prefix — the VPS's own real IPv6
  tailnet address slipped through ticket #01's audit entirely in ticket #02 and was only caught by
  manual inspection. Added `tailnet-ula-address` (`scripts/audit_rules.py`: matches
  `fd7a:115c:a1e0:…`, Tailscale's fixed ULA prefix per `group_vars/all/main.yml`'s
  `tailscale_subnet_v6`) — the bare `::/48` range notation itself never matches the pattern (no
  trailing hex digit before the slash), so unlike the IPv4 rule it needs no explicit exemption check.
  Extended the canary test with a matching positive case (an IPv6 ULA host address) and a negative
  case (the bare `fd7a:115c:a1e0::/48` CIDR). Allowlisted the two IPv6 fixture-address hits the new
  rule found in `tests/check-docker-user-firewall.sh` and `tests/test_docker_user_rules.yml` (the same
  fixture's IPv6 tailnet address, already allowlisted under the IPv4 rule for the same reason — a
  test/fixture address, not the operator's real one).
- **`docs/agents/content-policy.md`**: the one-page policy (placeholder vocabulary table, what's
  exempt — the functional CIDRs and test fixtures — and how to check it), linked from `AGENTS.md`'s
  "Agent skills" list alongside the issue-tracker/triage-labels/domain-docs skills, the same way every
  other agent-facing convention in this repo is discoverable.
  * The optional pre-commit hook (a 3-line `.git/hooks/pre-commit` running
    `--generic-only --tree-only`) is documented inside that same page, since an operator setting it up
    will already be reading it there.

Full `tests/lint.sh` passes end to end on the scrubbed tree (the AC's own completion condition).

**Fixed after independent review (two parallel fresh-context agents — Standards, Spec-conformance),
both independently caught the same self-inflicted irony**: the first commit's own new
`docs/agents/content-policy.md` wrote a literal, real CGNAT host address (the first address inside the
operator's own tailnet range) as a "leave as-is" example — which the generic rule this very ticket
documents correctly flagged, failing
`tests/lint.sh` on the committed tree despite the commit's own "guard passes" claim. Fixed by
describing the example without the literal address. The Standards review also caught a second, more
minor instance of the same category of mistake: the new rule's own explanatory comment in
`scripts/audit_rules.py` wrote out the fully-zero-expanded form of the ULA range literally to explain
why it WOULD (hypothetically) match — which, being a real matching string, flagged itself too. Fixed
by describing it in words instead. Re-verified clean (tree scan, canary test, full `tests/lint.sh`)
after both fixes.
