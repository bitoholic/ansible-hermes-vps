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
# Version pinned explicitly in both stages so a plugin build is reproducible
# and doesn't silently drift on rebuild — no floating `latest` tag anywhere in
# this file. NOT pinned to 2.8.4 (the stock image's original tag, epic 19
# #01's first choice) — bumped to 2.11.4 after a real deploy to the live VPS
# (epic 19 bugfix) hit a genuine upstream incompatibility: caddy-dns/cloudflare
# (every tagged release, not just latest) requires certmagic v0.23.0+ and
# go.uber.org/zap/exp v0.3.0, both of which changed APIs that caddy 2.8.4's own
# core code (context.go, and certmagic's own acmeclient.go at the version 2.8.4
# pins) was written against — the two can no longer compile together at all via
# `xcaddy build`, and no combination of `--replace` pins resolves it (tried
# forcing zap/exp and certmagic back down individually; each fix just moved the
# incompatibility to a different file, since caddy-dns/cloudflare's `libdns`
# requirement also moved on to the v1.x rewrite in the same window). 2.11.4 is
# the latest stable release whose own go.mod already requires certmagic
# v0.25.3 / zap-exp v0.3.0 / libdns v1.1.1 — all compatible with the plugin's
# requirements — so the build resolves cleanly with no `--replace` overrides
# needed. Verified by an actual `xcaddy build` against the real
# `caddy:2.11.4-builder` image (not just Dockerfile syntax): it compiles clean,
# and the resulting binary's `list-modules` includes `dns.providers.cloudflare`.
# caddy.listeners.proxy_protocol (epic 20's internal, loopback-only listener
# — see roles/gateway/templates/Caddyfile.j2's own comment for the full
# root-cause and security-boundary rationale) needs NO Dockerfile change at
# all: verified directly (`caddy list-modules` against the real, unmodified
# `caddy:2.11.4` image) that this module already ships in stock Caddy as of
# this pinned version — it is not a third-party plugin here. A first attempt
# at compiling in github.com/mastercactapus/caddy2-proxyprotocol via xcaddy
# panicked at runtime with "module already registered: caddy.listeners.
# proxy_protocol", which is what surfaced this — Caddy adopted native
# PROXY-protocol support as a built-in module at some point before 2.11.4,
# after the third-party module (and Caddy's own docs page describing it as
# non-standard) were written.
FROM caddy:2.11.4-builder AS builder

RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2.11.4

# Confirmed harmless today (verified in review against the real caddy:2.11.4
# image): this COPY overwrites the stock binary without re-applying
# setcap cap_net_bind_service, which the stock image sets so Caddy can bind
# privileged ports (80/443) as a non-root user. Not an issue here because
# nothing in this stack's compose fragments adds a USER directive — Caddy
# still runs as root. Flagging so a future change adding one doesn't
# silently break port binding: re-run setcap on the copied binary if that
# ever happens.
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
