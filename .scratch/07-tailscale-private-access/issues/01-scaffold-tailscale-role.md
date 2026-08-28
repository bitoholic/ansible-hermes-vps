---
title: Scaffold tailscale role (VPN + ufw firewall)
status: ready-for-agent
blocked_by: []
depends_on: []
---

# #01 — Scaffold `tailscale` role (VPN + ufw firewall)

New role that owns VPN access and the host perimeter: installs Tailscale, authenticates via a
reusable auth key from `secrets`, and configures ufw (default-deny inbound; allow `22/tcp`; allow
`80/443`; allow the Tailscale interface). The Tailscale subnet range is recorded in one place
(used by both the Caddy matcher and the ufw allow).

## What to build

- `roles/tailscale/tasks/main.yml`: install the Tailscale package; enable + start the service;
  run `tailscale up --authkey {{ secrets.tailscale_authkey }}`.
- Configure `ufw`: default-deny inbound; allow `22/tcp` (SSH fallback); allow `80/443` (Caddy,
  MFA-gated for public); allow the Tailscale interface. Record the Tailscale subnet constant.
- `secrets.tailscale_authkey` added to the secret manifest / `group_vars/all/secrets.yml`.

## Acceptance (Definition of Done)

- [ ] Tailscale service enabled and logged in (idempotent `tailscale up`).
- [ ] ufw reports default-deny with exactly `22`, `80/443`, and the Tailscale interface allowed.
- [ ] `ansible-playbook --check --diff` asserts `secrets.tailscale_authkey` is defined (single-seam contract).
- [ ] Port 22 is the only *other* public port (SSH already key-only via `ssh_hardening`).
