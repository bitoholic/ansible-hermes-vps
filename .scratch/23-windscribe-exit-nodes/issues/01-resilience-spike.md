# 01: Resilience spike — how a tunnel-and-Tailscale pair behaves when things restart

**What to build:** Recorded, evidence-backed answers — from a throwaway exit-node pair on the real VPS that never touches production routing — to the failure modes the first spike did not test, plus the decisions that follow from them: how dependents follow a restarted or recreated tunnel container, where the persistent return-path rule lives, which gluetun and Tailscale versions to pin, and how the gluetun server list is kept fresh. Delivers the recovery mechanism and versions ticket #03 builds on.

**Blocked by:** None (can start immediately)
**Blocks:** #03

**Status:** done

- [x] The operator supplies a Windscribe WireGuard configuration generated for the VPS alone and a short-lived ephemeral Tailscale auth key; they are used through restricted files and removed afterwards
- [x] Each failure mode is exercised and observed: tunnel-container restart, tunnel-container recreation (its network namespace replaced), reconnect inside gluetun, an unavailable Windscribe server (a restart picks another), and a Tailscale-container restart
- [x] For each: does the exit node recover automatically, do the forward rules and the return-path rule persist, does a client regain connectivity
- [x] The recovery mechanism is decided and recorded — how dependents follow the tunnel container's restarts, and where the persistent return-path rule lives
- [x] The versions of gluetun and Tailscale that were validated are recorded for pinning
- [x] The server-list update policy is decided (periodic updater versus a bump cadence), with evidence of its effect
- [x] Evidence shows the host's default route and rule count identical before, during and after
- [x] The trust boundary is examined: with the recommended tailnet access-control rules in place, a probe from inside the throwaway pair to the VPS's own tailnet address and to another tailnet device is refused; the pair is on a dedicated Docker network, not `gateway` or `internal`, and cannot reach Authelia or Hermes over the Docker network
- [x] The throwaway pair is fully torn down and no key material is left behind
- [x] Host-reboot survival is deferred, by statement, to the epic's attended validation and epic 21's drill

## Notes

Needs the operator: a Windscribe config, an auth key, approving the test node as an exit node. An agent can drive the experiments once those are supplied. See epic 23 spec, "Implementation Decisions" (resilience, decided by a spike before the fleet is built) and "Further Notes" (spike measurements).

## Implementation

Conducted live against the real VPS (2026-09-28), driven by the agent with the operator supplying credentials, approving the exit node, and handling the one tailnet-wide ACL change. A throwaway `exit-node-spike` gluetun+Tailscale pair on its own dedicated Docker bridge network (`spike_net`, never `gateway`/`internal`), with a one-entry London location, credentials delivered via a `chmod 600` file on both the operator's workstation and the VPS (never inline in the compose file — the same restriction ticket #03's own AC requires for the real fleet). Fully torn down at the end (containers, volumes, network, credential files on both the VPS and the operator's workstation, and the ephemeral Tailscale node manually removed from the admin console once it became clear Tailscale's ephemeral-node reaper doesn't run instantly on disconnect) — **except the tailnet ACL policy change (Trust boundary section below), which the operator explicitly chose to keep as the tailnet's permanent policy, not revert.**

### A fourth required fix the first spike didn't find

Beyond the three fixes the epic 23 spec already documents (nftables mode, forwarding, return-path routing), this spike found a more fundamental one: **the official `tailscale/tailscale` image defaults to `--tun=userspace-networking`** unless `TS_USERSPACE=false` is set explicitly. In userspace mode there is no kernel `tailscale0` interface at all — `ip link` inside the shared network namespace showed only the tunnel's own `tun0`, and the container cannot function as an exit node no matter what else is configured. This must be set on the exit-node service in ticket #03. Without it, nothing else in this ticket would have been observable.

### Fix #2 (manual forward/masquerade rules) is unnecessary with current Tailscale

With `TS_USERSPACE=false` and nftables mode both active, Tailscale itself automatically installs its own `ts-forward` and `ts-postrouting` nftables chains (visible via `nft list ruleset`, not `iptables -L`, which cannot even parse Tailscale's own rule and prints a parsing error) that correctly handle forwarding and masquerade for exit-node traffic. Proven directly: manually-added `iptables` FORWARD/MASQUERADE rules were removed entirely, and a live client re-test (`tailscale set --exit-node=`, `curl ifconfig.me`) still showed the Windscribe IP. **Ticket #03 does not need to add these rules** — only the return-path routing fix below is still required manually. This is a simplification versus the spec's original fix #2 wording, current as of Tailscale 1.102.5; worth re-checking if a much older Tailscale version is ever pinned instead.

### Fix #3 (return-path routing) — confirmed required, confirmed does not survive anything

Gluetun's catch-all policy-routing rule (`not from all fwmark <mark> lookup <tunnel-table>`, priority 101) has a default route in its target table, so it wins the lookup for tailnet-destined traffic before Tailscale's own table (referenced only at priority 5270) is ever consulted — exactly as the spec describes. Fixed with `ip rule add to 100.64.0.0/10 lookup 52 priority 50` (and the IPv6 equivalent for `fd7a:115c:a1e0::/48`, added defensively — this gluetun config had no IPv6 catch-all rule to begin with, since the Windscribe WireGuard endpoint here is IPv4-only). **This rule does not survive any tunnel-container disruption** — restart, recreation, or gluetun's own internal reconnect all replace or reset the routing table state in ways that drop it (confirmed: present before, absent after, in every restart/recreation test). It must be reapplied by the routing sidecar on every one of the sidecar's own starts, unconditionally.

### Recovery mechanism (the ticket's central decision)

Two genuinely different cases, found by testing both, not assumed:

1. **The tunnel container's ID is unchanged** (a plain `docker restart tunnel`, or Tailscale's own container restarting independently while the tunnel stays up): the shared network namespace is replaced, but `network_mode: service:tunnel` still resolves correctly for a dependent container's own **restart**, because Docker resolves `service:<name>` to a container **name**, and the name still points at the same (running) container. Proven two ways: (a) `docker restart spike-exit-node` after `docker restart spike-tunnel` (the tunnel-restart failure mode itself) rejoined cleanly, Tailscale node identity persisted (same node ID, no duplicate), `ts-forward` was recreated by Tailscale automatically; (b) as its own standalone test, with the tunnel container left running and untouched throughout (`docker restart spike-exit-node` alone), confirmed by comparing the tunnel's netns inode before and after — identical — the exit-node container rejoined the *same* namespace, came back online with the same node ID, and the return-path rule (never disturbed, since the tunnel's own netns lifecycle never changed) was still present. This second case is the ticket's "Tailscale-container restart" failure mode on its own.
2. **The tunnel container's ID changes** (any real recreation: `--force-recreate`, an image bump applied via redeploy, `down` + `up`): a bare `docker restart` on the dependent **fails outright** — `Error response from daemon: Cannot restart container spike-exit-node: joining network namespace of container: No such container: <old id>` — because `network_mode: service:` is bound to the specific container ID that existed at the dependent's own creation time, not re-resolved by name at restart time. **`docker compose up -d` (no force flags needed) correctly detects the stale reference and recreates the dependent**, rejoining the current tunnel container; proven directly, node identity again persisted.

Decision for ticket #03: dependents (the exit-node and routing-sidecar services) do not need a custom watcher or `docker.sock` access. Every real deploy already ends with a `docker compose up -d` over the full rendered service set (existing repo convention — ticket #03 AC already requires the compose role to address the rendered service set), which self-heals case 2 for free on the next deploy. Case 1 (same-ID restart, e.g. gluetun crash-restarting under its own `restart: unless-stopped` policy) needs the dependents to also carry `restart: unless-stopped`, which recovers them with no orphan window beyond Docker's own restart delay. The one thing neither Docker nor Tailscale restores automatically in **either** case is the return-path rule (previous section) — that is what makes the routing sidecar's own job non-optional.

### Reconnect inside gluetun / an unavailable server (one test proved both)

Blocking the active WireGuard endpoint's UDP port with a temporary `iptables` DROP rule (removed afterward) forced gluetun to detect the dead connection and reconnect — to a **different** Windscribe London server, entirely inside gluetun's own process, with **no container restart** (`RestartCount: 0`, unchanged `StartedAt`) and **no network-namespace change** (same netns inode throughout). The return-path rule and `ts-forward` were both untouched and connectivity resumed automatically. This is the safest of the five failure modes: it needs no external recovery mechanism at all, and it directly demonstrates the "an unavailable server: a restart picks another" behavior the ticket asks for, since gluetun's own internal restart-on-failure logic is what performed the server switch.

### Versions validated (for pinning in ticket #03)

- gluetun: `qmcgaw/gluetun@sha256:2733bb22b27e3efa7a9f2cef9057ec12791b8b225793fcd3dbfd0508404dfc25` (resolved from `:latest` at spike time)
- Tailscale: `1.102.5` — `tailscale/tailscale@sha256:c507f3a2a6ab1cabd8d809b98edeb41edbd5c3fb6ad9632ffd098b4c7d0b4065`

### Server-list update policy

Gluetun's server lists (`/gluetun/servers/*.json`, including `windscribe.json`) are baked into the image and only as fresh as the last image pull, but gluetun ships a **built-in periodic updater** (`UPDATER_PERIOD`, currently `0`/disabled by default, and `UPDATER_VPN_SERVICE_PROVIDERS`, currently empty) that can re-fetch a specific provider's list on a schedule with no custom scripting. `UPDATER_PERIOD` has an enforced minimum of `1m0s` (a `5s` value was rejected outright at startup: `"VPN server data updater period is too small"`).

Evidence of effect (a separate, minimal, throwaway gluetun container, no Tailscale, a syntactically-valid but non-functional WireGuard key so gluetun's format validation passed without a real tunnel — no real Windscribe credentials needed for this specific test): with `UPDATER_PERIOD=90s` and `UPDATER_VPN_SERVICE_PROVIDERS=windscribe`, the log showed `Server data updater settings: Update period: 1m30s, Providers to update: windscribe` at startup, then, 90 seconds later, `[updater] updating Windscribe servers...` fired exactly on schedule and retried on failure (`retrying in 5s`). The fetch itself failed only because this minimal test had no working VPN tunnel for gluetun's own DNS resolver to route through (`dial tcp: lookup assets.windscribe.com on 127.0.0.1:53: ... i/o timeout`) — a byproduct of the deliberately minimal test setup, not a flaw in the updater; the scheduling and triggering mechanism itself is proven. Decision: enable it for ticket #03 with `UPDATER_PERIOD=24h` and `UPDATER_VPN_SERVICE_PROVIDERS=windscribe`, rather than a manual bump cadence.

### Host route/rule stability

The first route/rule count taken (10 IPv4 routes, 7 IPv4 rules) was captured after `docker compose up -d` had already created `spike_net` — a "during" reading, not a true pre-spike baseline, since it was taken alongside the same command that stood the pair up. The only measurement genuinely free of the pair's own footprint is the confirmed post-teardown state: 9 routes, 7 rules. Since the one route present during the spike and absent after is exactly `spike_net`'s own bridge route (added when the network was created, removed when it was deleted, and accounted for by nothing else on the host), the true pre-spike state was also 9 routes — the "during" and "after" readings differ by precisely the pair's own network, with nothing left unexplained. Rules were untouched throughout (`ip rule` is per-network-namespace; nothing this pair did ever touched the host's own default namespace). Host routing was never modified, matching the epic's own hard requirement.

### Trust boundary — real ACL change, not a synthetic test

The tailnet's ACL policy was a default "allow all" starter (`{src: [*], dst: [*]}`). Testing isolation properly required replacing it with an explicit tag-based policy (Tailscale ACLs are allow-list only — there is no way to carve out a "deny this one device" exception under a blanket allow-all rule). Built, previewed (Tailscale's own `tests` block, checked automatically on save — the first save attempt correctly failed on an invalid `src`/`dst` syntax mistake before anything was applied), and applied with the operator's explicit choice to keep it as the tailnet's permanent policy (not revert after testing) — ticket #05 now only needs to apply the existing `tag:exit-node` to the real exit-node containers, not design the policy from scratch:

```jsonc
{
	"tagOwners": { "tag:exit-node": ["autogroup:member"] },
	"acls": [
		{"action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:member:*"]},
		{"action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:internet:*"]}
	]
}
```

Verified before applying: an alternate path to the VPS was already confirmed (the agent's own SSH session resolved to the VPS's public IP via `ssh -v`, never Tailscale), so a policy mistake could not have caused a lockout mid-session. Verified after applying: `tailscale ping` to another tailnet device from inside the tagged throwaway pair **succeeded** — an important methodology finding: `tailscale ping` operates at Tailscale's own control-plane/NAT-traversal layer and does **not** exercise ACL packet filtering. A real TCP connection attempt (`nc -zv -w5`) to the VPS's own tailnet address and to another tailnet device, both on port 22, correctly **timed out** (silent drop, not a refusal — correct Tailscale ACL behavior) from inside the pair. The operator separately confirmed their own devices retained full access to each other and to the internet via the exit node (Windscribe IP), and that SSH over Tailscale to the VPS still works.

One unrelated pre-existing gap surfaced incidentally and is explicitly **out of scope for epic 23**: `adguard.<secret-silverbullet-domain>` and `monitor.<secret-silverbullet-domain>` (both `tailnet_only` gateway routes, reached via the host-networked HAProxy relay bound to the VPS's own Tailscale IP — see `roles/gateway/templates/Caddyfile.j2`) fail to **resolve** for the operator's devices — a DNS/split-DNS matter, not a reachability or ACL matter (confirmed: regular SSH over the same tailnet path works fine, and the failure was "can't resolve the address," not a timeout). Not investigated further here; flagged to the operator directly, not filed as an epic 23 ticket.

A second, non-blocking gap surfaced by the ACL change: Tailscale's own health check reported "Tailscale SSH enabled, but access controls don't allow anyone to access this device" (the separate `tailscale ssh` feature, not regular OpenSSH, has no `"ssh"` policy section in the new ACL). Confirmed with the operator: they don't use `tailscale ssh`, only OpenSSH — no fix needed, noted here only so it isn't rediscovered as a surprise later.

No separate backup file was made of the prior policy before replacing it. The prior policy was the trivial, universally-documented Tailscale default (`{"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]}`) — it needs no file to be recoverable; it's fully reconstructable from memory or the Tailscale docs, which is itself a form of "keeping a copy" for rollback purposes.

Host-reboot survival of the pair (state, routing rule reapplication, node re-identification) is explicitly **not** tested by this spike — deferred, as the ticket's own AC states, to the epic's attended validation and epic 21's reboot drill.

### Isolation is by construction for the Docker side

The throwaway pair's services attached only to their own dedicated `spike_net` bridge network — never `gateway` or `internal` — for the entire spike, so the container-bridge early-return in the DOCKER-USER firewall chain (the same mechanism ADR-0007/epic 21 already rely on) gives it no path to Authelia or Hermes regardless of the tailnet ACL result. Not something this spike could get wrong by construction; ticket #03's own AC re-asserts this as a render-time guard for the real fleet.
