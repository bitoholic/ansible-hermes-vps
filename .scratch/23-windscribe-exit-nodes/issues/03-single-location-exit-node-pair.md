# 03: One exit-node pair from one list entry, with list-driven compose support

**What to build:** A single exit location renders end to end into the consolidated stack as a working exit-node pair — a Windscribe tunnel, a Tailscale exit node sharing its network namespace, and the routing sidecar — carrying the three fixes the first spike discovered and the recovery mechanism ticket #01 chose. The compose renderer gains generic support for a list-driven fragment that declares several services, and the stack start step addresses the services actually rendered.

**Blocked by:** #01, #02
**Blocks:** #04, #05

**Status:** ready-for-agent

- [ ] One pair renders from a one-entry list: the tunnel using gluetun's Windscribe provider with the entry's region and city, a Tailscale exit node in the tunnel's network namespace, and a routing sidecar
- [ ] There is no host network mode and no published port, every service declares a restart policy, and the epic 21 guard passes
- [ ] Credentials reach the containers through a per-node restricted environment file, never inline in the compose file; images are pinned to the versions recorded by #01
- [ ] Tailscale runs in nftables mode; the tunnel's firewall permits only forwarding from the Tailscale interface into the tunnel, established return traffic, and masquerade out of the tunnel; no IPv6 forwarding is accepted
- [ ] The return-path routing rule exists for both address families and persists across container recreation per #01
- [ ] Tailscale state persists per node, the hostname is `<host>-ws-<name>`, and the node is tagged for auto-approval
- [ ] The compose role supports a list-driven fragment declaring several services, generically; the stack start step addresses the rendered service set; existing services are unaffected
- [ ] Render tests assert all of the above, and the consolidated compose passes validation
- [ ] Nothing in the role modifies host routing (asserted)

## Notes

See epic 23 spec, "Implementation Decisions" (per-location pair; the three fixes; resilience; compose role change). The three fixes are stated there as required behavior: nftables mode, scoped forwarding, and a persistent return-path rule.
