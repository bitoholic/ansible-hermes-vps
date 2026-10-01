# Windscribe exit nodes runbook

Operational procedures for the per-location exit-node pairs (epic 23): one-time setup, everyday
use, version bumps, auth-key rotation and troubleshooting. See `CONTEXT.md` for vocabulary (**exit
node**, **exit location**, **exit-node pair**, **kill switch**) and [ADR-0008](adr/0008-windscribe-exit-node-pairs.md)
for the design and its evidence.

## One-time setup

Do these once, in order, before the first deploy that enables `exit_nodes`.

### 1. Generate a dedicated Windscribe WireGuard config

In the Windscribe web dashboard, generate a **new** WireGuard configuration specifically for the
VPS — never reuse a configuration already active on a workstation or phone. The same Windscribe
key connecting from two devices at once makes the chosen server flip between them (confirmed live
during ticket #01's spike: one key *can* drive two simultaneous tunnels from the same device
without issue, but was never tested, and is not supported, across two different devices). From the
generated config, you need three values:

- `PrivateKey` → `WINDSCRIBE_PRIVATE_KEY`
- `Address` (the tunnel-internal IPv4, e.g. `10.x.x.x/32`) → `WINDSCRIBE_ADDRESS`
- `PresharedKey` → `WINDSCRIBE_PRESHARED_KEY`

Add all three to the encrypted store:

```bash
scripts/secrets fill
```

(interactive, hidden-input prompts for any required name still missing — see
[`docs/secrets-runbooks.md`](secrets-runbooks.md) for the full secrets workflow).

### 2. Create the Tailscale tag, auto-approver and reusable auth key

In the [Tailscale admin console](https://login.tailscale.com/admin/acls/file), edit the tailnet
policy to add a `tag:exit-node` tag (owned by your own user group) and an **auto-approver** so a
freshly-registered exit-node container doesn't need a manual per-node click in the console:

```jsonc
{
  "tagOwners": { "tag:exit-node": ["autogroup:member"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:member:*"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:internet:*"] }
  ],
  "autoApprovers": {
    "exitNode": ["tag:exit-node"]
  }
}
```

This is the real policy this repo's exit nodes run under today (`autoApprovers` added on top of
the access-control rules below — see "The tailnet access-control rules" for why those two ACL
lines, on their own, already give `tag:exit-node` nodes no access to anything). **Without an
auto-approver**, skip the `autoApprovers` block and instead approve each new exit node by hand in
the console (Machines → the new node → "Review" → "Approve exit node") every time one registers —
viable for a small, static location list, more friction for a list that changes often.

Then mint a reusable, tagged auth key (Settings → Keys → "Generate auth key", tag it
`tag:exit-node`, reusable, and — unless you've decided otherwise — non-ephemeral so the key can
register more than one node without being consumed). Add it to the store:

```bash
scripts/secrets fill   # prompts for EXIT_NODE_TAILSCALE_AUTHKEY
```

This key is deliberately separate from `TAILSCALE_AUTHKEY` (the VPS's own node identity) — a
compromised exit-node container must never carry the VPS's own tailnet identity.

### 3. The tailnet access-control rules are required, not optional

Everything else on the VPS trusts every tailnet source (the source-based MFA bypass for the
tailnet range; the firewall allows the whole `tailscale0` interface). An exit-node container is a
tailnet member running a third-party image with `NET_ADMIN` — if it were ever compromised, an
unrestricted tailnet would hand that compromise the same trust every other tailnet device has. The
two `acls` lines above close that: they grant `autogroup:member` (your own devices) access to each
other and to the internet (needed to *use* an exit node), but grant `tag:exit-node` **no** `src`
entry at all — under Tailscale's allow-list-only ACL model, a tag with no matching `src` rule can
reach nothing in the tailnet. This is verified live, not just asserted: `scripts/verify-exit-nodes.sh`
probes from inside a running pair that the VPS's own tailnet address, and (when supplied) another
tailnet device, are both unreachable.

**Roll this out safely — the policy is global and a mistake can cut off every device, not just the
exit nodes:**

1. Confirm an alternate path to the VPS *before* touching the policy: SSH on the VPS's public
   address from a connection that doesn't go over the tailnet, and confirm the hosting provider's
   own console (for an out-of-band reset) is reachable.
2. Save a copy of the current policy (the admin console's file editor shows the current JSON — copy
   it somewhere outside the console before editing).
3. Preview the change with Tailscale's own policy **test** facility (the console runs this
   automatically on save and refuses to save a policy that fails its own test block) before
   applying.
4. Apply, then immediately re-verify existing access from your workstation and phone: AdGuard DNS
   still resolves, a tailnet-gated route (anything behind the gateway role's `tailnet_only` class)
   still loads, and SSH over the tailnet IP still connects.
5. If any of step 4 fails, restore the saved policy from step 2 immediately.

**A real regression step 4's re-verification caught, live** (the policy here was applied first and
checked against this procedure after the fact, not previewed in the order above — worth following
the steps in order regardless, since this is exactly the kind of problem step 3's preview exists to
catch before it reaches production): applying the ACL above (purely additive — it adds an
`autoApprovers` stanza, it does not change the `acls` rules' substance) broke SSH over the tailnet
IP, while public-IP SSH and every other tailnet-routed service kept working. The cause
was **not** the ACL edit itself — it was Tailscale's own embedded SSH server ("Tailscale SSH," a
feature distinct from real OpenSSH) intercepting tailnet-sourced port-22 connections against an
undefined `"ssh"` policy dimension the new ACL file never defined. Fixed with:

```bash
sudo tailscale set --ssh=false
```

on the VPS (OpenSSH was already handling tailnet SSH correctly on its own; "Tailscale SSH" was an
unrelated, previously-dismissed-as-harmless feature — see `tailscale status`'s own health warnings
for "Tailscale SSH enabled" before you ever touch the ACL, so this doesn't surprise you later).

## Everyday use

### Switching location (Android)

Open the Tailscale app → the menu (≡) → **Exit node** → pick the location you want
(`<host>-ws-london`, `<host>-ws-warsaw`, …) or **None** to stop using one. Takes effect
immediately — no deploy, no SSH. Ad-blocking keeps working regardless of which exit node (or none)
is selected, because the phone's DNS still goes to the tailnet's AdGuard over the tailnet itself,
not through the exit node.

### Adding a location

One entry in `roles/exit_nodes/defaults/main.yml`'s `exit_nodes` list:

```yaml
exit_nodes:
  - name: london
    region: United Kingdom
    city: London
  - name: warsaw
    region: Poland
    city: Warsaw
  - name: amsterdam          # new entry
    region: Netherlands
    city: Amsterdam
```

- `name`: lowercase letters, digits and hyphens only, starting and ending with a letter or digit,
  at most 20 characters (it becomes part of a Tailscale hostname: `<host>-ws-<name>`).
- `region`/`city`: Windscribe's own vocabulary — a country name and a city Windscribe actually
  offers under that country. Gluetun's Windscribe provider picks a random server matching both on
  every tunnel start; it fails loudly at container start if the combination doesn't match anything
  in gluetun's built-in server list.

No new secret and no new code — the existing Windscribe credential set and Tailscale auth key
cover every location (verified live: the same key connected two servers from the same device at
once). Deploy as usual; the new pair appears in the Tailscale app under its own name once the auth
key registers it (auto-approved if you set up the auto-approver above, otherwise approve it by hand
once).

## Auth-key expiry and rotation

Tailscale auth keys expire — at most 90 days from creation, sooner if you set a shorter expiry when
minting one. **An already-registered exit node keeps working past its key's expiry** — the key
only authenticates a *new* registration; a node's own identity (stored in the per-location state
directory, `exit_nodes_state_dir`) persists across restarts independently of the key that minted
it. You only need a fresh key when:

- Adding a new location (a key is needed to register its exit node for the first time), or
- Re-registering an existing node after wiping its state directory (rare — normally never needed;
  state persists across every restart and recreation tested in this epic).

To rotate: mint a new reusable, tagged (`tag:exit-node`) auth key in the admin console (same steps
as initial setup), then:

```bash
scripts/secrets edit   # update EXIT_NODE_TAILSCALE_AUTHKEY
./scripts/deploy        # --check first, then for real
```

Existing, already-registered nodes are unaffected by this — the auth key (`TS_AUTHKEY`, set via the
shared credentials file, `roles/exit_nodes/templates/credentials.env.j2`) is only consulted during a
node's *first* registration; an already-registered node ignores it on every subsequent start. If
you'd rather not repeat this every 90 days, a Tailscale **OAuth client**
(Settings → OAuth clients) can mint short-lived keys on demand instead of one long-lived reusable
key — out of scope for this repo today, left as a documented option.

## Version bump procedure (gluetun / Tailscale)

Both images are pinned by digest (`roles/exit_nodes/defaults/main.yml`:
`exit_nodes_gluetun_image`, `exit_nodes_tailscale_image`) deliberately, so a floating tag can never
change behavior under you. To bump one:

1. Resolve the new digest for the tag you want (`docker pull <image>:<tag>` then
   `docker inspect --format '{{index .RepoDigests 0}}' <image>:<tag>`, or the registry's own API).
2. Update the one variable (`exit_nodes_gluetun_image` or `exit_nodes_tailscale_image`) — nothing
   else in the role or template needs to change for a routine bump.
3. **Validate against the two live checks this epic built specifically to catch a bad bump:**
   - Deploy to a single location first if you can (or accept the full-fleet redeploy — both
     locations share the same pinned images, so a bad digest affects both at once).
   - `./scripts/verify-exit-nodes.sh <target>` — confirms health, isolation, no published port,
     Tailscale advertised + online, exit IP/country, firewall posture and the return-path rule, for
     every configured location.
   - Repeat the kill-switch + recovery test by hand: `docker stop` the tunnel, confirm egress from
     a dependent container fails (`docker exec <node> nc -zv -w5 1.1.1.1 443` → "Network
     unreachable"), `docker start` it again, and — **without** restarting node/sidecar yourself —
     confirm they self-restart on their own within a couple of minutes (the HEALTHCHECK-driven
     recovery mechanism; see ADR-0008). A gluetun bump in particular is worth re-checking here: a
     routing-table or firewall-chain change inside gluetun's own image could in principle move or
     rename the chains Tailscale's nftables mode depends on (ticket #01's fix #1/#2).
4. If anything regresses, revert the one variable to its previous digest and redeploy — nothing
   else needs to be undone.

### Server-list update policy (not a version bump)

Gluetun's own server list (which Windscribe servers exist under each region/city) is baked into
its image at build time and would otherwise only refresh on the next image bump. Instead, gluetun's
**built-in periodic updater** is enabled — the container sees `UPDATER_PERIOD: 24h` and
`UPDATER_VPN_SERVICE_PROVIDERS: windscribe` (set in `roles/docker/templates/services/exit_node_pair.yml.j2`
from the role's own `exit_nodes_updater_period`/`exit_nodes_updater_vpn_service_providers` defaults
in `roles/exit_nodes/defaults/main.yml`) — so the
list refreshes itself daily with no image bump and no manual action. This was decided over a manual
bump cadence specifically because a stale list risks quietly routing a tunnel to a server Windscribe
has since retired.

## Troubleshooting

Three failure modes were found live (ticket #01's spike) and are the ones most likely to recur
after any change to this stack, an image bump, or a new host kernel/Docker version:

1. **Exit-node function is silently impossible (no `tailscale0` interface in the node container).**
   Cause: the Tailscale container defaulted to userspace networking, which has no kernel
   `tailscale0` interface at all. Fix already applied and must not be removed:
   `TS_USERSPACE: "false"` and `TS_DEBUG_FIREWALL_MODE: nftables` on the `node` service
   (`roles/docker/templates/services/exit_node_pair.yml.j2`). If you see this again after an image
   bump, check whether the new Tailscale image changed its default firewall mode or still honors
   these two variables the same way.
2. **Forwarding rules missing (clients can select the exit node but get no traffic through it).**
   With `TS_USERSPACE: "false"` and `TS_DEBUG_FIREWALL_MODE: nftables` set, Tailscale installs its
   own `ts-forward`/`ts-postrouting` nftables chains automatically — no manual iptables/nft rule
   should ever be added for this (a manual rule was tested and found unnecessary). Check via
   `scripts/verify-exit-nodes.sh`'s own forward-rules check, or by hand:
   `sudo nsenter -t <tunnel-pid> -n nft list ruleset` inside the tunnel's network namespace should
   show both chains.
3. **Return path is dead (requests go out, replies never come back).** Gluetun's own catch-all
   policy route (installed for its own kill-switch purposes) sends tailnet-destined reply traffic
   back into the tunnel instead of to Tailscale's own routing table, where gluetun's forward policy
   then silently drops it. Fixed by the routing sidecar, which re-applies a higher-priority `ip
   rule`/`ip -6 rule` on every one of its own starts (it does not survive the tunnel's own restart
   or recreation on its own). If replies stop working after any change, check first whether the
   sidecar is actually running (`docker ps` — `exit-node-<name>-sidecar`) before suspecting
   anything else.

**Expect the phone-to-exit-node path to be relayed, not direct** — Windscribe's own NAT prevents a
direct Tailscale (DERP-bypass) connection, so traffic always goes phone → Tailscale relay → exit
node → Windscribe. This was measured acceptable during the phone test (lossless Spotify played
fine); a client reporting "it works but feels a bit slower than my LAN" is this expected relay, not
a bug.

**If a node is up but node/sidecar seem to have lost network function after a tunnel-side event**
(a tunnel crash-restart, or an operator `docker restart`/`stop`+`start` on the tunnel alone): this
used to be a real, permanent gap — `node`/`sidecar` would stay attached to the tunnel's old,
orphaned network namespace indefinitely, with `docker compose up -d` unable to detect or fix it.
As of this epic's ticket #07, both containers carry a self-healing `HEALTHCHECK` that detects this
(a real TCP probe, not "is the process alive") and forces its own restart after a few consecutive
failures, which correctly re-attaches to the tunnel's current namespace — confirmed live,
repeatedly, with no manual action needed. If you ever see this symptom persist for several minutes
without a container restart happening (`docker inspect --format '{{.RestartCount}}'` not
incrementing), that healthcheck itself has regressed and is the first place to look
(`roles/docker/templates/services/exit_node_pair.yml.j2`'s `recovery_healthcheck()` macro).

## Resource sizing

Measured live during ticket #01's spike, per exit-node pair: the tunnel (gluetun) container used
≈31 MB RSS, the Tailscale (`node`) container ≈53 MB RSS — both ≈0% CPU at idle — for a combined
≈84 MB per location. The routing sidecar (added by ticket #03, after the spike) was not separately
measured; it runs the same Tailscale image but no Tailscale daemon of its own, just a shell and a
single idle `sleep` process, so its footprint is small relative to the other two. Use ≈85 MB per
pair as the planning number when sizing the box for additional locations.

## Verifying a deployment

`./scripts/verify-exit-nodes.sh <target>` is the read-only, repeatable check covering everything
listed above that can be checked from outside a human's phone: container health, no published
port, network isolation, Tailscale advertised + online, exit IP/country matching configuration,
IPv6-forwarding-denied, the forward-rules and return-path checks, and the trust-boundary probe. It
cannot confirm Tailscale admin-console **approval** (only local, self-reported "advertised" state
is visible from the node) or the real phone experience — those remain operator-checked, per
[ADR-0008](adr/0008-windscribe-exit-node-pairs.md).
