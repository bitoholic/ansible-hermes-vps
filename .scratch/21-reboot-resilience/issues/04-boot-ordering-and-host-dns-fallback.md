# 04: Boot ordering, late-dependency tolerance, single-owner host DNS with a real fallback, and the runtime-state audit

**What to build:** After a reboot, dependencies arriving late no longer matter and host name resolution can't be taken down by a container. Docker is ordered after the Tailscale daemon (ordering only, never a hard dependency); every service is shown to tolerate a dependency that arrives late; exactly one component owns the host's resolver configuration and it has a fallback that is actually consulted, with a bounded delay when AdGuard is stopped or *hung*; and a written audit lists everything else the playbook sets up in runtime-only or order-dependent state, each item fixed or recorded as accepted.

**Blocked by:** #02
**Blocks:** #05

**Status:** ready-for-agent

- [ ] Docker is ordered after the Tailscale daemon using ordering only — no `Requires`/`Wants` — so a stopped Tailscale daemon cannot prevent Docker from starting (asserted on the rendered unit configuration)
- [ ] Every service's behavior when a dependency is absent at first start is documented, and each is shown to converge on its own via its restart policy (for example the front door starting before the authenticator; the `caddy-relay` starting before its Tailscale address exists), with a convergence bound stated for the drill to assert
- [ ] **Host DNS ownership is established first:** on the live host the resolver configuration currently points at Tailscale's resolver (which forwards to the tailnet's global nameserver, i.e. AdGuard itself), while the AdGuard DNS handover writes a different configuration on every run and the two overwrite each other. This ticket decides which component owns host resolution and makes it the only one; a deploy no longer flips it back and forth
- [ ] The resulting host resolver keeps AdGuard as primary and has a fallback that is actually consulted — the resolver daemon's `FallbackDNS` is ignored while any `DNS=` server is set, and with a stub-less resolver file the C library walks nameservers in order with a per-server timeout, so the nameserver order and the per-query timeout are specified, not assumed
- [ ] The delay a *hung* AdGuard adds to a lookup is bounded and the bound is stated; the drill (#06) asserts it for both the stopped and the paused case (a render-level text assertion alone does not satisfy this)
- [ ] A written audit lists everything the playbook configures that lives only in memory or depends on start order (sysctls — including the forwarding settings that Docker and the Tailscale installer each write and whether both address families persist —, interface-bound listeners, facts rendered from runtime queries, mounts, resolver state); each finding is fixed or recorded as accepted with a reason
- [ ] Nothing in this ticket affects SSH or UFW
- [ ] The existing AdGuard DNS handover tests still pass or are updated to the single-owner design

## Notes

See epic 21 spec, "Implementation Decisions" (boot ordering; host DNS independence; runtime-state audit). The audit's findings feed the ADR (#07). Epic 23's plain-exit-node ticket relies on the forwarding-sysctl findings.
