# 07: Attended validation on the VPS, including the phone test

**What to build:** The real evidence that epic 23 works: the operator sets up the Windscribe and Tailscale prerequisites, deploys, and confirms on their phone that switching location works, ad-blocking still works, streaming works, the kill switch holds, and the exit nodes recover and survive a reboot — with the VPS's routing and SSH untouched throughout.

**Blocked by:** #04, #05, #06
**Blocks:** #08, #09

**Status:** ready-for-human

- [ ] The one-time prerequisites are done: a Windscribe WireGuard config generated for the VPS, and the Tailscale tag, exit-node auto-approver and reusable auth key created (or each node approved by hand), **and tailnet access-control rules in place that let members use the tagged nodes as exit nodes while giving the tagged nodes no access to any tailnet destination**
- [ ] The deployment is run check-mode first and reviewed before applying
- [ ] **The tailnet access-control change is sequenced safely** (it is global and can cut every device off from services): before editing, an alternate path to the VPS is confirmed (SSH on the public address from a non-tailnet path, and the provider console reachable) and a copy of the current policy is saved for rollback; the change is previewed with Tailscale's policy test facility before it is applied; after applying, existing access is re-verified from the workstation and the phone (AdGuard DNS, a tailnet-gated route, SSH) before anything else proceeds; if any check fails, the saved policy is restored immediately
- [ ] Phone test, for each location: selecting the node shows the correct country and a Windscribe IP; ad-blocking still works; browsing and apps work; lossless audio plays; switching back to no exit node works
- [ ] Kill switch: a tunnel is deliberately taken down (attended) and exit traffic is dropped, never sent out of the VPS's IP; the tunnel is then restored
- [ ] Trust boundary: from inside a pair, the VPS's tailnet address and another tailnet device are unreachable (the live-verification script's probe, confirmed by hand once)
- [ ] Recovery: restarting a tunnel container makes its exit node recover automatically with no operator action
- [ ] Reboot: the exit nodes come back by themselves (preferably in the same reboot as epic 21's drill)
- [ ] The host's default route and rule count are unchanged and SSH was unaffected throughout
- [ ] Results are recorded in this ticket's notes

## Notes

Needs the operator: admin-console actions, their phone, deliberate failure injection. See epic 23 spec, "Testing Decisions" (operator-validated behaviors).
