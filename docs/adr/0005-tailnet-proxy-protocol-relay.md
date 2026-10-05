# ADR-0005: PROXY-Protocol Relay Restores Real Source IP for Tailnet-Facing Caddy Access

## Status
Accepted. Restores the intent of [ADR-0001](0001-source-based-mfa.md) (source-based MFA) and
epic 18's `tailnet_only` route type for tailnet-sourced traffic specifically; does not supersede
or contradict either — both mechanisms are unchanged, only the source IP they see is fixed.

## Context
ADR-0001 and epic 18's `tailnet_only` routes both depend on Caddy seeing a request's *real* source
IP: `mfa_auth` skips the Authelia challenge for Tailscale sources, and `tailnet_only` hard-blocks
everyone else. Both silently broke for a specific case neither ADR anticipated: a Tailscale client
reaching a gated hostname (`monitor`, `wiki`, `dash`, `owntracks-ui`, `adguard`) via **this VPS's
own Tailscale IP** — as opposed to some other route into the same Docker-published port.

Root cause, confirmed empirically (`iptables -t nat -L ts-postrouting`, real Caddy access logs):
Tailscale's own local-subnet masquerade rewrites the source IP of tailnet traffic destined for a
service running on the *same host* the traffic arrived at, before it ever reaches a Docker-published
port. Caddy sees the masqueraded (loopback/bridge-range) address, not `100.64.0.0/10` — so
`mfa_auth` treats a real Tailscale client as a public-internet client (forcing an unwanted Authelia
challenge), and `tailnet_only` treats it as untrusted entirely (a flat 404, no access at all). This
is not a bug in either ADR's own logic; it's a network-layer fact both were built without knowing.

Two side-findings surfaced during this investigation, explicitly out of this epic's scope but
recorded here so they aren't lost:
- At the time of the original investigation, `owntracks-ui.<domain>` had a public/Cloudflare-
  proxied DNS record despite being a `tailnet_only` route — independently of this bug, that made it
  unreachable via that hostname by anyone at all, since Cloudflare's edge IP never matches the
  tailnet subnet either. Whether that DNS record should exist at all, and whether other
  `tailnet_only` routes should or shouldn't have public DNS records, is an operator/DNS-console
  question outside this repo's code — and remains so regardless of the current record.
- By the time of this ticket, `monitor`, `adguard`, and `owntracks-ui` all had their own DNS records
  pointed directly at the VPS's Tailscale IP (an operator workaround applied during live debugging,
  before this fix existed — `owntracks-ui`'s record was evidently repointed at some point between
  the original investigation above and this ticket) — this sidesteps the masquerade bug for *that
  specific* hostname/DNS-record combination, but doesn't fix tailnet-facing access in general (a
  route reached via a Cloudflare-proxied or public-IP DNS record over the tailnet path would still
  hit the bug).

## Decision
1. **A PROXY-protocol relay, not host networking for Caddy.** Re-architecting Caddy itself to run
   in `network_mode: host` was considered and rejected: it would fix the same underlying problem,
   but at the cost of losing Docker's embedded DNS resolution for every `reverse_proxy` target
   Caddy proxies to (`conduit:8008` and every other service-name reference across every route)
   — each would need re-plumbing to a stable published port or static IP instead. The relay fixes
   the same problem with one small new component and zero changes to any existing `reverse_proxy`
   target.
2. **A dedicated relay component** (`caddy-relay`, HAProxy in pure TCP mode) binds this VPS's own
   Tailscale IP(s) — queried at deploy time via `tailscale ip`, both v4 and v6 — on port 443,
   accepts the raw connection, and forwards it to a **second, internal-only Caddy listener** with a
   PROXY protocol v2 header carrying the real client IP. Caddy's normal public listener (`:443`,
   unscoped to the VPS's public IP specifically) is completely unmodified: no PROXY-protocol
   wrapper, no new trust surface, provably unchanged behavior for every public-internet and
   Cloudflare-proxied client.
3. **The internal listener's trust boundary is a shared Unix domain socket, not a TCP port.** A
   loopback TCP port (e.g. `:8543`) with an IP `allow`-list was the first design tried; it was found,
   in review, to be a real, confirmed auth-bypass vector: an IP allow-list wide enough to admit the
   relay's own Docker-NAT'd source address (`172.16.0.0/12`, Docker's entire default bridge pool)
   could not distinguish "the relay" from any other host-networked container in this stack (e.g.
   `beszel-agent`, `network_mode: host`) — such a container could reach the same published port and
   forge a PROXY header claiming an arbitrary tailnet source IP, fully bypassing both `mfa_auth` and
   `tailnet_only`. Replaced with a shared, bind-mounted Unix socket directory (`caddy_relay_socket_dir`,
   same pattern as this repo's existing `beszel_socket_dir`): only a container with this exact
   directory mounted (`caddy` and `caddy-relay`, and only those two — enforced by a dedicated test)
   can reach the socket at all, a boundary Docker's own volume-mount scoping enforces rather than an
   IP check. This closes the confirmed, concretely-exploitable vector (an ordinary Docker container
   reaching a published port over the network). It does **not** close a host-level process with
   direct filesystem access to the bind-mounted path — accepted as an out-of-scope residual risk on
   this single-operator personal VPS, where a process already executing directly on the host implies
   the operator's own trusted code or a fully-compromised box either way, a strictly stronger
   attacker than container isolation is designed to defend against.
4. **Both `mfa_auth`'s and `tailnet_only`'s `not remote_ip` matchers were extended to check
   `tailscale_subnet_v6` alongside the existing v4 constant** — a pre-existing, independent v4-only
   gap this investigation surfaced (the constant already existed and was used by the `DOCKER-USER`
   v6 firewall rules, but was never wired into either Caddyfile matcher). Fixed for both matchers
   together, since both share the same underlying "is this a tailnet source" check.

## Consequences
- Neither ADR-0001's nor epic 18's route-type mechanism changed at all — `mfa_auth` and
  `tailnet_only` are exactly the same Caddy snippets, importing the same matcher shape. Only the
  source IP they now see, for tailnet-originated traffic specifically, is correct.
- A new always-running component (`caddy-relay`) exists in the stack, `network_mode: host`, whose
  only job is PROXY-protocol injection — pure TCP passthrough, no TLS termination, no application
  logic of its own.
- Every mfa/tailnet_only-gated route (`wiki`, `dash`, `owntracks-ui`, `monitor`, `adguard`) now
  renders as two separate Caddyfile site blocks for the same hostname: one for the normal public
  listener, one bound to the shared Unix socket for the internal listener. Ungated routes (`auth`,
  `matrix`, `owntracks`) are unaffected and still render as a single block each.
- The two DNS/scope side-findings above (`owntracks-ui`'s public DNS record; other routes' tailnet-
  IP DNS workarounds) remain open operator questions, not resolved by this decision.

## References
- Epic 20 spec (`.scratch/20-tailnet-caddy-access/spec.md`), tickets #01–#02.
- ADR-0001 (source-based MFA) — this decision restores its intent for tailnet-sourced traffic; not
  superseded.
- Epic 18 (`tailnet_only` route type, `beszel_socket_dir` precedent for a shared Unix socket).
- `moby/moby#45629` — external confirmation of the Docker port-publish NAT behavior underlying both
  the original masquerade bug and the rejected loopback-allowlist design's own vulnerability.
