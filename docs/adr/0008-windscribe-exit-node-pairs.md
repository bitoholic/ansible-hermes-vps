# Windscribe exit nodes as per-location Tailscale exit-node pairs, not host-level WireGuard or a roaming node

The operator wants their phone to exit through a Windscribe WireGuard tunnel in a chosen country,
switchable in seconds, while still using the tailnet's AdGuard for ad-blocking and keeping the
VPS's own routing and SSH completely untouched. Android allows only one active VPN connection, so
running Windscribe's own app alongside Tailscale on the phone is impossible — the VPS has to do the
tunneling on the phone's behalf, exposed back to it as something the Tailscale app already knows
how to select.

We chose **one exit-node pair per location**: for each entry in a short `exit_nodes` list, the
stack runs a gluetun container holding a Windscribe WireGuard tunnel to that city, and a Tailscale
container sharing its network namespace that advertises itself as a Tailscale **exit node**. A
third, small routing sidecar (also sharing that namespace) repairs a return-path routing rule that
does not survive the tunnel's own restart or recreation. Switching location, from the operator's
phone, is picking a different exit node in the Tailscale app — no deploy, no SSH, no server-side
action at all.

## Why one node per location, not a single node you reconfigure

Tailscale's **exit node** is the only per-device selector a client has — there is no "pick a
country" control within a single exit node. Expressing "switch location from the phone in seconds"
is therefore only possible as one exit node per location; anything that needs an external trigger
to change where a single node exits stops being self-service.

## Alternatives considered and rejected

- **Host-level WireGuard tunnel with policy routing.** Run one Windscribe tunnel directly on the
  VPS host, and route specific traffic through it with `ip rule`/routing tables instead of
  containerizing it. Rejected for two reasons: it can only ever expose *one* behavior as one exit
  node — the "pick a country from the phone" requirement would need as many host-level tunnels and
  routing table entries as locations, hand-maintained; and it edits the host's own routing table
  directly, which is exactly the SSH-safety risk the operator's constraints rule out ("SSH access to
  the VPS must never be cut off at any point"). The container-per-location design keeps every
  tunnel's routing inside its own network namespace, so the host's routing table and SSH are
  provably never touched — verified, not assumed: ticket #01's spike measured the host's default
  route and rule count identical before, during and after.
- **A single roaming node, reconfigured via gluetun's control API.** One gluetun+Tailscale pair
  whose Windscribe server is changed by calling gluetun's own control server when the operator wants
  a different country. Rejected because it needs an explicit trigger from the operator every time
  (an API call, a script, something to run) rather than a selection already available in the
  Tailscale app's own UI, and because it changes location for *every* client using that exit node
  at once — there is no way for one device to pick Warsaw while another keeps London, which the
  per-location design gets for free (each location is visible to every tailnet client
  independently).

## Trust boundary: tailnet members running third-party images with elevated network capability

Every other service on this VPS treats *any* tailnet source as trusted — the firewall allows the
whole `tailscale0` interface, and the source-based MFA bypass (ADR-0001) extends to the entire
tailnet range. An exit-node container is a tailnet member that runs third-party images (gluetun,
Tailscale) with `NET_ADMIN`, specifically because exit-node function requires it. If one of those
images were ever compromised — a supply-chain issue in gluetun or the Tailscale client, not
something this repo controls — the existing "every tailnet source is trusted" assumption would hand
that compromise the same trust as any of the operator's own devices, unless something explicitly
prevents it. Three controls close this, layered rather than relying on any single one:

1. **Tailnet access-control rules** (a one-time admin-console step, documented in
   [the exit-nodes runbook](../exit-nodes-runbook.md)) grant `autogroup:member` access to other
   members and the internet, but give `tag:exit-node` no `src` entry at all — under Tailscale's
   allow-list-only ACL model, a tag with no matching `src` rule can initiate nothing in the tailnet.
2. **A dedicated Docker network** (`exit_nodes_net`), never `gateway` or `internal` — the network
   those other services live on. Container-bridge traffic is returned early in the host's firewall
   chain (the same mechanism this repo already relies on for every other service's isolation), so a
   compromised exit-node container has no Docker-network path to Authelia or Hermes regardless of
   what the tailnet ACL does.
3. **A live probe from inside a running pair**, run by `scripts/verify-exit-nodes.sh`, confirms the
   VPS's own tailnet address and (when one is supplied) another tailnet device are genuinely
   unreachable — proving control #1 actually holds for the real deployed fleet, not just asserting
   it from the policy text.

No single one of these is treated as sufficient on its own: the ACL is a tailnet-wide, out-of-band
setting this repository cannot verify was applied correctly without the live probe; the dedicated
network protects the Docker side even if the ACL were ever misconfigured; the live probe exists
specifically because an admin-console setting can silently drift from what was intended.

## Resilience: a spike before the fleet, and what it found

Ticket #01 ran a throwaway pair against the real VPS, deliberately *not* touching production
routing, before any of the real fleet was built — specifically to decide the recovery mechanism on
tested behavior rather than on assumption. It found three required fixes, all now baked into the
real template (`roles/docker/templates/services/exit_node_pair.yml.j2`):

1. **Firewall backend**: the Tailscale container's stock image defaults to userspace networking,
   which has no kernel `tailscale0` interface at all — `TS_USERSPACE: "false"` plus
   `TS_DEBUG_FIREWALL_MODE: nftables` are both required or exit-node function is silently
   impossible.
2. **Forwarding**: with the above set, Tailscale installs its own `ts-forward`/`ts-postrouting`
   nftables chains automatically — no manual iptables/nft rule needed, confirmed live.
3. **Return path**: gluetun's own catch-all policy route otherwise wins the lookup for
   tailnet-destined reply traffic before Tailscale's own table is ever consulted, and its forward
   policy then silently drops it. A higher-priority `ip rule` in both address families fixes it, but
   does not survive the tunnel's own restart or recreation — the routing sidecar exists purely to
   reapply it on every one of *its own* starts.

Measured in the same spike: ≈31 MB (tunnel) + ≈53 MB (Tailscale container) ≈ 84 MB per pair, both
≈0% CPU idle; the host's default route and rule count were identical before, during and after; the
phone's path to an exit node is relayed (Windscribe's NAT prevents a direct Tailscale connection),
measured acceptable (lossless Spotify played fine during the later attended phone test).

## A real gap the spike didn't cover, found during attended validation, and fixed within this epic

The spike always tested restarting the tunnel *and* its dependents together. Ticket #07's attended
validation on the real, fully-built fleet tested a narrower case the spike never exercised:
restarting *only* the tunnel container (a crash under its own restart policy, or a plain `docker
restart`) while `node`/`sidecar` keep running and never crash themselves. This left them attached
to the tunnel's **old, now-orphaned network namespace indefinitely** — confirmed via
`/proc/<pid>/ns/net` inode comparison — with `docker compose up -d` unable to detect or fix it,
since the dependents' own container IDs never changed (the mechanism that *does* let
`docker compose up -d` fix ticket #01's original case, where the tunnel's own ID changes). No
traffic leaked — gluetun's kill switch held even with the dependents stuck in the stale namespace —
but exit-node function was silently lost until an operator noticed and manually restarted them.

Given the choice to record this as a known limitation or fix it within the epic, the operator chose
to fix it. The fix — a debounced TCP-probe `HEALTHCHECK` on `node` and `sidecar` that forces its own
container to restart after sustained failure, relying on `restart: unless-stopped` and the fact
that a normal restart correctly re-resolves `network_mode: service:tunnel` to the tunnel's current
namespace — went through three rounds live before it actually worked:

- Docker Compose's own `$VAR` interpolation silently ate the healthcheck script's shell syntax,
  resolved against Compose's own unset variable namespace (fixed by escaping every literal `$` the
  container's shell needed as `$$`).
- `node` self-recovered on the first attempt (its PID 1 — Tailscale's own `containerboot` — already
  traps SIGTERM for its own graceful shutdown); `sidecar` did not, because a process that is PID 1
  of a PID namespace is immune to **any** unhandled signal, including SIGKILL, sent by another
  process *inside that same namespace* (`pid_namespaces(7)`) — confirmed live via `docker exec kill
  -9 1` doing nothing while an external `docker kill` from the host worked instantly. Fixed by
  having the sidecar's own script `trap` SIGTERM explicitly instead of `exec`ing into a signal-blind
  `sleep`.
- Confirmed, live, end to end, after both fixes: a tunnel-only restart on the real london pair is
  followed by both `node` and `sidecar` self-restarting within roughly a minute and regaining real
  connectivity, with zero manual intervention.

This incident is the concrete argument for building resilience from live, attended evidence rather
than from design review alone — a design that looks complete (restart policies, a healthcheck, the
right signal) can still fail for a reason invisible until it's actually run against the real
kernel, the real images, and the real failure it's meant to catch.

## Consequences

- Adding a location costs one list entry (`name`/`region`/`city`) — no new secret, no new code,
  since every pair shares the same Windscribe credential set and the same Tailscale auth key.
- Every exit-node container's resilience now depends on a working `HEALTHCHECK` script embedded in
  the compose template rather than Docker's restart policy alone — a regression there (a shell
  syntax error, a Compose-interpolation mistake, a signal a future base image's PID 1 doesn't trap)
  degrades silently back to the original gap rather than failing loudly, which is why the
  [runbook's troubleshooting section](../exit-nodes-runbook.md#troubleshooting) says explicitly what
  to check if it ever recurs.
- The tailnet access-control change is the one part of this epic that acts **outside** the VPS
  (a tailnet-wide policy, not a host setting) and therefore carries its own rollback procedure,
  separate from every other change in this repository, which is normal `git revert` plus a redeploy.
- Server pinning (a stable IP per location) is deliberately not modeled — Windscribe server
  selection within a chosen city is random on every tunnel start. An easy later extension if a
  specific service ever dislikes a changing IP, not built now because nothing the operator uses
  needs it.
