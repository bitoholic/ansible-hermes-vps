# Spec: Windscribe exit nodes — pick a country from the Tailscale app, keep ad-blocking, never touch SSH

> Status: ready-for-agent
> Source: Epic 23 — operator request. Android allows one VPN at a time, so the operator cannot run Windscribe next to Tailscale on the phone. They want the phone to exit through Windscribe in a chosen location while still using the tailnet's AdGuard for ad-blocking, with the VPS still reachable on its public address and SSH never disrupted. A hands-on spike on the live VPS (September 2026) proved the approach and found three non-obvious fixes and several unanswered resilience questions.
> Related: `18-second-wave-custom-services` (AdGuard as the tailnet's resolver — unchanged), `20-tailnet-caddy-access` (Tailscale masquerade knowledge), epic 21 (restart-policy and boot conventions this epic inherits), epic 22 (secrets — new manifest entries land in whichever store exists). Adds an ADR; contradicts none.
> Vocabulary: see `CONTEXT.md` — **exit node**, **Windscribe exit node**, **exit location**, **exit-node pair**, **kill switch**.

## Problem Statement

The operator's phone already gets ad-blocking by using the VPS's AdGuard over Tailscale. They also want the privacy and geo-switching of their Windscribe subscription — hide the phone's IP from the sites they visit, and switch country at times to reach geo-restricted content. Android permits only one VPN connection, so running Windscribe's own app and Tailscale together is impossible. The operator's Windscribe subscription includes WireGuard configurations, and the VPS is already a tailnet member with a public IP and a capable host.

Constraints from the operator: switching location must be easy and immediate; browsing and streaming (lossless Spotify) must work; the VPS must remain reachable on its public IP; and **SSH access to the VPS must never be cut off at any point**, including while building, deploying, or if the new machinery fails.

## Solution

For each entry in a short list of **exit locations** (initially London and Warsaw) the stack runs an **exit-node pair**: a gluetun container holding a Windscribe WireGuard tunnel to that city, and a Tailscale container in the same network namespace that advertises itself as an exit node. To change country, the operator picks a different exit node in the Tailscale app — no deploy, no SSH. Ad-blocking keeps working because the phone still uses the tailnet's DNS. All locations share one Windscribe credential set and one Tailscale auth key. The tunnel's own firewall is a kill switch, so traffic is dropped, never leaked through the VPS's IP, if a tunnel fails. Because each tunnel lives inside its own container network namespace, the host's routing table and SSH are never modified. Adding a location is one list entry. The exit nodes come back by themselves after a reboot or a container restart. An optional plain exit node (egress from the VPS's own IP) is offered as a small extra.

## User Stories

1. As the operator, I want to choose my phone's exit country by selecting a node in the Tailscale app, so that switching location takes seconds and no deployment.
2. As the operator, I want a London and a Warsaw exit node from day one, so that I have the two locations I use.
3. As the operator, I want adding a location to be one entry in a list, so that a new country needs no new secrets and no new code.
4. As the operator, I want each location to appear in my tailnet under a clear, predictable name, so that I can tell them apart in the Tailscale app.
5. As the operator, I want sites I visit to see a Windscribe IP in the chosen city and never the VPS's or my phone's, so that my IP stays private.
6. As the operator, I want traffic to be dropped rather than leaked through the VPS's IP whenever a tunnel is down, so that a failure never silently unmasks me.
7. As the operator, I want IPv6 traffic from an exit-node client never to bypass the tunnel, so that there is no second path around Windscribe.
8. As the operator, I want ad-blocking to keep working while an exit node is selected, so that I get both protections at once.
9. As the operator, I want browsing, apps and lossless Spotify to work through an exit node, so that using it doesn't cost me functionality.
10. As the operator, I want it to be fine that the phone-to-exit-node path is relayed rather than direct, so that I'm not forced into extra exposure just to gain speed.
11. As the operator, I want the VPS's routing to be unchanged by any of this, so that public services and SSH keep working exactly as before.
12. As the operator, I want the VPS to remain reachable on its public IP throughout, so that tunnels can never swallow the replies to my public traffic.
13. As the operator, I want SSH access to be independent of every exit-node component, so that a failure, a bad deploy, or a reboot can never lock me out.
14. As the operator, I want no new ports published on the VPS for this feature, so that the firewall perimeter doesn't grow.
15. As the operator, I want the Windscribe credentials stored as secrets like every other credential, so that nothing sensitive sits in the repository in plaintext.
16. As the operator, I want the exit nodes to use a Windscribe configuration generated for the VPS alone, not one I use on a workstation, so that two of my devices never fight over one key on the same server.
17. As the operator, I want one credential set to cover every location, so that adding countries doesn't multiply secrets.
18. As the operator, I want a random Windscribe server picked within the chosen city on each tunnel start, so that I don't have to maintain server names.
19. As the operator, I want the exit nodes to authenticate to my tailnet with one reusable tagged key, so that adding a location doesn't require a new key or a manual approval each time.
20. As the operator, I want documentation for the one-time Tailscale admin steps (create the tag, allow it to auto-approve exit nodes, create the key), so that I can do them once and correctly.
21. As the operator, I want each exit node's Tailscale identity to persist across restarts, so that a restart doesn't create a duplicate node in my tailnet.
22. As the operator, I want exit-node containers' secrets delivered through restricted files rather than inlined in the compose file, so that they don't leak into `docker compose config` output or a world-readable file.
23. As the operator, I want gluetun and Tailscale pinned to specific versions, so that a floating tag can't change behavior under me.
24. As the operator, I want a documented way to bump those versions safely, so that updates are deliberate.
25. As the operator, I want the gluetun server list kept fresh (or a clear bump cadence), so that a stale list doesn't quietly route me to dead servers.
26. As the operator, I want the exit nodes to come back on their own after a host reboot, so that I never have to run anything to restore them.
27. As the operator, I want them to recover on their own if the tunnel container is restarted or recreated, so that a crash doesn't strand the Tailscale container in a dead network namespace.
28. As the operator, I want them to recover on their own if the Windscribe connection drops and reconnects, so that a network blip doesn't need me.
29. As the operator, I want them to recover if the chosen Windscribe server is unavailable, so that one dead server doesn't take a location down for good.
30. As the operator, I want the return-path routing fix to survive container recreation, so that replies to my phone never black-hole after a restart.
31. As the operator, I want a resilience spike before the fleet is built, so that the recovery mechanism rests on tested behavior for restart, reconnect, and reboot.
32. As the operator, I want a read-only live verification script that confirms, for each exit location, that traffic exits in the right country and not via the VPS, that the kill switch holds, and that the return path is in place, so that I can trust the setup any time.
33. As the operator, I want a documented phone test (select the node, check my IP, check ad-blocking, play lossless audio, switch back), so that acceptance includes the real experience.
34. As the operator, I want a plain exit node on the VPS itself as an optional extra, so that I can choose "VPS IP" as one of my exits when I don't need Windscribe.
35. As the operator, I want a documented troubleshooting guide covering the three known failure modes (Tailscale firewall backend, forward rules, return-path routing) and the relayed-path expectation, so that I can fix a recurrence without rediscovering them.
36. As the operator, I want an ADR recording the design, the rejected alternatives, and the spike's measurements, so that the reasoning survives.
37. As a future maintainer, I want the list of locations validated (unique names, non-empty region and city), so that a typo fails at deploy time, not at 2 a.m.
38. As a future maintainer, I want the multi-service fragment support added to the compose role to be generic, so that future list-driven services reuse it.
39. As a future maintainer, I want the new role wired into the skip-tags mechanism and role-ordering tests, so that `--skip-tags` and the ordering guards keep meaning what they say.
40. As a future maintainer, I want the resource cost documented (measured ≈ 85 MB per pair), so that I can size the box for more locations.

## Implementation Decisions

- **Per-location exit-node pair, list-driven.** For each `exit_nodes` entry the consolidated stack renders three services: a **tunnel** (gluetun, Windscribe provider, WireGuard), an **exit node** (Tailscale, sharing the tunnel's network namespace) and a **routing sidecar** (also sharing that namespace) that repairs the return path. No published ports, no host networking, no change to host routing — an invariant guarded by tests.
- **Why one node per location.** In Tailscale the exit node a client selects is the only per-device selector, so "switch location from the phone" is only expressible as one exit node per location. **Rejected:** a host-level WireGuard tunnel with policy routing (it can expose only one behavior as one exit node, and it edits host routing — the SSH-safety risk); a single roaming node whose server is changed via gluetun's control API (needs a trigger from the operator each time, and changes location for every client at once).
- **Data model.** Each `exit_nodes` entry has a short `name` (used in the tailnet hostname), a Windscribe `region` (a country name in Windscribe's vocabulary) and a `city`. Validation is schema-driven in the style of the gateway route schema: unique names, allowed characters, non-empty region and city. Server pinning is **not** modeled (see Out of Scope).
- **Secrets.** One Windscribe WireGuard credential set (private key, IPv4 address, preshared key) from a configuration generated in Windscribe *for the VPS only*, and one reusable, tagged Tailscale auth key. All become required manifest entries; the names-only template is regenerated. Values reach the containers through per-node environment files with restrictive permissions, not inline in the compose file.
- **One credential set serves every location.** Verified in the spike: the Warsaw credentials connected successfully to a London server through gluetun's Windscribe provider, and the same key was connected to two servers at once. This is why the list needs no per-location secrets.
- **Windscribe provider, not the custom provider.** Gluetun's Windscribe provider selects servers itself (by region and city) from its built-in list, so the deploy never resolves or stores endpoint addresses. The list matched Windscribe's real data in the spike (its stored WireGuard public key for the Warsaw server equalled the operator's exported config's). Selection within a match is random on each start.
- **Tailscale identity.** Nodes are non-ephemeral with persistent state per node so a restart re-uses its identity; hostnames are `<host>-ws-<name>`; the auth key is tagged so an ACL auto-approver can approve exit-node advertisement without a manual click each time. The tag, the auto-approver entry and the key are one-time manual admin-console steps documented in the README's manual post-deploy section, like the existing Beszel and AdGuard steps. Without the auto-approver, each new node needs a manual approval.
- **The three fixes the spike discovered (required behavior, not implementation detail):**
  1. **Firewall backend.** The Tailscale container must use nftables mode; the stock image's legacy `iptables` cannot initialise on this host's kernel, and without it forwarding and NAT for exit traffic are never configured.
  2. **Forwarding.** The tunnel container's firewall (gluetun sets forwarding to deny) must permit exactly: forwarding from the Tailscale interface into the tunnel, established return traffic, and masquerade out of the tunnel — nothing else. IPv6 forwarding stays denied, which is what keeps IPv6 from bypassing the tunnel and is the kill switch's other half.
  3. **Return path.** Gluetun's catch-all policy routing rule (priority ahead of Tailscale's own table) sends replies destined for tailnet peers back into the tunnel, where the forward policy drops them — the client sends requests and never hears back. The namespace needs a higher-priority rule, in both address families, that routes tailnet-destined traffic to Tailscale's table. It must be **persistent** across container recreation.
- **Resilience, decided by a spike before the fleet is built.** The spike's manual fix for the return-path rule vanished with the namespace, and several failure modes were not tested. Ticket #01 tests, on the real VPS but not touching production routing: tunnel-container restart (the namespace is destroyed and recreated; a container that joined the old namespace is orphaned and must be restarted with it), tunnel drop and reconnect within gluetun, an unavailable Windscribe server, a Tailscale-container restart, and the persistence of the routing rule and the forward rules in each case. It records the mechanism chosen (for example dependents restarting with their tunnel, a health-driven restarter, and where the routing rule lives), pins the gluetun and Tailscale versions it validated, and decides gluetun's server-list update policy (the built-in list was about six weeks old at image build; its periodic updater is the leading option). Host-reboot survival is validated in the epic's final live check and in epic 21's drill.
- **Kill switch is an invariant.** Exit traffic is dropped, never sent out of the VPS's own IP, whenever the tunnel is down. Guarded statically (the only forward rule leads into the tunnel) and validated live by taking a tunnel down.
- **DNS.** Clients keep the tailnet's global DNS (the VPS's AdGuard), reached over the tailnet, so ad-blocking is unaffected by which exit node is selected. Gluetun's own resolver is internal to the pair. AdGuard's own upstream resolution still leaves from the VPS's IP; that is accepted and documented, and routing it through a tunnel is out of scope (its failure mode — tailnet DNS outage — is worse than the exposure).
- **Relayed path accepted.** The phone reaches an exit node through a Tailscale relay because Windscribe's NAT prevents direct connections; measured acceptable (lossless Spotify played fine). No published UDP port and no direct-path variant.
- **Firewall interplay.** No published ports means no `DOCKER-USER` entries. Container networks return early in that chain; the tunnel's UDP egress is ordinary container egress. Verified, not assumed, in the live check.
- **Compose role change.** The compose renderer today includes one fragment per enabled service name and starts the stack by naming those services. A list-driven fragment declares several services, so the start step must address the *rendered* service set. This is a generic capability, not exit-node-specific.
- **Role wiring.** The new role is tagged and added to the skip-tags guard, wired with the existing ordering conventions, and the role-ordering and role-duplication tests are updated.
- **Optional plain exit node.** The VPS's own Tailscale node advertises as an exit node too (egress = the VPS's public IP), so "no Windscribe" is one more entry in the app. Host routing is unchanged (Tailscale's own chain accepts the forwarding; the `DOCKER-USER` interaction is verified). Delivered as a separate, last, droppable ticket.
- **Docs and ADR.** README manual steps (generating the dedicated Windscribe config, the Tailscale tag/auto-approver/key), how to switch locations on Android, how to add a location, troubleshooting, and a new ADR (next available number) with the spike's measurements.

## Testing Decisions

- **What makes a good test here:** assert observable properties of the rendered stack and of a running exit node — where traffic exits, what the tunnel firewall allows, what is published — not the internals of gluetun or Tailscale.
- **Seams (existing seams preferred):**
  - The consolidated-compose render tests (`tests/test_docker_compose.yml` via `tests/check-docker-compose-render.sh`) render a fixture `exit_nodes` list — including a three-entry list to prove list-driven scaling — and assert: N pairs; no host network mode; no published ports; every service has a restart policy; images pinned (no floating tag); secrets not inline; hostnames unique; the forward rules are exactly scoped and contain no IPv6 accept; the return-path rule is present for both families; Tailscale is in nftables mode.
  - The schema-driven validation is tested where the gateway route schema's validation is tested (fail-fast on a malformed location).
  - One new per-epic static guard script in the repo's established convention, with an honest header stating what it cannot prove.
  - The manifest entries follow the existing resolver and template-sync tests.
- **What cannot be tested statically, and is operator-validated:** exit country and IP per node, the kill switch holding when a tunnel is taken down, recovery from each failure mode, reboot survival, and the phone experience. A read-only live verification script (in the style of epic 21's) automates the checkable parts; the phone test is manual and documented.
- **Prior art:** `tests/check-tailnet-caddy-access.sh` and `tests/check-adguard-dns.sh` (static-only guards that say what they don't verify), `tests/test_docker_compose.yml`, `tests/check-gateway-render.sh` (schema validation), `tests/check-role-ordering.sh` and `tests/check-role-duplication.sh`.

## Out of Scope

- **Server pinning** (a stable exit IP per location). Selection is random by decision; pinning is an easy later extension if a service dislikes a changing IP.
- IPv6 through exit nodes (IPv6-only destinations will not work through them).
- A direct-path variant with a published UDP port.
- Per-app split tunneling and Windscribe-only features (its ad/malware blocking, port forwarding).
- Routing AdGuard's upstream DNS through a tunnel.
- More than London and Warsaw at launch (adding is one entry).
- Automatic failover between locations.
- Tailscale's own Mullvad integration.
- Tunnel-health monitoring and alerting (a possible later Beszel follow-up).
- On-demand start/stop of pairs to save memory.
- Using exit nodes from clients other than the operator's phone (expected to work, untested).

## Further Notes

- **Spike measurements** (live VPS, September 2026): tunnel container ≈ 31 MB and Tailscale container ≈ 53 MB, both ≈ 0% CPU; the phone's path was relayed and lossless Spotify played fine; with the return-path rule in place the tunnel-side forward-drop counter stopped increasing; the VPS's default route and rule count were identical before, during and after.
- **The operator's other Windscribe configurations** (used on a workstation) are deliberately not reused: the same key on the same server from two devices makes the server flip between them.
- **Ordering.** Independent of epic 22; preferably after epic 21 so the new services inherit its restart-policy convention from day one.
