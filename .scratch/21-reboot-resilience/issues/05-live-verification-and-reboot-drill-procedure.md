# 05: Read-only live verification script and the reboot-drill procedure

**What to build:** A read-only script the operator runs from a workstation that proves the VPS is in the correct state — after any reboot, or any time they doubt it — and a written, rehearsed reboot-drill procedure that uses it. The script changes nothing on the VPS and never claims a pass it cannot support.

**Blocked by:** #02, #03, #04
**Blocks:** #06

**Status:** ready-for-agent

- [ ] The script runs only read-only commands on the VPS (a documented allowlist) and changes nothing
- [ ] It verifies: the `DOCKER-USER` rules for both families equal the rendering; the boot firewall unit is enabled and active; every expected container is running; restart policies are as declared; Docker, Tailscale and UFW are enabled; the host resolves names; the public ingress ports answer; the tailnet-gated routes answer from the tailnet
- [ ] It includes an outside-in probe of the restricted ports that reports *inconclusive* — never *pass* — when the operator's route to the VPS is not a plain internet path (for example when the workstation's traffic goes through another VPN)
- [ ] It prints nothing sensitive and takes the target host as an argument or from the environment
- [ ] The reboot-drill procedure is documented: pre-flight (provider console access verified, an alternate tailnet path to the host verified, a baseline captured), the reboot, post-boot verification, the stop-AdGuard-and-resolve check, and what to do if locked out (via the console)
- [ ] The procedure states the bounds under test (relay convergence, front door up, rules live)

## Notes

See epic 21 spec, "Implementation Decisions" (reboot drill and live verification). Style prior art: the static-only guards' "what this cannot verify" headers from epics 18–20.
