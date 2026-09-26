# 06: Remove the hardcoded domain from code, templates and fixtures

**What to build:** No plaintext copy of the operator's private domain remains in code: the gateway template's Authelia forward-auth URL is built from the stack domain secret, and the legacy Caddyfile test fixture uses a placeholder domain, with its byte-equivalence expectation adjusted to match. Documentation and specs are handled by epic 24's scrub.

**Blocked by:** None (can start immediately)
**Blocks:** Epic 24 #02

**Status:** ready-for-agent

- [x] The Authelia forward-auth URL in the gateway template derives from the stack domain secret instead of a literal hostname
- [x] The legacy Caddyfile fixture uses a placeholder domain and the byte-equivalence test is updated correspondingly
- [x] A search of code, templates, group variables, tests and fixtures finds no literal occurrence of the operator's domain (documentation and specs excluded)
- [x] All gateway render tests pass

## Notes

See epic 22 spec, "Implementation Decisions" (domain de-hardcoding). The variable named for SilverBullet's domain continues to serve as the stack-wide domain; renaming it is out of scope.

## Implementation

`roles/gateway/templates/Caddyfile.j2`'s `mfa_auth` snippet had `authelia_url=https://auth.<secret-silverbullet-domain>` hardcoded
in its forward-auth query string; changed to `authelia_url=https://auth.{{ secrets.silverbullet_domain }}`, matching
the exact `auth.{{ secrets.silverbullet_domain }}` convention Authelia's own rendered configuration already uses
for this same hostname (`roles/authelia/templates/authelia-configuration.yml.j2`).

**The "legacy Caddyfile fixture" criterion needed a different fix than its literal wording, because the fixture
it names is orphaned.** `tests/fixtures/legacy_caddyfile.j2` (which also hardcoded the real domain) was added in
epic 03 #04 for a byte-equivalence regression test, but that check was removed in a later commit (`a75b6ab`, "move
Conduit from hardcoded Caddyfile block to gateway loop") once the gateway's own shape could no longer match a
frozen historical snapshot — confirmed via `git log -S`: nothing in the current `tests/test_gateway_render.yml` or
anywhere else in the repo reads this fixture any more (its own content also predates several unrelated fields —
no IPv6 tailnet subnet, no per-service route blocks added in epics 12/16/18/19/20 — further confirming it's dead).
Deleted rather than "updated," since updating a domain in a file nothing reads doesn't serve the acceptance
criterion's actual goal any better than removing it, and keeping known-dead code around isn't warranted. Cleaned up
the two remaining comments (`tests/check-gateway-render.sh`, `tests/lint.sh`) that still described this as a
byte-equivalence check to match what the test actually does today.

**A real, if narrow, test regression was found and fixed along the way**: `tests/test_gateway_render.yml`'s own
site-block-counting assertion (`regex_findall('\.test\.example\.com[^{]*\{')`) used `[^{]*`, which matches across
line breaks (a negated character class isn't restricted to a single line by default) — so once the domain fix
introduced a NEW, legitimate occurrence of the test's stub domain outside an actual site-block header (inside the
forward-auth query string), the regex's loose `[^{]*` kept consuming text across the intervening lines until it
hit the NEXT site block's `{`, coincidentally still "matching" and inflating the count by one. Fixed by excluding
`\n` from the character class (`[^{\n]*`), which correctly restricts the match to a real site-block header line
(hostname and `{` on the same line) without changing any other assertion's behavior — verified: this was the ONLY
one of the file's dozen or so `regex_findall` assertions whose pattern combines the domain with a following brace,
so no other assertion needed the same fix.

Verified with `tests/check-gateway-render.sh`, `tests/check-tailnet-caddy-access.sh`,
`tests/check-cloudflare-proxied-ingress.sh`, and `tests/check-second-wave-services.sh` (all of which render the
same Caddyfile template) — all pass. Full-repo grep for the real domain outside `docs/`/`CONTEXT.md`/`.scratch/`
found only `.gitignore`'s reference to the git-crypt key FILENAME (a real external file's name, not a functional
hardcoding — explicitly epic 24's concern per the epic 22 spec's own "Wiki backup untouched" note) — left alone,
out of this ticket's scope.

## Review round 1 (independent fresh-context subagent): PASS

Every claim independently re-derived, not taken on the implementation notes' word: the orphaned-fixture history
confirmed via its own `git log -S`; the regex fix proven both necessary (reverting it alone reproduces the
failure) and sufficient (an independent Python render+regex check against the real output matches exactly
`gateway_routes + gated_route_count`, correctly spanning `:8443`-suffixed and gated double-block headers while
correctly excluding the new query-string occurrence); the Authelia URL convention confirmed to genuinely match
Authelia's own rendered config for the same hostname, not a coincidental lookalike. No code defects, no
test-coverage gaps, no new documentation gaps.

**Ticket #06 is closed.**
