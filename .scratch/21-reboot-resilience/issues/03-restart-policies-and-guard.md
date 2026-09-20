# 03: Restart policies for every service, with a guard over the rendered services

**What to build:** The public front door (`caddy`, `authelia`, `silverbullet`) comes back by itself after a reboot or crash, and it becomes impossible to add a service without deciding its restart behavior: every *rendered* service declares a restart policy, and a guard in the standard test run fails if one doesn't. The guard inspects the rendered service set rather than the fragment files, so list-driven fragments (such as epic 23's exit-node pairs, which render several services from one fragment) are covered.

**Blocked by:** None (can start immediately)
**Blocks:** #05, Epic 23 #03

**Status:** ready-for-agent

- [ ] `caddy`, `authelia` and `silverbullet` declare a restart policy of `unless-stopped`
- [ ] The guard asserts over the **rendered** compose services that every one declares a restart policy; there is no exemption list (a service that genuinely must not restart is added to the guard with a written reason when it first appears)
- [ ] The guard fails when a rendered service omits a policy — demonstrated by a negative case, including a case where a single fragment renders more than one service
- [ ] The consolidated compose still validates and every existing render test passes unchanged
- [ ] The guard runs as part of the standard test run

## Notes

See epic 21 spec, "Implementation Decisions" (restart policies). Epic 23 depends on this guard.
