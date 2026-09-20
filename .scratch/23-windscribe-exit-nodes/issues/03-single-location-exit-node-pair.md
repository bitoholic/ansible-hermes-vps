# 03: One exit-node pair from one list entry, isolated, with list-driven compose support

**What to build:** A single exit location renders end to end into the consolidated stack as a working exit-node pair — a Windscribe tunnel, a Tailscale exit node sharing its network namespace, and the routing sidecar — carrying the three fixes the first spike discovered, the recovery mechanism and versions ticket #01 chose, and the gluetun server-list policy #01 decided. The pair sits on its own dedicated Docker network so a compromised container cannot reach the rest of the stack, and a deploy from a clean host works before any exit-node credential file exists. The compose renderer gains generic support for a list-driven fragment that declares several services, and the stack start step addresses the services actually rendered.

**Blocked by:** #01, #02, Epic 21 #03
**Blocks:** #04, #05

**Status:** ready-for-agent

- [ ] One pair renders from a one-entry list: the tunnel using gluetun's Windscribe provider with the entry's region and city, a Tailscale exit node in the tunnel's network namespace, and a routing sidecar
- [ ] There is no host network mode and no published port; every rendered service declares a restart policy and epic 21's guard (over rendered services) passes
- [ ] **Isolation:** the pair's services attach to a dedicated network of their own and to neither `gateway` nor `internal` (asserted); the container-bridge early-return in the firewall chain therefore gives the pair no path to Authelia, Hermes or any other service
- [ ] Credentials reach the containers through a per-node restricted environment file, never inline in the compose file; images are pinned to the versions recorded by #01
- [ ] **Clean-host deploy:** compose validation and image pulls, which run before the roles that depend on the compose role, succeed on a host where the per-node environment files do not yet exist — either the exit-node role runs ahead of the compose role or the files are declared optional to the compose file — proven by a render test that starts from a clean host
- [ ] Tailscale runs in nftables mode; the tunnel's firewall permits only forwarding from the Tailscale interface into the tunnel, established return traffic, and masquerade out of the tunnel; no IPv6 forwarding is accepted
- [ ] The return-path routing rule exists for both address families and persists across container recreation per #01
- [ ] **The server-list update policy #01 decided is implemented** (for example gluetun's periodic updater at the chosen period, or the documented bump cadence with its mechanism)
- [ ] Tailscale state persists per node, the hostname is `<host>-ws-<name>`, and the node is tagged for auto-approval
- [ ] The compose role supports a list-driven fragment declaring several services, generically; the stack start step addresses the rendered service set; existing services are unaffected
- [ ] Render tests assert all of the above, and the consolidated compose passes validation
- [ ] Nothing in the role modifies host routing (asserted)

## Notes

See epic 23 spec, "Implementation Decisions" (per-location pair; trust boundary; the three fixes; resilience; compose role change; secrets ordering). Blocked by epic 21's #03 because that guard inspects rendered services and so covers this list-driven fragment.
