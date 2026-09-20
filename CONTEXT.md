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

### Exit nodes & egress

**Exit node**: A Tailscale node that tailnet clients can route all their internet traffic through, so that traffic egresses from the node instead of from the client's own network. This repo runs Windscribe exit nodes, and optionally a plain exit node on the VPS's own Tailscale node (egress from the VPS's own public IP).
_Avoid_: VPN (too generic), proxy

**Windscribe exit node**: An exit node whose egress is a Windscribe WireGuard tunnel to a chosen city, so sites see a Windscribe IP instead of the VPS's or the client's. One exists per exit location.

**exit location**: One entry in the `exit_nodes` list: a short name plus a Windscribe region (a country) and a city. Adding a location adds one exit-node pair. The Windscribe *server* used within a location is chosen randomly on every tunnel start; the location, not the server, is what the operator selects.
_Avoid_: server, endpoint, region (alone; Windscribe "region" means country)

**exit-node pair**: The tunnel container (gluetun) plus the Tailscale container that shares its network namespace, plus the routing sidecar that repairs the return path; together they expose one Windscribe exit node.

**kill switch**: The guarantee that exit-node traffic is dropped, never sent out of the VPS's own IP, whenever its tunnel is down.

### Boot resilience

**port class**: The access category of a Docker-published port — public, restricted (tailnet only; TCP or UDP), or allowlisted (Syncplay). Classes are enforced in the `DOCKER-USER` chain because published ports bypass UFW.

**boot firewall unit**: The systemd unit that loads the `DOCKER-USER` rules at boot and again whenever Docker restarts. The rules' single source is the port-class variables; Ansible deploys and the unit load the same rendering.
_Avoid_: iptables persistence (that means snapshotting the whole ruleset, which this repo deliberately does not do — Docker owns its own chains)

**reboot drill**: The attended procedure that reboots the VPS and then proves, with the read-only live verification script, that it came back correct without an operator running the playbook.

### Secrets & deployment

**encrypted secrets file**: The SOPS-encrypted dotenv file that holds every value the `secrets` resolver reads from the environment. All values in it are treated as secret — including ones (domain, usernames) that would not be secret in a private repo.

**recipient**: An age public key allowed to decrypt the encrypted secrets file — one per workstation. The **break-glass key** is one extra recipient whose private half lives offline, so losing every workstation does not lock the operator out.

**deploy wrapper**: The single entry point for running Ansible against the VPS. It decrypts the encrypted secrets file into the playbook process's environment only (never to disk), runs the playbook, and applies output redaction.

**output redaction**: Replacing every decrypted value with a mask in everything a command prints, so deployments can be run and observed (including by an agent) without secrets reaching a terminal transcript.

**public-readiness audit**: The repeatable scan of the working tree, full git history, and commit metadata for the operator's identifying values (derived from the decrypted secrets at run time, never listed in the repo) and for credential-shaped strings. It gates publishing any public version of the repository. The encrypted secrets file stays in the private repository and is never part of a public export.
