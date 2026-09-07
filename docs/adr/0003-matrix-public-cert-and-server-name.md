# ADR-0003: Matrix Serves a Public ACME Certificate; server_name Is matrix.<domain>

## Status
Accepted

## Context
After the epic 12 deploy, Matrix clients could not register against
`https://matrix.<domain>:8448`. Diagnosis (verified from outside the VPS):

1. The SNI routing on the shared `:8448` listener was correct — with
   SNI=`matrix.<domain>`, Caddy proxied to Conduit and the
   `/_matrix/client/versions` endpoint returned a healthy homeserver response.
2. But Caddy presented its **internal-CA certificate**
   (`Caddy Local Authority`) for matrix. Standard Matrix clients (Element et
   al.) refuse private CAs, so the TLS layer failed before any Matrix API
   call, which clients surface as misleading errors ("not a matrix
   homeserver").
3. 8448 is the Matrix **federation** convention port, but this homeserver is
   deliberately non-federated (`allow_federation = false`) — no federation
   traffic will ever traverse it. The only consumers are the operator's own
   clients, which accept any port in the homeserver URL.
4. Separately, `conduit_server_name` was templated from `inventory_hostname`
   (`hermes`), which would have made user IDs `@user:hermes` — decided before
   the first account was ever registered.

## Decision
1. **matrix's gateway route uses `tls_mode: "auto"`** — Caddy obtains a real
   Let's Encrypt certificate for `matrix.<domain>` on the 8448 listener
   (challenge ports 80/443 are open; the DNS record is direct/not proxied).
   The client URL stays `https://matrix.<domain>:8448`.
2. **`conduit_server_name` is set explicitly to `matrix.{{ secrets.silverbullet_domain }}`**
   (was `{{ inventory_hostname }}`), so user IDs read
   `@user:matrix.<domain>`. Changed **before** the first registration:
   Matrix user IDs are permanent, and changing server_name after accounts
   exist orphans them (Conduit's data directory must be wiped on change).
3. The exposure posture changes knowingly: the 8448 port class is already
   public (shared with OwnTracks, whose mobile app needs a publicly-trusted
   cert), so matrix's client API becomes publicly reachable too. Risk is
   accepted because registration is gated by a static registration token and
   federation is disabled. Strict Tailscale-only access with a trusted cert
   would require a dedicated restricted port (DOCKER-USER is port-based and
   cannot filter by hostname on a shared listener) — rejected for now as
   disproportionate.

## Consequences
- Matrix clients register and sync without certificate overrides.
- Matrix's route no longer renders `tls internal`; the gateway render test
  pins the `https://` scheme form and the reduced internal-CA set
  (wiki/dash/auth).
- `conduit_server_name` must never change casually: it is baked into user
  IDs and the Hermes bot identity (`@hermes:<server_name>`). The group_vars
  comment and this ADR record that.
- OwnTracks remains the other SNI-sharer on 8448 and must keep a
  direct (not CDN-proxied) DNS record so ACME issuance and the mobile app
  both work.

## References
- Incident: matrix registration failure after the epic 12 deploy
  (diagnosed via external SNI probes + `caddy adapt`).
- ADR-0001 (source-based MFA), epic 12 #00 (gateway route loop).
