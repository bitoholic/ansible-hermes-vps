# 09: Optional — the VPS's own node as a plain exit node (droppable)

**What to build:** "No Windscribe" becomes one more choice in the Tailscale app: the VPS's own Tailscale node also advertises as an exit node, with egress from the VPS's own public IP — including on a node that is already running, where the existing bring-up step does not run. **Droppable:** removing this ticket affects nothing else.

**Blocked by:** #07
**Blocks:** None

**Status:** ready-for-agent

- [ ] The VPS's Tailscale node advertises itself as an exit node through an idempotent step that also works when the node is already running (the existing bring-up only runs when it is not), without re-authenticating and without disturbing the node's other settings
- [ ] Host routing is unchanged — advertising an exit node does not alter the default route (asserted)
- [ ] The forwarding settings the exit node depends on are persistent for both address families (the finding of epic 21's runtime-state audit is reused; the check states where each setting is persisted)
- [ ] **Live check, not a render assertion:** the interaction with the `DOCKER-USER` port-class rules — a runtime chain-ordering question — is proven on the real VPS by sending traffic through the plain exit node from a tailnet device and confirming it is forwarded and not dropped; the check is recorded here and added to the live verification script's optional section
- [ ] The README notes that the route must be approved in the Tailscale admin console and how to select the node

## Notes

See epic 23 spec, "Implementation Decisions" (optional plain exit node). The admin-console approval and the phone selection are the operator's, noted in the README.
