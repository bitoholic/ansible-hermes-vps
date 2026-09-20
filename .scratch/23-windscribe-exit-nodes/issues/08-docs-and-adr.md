# 08: Documentation and ADR

**What to build:** The operator can set up, use, extend, bump and troubleshoot exit nodes from the documentation alone, and an ADR records the design, the threat model and the evidence behind them.

**Blocked by:** #07
**Blocks:** None

**Status:** ready-for-agent

- [ ] README manual post-deploy steps cover: generating the dedicated Windscribe config, creating the Tailscale tag and auto-approver, creating the key, and approving nodes when no auto-approver exists
- [ ] **The tailnet access-control rules are documented as required, not optional:** members may use the tagged nodes as exit nodes; the tagged nodes are a source for nothing — with the reason (everything on the VPS trusts every tailnet source, and these are third-party images with elevated network capability)
- [ ] **Auth-key expiry is documented:** Tailscale auth keys expire (at most 90 days), already-registered nodes keep working because their identity persists, and adding a location or re-registering a node after expiry needs a fresh key (or an OAuth client that mints them); the rotation steps are in the runbook
- [ ] **A version-bump procedure is documented** for gluetun and Tailscale (which to change, how to validate a bump against the recovery and kill-switch checks, how to roll back), and the server-list update policy is described
- [ ] Documented: how to switch location on Android, and how to add a location (one list entry)
- [ ] A troubleshooting guide covers the three known failure modes (Tailscale firewall backend, forward rules, return-path routing) and the expectation that the phone-to-node path is relayed
- [ ] The measured resource cost per pair is documented so the box can be sized for more locations
- [ ] A new ADR (ADR-0008) records the per-location design, the rejected alternatives (host-level WireGuard with policy routing; a single roaming node), the trust-boundary threat note (tailnet members running third-party images with elevated capability, and the three controls), the resilience findings from #01 and the attended validation's measurements

## Notes

See epic 23 spec, "Implementation Decisions" (trust boundary; Tailscale identity; docs and ADR) and "Further Notes".
