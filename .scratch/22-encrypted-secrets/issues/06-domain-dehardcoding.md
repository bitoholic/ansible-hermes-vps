# 06: Remove the hardcoded domain from code, templates and fixtures

**What to build:** No plaintext copy of the operator's private domain remains in code: the gateway template's Authelia forward-auth URL is built from the stack domain secret, and the legacy Caddyfile test fixture uses a placeholder domain, with its byte-equivalence expectation adjusted to match. Documentation and specs are handled by epic 24's scrub.

**Blocked by:** None (can start immediately)
**Blocks:** Epic 24 #02

**Status:** ready-for-agent

- [ ] The Authelia forward-auth URL in the gateway template derives from the stack domain secret instead of a literal hostname
- [ ] The legacy Caddyfile fixture uses a placeholder domain and the byte-equivalence test is updated correspondingly
- [ ] A search of code, templates, group variables, tests and fixtures finds no literal occurrence of the operator's domain (documentation and specs excluded)
- [ ] All gateway render tests pass

## Notes

See epic 22 spec, "Implementation Decisions" (domain de-hardcoding). The variable named for SilverBullet's domain continues to serve as the stack-wide domain; renaming it is out of scope.
