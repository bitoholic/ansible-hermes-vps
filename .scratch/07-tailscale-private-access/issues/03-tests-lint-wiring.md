---
title: Tests + lint wiring for tailscale access
status: ready-for-agent
blocked_by:
  - 01-scaffold-tailscale-role
  - 02-gateway-source-based-mfa
depends_on: [tailscale, gateway]
---

# #03 — Tests + lint wiring for tailscale access

CI-surfacesafe checks that the access model is wired (secrets defined, Caddyfile renders the bypass
matcher). Live ufw/Tailscale behavior is operator-validated on the VPS (needs the host, which CI lacks).

## What to build

- `tests/check-tailscale.sh`: assert `secrets.tailscale_authkey` is defined; static guard that the
  Caddyfile contains the `mfa_auth` matcher and the Tailscale subnet constant; assert the `tailscale`
  role defines the ufw allow rules (80/443 + 22 + Tailscale interface, default-deny).
- Wire `./tests/check-tailscale.sh` into `tests/lint.sh`.

## Acceptance (Definition of Done)

- [ ] `tests/check-tailscale.sh` exits non-zero on any contract violation.
- [ ] Invoked from `tests/lint.sh`; `bash tests/lint.sh` → exit 0.
- [ ] Live `ansible-playbook --check --diff` + from-VPN (no MFA) / from-public (MFA) reachability
      operator-validated on VPS.
