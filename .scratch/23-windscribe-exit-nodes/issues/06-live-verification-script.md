# 06: Read-only live verification script for the exit nodes

**What to build:** A read-only script the operator runs from a workstation that confirms, for each exit location, that the exit node is healthy, exits in the right country and not via the VPS, is correctly firewalled, and that the host's routing is unchanged — automating everything checkable without a phone.

**Blocked by:** #04
**Blocks:** #07

**Status:** ready-for-agent

- [ ] For each configured location it verifies: the pair is running and healthy; the Tailscale exit node is advertised and approved; the exit IP is in the configured country and differs from the VPS's public IP
- [ ] It verifies the tunnel firewall's forward rules are exactly the expected ones and that IPv6 forwarding is denied
- [ ] It verifies the return-path rule is present for both address families
- [ ] It verifies the host's default route and rule count match a recorded baseline and that no ports are published for the feature
- [ ] It verifies the trust boundary: from inside each pair, the VPS's own tailnet address and other tailnet devices are unreachable, and the pair is attached to no network other than its own dedicated one
- [ ] It verifies the firewall interplay for the pairs: the `DOCKER-USER` chain holds no entries specific to them, and each tunnel is up — showing the container-bridge early return lets the tunnel's UDP egress through without any per-pair rule
- [ ] It runs only read-only commands, prints no credentials, takes the target host from an argument, the environment or epic 22's wrapper in script mode, and states plainly that it cannot verify the phone experience or an active tunnel-down test (those are attended, #07)

## Notes

See epic 23 spec, "Testing Decisions". Style prior art: epic 21's live verification script (#05 there).
