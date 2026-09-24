# ADR-0006: Boot-Time Firewall Persistence, Fail-Closed Docker Coupling, and Single-Owner Host DNS

## Status
Accepted. Validated by the attended reboot drill of 2026-09-24 (epic 21 ticket #06, three reboots): both staged
switches — the fail-closed coupling and the host-DNS ownership change — were enabled by the drill and are now the
defaults; the measured values are below. Reverses the "not persisted across reboot; restored by
playbook run" decision recorded when epic 12 (#08) introduced the `DOCKER-USER` port classes. Does not
contradict any earlier ADR: [ADR-0005](0005-tailnet-proxy-protocol-relay.md)'s relay is unchanged, only
the order it can rely on at boot is now documented and tested.

## Context
Epic 07 created the `tailscale` role as the sole owner of the perimeter (UFW); epic 12 (#08) put the
`DOCKER-USER` chain in the same role and introduced the port classes enforced there (public 80/443/8443, tailnet-only restricted TCP/UDP ports, a
Syncplay IP allowlist) and decided the rules need not survive a reboot because a playbook run restores
them. Epic 20 added the `caddy-relay`, which needs this host's Tailscale address at boot. Epic 18 handed
host DNS to AdGuard.

An audit of the live VPS found three faults, each a normal consequence of a routine reboot:

1. **The `DOCKER-USER` chain was empty.** Docker publishes container ports through its own chains and
   bypasses UFW; the only thing standing between the restricted ports (3000, 8008, 8642, 9119, 8090,
   3001, 53) and the internet is this chain. After a reboot it is a bare `-N DOCKER-USER` until someone
   runs the playbook. The deploy itself could not repair it either: it compared the rendered rule
   *files*, saw no change, and skipped loading — "files unchanged, chain empty".
2. **Three services had no restart policy** (`caddy`, `authelia`, `silverbullet`) and stayed down after a
   reboot.
3. **Nothing ordered Docker against Tailscale, and host DNS had two owners.** Tailscale had taken
   `/etc/resolv.conf`; the playbook's handover repointed it on every deploy and Tailscale rewrote it back; with AdGuard stopped or hung
   the host could not resolve names.

**The exposure in (1) was masked only by luck.** Probing the restricted ports from an ordinary internet
path while the chain was empty still timed out, and the NAT counters showed the packets never reached the
host: an *upstream* filter this repository does not manage was dropping them. That is not a control this
repository owns, can see, or can rely on — it is luck, not design. It must not be cited as a reason the
chain is not important.

## Decision

### 1. Persistence: a dedicated boot unit, not a ruleset snapshot
The `tailscale` role installs `hermes-docker-user-firewall.service` — a `Type=oneshot`,
`RemainAfterExit=yes` unit that loads the rendered rule files for **both** IP families with
`iptables-restore --noflush`, declaring only `DOCKER-USER`. It is enabled at boot, ordered
`Before=docker.service`, and `PartOf=`/`WantedBy=docker.service` so every Docker start or restart runs the
loader first. It has **no `ExecStop`**: `PartOf` propagates a Docker stop to it, and a flush there would
empty the chain on every restart.

**Rejected: snapshotting the ruleset** (`netfilter-persistent` / `iptables-persistent`). It saves the
*entire* ruleset, including Docker-managed chains; the snapshot goes stale as Docker recreates its own
chains and then fights Docker on the next start. Owning exactly one chain, from the same source the deploy
renders it from, cannot go stale relative to that source. **Rejected: the status quo** — the fault above.

Why *before* Docker, and why `--noflush` (ticket #01, `.scratch/21-reboot-resilience/spike/`,
raw evidence in `spike/evidence/`; run in a disposable rootless container with its own network namespace,
never on the VPS):
- Docker **preserves** a pre-populated `DOCKER-USER` chain across daemon start and restart, for both
  families, and adds its `FORWARD` jump without touching the contents (E2, E3, E4b).
- `iptables-restore --noflush` with the chain declared replaces **only** that chain, leaving Docker's own `DOCKER` chain byte-identical and re-application identical
  (E5). Atomicity itself rests on `iptables-restore` submitting one nftables transaction; E6 is a contrast, not
  a proof: the role's old flush-then-append had the canary rule absent at all 300 probes while a deploy ran.
- Loading the rules **after the API answers is unsafe**: the daemon restarts restart-policy containers —
  publishing their ports — while it is still initializing, before the API answers. Measured with an ordered
  event stream: rules loaded after the API answered were unsafe in **10/10** cycles (the port went live
  470–1332 ms before its rule); loaded before the daemon started, safe in **10/10** (the rule preceded the
  port by ~1.9–2.1 s) (E7). Limits of that measurement (ticket #01): "port live" means the DNAT/ACCEPT rule
  appeared, not that a connection succeeded; IPv4 published ports only; one container, the workstation's
  kernel, and **no systemd inside** — so `Before=` ordering itself rests on systemd's documented semantics
  and is verified in the drill. An earlier polling-based measurement reported "no window" and was wrong — it
  could not detect a positive window; the event-driven redesign reversed it.

### 2. Fail closed (staged, then enabled by the drill), and outside SSH's blast radius
The unit can be made a hard prerequisite of Docker with a `docker.service` drop-in (`Requires=` + `After=`
the unit). With it on, **Docker refuses to start if the rules failed to load** — no published port without
its rule. Because a wrong dependency could leave the stack down, the drop-in **shipped absent** (variable
`tailscale_docker_user_firewall_fail_closed`, then `false`) and was enabled by the attended drill after the unit
had been observed working across a reboot; the variable now defaults to `true` (a deploy with it `false` removes the
drop-in).

SSH and UFW are outside this blast radius: `ssh.socket` and UFW's own rules do not depend on Docker,
Tailscale or the firewall unit, and nothing in this epic touches them (asserted by tests). With the
coupling on, **do not `systemctl restart` the unit** — `docker.service` `Requires=` it and would bounce
every container; reload with `hermes-docker-user-rules apply`. Starting Docker by hand after a failed load
*exposes* the restricted ports (Docker bypasses UFW); the drill's rollback section gives the safe order. The unit and Docker reference each other (`PartOf=` one way,
`Requires=` the other); the drill exercised a Docker restart with the coupling on — the unit re-ran first, no loop.

### 3. A deploy heals an unchanged artifact
Deploys compare the **live chain** before and after loading, not just the rendered files, and treat "the
files did not change but the chain differs" as a change. The original fault — files unchanged, chain empty —
cannot survive a deploy that runs the `tailscale` role.

### 4. Restart policies, guarded over the rendered set
Every rendered compose service must carry `restart: always` or `unless-stopped`. The guard runs over the
*rendered* service set, not the templates' text, so a new service with no policy fails lint.

### 5. Boot ordering and late dependencies
Docker is ordered **after** `tailscaled` by an ordering-only drop-in (`After=` only; a stopped or failed
Tailscale can never keep Docker from starting — the test forbids `Requires`/`Wants`/`BindsTo`/`PartOf`/…).
Containers start in no guaranteed order after a reboot (`depends_on` orders only `docker compose up`), so
each service's late-dependency behavior and its bound is stated per service in
`docs/reboot-resilience.md`; a test fails if an enabled service has no row there, and the bounds
themselves are asserted in the drill. Docker's restart backoff caps at 60 s, which is
the bound for services that exit until a dependency exists (`caddy-relay`, `owntracks-frontend`,
`beszel-agent`; and possibly `hermes-agent`, whose internal retry behavior is observed in the drill).

### 6. Host DNS: one owner (staged, then enabled by the drill), with a fallback that is actually consulted
Captured live and read-only before the design: `/etc/resolv.conf` was a regular file generated by
Tailscale, so host lookups went `libc → Tailscale → the tailnet's nameserver (AdGuard on this very host)`,
and the deploy's handover fought Tailscale over the file.

- **Owner: the repo's handover (systemd-resolved), not Tailscale**, behind
  `host_dns_resolver_owner_enabled` (default `false`, enabled by the drill). Off: a deploy leaves a working
  resolver **exactly as found** (the repoint runs only if the current file would be broken by the stub
  listener being off), and the resolver drop-in is byte-identical to the one the role always wrote. On:
  `tailscale set --accept-dns=false`, wait for Tailscale to release the file (a timeout **fails** the play —
  it never repoints anyway), then point `resolv.conf` at resolved's non-stub file.
- **Fallback mechanism:** `127.0.0.1` (AdGuard) first, then `host_dns_fallback_servers` as ordinary `DNS=`
  servers — `FallbackDNS=` is ignored whenever any `DNS=` is set. The C library reads only the first **three**
  nameservers, so with the switch on the provider's DHCP resolvers drop out of the path (accepted: if AdGuard
  *and* the public fallbacks are unreachable, the host has no DNS).
- **Bounds:** AdGuard stopped ≈ 0 s extra (nothing listens; the kernel answers "port unreachable" and the
  library moves on); hung ≤ ~5 s extra per lookup (glibc's default per-server timeout). A tighter bound needs
  a static `resolv.conf` with `options timeout:1`, considered and not chosen because it takes the file out
  of resolved's hands. *Measured in the drill: stopped ≈ 0.015 s, hung 5.0 s per real name (~20 s for a name that does not exist).*
- **Side effect:** with Tailscale not managing DNS on the host, the host no longer resolves MagicDNS names
  (it reaches tailnet peers by IP, which is all the stack does). Turning the switch off does **not** undo
  it; the manual rollback is in the doc.

### 7. Runtime-state audit
Everything the playbook configures that lives only in memory or depends on start order was audited
(`docs/reboot-resilience.md`, "Runtime-state audit") and each item **fixed or accepted with a reason**:
the `DOCKER-USER` rules (fixed), restart policies (fixed), Docker→Tailscale order (fixed), host resolver
(fixed by the drill); the full table, including the accepted persistent items (`/run/shm` options, non-project Docker
networks, the TUN/WireGuard modules, the enabled units), is in the doc; forwarding sysctls (persisted by the Tailscale installer's `/etc/sysctl.d/99-tailscale.conf`
for both families — accepted, dependent on that installer file); Caddy's public publish address and the
`caddy-relay` bind addresses (rendered into files at deploy time — accepted; stale only if the provider
changes the VPS's address or the node is re-registered; a redeploy fixes it); UFW, SSH, the enabled units and
unattended-upgrade timers (persistent — accepted; automatic reboot stays disabled). One **finding** feeds
epic 23: Tailscale preferences set by hand are invisible to the playbook (the live node advertises itself as
an exit node) and `tailscale up` refuses to run without restating every non-default flag, so the playbook's
re-login path would fail on such a node; this epic restates `--accept-dns` in both switch states and epic
23's plain-exit-node ticket owns the rest.

### 8. Verification
`scripts/verify-live.sh` proves the state after any reboot without changing anything: read-only over an
allowlist that refuses shell metacharacters, one multiplexed SSH connection (UFW's `limit 22/tcp` locked the
operator's own workstation out when the first version opened one per check), and it reports
INCONCLUSIVE/SKIPPED — never PASS — for anything it cannot support (for example the outside-in
restricted-port probe from a workstation whose route to the VPS is a VPN). The attended reboot drill
(`docs/reboot-resilience.md`) is the only thing that exercises real systemd ordering, real Tailscale
release of `resolv.conf` and real convergence.

### 9. Scope notes
`--skip-tags tailscale` skips *updating* the rules and the unit but never removes an installed unit. The
restart-policy guard has no exemption list. The rendered rule artifact stays byte-stable, so a deploy with
nothing to change changes nothing. The loader validates both families' files before loading either, but
the IPv4 and IPv6 loads are two separate transactions: a failure on the second leaves the first applied
(stated in the loader's header). Out of scope: the upstream filter (not managed here), Docker's nftables
backend, and Caddy's IPv4-only `:443` publish.

## Drill measurements (attended drill, 2026-09-24, three reboots — details in `docs/reboot-resilience.md`)
| Bound | Stated | Measured |
|---|---|---|
| Restricted rules live before any published port | before | yes, all three reboots: the unit finished **4.4–4.8 s before** the first container started, and Docker began starting ~2 s after the unit finished |
| Public front door (Caddy + Authelia) answers after boot | ≤ 3 min | **35–44 s** from the reboot command |
| Every enabled container `running` | ≤ 5 min | **32–41 s**, 13/13, **0 restarts** |
| `caddy-relay` bound | ≤ 2 min | bound at container start on the tailnet address, 0 restarts |
| Host lookup, AdGuard stopped | ≈ 0 s extra | **≈ 0.015 s** (before the DNS change the lookup *failed after 40 s*) |
| Host lookup, AdGuard paused (hung) | ≤ ~5 s extra | **5.0 s** per real name; **~20 s** for a name that does not exist (documented limit) |
| Docker restart leaves the rules in place (coupling off, then on) | yes | yes (24 s / 25 s; 24 v4 + 23 v6 rules intact; no dependency loop) |
| `hermes-agent` convergence mechanism | observed | none needed: 0 restarts, no dependency-related failure |
| Fail-closed: Docker starts only when the rules loaded | yes | yes: with the rules file removed the loader failed and Docker refused to start (0 published-port listeners); restored, 13/13 came back |

The drill also found three things no test had and led to fixes: a `template` source that is not found when a task file
is included by raw path (guard added), a false "restricted port reachable" from a network that answers TCP 53 on any
address (negative control added), and Tailscale SSH's browser check making the tailnet SSH path hang until approved
(follow-up).

## Consequences
- The design is that a reboot, a Docker restart or a routine deploy cannot leave the restricted ports
  unprotected; with the coupling on, Docker cannot even start without the rules. **The drill
  confirmed the ordering on real systemd across three reboots and a deliberately broken rules load, and the
  coupling is the default. With the coupling off (a rollback state) a failed rules load at boot would not stop
  Docker:** it would come up with an empty chain until `verify-live.sh` or a deploy noticed.
- One more unit and two drop-ins to know about; the coupling and the DNS ownership are deliberate switches
  with a documented rollback each, not silent behavior.
- The exposure window is closed by *ordering* (rules before the daemon), which is only as good as systemd's
  `Before=` semantics — verified in the drill, not in CI.
- Tests are behavioral (rendered/executed, mutation-checked); real boot behavior, Tailscale releasing the
  DNS file, and measured delays remain operator-validated in the attended drill.
- Epic 23 (exit nodes) relies on this epic's restart-policy guard and its forwarding-sysctl finding; epic 22's
  wrapper will supply `TARGET_HOST`/`SILVERBULLET_DOMAIN` to `verify-live.sh` in script mode (nothing here
  waits for it).

## References
- Spec: `.scratch/21-reboot-resilience/spec.md`; tickets `.scratch/21-reboot-resilience/issues/`
- Spike harness and raw evidence: `.scratch/21-reboot-resilience/spike/` (`evidence/e1-e6.txt`, `evidence/e7-window.txt`)
- Behavior, bounds, audit and the reboot drill: `docs/reboot-resilience.md`
- Verification: `scripts/verify-live.sh`, guarded by `tests/check-live-verification.sh`
- Related: epic 07 (`tailscale` role), epic 12 #08 (`DOCKER-USER` port classes), epic 18 #05 (host DNS to AdGuard), epic 20 ([ADR-0005](0005-tailnet-proxy-protocol-relay.md), the `caddy-relay`), epic 22 (secrets wrapper), epic 23 (exit nodes)
