# Spec: Reboot resilience — the VPS returns to a correct, secure state on its own

> Status: ready-for-agent
> Source: Epic 21 — found while auditing the live VPS after an unrelated DNS question: the host had been up ~23 hours since a reboot with an **empty `DOCKER-USER` chain** on IPv4 and IPv6, and three public-front-door services were not running until someone redeployed six minutes after boot.
> Related: `07-tailscale-private-access` (origin of the firewall role), `12-add-custom-services` #08 (introduced the `DOCKER-USER` port classes and the "not persisted across reboot; restored by playbook run" decision this epic reverses), `20-tailnet-caddy-access` (the `caddy-relay` boot dependency on the Tailscale address), `18-second-wave-custom-services` #05 (host DNS handed to AdGuard). Does not contradict any ADR; records a new one.
> Vocabulary: see `CONTEXT.md` — **port class**, **boot firewall unit**, **reboot drill**. Also used here: "restricted port" (a Docker-published port only tailnet sources may reach), "front door" (Caddy, Authelia, SilverBullet — the public web ingress path).

## Problem Statement

The operator's VPS does not survive a reboot in a correct state. Three separate faults were found on the live host, and each is a normal consequence of a routine reboot (kernel update, provider maintenance, a crash):

1. **The access-control boundary disappears.** Every "tailnet-only" service published by Docker (the wiki's raw port, the Hermes dashboard and API, the Matrix homeserver, the monitoring hub, AdGuard's UI and its DNS) is protected only by rules in the `DOCKER-USER` chain, and Syncplay's IP allowlist lives there too. Those rules exist only in kernel memory. After a reboot Docker recreates the chain empty and nothing refills it until the operator happens to re-run the playbook. On the audited host the chain was empty on both IP families about 23 hours after boot. The ports were, in practice, still unreachable from the internet — but only because of an upstream network filter (probably provider-side) that nothing in this repo manages, documents, or can be relied on to keep.
2. **The public front door stays down.** `caddy`, `authelia` and `silverbullet` declare no restart policy. After the last reboot they did not come back until a manual deploy started them about six minutes later. Until then every public hostname behind them was dark.
3. **Boot-time dependencies were never examined.** The host's own DNS resolver is a container (AdGuard), with no fallback — so after a reboot, and any time that container is unhealthy, the host cannot resolve names. The `caddy-relay` binds the VPS's Tailscale address and needs the Tailscale interface up first. Nothing states, orders, or tests any of this.

The operator can currently repair all of it by re-running the playbook, but only if they notice. A VPS whose security boundary and public availability depend on a human noticing a reboot is not correctly provisioned.

## Solution

After this epic a reboot is uneventful. The `DOCKER-USER` rules are loaded automatically at boot, again whenever Docker restarts, and atomically on every deploy, all from one rendering of the same port-class variables; the system fails closed if they cannot be loaded. Every service that should be running has a restart policy. The host resolves names even when AdGuard is down. Boot-time ordering is deliberate and its convergence is bounded and verified. A documented **reboot drill** plus a read-only live verification script let the operator prove all of it on the real VPS, and an ADR records the decisions. SSH access is never touched by any of this work.

## User Stories

1. As the operator, I want the `DOCKER-USER` rules to be loaded automatically at every boot, so that restricted ports are never exposed just because I forgot to re-run the playbook.
2. As the operator, I want the same rules to be reloaded whenever Docker restarts (daemon restart, Docker package upgrade), so that a Docker restart cannot silently drop my access control.
3. As the operator, I want the boot-time rules to come from the same rendering my deploys use, so that there is exactly one definition of the port classes and the two can never disagree.
4. As the operator, I want a deploy to replace the rules atomically, so that there is never a moment mid-deploy when the chain is half-built or empty.
5. As the operator, I want the rules for IPv4 and IPv6 to be handled identically, so that one family cannot quietly be less protected than the other.
6. As the operator, I want the system to fail closed — Docker-published services must not come up if the firewall rules could not be loaded — so that a broken ruleset produces an outage I notice instead of an exposure I don't.
7. As the operator, I want a rules-loading failure to be visible in the service manager and journal, so that I can see and diagnose it.
8. As the operator, I want SSH access to be independent of every mechanism in this epic, so that no bug in Docker, the firewall unit, or a restart policy can lock me out of the box.
9. As the operator, I want the firewall unit to touch only the `DOCKER-USER` chain and never UFW's rules, the INPUT chain, or sshd, so that its blast radius is exactly the published-port classes.
10. As the operator, I want the exposure window between Docker starting and the rules being live to be as short as the platform allows, measured, and documented, so that I know what "boot-safe" actually means.
11. As the operator, I want that window closed entirely if Docker preserves a pre-existing chain, so that no published port is ever reachable before its rule exists.
12. As the operator, I want to know empirically how Docker treats a `DOCKER-USER` chain that already exists when the daemon starts or restarts, so that the design rests on tested behavior rather than assumption.
13. As the operator, I want that experiment done in a disposable environment, never on the production VPS, so that finding the answer cannot cost me the box.
14. As the operator, I want `caddy`, `authelia` and `silverbullet` to restart automatically after a reboot or crash, so that the public front door comes back without me.
15. As the operator, I want every service in the stack to have an explicit restart policy (or an explicit, documented exemption), so that a new service can't be added and forgotten the way these three were.
16. As the operator, I want the check for restart policies to run in the standard test suite, so that the omission cannot come back unnoticed.
17. As the operator, I want each service to tolerate its dependencies arriving late after a boot, so that the container `depends_on` (which only orders `compose up`) is not what I'm silently relying on.
18. As the operator, I want Docker ordered after the Tailscale daemon at boot, so that the `caddy-relay` usually finds its Tailscale address on the first try.
19. As the operator, I want a Tailscale outage to be unable to block Docker from starting, so that ordering never becomes a hard dependency that trades one outage for another.
20. As the operator, I want `caddy-relay` to recover on its own if the Tailscale address wasn't ready at first start, within a documented bound, so that tailnet access to the gated routes returns without intervention.
21. As the operator, I want the host's own name resolution (package updates, the Tailscale daemon, image pulls) to keep working when the AdGuard container is stopped or unhealthy, so that AdGuard can never take the host itself offline.
22. As the operator, I want AdGuard to remain the host's primary resolver when it is up, so that the host's lookups still benefit from filtering.
23. As the operator, I want the host resolver's fallback to be verified by stopping AdGuard and resolving a name, so that the safety net is proven, not assumed.
24. As the operator, I want an audit of everything else this playbook sets up in runtime-only state, so that I don't discover a fourth reboot fault next time.
25. As the operator, I want every gap that audit finds either fixed or explicitly recorded as accepted, so that "whatever else needs to be in place" has a definite answer.
26. As the operator, I want a documented reboot drill with a pre-flight checklist (console access confirmed, an alternate tailnet path to the box, a baseline captured), so that rebooting the production VPS is a rehearsed procedure and not an act of faith.
27. As the operator, I want a read-only live verification script that checks the rules, the containers, the units, DNS and the public and tailnet paths, so that I can prove the VPS is correct after any reboot or any time I doubt it.
28. As the operator, I want that script to report "inconclusive" instead of "pass" when my vantage point makes an outside-in probe meaningless (for example when my workstation's traffic goes through another VPN), so that it never gives false confidence.
29. As the operator, I want the reboot drill's results recorded, so that the epic's acceptance is evidence and not a claim.
30. As the operator, I want an ADR recording persistence-by-own-unit versus snapshotting the whole ruleset, the fail-closed choice, and the measured boot window, so that future changes don't undo it for a reason I've forgotten.
31. As a future maintainer, I want the existing idempotency guarantee — the ruleset is byte-identical across repeated runs — preserved under the new mechanism, so that redeploys stay boring.
32. As a future maintainer, I want the shared port-class variables and their explanatory comments to remain the single place to add a new restricted or public port, so that adding a service is still one edit.
33. As a future maintainer, I want the exit nodes added by epic 23 to inherit this epic's restart-policy convention, so that a later epic doesn't reintroduce the fault.

## Implementation Decisions

- **One source, one rendering.** The firewall rules are generated from the existing port-class variables (public, restricted TCP, restricted UDP, the Syncplay allowlist, the tailnet subnets). The imperative per-rule tasks that build the chain today are replaced by rendering a ruleset for each IP family. The same rendered artifact is used by Ansible deploys and by the boot firewall unit — there is no second, hand-maintained copy.
- **Atomic application.** Rules are loaded in one transaction that resets only the `DOCKER-USER` chain and installs the new contents together (restore in no-flush mode scoped to that chain), replacing today's flush-then-append sequence, which leaves the chain briefly empty on every deploy. Docker's own chains are never touched.
- **Own unit, not ruleset snapshotting.** The mechanism is a dedicated systemd oneshot unit owned by the role that already owns the firewall. It is enabled at boot and wired to Docker's lifecycle so a Docker restart reapplies it. **Rejected:** `netfilter-persistent`/`iptables-persistent`, because it snapshots the entire ruleset including Docker-managed chains — the snapshot goes stale and fights Docker's own recreation of those chains on start. **Rejected:** the status quo (rebuild only when the playbook runs).
- **Required properties, mechanism decided by a spike.** The exact unit wiring (before Docker, after Docker, a drop-in on Docker's own unit, or a combination) is decided by ticket #01's disposable-environment experiment on how Docker treats a pre-existing `DOCKER-USER` chain on daemon start and restart. Whatever wiring wins must satisfy: idempotent; atomic; applied at boot and on every Docker restart; fail closed (Docker-published services do not start if the rules failed to load); populated before Docker starts containers if and only if Docker preserves the chain, otherwise reapplied immediately after daemon readiness with the resulting window measured and documented.
- **Fail closed, with SSH out of the blast radius.** A failed rules load must stop Docker-published services from starting rather than start them unprotected. This cannot affect SSH: sshd and UFW are independent of Docker and of this unit, and the unit manipulates only the `DOCKER-USER` chain.
- **Restart policies.** Every long-running service fragment declares `unless-stopped`. The three currently without one (`caddy`, `authelia`, `silverbullet`) gain it. A static guard asserts that every enabled service fragment declares a restart policy unless it is on an explicit, reasoned exemption list (initially empty).
- **Boot ordering is best-effort ordering, not a hard dependency.** Docker is ordered after the Tailscale daemon (ordering only — no `Requires`/`Wants`), so a Tailscale failure cannot block Docker. Services rely on restart policies, not `depends_on`, to converge after a boot; `depends_on` only orders `compose up`. The `caddy-relay`, which binds the Tailscale address, is expected to restart until that address exists and then hold; the reboot drill asserts convergence within a stated bound.
- **Host DNS independence.** The host resolver keeps AdGuard as its primary (so host lookups stay filtered when it is up) but gains a public fallback resolver so that name resolution never depends on a container being healthy. Verified by stopping AdGuard and resolving a name from the host.
- **Runtime-state audit.** A short, written audit of everything the playbook configures that lives only in memory or depends on service start order (sysctls, interface-bound listeners, facts rendered from runtime queries such as the Tailscale address, mounts, resolver state). Each finding is fixed or recorded as accepted in the ADR.
- **Reboot drill and live verification.** A rehearsed procedure with a pre-flight (provider console access verified, an alternate tailnet path to the host verified, a baseline captured) and a post-boot check. The check is a read-only script run from the operator's workstation. It verifies: the ruleset matches the rendering for both families; the boot unit is enabled and active; every expected container is running; restart policies are as declared; Docker, Tailscale and UFW are enabled; DNS resolves with AdGuard up and with it stopped; the public ingress ports answer; the tailnet-gated routes answer from the tailnet. An outside-in probe of the restricted ports is included but reports *inconclusive* when the operator's route to the VPS is not a plain internet path.
- **Scope of the firewall role.** The role remains the single owner of the perimeter (UFW and `DOCKER-USER`). No change to UFW rules, SSH, or the tailnet interface allow.
- **ADR.** A new ADR (next available number) records the decisions above, the measured boot window, the audit findings, and the rejected alternatives.

## Testing Decisions

- **What makes a good test here:** assert the *observable classification* — given a set of port-class inputs, which ports end up public, tailnet-only (per protocol and family) or allowlisted — and observable service properties (every service restarts; the unit is enabled and ordered as decided). Do not assert on incidental text, rule order beyond what semantics require, or Ansible task structure.
- **Modules/seams (existing seams preferred):**
  - The firewall role's existing static-plus-live check (`tests/check-tailscale.sh`, including its "ruleset identical across runs" live idempotency assertion) is extended to the new rendering and unit; the idempotency assertion is kept and now also asserts the *rendered artifact* is byte-stable.
  - The consolidated-compose render tests (`tests/test_docker_compose.yml` via `tests/check-docker-compose-render.sh`) gain the restart-policy guard across every fragment.
  - The host resolver drop-in is asserted where the AdGuard DNS handover is already asserted (`tests/check-adguard-dns.sh`).
  - One new operator-facing artifact: the read-only live verification script. It is a tool, not a CI test.
- **What cannot be tested statically, and is operator-validated instead:** that the rules survive a real reboot and a Docker restart, the measured boot window, and the restart/convergence behavior on the real VPS. This follows the repo's established practice for anything needing live network state (epic 18's DNS handover, epic 19's DNS-01 issuance, epic 20's relay): a STATIC-only CI guard with an explicit comment about what it does not prove, plus a documented live check. The Docker-behavior experiment runs in a disposable environment, and its findings are recorded, not re-run in CI.
- **Prior art:** `tests/check-tailscale.sh` (live idempotency), `tests/check-tailnet-caddy-access.sh` (framing of a static guard with an honest "what this cannot verify" header), `tests/check-docker-compose-render.sh`, `tests/check-adguard-dns.sh`.

## Out of Scope

- Managing, documenting, or removing the upstream network filter that currently masks the exposure (a provider-console concern, not this repo's).
- Caddy's `:443` being published on the VPS's IPv4 address only (so direct-to-origin IPv6 on 443 does not answer) — a separate finding recorded for its own triage.
- AdGuard seeing every query as coming from the Docker bridge gateway instead of the real client (a source-NAT effect, unrelated to boot).
- The Syncplay allowlist still holding its placeholder address.
- Any change to unattended-upgrades' no-auto-reboot policy, or orchestrating reboots.
- Migrating Docker to its nftables backend.
- UFW rules, SSH configuration, and the tailnet interface allow (unchanged and untouched).
- Boot behavior of the Windscribe exit nodes — epic 23 owns it, consuming this epic's restart-policy convention.

## Further Notes

- **How it was found and the interim state.** The gap was discovered on the live VPS during an unrelated investigation. As an interim measure the rules were rebuilt once by hand using a throwaway playbook sliced from the firewall role's own tasks; they are correct now but will vanish at the next reboot. The role's own comment ("not persisted across reboot; the deployment model restores them by playbook run") documents the decision this epic reverses.
- **Why the exposure was masked.** Probing the restricted ports from an ordinary internet path while the chain was empty still timed out, and the NAT counters showed the packets never reached the host — so an upstream filter was dropping them. That is luck, not design, and the ADR should say so.
- **Ordering across epics.** This epic should land first: it is the smallest, it closes a live gap, and epic 23 builds on its restart-policy convention.
