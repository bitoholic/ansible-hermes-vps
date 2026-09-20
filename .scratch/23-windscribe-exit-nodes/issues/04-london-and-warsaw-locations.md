# 04: London and Warsaw, and proof that adding a location is one entry

**What to build:** The default configuration yields the two locations the operator wants, and a test proves the stack scales by list entry: a three-entry fixture yields three pairs with no other change and no per-location secrets.

**Blocked by:** #03
**Blocks:** #06, #07

**Status:** ready-for-agent

- [ ] The default list yields two pairs — London (United Kingdom) and Warsaw (Poland) — each with a distinct name, hostname, state directory and environment file
- [ ] A three-entry fixture yields three pairs; adding a location is shown to be only a list entry
- [ ] No per-location secrets are introduced (one credential set serves every location)
- [ ] A per-epic static guard script, in the repo's established convention, is added to the standard lint run: it re-runs the render assertions and adds assertions against the real template and task files, with an honest header stating what it cannot prove (the live behavior)
- [ ] Render tests pass, and the consolidated compose still validates

## Notes

See epic 23 spec, "Implementation Decisions" (one credential set serves every location) and user story 3.
