# Spec: Tailscale private access + public MFA

> Status: ready-for-agent
> Source: Operator request to add a VPN access path and harden the public perimeter
> Related: `06-matrix-transport` (Conduit reached over Tailscale), `CONTEXT.md` (Tailscale, public ingress, access model, source-based MFA), `docs/adr/0001-source-based-mfa.md`
> Vocabulary: see `CONTEXT.md`.

## Problem Statement

The operator wants the best of both access models: reach the VPS services over the **Tailscale VPN with no extra auth** (the VPN already authenticates and encrypts), and still reach the same services over the **public internet with Authelia MFA**. Today there is no VPN path and no host firewall; the public Caddy ingress is MFA-gated but the operator must authenticate even from a trusted network. The operator also wants the perimeter locked down so that, if Tailscale is ever down, they can still SSH in (port 22) but nothing else is openly reachable.

## Solution

Add a new `tailscale` role that installs Tailscale (authenticating via a reusable auth key from `secrets`) and owns the host firewall (ufw): default-deny inbound, allow `22/tcp` (SSH fallback, already key-only via `ssh_hardening`), allow `80/443` (served by Caddy, MFA-gated for public clients). Keep the `authelia` role, but modify the `gateway` role so the Caddyfile `mfa_auth` snippet is wrapped in a **source-IP matcher** that skips the Tailscale subnet and applies Authelia to everything else. Result: VPN → direct; public → MFA. Port 22 is the only other public port. (This reverses an earlier设想 to retire Authelia; ADR-0001 records the source-based-MFA decision.)

## User Stories

1. As an operator, I want Tailscale installed and logged in on the VPS, so that I have a private encrypted network to the box.
2. As an operator, I want Tailscale to authenticate non-interactively on provisioning, so that `ansible-playbook site.yml` brings up the VPN without me pasting a command.
3. As an operator, I want to reach the wiki and Hermes dashboard over Tailscale without typing a password, so that trusted-network access is frictionless.
4. As an operator, I want to reach the same services over the public internet and be challenged by Authelia MFA, so that the open internet still requires a second factor.
5. As an operator, I want a host firewall that denies all inbound traffic except what I explicitly allow, so the perimeter is locked down.
6. As an operator, I want port 22 (SSH) open as a fallback, so I can get in if Tailscale is down.
7. As an operator, I want SSH to remain key-only (via `ssh_hardening`), so the 22 fallback isn't a password brute-force target.
8. As a reviewer, I want `tailscale` to be a single-seam role that owns VPN + firewall, so "who owns access?" has one answer.
9. As a developer, I want the Caddy `mfa_auth` to bypass Tailscale source IPs, so VPN users aren't double-authenticated.
10. As a developer, I want `authelia` kept as-is, so we don't throw away the MFA layer we already have.
11. As an operator, I want the public 80/443 to stay open (MFA-gated) rather than firewalled shut, so I can reach services from anywhere with MFA.
12. As a developer, I want the Tailscale subnet encoded in one place (the Caddy matcher / firewall allow), so a subnet change is a single edit.

## Implementation Decisions

- **New `tailscale` role** — the sole owner of VPN + perimeter: installs the Tailscale package, enables the service, and runs `tailscale up --authkey {{ secrets.tailscale_authkey }}`. It also configures **ufw**: default-deny inbound; allow `22/tcp`; allow `80/443` (Caddy); allow the Tailscale interface. (Conduit's internal port is not published; it is reached over Tailscale's routing to the host's internal address.)
- **`secrets.tailscale_authkey`** added to the secret manifest / `group_vars/all/secrets.yml` (epic-01 single-seam contract: read from env).
- **Keep `authelia`**; only the `gateway` role changes. The Caddyfile `mfa_auth` (Authelia forward-auth) snippet is wrapped in a matcher such as `match / { not remote_ip <tailscale-subnet> }` so Authelia applies to non-Tailscale clients and is skipped for Tailscale clients. Existing `mfa: true` routes keep working; the snippet just gains the bypass.
- **SSH fallback**: `22/tcp` allowed in ufw; `ssh_hardening` already enforces key-only auth, so the fallback is not a password target. No change to `ssh_hardening`.
- **Public ingress stays**: `80/443` remain open and Caddy-served; Authelia is the gate for public clients (per ADR-0001).
- The Tailscale subnet range is recorded once (used by both the Caddy matcher and the ufw allow) to satisfy user story #12.

## Testing Decisions

- **What makes a good test**: assert external behavior — after `tailscale` runs, the service is enabled and ufw reports the expected allow/deny rules; after `gateway` runs, the Caddyfile renders `mfa_auth` inside the source-IP matcher. Do not assert on Tailscale daemon internals.
- **Modules tested**: `tailscale` (idempotent enable + ufw rules) and `gateway` (Caddyfile renders the bypass matcher). Prior art: the repo's `--check --diff` dry-run + top-level `assert` pre-flight (epic 04/05) — assert `secrets.tailscale_authkey` is defined before applying; a static lint guard can assert the Caddyfile contains the `mfa_auth` matcher and the Tailscale subnet constant.
- **Operator validation**: a live `ansible-playbook --check --diff` plus a from-VPN (no MFA) and from-public (MFA prompt) reachability check are validated on the VPS (Tailscale + ufw need the host, which CI lacks).

## Out of Scope

- **Removing `authelia`** — explicitly kept (reverses an earlier idea; ADR-0001).
- **Publishing Conduit publicly** — Conduit remains Tailscale-only (epic `06`).
- **Changing SSH config** beyond what `ssh_hardening` already enforces.
- **Full zero-trust / device posture checks** beyond Tailscale's built-in auth.

## Further Notes

- ADR-0001 ("Source-based MFA: Tailscale clients bypass Authelia; public clients require it") records the trade-off: VPN convenience vs. one MFA gate for the open internet. The Caddyfile now encodes a network-topology assumption (Tailscale subnet); if that range changes, the matcher + ufw allow must be updated together.
- Tailscale reaches its DERP relays outbound, so no inbound port beyond 22 is required for the VPN to function.

## Tickets

Vertical slices under `.scratch/07-tailscale-private-access/issues/` (blockers-first):

- **#01** `01-scaffold-tailscale-role.md` — new `tailscale` role: install + `tailscale up --authkey` (from `secrets`) + ufw (default-deny; allow 22, 80/443, Tailscale interface); Tailscale subnet recorded once.
- **#02** `02-gateway-source-based-mfa.md` — `gateway` Caddyfile `mfa_auth` wrapped in a Tailscale-subnet bypass matcher; `authelia` unchanged (ADR-0001). *Blocked by #01.*
- **#03** `03-tests-lint-wiring.md` — `tests/check-tailscale.sh` (secret assert + Caddyfile matcher guard + ufw rules) wired into `lint.sh`; operator-validated on VPS. *Blocked by #01–#02.*
