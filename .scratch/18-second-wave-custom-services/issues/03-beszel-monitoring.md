# 03: Beszel — hub + local agent monitoring dashboard

**What to build:** A self-hosted monitoring dashboard for the VPS's own health (CPU, memory, disk, container status), reachable only over Tailscale. The hub and a local agent (monitoring the same VPS, no Docker-socket access) are added as new containers; the agent-to-hub pairing credential is documented as a manual, one-time step the operator performs after the hub's first boot.

**Blocked by:** #01
**Blocks:** #06

**Status:** ready-for-agent

- [ ] A new role stands up the hub and agent as two containers in the consolidated compose stack, with the hub's persistent data on durable storage that survives container restarts
- [ ] The agent connects to the hub via a local, non-networked mechanism (no published port for the agent, no Docker-socket mount)
- [ ] The hub's dashboard is published via a tailnet-only gateway route (no MFA, no public path)
- [ ] The new role's tasks are tagged and included in the skip-tags guard, and the role is wired in as a dependency of the gateway role rather than a fresh top-level entry
- [ ] The secrets manifest has entries for the agent's hub-issued pairing credential, with the manual retrieval/population step documented clearly enough that an operator can follow it without reading the role's source
- [ ] Consolidated docker-compose render passes with the new services enabled

## Notes

See epic 18 spec, section "Beszel" — including the explicit call-out that the hub's own admin-account bootstrap mechanism is unverified and must be confirmed during implementation (it may also require a documented manual first-boot step, the same shape as the agent pairing). Do not attempt to script or pre-seed the agent's key/token — it's hub-generated after first boot, not something Ansible can originate, structurally identical to how `TAILSCALE_AUTHKEY` already works in this repo.
