# 08: Documentation and ADR

**What to build:** The operator can set up, use, extend and troubleshoot exit nodes from the documentation alone, and an ADR records the design and the evidence behind it.

**Blocked by:** #07
**Blocks:** None

**Status:** ready-for-agent

- [ ] README manual post-deploy steps cover: generating the dedicated Windscribe config, creating the Tailscale tag, auto-approver and key, and approving nodes when no auto-approver exists
- [ ] Documented: how to switch location on Android, and how to add a location (one list entry)
- [ ] A troubleshooting guide covers the three known failure modes (Tailscale firewall backend, forward rules, return-path routing) and the expectation that the phone-to-node path is relayed
- [ ] The measured resource cost per pair is documented so the box can be sized for more locations
- [ ] A new ADR (next available number) records the per-location design, the rejected alternatives (host-level WireGuard with policy routing; a single roaming node), the resilience findings from #01 and the attended validation's measurements

## Notes

See epic 23 spec, "Implementation Decisions" (docs and ADR) and "Further Notes".
