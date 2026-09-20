# 04: Boot ordering, late-dependency tolerance, single-owner host DNS with a real fallback (staged), and the runtime-state audit

**What to build:** After a reboot, dependencies arriving late no longer matter and host name resolution can't be taken down by a container. Docker is ordered after the Tailscale daemon (ordering only, never a hard dependency); every service is shown to tolerate a dependency that arrives late; and — starting from a fresh, attended capture of the live resolver chain — exactly one component owns the host's resolver configuration, with a fallback that is actually consulted and a bounded delay when AdGuard is stopped or *hung*. The ownership change ships **disabled** and is enabled only by the attended drill. A written audit lists everything else the playbook sets up in runtime-only or order-dependent state, each item fixed or recorded as accepted.

**Blocked by:** #02
**Blocks:** #05

**Status:** ready-for-agent

- [ ] **The first step is an attended, read-only capture of the live host's resolver chain** (which component writes the resolver configuration, what it currently points at, what the tailnet's global nameserver setting resolves to, and how the AdGuard handover's writes interact with it), recorded in this ticket before any design is committed to — the state described in the spec was observed on a specific date and the operator changes tailnet DNS settings, so it is treated as a hypothesis to confirm
- [ ] Based on the capture, this ticket decides which component owns host resolution and makes it the only one, so a deploy no longer flips the configuration back and forth
- [ ] **The ownership change ships disabled behind an explicit variable** and is enabled only by the attended drill (#06); with it disabled, a routine deploy leaves the host's resolver exactly as it found it (asserted)
- [ ] The resulting resolver keeps AdGuard as primary and has a fallback that is actually consulted — the resolver daemon's `FallbackDNS` is ignored while any `DNS=` server is set, and with a stub-less resolver file the C library walks nameservers in order with a per-server timeout, so nameserver order and per-query timeout are specified, not assumed
- [ ] The delay a *hung* AdGuard adds to a lookup is bounded and the bound is stated; the drill (#06) asserts it for both the stopped and the paused case (a render-level text assertion alone does not satisfy this)
- [ ] Docker is ordered after the Tailscale daemon using ordering only — no `Requires`/`Wants` — so a stopped Tailscale daemon cannot prevent Docker from starting (asserted on the rendered unit configuration)
- [ ] Every service's behavior when a dependency is absent at first start is documented, and each is shown to converge on its own via its restart policy (for example the front door starting before the authenticator; the `caddy-relay` starting before its Tailscale address exists), with a convergence bound stated for the drill to assert
- [ ] A written audit lists everything the playbook configures that lives only in memory or depends on start order (sysctls — including the forwarding settings that Docker and the Tailscale installer each write and whether both address families persist —, interface-bound listeners, facts rendered from runtime queries, mounts, resolver state); each finding is fixed or recorded as accepted with a reason
- [ ] Nothing in this ticket affects SSH or UFW
- [ ] The existing AdGuard DNS handover tests still pass or are updated to the single-owner design

## Notes

See epic 21 spec, "Implementation Decisions" (boot ordering; host DNS independence; staged rollout; runtime-state audit). Epic 18 itself called this host-level DNS change the highest-risk step of that epic, which is why it is captured first and staged. The audit's findings feed the ADR (#07). Epic 23's plain-exit-node ticket relies on the forwarding-sysctl findings.
