# Caddy built with the Cloudflare DNS plugin (epic 19, #01) — needed for
# DNS-01 ACME challenges (epic 19, #02), which don't require inbound
# reachability to the origin and so keep working once matrix/owntracks' DNS
# records are Cloudflare-proxied. Built via Caddy's own official xcaddy
# builder mechanism, not a third-party pre-built plugin image — Caddy is this
# stack's single TLS-termination point for every service, so the
# trust/blast-radius calculus for a third-party build pipeline is materially
# different here than for any individual service's own image (grilled
# decision, epic 19 spec). The plugin is compiled in here but unused until
# ticket #02 wires it into the Caddyfile — zero behavior change from this
# ticket alone.
#
# Version pinned explicitly (matches the stock image's prior pin) in both
# stages so a plugin build is reproducible and doesn't silently drift on
# rebuild — no floating `latest` tag anywhere in this file.
FROM caddy:2.8.4-builder AS builder

RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2.8.4

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
