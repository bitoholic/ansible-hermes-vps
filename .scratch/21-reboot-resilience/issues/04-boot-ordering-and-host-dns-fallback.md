# 04: Boot ordering, relay convergence, host DNS fallback and the runtime-state audit

**What to build:** After a reboot, dependencies arriving late no longer matter. Docker is ordered after the Tailscale daemon (ordering only, never a hard dependency); the `caddy-relay`, which binds the VPS's Tailscale address, is documented to converge on its own via its restart policy within a stated bound; the host resolver keeps AdGuard as primary but gains a public fallback so host name resolution never depends on a container; and a written audit lists everything else the playbook sets up in runtime-only or order-dependent state, each item fixed or recorded as accepted.

**Blocked by:** #02
**Blocks:** #05

**Status:** ready-for-agent

- [ ] Docker is ordered after the Tailscale daemon using ordering only — no `Requires`/`Wants` — so a stopped Tailscale daemon cannot prevent Docker from starting (asserted on the rendered unit configuration)
- [ ] The `caddy-relay`'s behavior when its Tailscale address is not yet present is documented and relies on its restart policy; a convergence bound is stated for the drill to assert
- [ ] The host resolver keeps AdGuard as its primary and gains a public fallback resolver, asserted at render level (the stop-AdGuard-and-resolve check is part of the attended drill, #06)
- [ ] A written audit lists everything the playbook configures that lives only in memory or depends on start order (sysctls, interface-bound listeners, facts rendered from runtime queries, mounts, resolver state); each finding is fixed or recorded as accepted with a reason
- [ ] Nothing in this ticket affects SSH or UFW
- [ ] The existing AdGuard DNS handover tests still pass

## Notes

See epic 21 spec, "Implementation Decisions" (boot ordering is best-effort ordering, not a hard dependency; host DNS independence; runtime-state audit). The audit's findings feed the ADR (#07).
