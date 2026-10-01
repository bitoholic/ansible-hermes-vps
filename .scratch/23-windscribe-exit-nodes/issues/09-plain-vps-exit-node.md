# 09: Optional — the VPS's own node as a plain exit node (droppable)

**What to build:** "No Windscribe" becomes one more choice in the Tailscale app: the VPS's own Tailscale node also advertises as an exit node, with egress from the VPS's own public IP — including on a node that is already running, where the existing bring-up step does not run. **Droppable:** removing this ticket affects nothing else.

**Blocked by:** #07
**Blocks:** None

**Status:** ready-for-human (code done; the live traffic test needs the operator — see Notes)

- [x] The VPS's Tailscale node advertises itself as an exit node through an idempotent step that also works when the node is already running (the existing bring-up only runs when it is not), without re-authenticating and without disturbing the node's other settings
- [x] Host routing is unchanged — advertising an exit node does not alter the default route (asserted — see Notes for why no new code path exists to assert over)
- [x] The forwarding settings the exit node depends on are persistent for both address families (the finding of epic 21's runtime-state audit is reused; the check states where each setting is persisted)
- [ ] **Live check, not a render assertion:** the interaction with the `DOCKER-USER` port-class rules — a runtime chain-ordering question — is proven on the real VPS by sending traffic through the plain exit node from a tailnet device and confirming it is forwarded and not dropped; the check is recorded here and added to the live verification script's optional section
- [x] The README notes that the route must be approved in the Tailscale admin console and how to select the node

## Notes

See epic 23 spec, "Implementation Decisions" (optional plain exit node). The admin-console approval and the phone selection are the operator's, noted in the README.

## Implementation

**`roles/tailscale/tasks/main.yml`**: two new tasks after "Set facts for this host's own Tailscale
addresses" — `Check whether this host already advertises itself as an exit node`
(`tailscale status --self --json`, reading `Self.ExitNodeOption`, mirroring the exact field
`scripts/verify-exit-nodes.sh` already reads for the containerized pairs) and
`Advertise this host's own Tailscale node as a plain exit node` (`tailscale set
--advertise-exit-node`, guarded by a `when:` that skips it once already true). Deliberately `set`,
never a second `up`: the existing "Bring up Tailscale" block only runs `tailscale up` when the node
isn't already `Running` (epic 21's runtime-state audit finding — re-running `up` on an
already-logged-in node needs every non-default flag restated or it refuses), so a preference change
on an already-running node needs its own step that can't re-authenticate or touch any other
setting. `tailscale set` is exactly that: it changes only the one flag named, nothing else — the
mechanism this AC's "without disturbing the node's other settings" calls for, not a design choice
invented for this ticket.

**Host routing is unchanged by construction, not by a new runtime check**: this ticket adds no `ip
route`/`ip rule`/sysctl-writing task of its own — `tailscale set` is Tailscale's own preference
mechanism, and the forwarding sysctls it depends on were already made persistent by the Tailscale
installer (epic 21's runtime-state audit, reused here rather than re-solved). The existing
"host routing: unchanged" section of `scripts/verify-exit-nodes.sh` (ticket #06, host-wide, not
per-feature) already covers this generically — re-running it before/after enabling this ticket is
the proof, not a new dedicated check.

**`scripts/verify-exit-nodes.sh`** gets a new optional section (after the fleet-wide checks, before
the summary): reports whether the host advertises itself as an exit node (INCONCLUSIVE, not FAIL,
when it doesn't — "never enabled" and "a real regression" look identical from here alone, the same
honesty discipline the admin-console-approval check already applies) and live-checks both
forwarding sysctls on the host itself (`sudo sysctl -n net.ipv4.ip_forward` /
`net.ipv6.conf.all.forwarding`), stating in the PASS line exactly where each is persisted. The
genuinely unresolvable part — whether traffic from a real tailnet device actually gets forwarded by
the `DOCKER-USER` port-class rules rather than silently dropped — is stated plainly as NOT verified
here, in both the section's own `info` line and the script's closing summary, the same pattern
ticket #07's phone test already established for what a script alone can't prove.

**`tests/check-tailscale.sh`** gets a new section (4) asserting the two new tasks exist, that the
check-before-set guard reads `ExitNodeOption`, and — the one thing that would silently reintroduce
the re-auth risk this design exists to avoid — that the new step never calls `tailscale up`.

**README**: a new manual-post-deploy bullet explaining that this node, unlike the tagged
`exit_nodes` pairs, does **not** match the `tag:exit-node` auto-approver (it's the VPS's own
regular identity) and needs one manual admin-console approval, plus how to select it from the app.

### Review finding, fixed before any deploy

An independent pre-deployment review (explicitly framed as a higher-bar gate, since this touches
the VPS's own primary Tailscale node — the one SSH itself depends on) ran empirical tests against
real ansible-core and found the new block's placement, not its logic, was the real risk: positioned
between the Tailscale bring-up and the "Host firewall" section (as first written), a failure in the
new `when:` clause's `from_json` parse (a pre-existing fragility already present in the older
"Bring up Tailscale" block, not newly introduced here, but newly exposed to it) would abort the
whole play *before* UFW, the SSH rate-limit rule and the DOCKER-USER chain got applied — exactly
backwards for a feature this ticket's own AC calls "droppable: removing this ticket affects nothing
else." Fixed by moving the entire block to the very end of `roles/tailscale/tasks/main.yml`, after
every firewall/SSH task, and adding `failed_when: false` to both new tasks as additional
containment. Any failure here now leaves the host exactly as configured as it would have been
without this ticket at all — never worse. The review found no issue with the idempotency logic
itself (verified live against real ansible-core: a missing `Self` key degrades gracefully; the
`--check`-mode `ignore_errors` is inert but consistent with this file's own existing pattern on
neighboring tasks; `tailscale set` cannot touch `--accept-dns` or any other preference). Full local
suite (`tests/lint.sh`) re-run clean after the move.

### Why the live traffic test is not run here

The AC is explicit that the `DOCKER-USER` interaction is a runtime chain-ordering question only a
live check can answer — reasoning about `roles/tailscale/templates/docker-user.rules.v4.j2` alone
confirms the chain has no rule specific to this traffic (it's host-level forwarding from
`tailscale0` outward, matching none of the `--dport`-scoped port-class rules), but what actually
happens when a non-matching, non-established packet falls off the end of `DOCKER-USER` depends on
Docker's own `FORWARD` chain rules and the kernel's default policy — genuinely not something to
assert from reading the render alone. Proving it needs: (1) the admin-console approval only the
operator can grant (this node doesn't match the `tag:exit-node` auto-approver), and (2) a second
tailnet device actually selecting this node as its exit node and generating real traffic through it
— the same category of attended, real-device action as ticket #07's phone test, on the VPS's own
primary Tailscale identity (the one SSH access itself depends on), rather than a disposable
container. Code, static checks, and the live-verification script's own supporting checks
(advertised state, forwarding sysctls) are all done and reviewed; the live traffic test itself is
left for the operator to run together, the same way ticket #07's live validation was done.
