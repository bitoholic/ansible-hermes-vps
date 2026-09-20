# 02: Boot-persistent, atomic DOCKER-USER rules and the boot firewall unit

**What to build:** After this ticket a reboot or a Docker restart reloads the restricted-port rules by itself. The port classes are rendered once, for both IP families, into a single ruleset; every deploy loads it atomically (the chain is never half-built or empty, even momentarily), and a boot firewall unit loads that same rendering at boot and whenever Docker restarts, failing closed if it cannot. The imperative per-rule tasks are removed. Deploys stay idempotent, and SSH, UFW and the INPUT chain are untouched.

**Blocked by:** #01
**Blocks:** #04, #05

**Status:** ready-for-agent

- [ ] Given the existing port-class variables, the rendered ruleset classifies ports correctly per address family and protocol: public ports accepted; restricted TCP and UDP ports accepted from tailnet sources only and dropped otherwise; the allowlisted Syncplay port accepted only from its list (an empty list means blocked; IPv6 always blocked); docker-bridge and established traffic accepted early
- [ ] A deploy replaces the chain's contents atomically and touches only that chain; Docker's own chains are never modified
- [ ] A boot firewall unit is installed and enabled, wired as ticket #01 recommended, and loads the very same rendering the deploy uses
- [ ] Restarting Docker re-applies the rules
- [ ] If the rules cannot be loaded, Docker-published services do not start (fail closed), and the failure is visible in the service manager and the journal
- [ ] Repeated deploys produce a byte-identical rendered artifact and identical resulting chains (the existing live idempotency assertion is preserved and extended)
- [ ] The imperative per-rule tasks are gone; adding a port to a class is still a single edit to the shared port-class variables
- [ ] Neither the unit nor the deploy changes UFW rules, the INPUT chain, or sshd
- [ ] The role's outdated "not persisted across reboot" comment is replaced with the new behavior
- [ ] The standard test run passes with the firewall role's static and live-idempotency checks extended to the new rendering and unit

## Notes

See epic 21 spec, "Implementation Decisions" (one source, one rendering; atomic application; own unit, not ruleset snapshotting; fail closed) and "Testing Decisions". Rollout to the production VPS happens in the attended drill (#06), not by merging this ticket.
