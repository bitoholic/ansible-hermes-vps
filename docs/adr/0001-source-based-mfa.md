# Source-based MFA: Tailscale clients bypass Authelia, public clients require it

The operator wants both conveniences at once: reach services over the Tailscale VPN with no extra
auth (the VPN already authenticates and encrypts), and reach the same services over the public
internet with Authelia MFA. We keep the `authelia` role and the Caddy `mfa_auth` snippet, but wrap
it in a Caddy matcher that skips Tailscale/VPN source IPs and applies to everything else. Public
ports 80/443 stay open and are MFA-gated; port 22 (SSH, key-only) is the only other public port.

**Consequences**: the Caddyfile now encodes a network-topology assumption (the Tailscale subnet
range); if that range changes, the bypass matcher must be updated or VPN clients start hitting MFA.
Conduit (the Matrix homeserver) is intentionally *not* published — it is reached only over Tailscale.
