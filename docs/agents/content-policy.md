# Content policy: placeholders only

This repository may be published as a public export (epic 24). Committed prose — documentation, specs,
ADRs, tickets, commit messages, test fixtures — never names the operator's real domain, hostnames,
tailnet addresses or personal details. Use a fixed placeholder instead, every time:

| Placeholder | Stands for |
| --- | --- |
| `<domain>` | The operator's real domain (e.g. `monitor.<domain>`, `auth.<domain>`) |
| `<domain-dashed>` | The same domain where Tailscale's MagicDNS has already turned its dots into dashes (used inline, once, where that specific mangled form matters — see `.scratch/20-tailnet-caddy-access/issues/01-proxy-protocol-relay.md` for the pattern) |
| `<tailnet-ip>` | A peer device's real tailnet address |
| `<vps-tailnet-ip>` | The VPS's own real tailnet IPv4 address |
| `<vps-tailnet-ipv6>` | The VPS's own real tailnet IPv6 (ULA) address |
| `<vps-public-ip>` | The VPS's real public IP address |

Introduce a new placeholder the same way if none of these fit, rather than writing the real value.

**Not covered by this policy — leave these as they are:**
- The tailnet range's own CIDR notation (`100.64.0.0/10`, Tailscale's ULA prefix `fd7a:115c:a1e0::/48`)
  wherever it names the *range* rather than one address — it is a functional value (`group_vars/all/
  main.yml`'s `tailscale_subnet`, firewall rules, Caddy matchers), not an identifying one.
- A test or render-fixture value that only needs to be *some* syntactically valid address and was never
  the operator's real one (e.g. `tailscale_ip_v4: 100.64.0.1` in a render test) — don't placeholder-ize a
  functional test input; if the audit ever flags one, allowlist it with a reason instead (see below).
- Live-verification notes already using a placeholder, or narrative that doesn't actually name a real
  value in the first place.

**Checking it:** `python3 scripts/public-readiness-audit.py --generic-only --tree-only` (no key needed)
catches a tailnet-range host address or a credential-shaped string in any tracked file — it's wired into
the standard lint run (`tests/lint.sh`). The full audit (`scripts/deploy --script audit`, operator-run,
needs the real secrets) additionally catches the operator's actual domain, username and any
`AUDIT_EXTRA_TERMS` entries, across the tree, full history and commit metadata. See
`docs/public-readiness-audit.md` for what each one scans and how `audit-allowlist.yml` works.

**Optional pre-commit hook.** To catch a violation before it's even committed, add to
`.git/hooks/pre-commit` (not tracked by this repo; create it locally):

```bash
#!/usr/bin/env bash
python3 scripts/public-readiness-audit.py --generic-only --tree-only || exit 1
```

`chmod +x .git/hooks/pre-commit` after creating it. This is optional and local — `tests/lint.sh` already
runs the same check, so nothing is missed by skipping it, but it saves a round-trip for a change that
would fail lint anyway. It runs the generic rules only (no key, and fast — tree-only, not full history),
exactly like the lint-run entry.
