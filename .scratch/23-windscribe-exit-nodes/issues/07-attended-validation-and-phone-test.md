# 07: Attended validation on the VPS, including the phone test

**What to build:** The real evidence that epic 23 works: the operator sets up the Windscribe and Tailscale prerequisites, deploys, and confirms on their phone that switching location works, ad-blocking still works, streaming works, the kill switch holds, and the exit nodes recover and survive a reboot — with the VPS's routing and SSH untouched throughout.

**Blocked by:** #04, #05, #06
**Blocks:** #08, #09

**Status:** ready-for-human

- [ ] The one-time prerequisites are done: a Windscribe WireGuard config generated for the VPS, and the Tailscale tag, exit-node auto-approver and reusable auth key created (or each node approved by hand)
- [ ] The deployment is run check-mode first and reviewed before applying
- [ ] Phone test, for each location: selecting the node shows the correct country and a Windscribe IP; ad-blocking still works; browsing and apps work; lossless audio plays; switching back to no exit node works
- [ ] Kill switch: a tunnel is deliberately taken down (attended) and exit traffic is dropped, never sent out of the VPS's IP; the tunnel is then restored
- [ ] Recovery: restarting a tunnel container makes its exit node recover automatically with no operator action
- [ ] Reboot: the exit nodes come back by themselves (preferably in the same reboot as epic 21's drill)
- [ ] The host's default route and rule count are unchanged and SSH was unaffected throughout
- [ ] Results are recorded in this ticket's notes

## Notes

Needs the operator: admin-console actions, their phone, deliberate failure injection. See epic 23 spec, "Testing Decisions" (operator-validated behaviors).
