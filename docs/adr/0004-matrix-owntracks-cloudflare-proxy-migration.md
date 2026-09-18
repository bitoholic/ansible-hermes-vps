# ADR-0004: Matrix/OwnTracks Move to Port 8443 with DNS-01, Enabling Cloudflare Proxying

## Status
Accepted. Supersedes [ADR-0003](0003-matrix-public-cert-and-server-name.md)'s port choice and
DNS-record-exposure decision (its `server_name`/registration-token decisions are unaffected and
still stand).

## Context
ADR-0003 put matrix's public route on the `:8448` SNI-shared listener with a real ACME
certificate, and accepted a grey-clouded (DNS-only, not Cloudflare-proxied) DNS record for both
matrix and OwnTracks (they share the one listener) as a necessary consequence: Caddy's automatic
HTTPS obtains that certificate via a challenge (HTTP-01/TLS-ALPN-01) that requires the ACME
validation traffic to reach the origin directly, which a Cloudflare-proxied record would
intercept.

Once the rest of the public stack (`wiki`, `dash`, `auth`, `syncplay`) was stable on
Cloudflare-proxied records, this became the one visible inconsistency: matrix and OwnTracks were
the only two public hosts with their origin IP directly exposed and without Cloudflare's edge
protection. Investigating a fix surfaced a **second, independent blocker** ADR-0003 didn't call
out: Cloudflare's standard proxy plans only forward a fixed allowlist of ports for proxied
HTTP/HTTPS traffic. Port 8448 is not on that list; port 8443 is. Solving the certificate-issuance
problem alone would not have been enough — a proxied record on `:8448` still would not route
traffic to the origin at all.

## Decision
1. **Move the shared SNI listener from `:8448` to `:8443`** for both the `matrix` and `owntracks`
   (recorder) gateway routes — a value change to two already-schema-conformant route entries
   (`port`), not a schema change. Every other field on both routes (`mfa: false`,
   `tls_mode: "auto"`, OwnTracks' `basic_auth_user`/`hash`) is unchanged.
2. **Switch certificate issuance for exactly these two routes from HTTP-01/TLS-ALPN-01 to
   DNS-01**, authenticated via a new `cloudflare_api_token` secret (`Zone:DNS:Edit` scope only).
   DNS-01 proves domain ownership via a DNS TXT record published through the Cloudflare API,
   needing zero inbound reachability — it keeps working once the DNS record is proxied, and (as
   a side benefit) can be verified working *before* the record is ever flipped, since DNS-01
   doesn't care about the record's current proxy status. Scoped to exactly the `matrix`/
   `owntracks` Caddyfile blocks via a `(dns01_tls)` named snippet imported by those two routes
   only — no global default-issuer change, no new gateway-route schema field (two live cases
   don't justify one).
3. **Caddy is built from a local Dockerfile** using Caddy's own official `xcaddy` builder
   mechanism (`caddy:<pinned-version>-builder` → `xcaddy build --with github.com/caddy-dns/cloudflare`
   → copied into a matching `caddy:<pinned-version>` runtime stage), mirroring this repo's
   existing `hermes-agent` local-Dockerfile pattern, instead of a third-party pre-built plugin
   image — grilled explicitly: Caddy is this stack's single TLS-termination point for *every*
   service, so the trust/blast-radius calculus for an external build pipeline is materially
   different here than for any individual service's own image.
4. **Verification precedes cutover.** The port move, DNS-01 switch, and custom Caddy build are
   deployed and a real Let's Encrypt certificate confirmed obtained and served on `:8443` for
   both hosts *while their DNS records are still grey-clouded* — only then does the operator
   manually flip both records to Proxied in the Cloudflare dashboard. This repo has no
   DNS-record-management automation (no Terraform/Cloudflare-API-managed zone); the flip is,
   and remains, a manual external-console step, the same category as obtaining
   `TAILSCALE_AUTHKEY`.

## Consequences
- Matrix and OwnTracks clients need a one-time manual update to their configured server port
  (`:8448` → `:8443`); Ansible cannot push this client-side change.
- Once the DNS records are flipped, matrix and OwnTracks origin IPs are hidden behind
  Cloudflare's edge, consistent with `wiki`/`dash`/`auth`/`syncplay`.
- `wiki`/`dash`/`auth`/`syncplay`'s routes and epic 18's `tailnet_only` routes (OwnTracks
  frontend, Beszel hub, AdGuard admin UI — `tls internal`, no ACME, no public DNS record) are
  untouched and unaffected by this decision.
- Caddy's image is now built (not pulled) from `roles/gateway/files/Dockerfile`, adding a build
  step to every deploy that touches the `caddy` service; the Caddy version is pinned explicitly
  in both build stages so a plugin rebuild is reproducible.
- **Follow-up, not enforced by this decision**: once matrix/owntracks serve a real trusted
  Let's Encrypt certificate, Cloudflare's "Full (strict)" SSL/TLS encryption mode becomes viable
  for the zone (currently "Full", which tolerates a self-signed/mismatched origin cert). Changing
  it is a manual Cloudflare-dashboard action the operator can make independently at any point
  after cutover — left as an operator option, not implemented or enforced here.
- ADR-0003's `server_name`/registration-token decisions (matrix user IDs read
  `@user:matrix.<domain>`; registration gated by a static token) are unaffected and still stand;
  only its port choice and "DNS record must stay direct/unproxied" conclusion are superseded.

## References
- Epic 19 spec (`.scratch/19-cloudflare-proxied-ingress/spec.md`), tickets #01-#03.
- ADR-0003 (matrix's public ACME cert and `server_name`) — superseded in part by this ADR.
- Epic 12 (origin of the `:8448` SNI-sharing decision between matrix and owntracks); epic 13
  (gateway route schema's `port`/`tls_mode` fields, reused here with no schema change).
