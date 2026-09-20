# 01: Resilience spike — how a tunnel-and-Tailscale pair behaves when things restart

**What to build:** Recorded, evidence-backed answers — from a throwaway exit-node pair on the real VPS that never touches production routing — to the failure modes the first spike did not test, plus the decisions that follow from them: how dependents follow a restarted or recreated tunnel container, where the persistent return-path rule lives, which gluetun and Tailscale versions to pin, and how the gluetun server list is kept fresh. Delivers the recovery mechanism and versions ticket #03 builds on.

**Blocked by:** None (can start immediately)
**Blocks:** #03

**Status:** ready-for-human

- [ ] The operator supplies a Windscribe WireGuard configuration generated for the VPS alone and a short-lived ephemeral Tailscale auth key; they are used through restricted files and removed afterwards
- [ ] Each failure mode is exercised and observed: tunnel-container restart, tunnel-container recreation (its network namespace replaced), reconnect inside gluetun, an unavailable Windscribe server (a restart picks another), and a Tailscale-container restart
- [ ] For each: does the exit node recover automatically, do the forward rules and the return-path rule persist, does a client regain connectivity
- [ ] The recovery mechanism is decided and recorded — how dependents follow the tunnel container's restarts, and where the persistent return-path rule lives
- [ ] The versions of gluetun and Tailscale that were validated are recorded for pinning
- [ ] The server-list update policy is decided (periodic updater versus a bump cadence), with evidence of its effect
- [ ] Evidence shows the host's default route and rule count identical before, during and after
- [ ] The throwaway pair is fully torn down and no key material is left behind
- [ ] Host-reboot survival is deferred, by statement, to the epic's attended validation and epic 21's drill

## Notes

Needs the operator: a Windscribe config, an auth key, approving the test node as an exit node. An agent can drive the experiments once those are supplied. See epic 23 spec, "Implementation Decisions" (resilience, decided by a spike before the fleet is built) and "Further Notes" (spike measurements).
