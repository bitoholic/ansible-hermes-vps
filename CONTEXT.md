# Hermes VPS

Personal "second brain" + agent stack on a Debian/Ubuntu VPS: Ansible roles provision a Docker Compose stack (Hermes agent, SilverBullet wiki, Caddy gateway, Authelia, backup) reached by the operator over a private VPN and/or the public internet.

## Language

### Hermes agent & transports

**IM transport**: A channel the Hermes agent uses to exchange messages with the operator (Signal, Matrix, Telegram, …). The agent (`nousresearch/hermes-agent`) supports several natively; this repo feeds each one a block of env vars. There is no pluggable "transports" list in-repo — each transport is wired as a parallel copy of the Signal pattern.
_Avoid_: connector, bridge (those imply an extra component; the agent is itself the Signal/Matrix client)

**Matrix homeserver**: A Matrix server that hosts accounts and rooms. This repo runs **Conduit** as the personal homeserver.
_Avoid_: matrix server (ambiguous with the client app)

**Conduit**: The specific Matrix homeserver image deployed here (Rust, single-binary, private).
_Avoid_: matrix, homeserver (use Matrix homeserver for the concept)

**Hermes bot user**: The agent's Matrix account (`@hermes:<homeserver>`) that receives the operator's DMs and replies. Provisioned automatically via Conduit's registration shared secret.
_Avoid_: bot, matrix bot

**personal homeserver**: A Matrix homeserver run for one operator: non-federated, not publicly registered, registration open only to the operator. The Matrix traffic stays on the private network.

### Network access

**Tailscale**: A private overlay/VPN network that gives the operator authenticated, encrypted access to the VPS and its internal services (including the Matrix homeserver and Caddy-routed apps).
_Avoid_: VPN (too generic; Tailscale is the choice here)

**public ingress**: The Caddy reverse proxy listening on 80/443 that exposes internal services (wiki, dashboard) to the internet, fronted by Authelia MFA.
_Avoid_: gateway (that's the role); reverse proxy

**access model**: How the operator reaches a service — over Tailscale (no auth, already gated by the VPN) or over the public internet (Authelia MFA required).

**source-based MFA**: Caddy applies Authelia MFA only to requests whose source IP is *not* in the Tailscale subnet; Tailscale clients bypass it. See ADR-0001.
