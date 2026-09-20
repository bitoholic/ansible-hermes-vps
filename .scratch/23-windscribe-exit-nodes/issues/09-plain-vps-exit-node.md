# 09: Optional — the VPS's own node as a plain exit node (droppable)

**What to build:** "No Windscribe" becomes one more choice in the Tailscale app: the VPS's own Tailscale node also advertises as an exit node, with egress from the VPS's own public IP. **Droppable:** removing this ticket affects nothing else.

**Blocked by:** #07
**Blocks:** None

**Status:** ready-for-agent

- [ ] The VPS's Tailscale node advertises itself as an exit node
- [ ] Host routing is unchanged — advertising an exit node does not alter the default route (asserted)
- [ ] The interaction with the `DOCKER-USER` port-class rules is verified: forwarded tailnet-to-internet traffic is not dropped by them (render-level assertion plus a note)
- [ ] The README notes that the route must be approved in the Tailscale admin console and how to select the node

## Notes

See epic 23 spec, "Implementation Decisions" (optional plain exit node). The admin-console approval and a live check are the operator's, noted in the README rather than performed by this ticket.
