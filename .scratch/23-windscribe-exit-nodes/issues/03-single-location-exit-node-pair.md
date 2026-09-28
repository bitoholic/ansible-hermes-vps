# 03: One exit-node pair from one list entry, isolated, with list-driven compose support

**What to build:** A single exit location renders end to end into the consolidated stack as a working exit-node pair — a Windscribe tunnel, a Tailscale exit node sharing its network namespace, and the routing sidecar — carrying the three fixes the first spike discovered **plus the fourth fix ticket #01's own spike found (the Tailscale image defaults to userspace networking; kernel networking must be explicitly enabled, or none of the other fixes matter)**, the recovery mechanism and versions ticket #01 chose, and the gluetun server-list policy #01 decided. The pair sits on its own dedicated Docker network so a compromised container cannot reach the rest of the stack, and a deploy from a clean host works before any exit-node credential file exists. The compose renderer gains generic support for a list-driven fragment that declares several services, and the stack start step addresses the services actually rendered.

**Blocked by:** #01, #02, Epic 21 #03
**Blocks:** #04, #05

**Status:** ready-for-agent

- [ ] One pair renders from a one-entry list: the tunnel using gluetun's Windscribe provider with the entry's region and city, a Tailscale exit node in the tunnel's network namespace, and a routing sidecar
- [ ] There is no host network mode and no published port; every rendered service declares a restart policy and epic 21's guard (over rendered services) passes
- [ ] **Isolation:** the pair's services attach to a dedicated network of their own and to neither `gateway` nor `internal` (asserted); the container-bridge early-return in the firewall chain therefore gives the pair no path to Authelia, Hermes or any other service
- [ ] Credentials reach the containers through a per-node restricted environment file, never inline in the compose file; images are pinned to the versions recorded by #01
- [ ] **Clean-host deploy:** compose validation and image pulls, which run before the roles that depend on the compose role, succeed on a host where the per-node environment files do not yet exist — either the exit-node role runs ahead of the compose role or the files are declared optional to the compose file — proven by a render test that starts from a clean host
- [ ] **The Tailscale container runs in kernel networking mode (`TS_USERSPACE=false`), not the image's userspace-networking default** — #01 found that without this, no `tailscale0` interface exists at all and exit-node function is silently impossible regardless of anything else configured
- [ ] Tailscale runs in nftables mode; with kernel networking active, Tailscale's own `ts-forward`/`ts-postrouting` nftables chains handle forwarding and masquerade automatically (#01 found manually-added `iptables` FORWARD/MASQUERADE rules unnecessary and did not render them) — asserted: no IPv6 forwarding is accepted, and nothing beyond what Tailscale itself installs is added
- [ ] The return-path routing rule (gluetun's catch-all policy route otherwise wins over Tailscale's own table for tailnet-destined traffic) exists for both address families and is reapplied by the routing sidecar on every one of its own starts — it does not survive tunnel restart OR recreation (#01: confirmed lost in both cases, not just recreation)
- [ ] Dependents (exit-node, routing sidecar) recover via the existing deploy flow's `docker compose up -d` over the full rendered service set — #01 found a bare `docker restart` fails outright once the tunnel container's ID has changed (`network_mode: service:` binds to the container ID at creation time, not its name); no custom watcher or `docker.sock` access is needed
- [ ] **The server-list update policy #01 decided is implemented**: gluetun's built-in periodic updater, `UPDATER_PERIOD=24h` and `UPDATER_VPN_SERVICE_PROVIDERS=windscribe`
- [ ] Tailscale state persists per node, the hostname is `<prefix>-ws-<name>` using the validated prefix from #02, and the node is tagged (`tag:exit-node`, already created by #01's tailnet ACL change) for auto-approval
- [ ] The compose role supports a list-driven fragment declaring several services, generically; the stack start step addresses the rendered service set; existing services are unaffected
- [ ] Render tests assert all of the above, and the consolidated compose passes validation
- [ ] Nothing in the role modifies host routing (asserted)

## Notes

See epic 23 spec, "Implementation Decisions" (per-location pair; trust boundary; the three fixes; resilience; compose role change; secrets ordering) **and ticket #01's own "## Implementation" section for the full evidence and decisions this ticket implements directly** — the fourth fix, the simplified fix #2, the recovery-mechanism split (same container ID vs. changed), exact versions to pin, and the server-list updater env vars. Blocked by epic 21's #03 because that guard inspects rendered services and so covers this list-driven fragment.
