# 01: Add the tailnet-facing PROXY-protocol relay and Caddy's internal listener

**What to build:** A real Tailscale client reaching any `mfa_auth`- or `tailnet_only`-gated hostname (`wiki`, `dash`, `owntracks-ui`, `adguard`, `monitor`) via the VPS's own Tailscale IP gets correctly recognized as a tailnet source — `mfa_auth` routes skip the Authelia challenge, `tailnet_only` routes actually load instead of 404ing — while every public-internet and Cloudflare-proxied client's existing, already-correct behavior is completely untouched.

**Blocked by:** None (can start immediately)
**Blocks:** #02

**Status:** ready-for-agent

- [ ] A new host-networked relay component binds to the VPS's Tailscale IP (both v4 and v6) on ports 80 and 443, accepts the raw TCP connection, and forwards it to Caddy with a PROXY protocol header carrying the real client IP
- [ ] Caddy's public port-publish for 80/443 is narrowed to the VPS's public IP specifically (no longer all-interfaces), freeing those same ports on the Tailscale IP for the relay
- [ ] Caddy's Dockerfile compiles in a PROXY-protocol-terminating module (`caddy.listeners.proxy_protocol` or equivalent) alongside the existing Cloudflare DNS plugin from epic 19 — verified by actually building the image and checking the module is present, not just that the Dockerfile text requests it
- [ ] Caddy gains a second, internal-only listener (loopback-bound, never published to the Docker bridge's externally-reachable side or the public internet) that trusts and terminates PROXY protocol from the relay only; the existing public-facing listener's configuration is provably unchanged — no PROXY-protocol wrapper, no new trust surface
- [ ] Both `mfa_auth`'s and `tailnet_only`'s `not remote_ip` matchers check `tailscale_subnet_v6` alongside the existing v4 constant, closing the pre-existing v4-only gap surfaced during this epic's investigation
- [ ] Port 8443 (matrix/owntracks) is untouched — confirmed no PROXY-protocol dependency or listener change applies there
- [ ] Each service's own raw published port (Beszel's 8090, AdGuard's 3001) is confirmed still reachable over Tailscale exactly as before, unaffected by this change
- [ ] The fix is verified against the real VPS: a real Tailscale client reaching `monitor.<secret-silverbullet-domain>` (or another `tailnet_only` route) via the VPS's Tailscale IP loads correctly, and `wiki.<secret-silverbullet-domain>`/`dash.<secret-silverbullet-domain>` correctly skip the Authelia challenge over the same path

## Notes

See epic 20 spec, "Solution" and "Implementation Decisions". Two decisions are explicitly left open for this ticket to resolve, not pre-decided by the spec:

- **How the VPS's public IP and its own Tailscale IP(s) are obtained at deploy time** — no existing variable holds either today. Candidates the spec names: Ansible's own gathered facts (`ansible_default_ipv4.address`, `ansible_tailscale0.ipv4.address`/`ansible_tailscale0.ipv6`) versus a manually-set `group_vars` value versus parsing `tailscale ip`/`tailscale status --json` directly. Whichever is chosen must work reliably under `--check` and must account for `tailscale0` not existing as an interface until the `tailscale` role's own "bring up Tailscale" task has already run in the same play.
- **The exact relay tool** — the spec suggests HAProxy in TCP mode (`send-proxy`/`send-proxy-v2`) as the natural fit, but leaves the final choice to this ticket.

PROXY-protocol trust is a hard security boundary (see spec's Implementation Decisions): getting the internal listener's reachability wrong would let anyone on the public internet forge a PROXY header claiming a `100.64.0.0/10` source and fully bypass both `mfa_auth` and `tailnet_only`. Treat the "public listener has no PROXY-protocol wrapper" test as the single most important regression guard this ticket adds, not a minor config nit.

Live verification (the last checkbox) cannot be satisfied by a rendering-only test — there is no real Tailscale network, masquerade behavior, or PROXY-protocol handshake available outside a real deploy. Static tests should cover everything else (compose-fragment shape, Dockerfile module presence, the loopback-only/no-public-wrapper regression guard, the v6 matcher extension, and that every existing gateway-render assertion still passes unchanged).
