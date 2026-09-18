# 02: ADR, cross-route spot-check, and docs

**What to build:** The decision this epic made (a PROXY-protocol relay for tailnet-facing access, over the rejected alternative of running Caddy in host network mode) is recorded for future reference, and every route this epic's investigation found affected — not just the one that surfaced the bug — is confirmed working over a real Tailscale connection.

**Blocked by:** #01
**Blocks:** None

**Status:** ready-for-agent

- [ ] A new ADR documents the masquerade root cause, the relay/dual-listener decision, the rejected host-networking alternative and why, and the PROXY-protocol trust boundary — cross-referencing ADR-0001 (source-based MFA) as the decision whose intent this epic's fix restores, without superseding or contradicting it
- [ ] Every route this epic's investigation identified as affected (`monitor`, `owntracks-ui`, `adguard`, `wiki`, `dash`) is spot-checked over a real Tailscale connection post-fix, not just the one (`monitor`) that originally surfaced the bug
- [ ] Any operator-facing documentation the new relay component needs (e.g. a README "Manual Post-Deploy Steps" entry, if the relay requires any one-time setup) is added

## Notes

See epic 20 spec, "Further Notes" and "Out of Scope". Two side-findings from this epic's investigation are explicitly *not* this ticket's scope, but should be noted in the ADR so they aren't lost:

- `owntracks-ui.<secret-silverbullet-domain>` currently has a public/Cloudflare-proxied DNS record despite being a `tailnet_only` route, which independently makes it unreachable by anyone via that hostname (Cloudflare's edge IP never matches the tailnet subnet either) — an operator/DNS-console question, not something this epic's code touches.
- Whether that DNS record should exist at all, and whether other `tailnet_only` routes should or shouldn't have public DNS records, is out of scope for this epic entirely.
