# Ticket #08: DOCKER-USER firewall rules + OwnTracks deployment wiring

**Blocked by:** #06
**Blocks:** epic 12 completion

## Part A: DOCKER-USER firewall rules (published ports bypass UFW)

### Problem (verified in review of #06)

Docker routes host-published port traffic through the nat PREROUTING DNAT chain; packets
never traverse UFW's INPUT chain, and Docker's own FORWARD rules ACCEPT them. Per Docker's
official docs, UFW config is "effectively ignored" for published ports. The repo has zero
DOCKER-USER handling (grep-verified).

Consequences today:

| Host port | Service | Intended access | Actual (pre-fix) |
|---|---|---|---|
| 80/443/8448 | caddy | public (UFW rate-limited) | open — UFW rate-limiting illusory |
| 8999 | syncplay | IP allowlist (#06) | fully open — allowlist never matches |
| 3000 | silverbullet | Tailscale-only | internet-reachable |
| 8008 | conduit | Tailscale-only (its own comment claims "no public exposure") | internet-reachable |
| 8642/9119 | hermes-agent | Tailscale-only | internet-reachable |

The tailscale role's UFW perimeter (default-deny + Tailscale-interface allow) only governs
non-published traffic. This is a pre-existing gap epic 12's #06 surfaced.

### Design

Manage the `DOCKER-USER` chain in the tailscale role (single firewall owner). Packets arrive
post-DNAT, so matching the ORIGINAL destination port requires conntrack:
`-m conntrack --ctorigdstport <port>` (Docker-documented caveat).

1. Ensure `DOCKER-USER` chain exists and is jumped from FORWARD (Docker creates it, but
   create idempotently — account for role ordering vs the docker role).
2. ACCEPT established/related.
3. Syncplay 8999 (`--ctorigdstport 8999`): ACCEPT from each IP in `syncplay_allowed_ips`,
   DROP the rest — makes #06's "IP-restricted public access" model real.
4. Tailscale-only ports (3000, 8008, 8642, 9119 — consider a
   `docker_published_restricted_ports` var instead of hardcoding): ACCEPT from the Tailscale
   subnet (the constant shared with the Caddyfile MFA bypass), DROP the rest.
5. Public-by-design ports (80, 443, 8448): ACCEPT (documents intent; restoring rate-limiting
   at the DOCKER-USER layer is optional scope — the epic's access models don't require it).
6. Final RETURN so Docker-internal and other forwarding is untouched.

Implementation notes:
- `ansible.builtin.iptables`, `chain: DOCKER-USER`; make the ruleset declarative and
  idempotent across playbook re-runs (flush + re-add or explicit rule set).
- Decide IPv4-only vs ip6tables parity; at minimum document the choice.
- Rules must survive reboot or be restored by playbook run (deployment model = playbook).

### Acceptance criteria (Part A)

- DOCKER-USER rules implement the port matrix above (allowlist / tailscale-only / public)
- Syncplay 8999 reachable only from `syncplay_allowed_ips` (conntrack `--ctorigdstport` match)
- 3000/8008/8642/9119 reachable only from the Tailscale subnet
- 80/443/8448 reachable from anywhere
- Idempotent: repeated playbook runs don't duplicate or clobber rules
- The firewall check (extend `tests/check-tailscale.sh` or `check-custom-services.sh`)
  asserts the DOCKER-USER contract
- `group_vars/all/main.yml` syncplay comment updated: allowlist takes effect at the
  DOCKER-USER layer (UFW INPUT rules don't govern published ports)

## Part B: OwnTracks deployment wiring

The owntracks role (created in #02, htpasswd generation) was deliberately left out of
site.yml in #02 (out of that ticket's scope). Wire it in here so the htpasswd file actually
deploys.

1. Add `- role: owntracks` to `site.yml` with `tags: [owntracks]` (skip-tags guard pattern),
   placed before the docker role so the htpasswd file exists before the compose stack
   renders/starts (the owntracks container bind-mounts it read-only).
2. Update the role skip-tags guard in `tests/lint.sh` to include `owntracks` in its role list.
3. The role needs `docker_compose_dir` (its htpasswd path derives from it) — verify the var
   is available at that point in the run (docker role defaults are not loaded before docker
   runs; either define the path from a group_vars-level var or add a role default that does
   not depend on docker's defaults being loaded).

### Acceptance criteria (Part B)

- `site.yml` runs the owntracks role with `tags: [owntracks]`
- htpasswd file deployed at the path the compose fragment bind-mounts
- `tests/lint.sh` role skip-tags guard covers owntracks
- Full `tests/lint.sh` passes

## Notes

- The per-port groups should ideally derive from the service fragments (single source of
  truth) rather than a second hardcoded list in the firewall role — decide during
  implementation whether to introduce a published-ports var consumed by both.
- Reviewer-suggested alternative (fold DOCKER-USER into #07) was rejected: a security
  control doesn't belong in a test-wiring ticket. Full-surface scope chosen over
  syncplay-only because the Tailscale-only exposure (3000/8008/8642/9119) is the same
  root cause.
- OwnTracks role wiring was confirmed by the operator to belong in this ticket (review
  round of #07).
