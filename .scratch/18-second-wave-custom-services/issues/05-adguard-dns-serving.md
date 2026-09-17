# 05: AdGuard Home — serve DNS to the tailnet

**What to build:** AdGuard actually serving DNS for Tailscale-connected devices — port 53 (UDP+TCP) published and firewall-restricted to the Tailscale subnet, with the host's own DNS resolution (systemd-resolved) still working throughout the change.

**Blocked by:** #04
**Blocks:** #06

**Status:** ready-for-agent

- [ ] Port 53 (UDP and TCP) is published for the AdGuard container and restricted at the firewall to Tailscale-sourced traffic only — not reachable from the public internet
- [ ] A new firewall port class handles UDP restriction (today's restricted-port mechanism is TCP-only), mirroring the existing TCP restricted-port rules' structure
- [ ] The host's systemd-resolved stub listener is disabled to free port 53, sequenced so the host is never left without working DNS resolution during the change (AdGuard bound to port 53 before or atomically with the host listener going down, not after)
- [ ] From a Tailscale-connected client, DNS queries against the VPS's Tailscale IP resolve correctly and are ad/tracker-filtered
- [ ] The manual step of pointing the tailnet's devices at AdGuard (Tailscale's own admin-console DNS override setting) is documented clearly enough for the operator to complete independently — not attempted as automation

## Notes

See epic 18 spec, section "AdGuard Home", and the Further Notes flag that this is the highest-risk step in the epic (a host-level DNS config change with a real failure mode if sequenced wrong). Verify the sequencing against a real deploy, not just a `--check` dry run, per this repo's established practice for this class of change (epics 13, 15, 16, 17 all caught sequencing bugs only visible on a live run).
