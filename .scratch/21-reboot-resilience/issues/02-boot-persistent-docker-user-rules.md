# 02: Boot-persistent, atomic DOCKER-USER rules and the boot firewall unit

**What to build:** After this ticket a reboot or a Docker restart reloads the restricted-port rules by itself, and a routine deploy repairs a missing chain even when nothing about the rules changed. The port classes are rendered once, for both IP families, into a single ruleset; every deploy compares the live chain with it and loads it atomically when they differ (the chain is never half-built or empty, even momentarily), and a boot firewall unit loads that same rendering at boot and whenever Docker restarts. The imperative per-rule tasks are removed. SSH, UFW and the INPUT chain are untouched. The fail-closed coupling ships **disabled** until the attended drill enables it.

**Blocked by:** #01
**Blocks:** #04, #05

**Status:** ready-for-agent

- [ ] Given the existing port-class variables, the rendered ruleset classifies ports correctly per address family and protocol: public ports accepted; restricted TCP and UDP ports accepted from tailnet sources only and dropped otherwise; the allowlisted Syncplay port accepted only from its list (an empty list means blocked; IPv6 always blocked); docker-bridge and established traffic accepted early
- [ ] A deploy replaces the chain's contents atomically and touches only that chain; Docker's own chains are never modified
- [ ] **A deploy heals an unchanged artifact:** with the rendered files unchanged and the live chain emptied (simulating a reboot), a deploy reloads the rules — it compares the live chain with the rendering rather than relying on a file change or on the unit reporting itself already started
- [ ] A boot firewall unit is installed and enabled, wired as ticket #01 recommended, and loads the very same rendering the deploy uses
- [ ] Restarting Docker re-applies the rules
- [ ] The fail-closed coupling (Docker-published services do not start if the rules cannot be loaded) is implemented but **ships disabled behind an explicit variable**; ticket #06 enables it after the unit has been observed working on the real VPS. With it disabled, a routine deploy cannot take the stack down. When enabled, a load failure is visible in the service manager and the journal
- [ ] Repeated deploys produce a byte-identical rendered artifact and identical resulting chains (the existing live idempotency assertion is preserved and extended)
- [ ] The imperative per-rule tasks are gone; adding a port to a class is still a single edit to the shared port-class variables
- [ ] Neither the unit nor the deploy changes UFW rules, the INPUT chain, or sshd
- [ ] The unit and rules live in the `tailscale` role (which owns UFW and `DOCKER-USER`; there is no separate firewall role); the documentation states that `--skip-tags tailscale` skips *updating* the rules and unit but never removes an installed unit
- [ ] The role's outdated "not persisted across reboot" comment is replaced with the new behavior
- [ ] The standard test run passes with the role's static and live-idempotency checks extended to the new rendering and unit

## Notes

See epic 21 spec, "Implementation Decisions" (one source, one rendering; atomic application; a deploy heals an unchanged artifact; own unit; fail closed; staged rollout). Rollout to the production VPS happens in the attended drill (#06), not by merging this ticket.
