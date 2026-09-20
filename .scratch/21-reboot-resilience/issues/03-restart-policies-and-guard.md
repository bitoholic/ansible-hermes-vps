# 03: Restart policies for every service, with a guard

**What to build:** The public front door (`caddy`, `authelia`, `silverbullet`) comes back by itself after a reboot or crash, and it becomes impossible to add a service without deciding its restart behavior: every enabled service fragment declares a restart policy, and a guard in the standard test run fails if one doesn't.

**Blocked by:** None (can start immediately)
**Blocks:** #05

**Status:** ready-for-agent

- [ ] `caddy`, `authelia` and `silverbullet` declare a restart policy of `unless-stopped`
- [ ] Every enabled service fragment declares a restart policy, or is on an explicit exemption list that carries a written reason (the list starts empty)
- [ ] The guard fails when a fragment omits a policy — demonstrated by a negative case
- [ ] The consolidated compose still validates and every existing render test passes unchanged
- [ ] The guard runs as part of the standard test run

## Notes

See epic 21 spec, "Implementation Decisions" (restart policies). Later epics (23) inherit this convention.
