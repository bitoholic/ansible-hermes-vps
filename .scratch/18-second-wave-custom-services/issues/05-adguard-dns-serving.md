# 05: AdGuard Home — serve DNS to the tailnet

**What to build:** AdGuard actually serving DNS for Tailscale-connected devices — port 53 (UDP+TCP) published and firewall-restricted to the Tailscale subnet, with the host's own DNS resolution (systemd-resolved) still working throughout the change.

**Blocked by:** #04
**Blocks:** #06

**Status:** done

- [x] Port 53 (UDP and TCP) is published for the AdGuard container and restricted at the firewall to Tailscale-sourced traffic only — not reachable from the public internet
- [x] A new firewall port class handles UDP restriction (today's restricted-port mechanism is TCP-only), mirroring the existing TCP restricted-port rules' structure
- [x] The host's systemd-resolved stub listener is disabled to free port 53, sequenced so the host is never left without working DNS resolution during the change (AdGuard bound to port 53 before or atomically with the host listener going down, not after) — see Implementation notes for a real sequencing correction found while tracing this against the actual play
- [x] From a Tailscale-connected client, DNS queries against the VPS's Tailscale IP resolve correctly and are ad/tracker-filtered (verified via static/structural checks — `tests/check-adguard-dns.sh`; the live behavior itself is operator-validated on the real VPS, the same scoping this repo already applies to live UFW/Tailscale behavior in `check-tailscale.sh`)
- [x] The manual step of pointing the tailnet's devices at AdGuard (Tailscale's own admin-console DNS override setting) is documented clearly enough for the operator to complete independently — not attempted as automation

## Notes

See epic 18 spec, section "AdGuard Home", and the Further Notes flag that this is the highest-risk step in the epic (a host-level DNS config change with a real failure mode if sequenced wrong). Verify the sequencing against a real deploy, not just a `--check` dry run, per this repo's established practice for this class of change (epics 13, 15, 16, 17 all caught sequencing bugs only visible on a live run).

When documenting the manual Tailscale-console step, be explicit that the correct setting is the tailnet-wide **global override nameserver**, not split-DNS — split-DNS solves a different problem (routing specific domains elsewhere) and is not the mechanism this ticket needs. Recording this distinction here saves a future revisit from re-investigating the wrong Tailscale feature.

## Implementation notes

**A real sequencing correction, found by tracing this repo's actual `site.yml` execution order — not by guessing.** The epic spec's Implementation Decisions said the systemd-resolved disable logic should live in "this role's tasks," running "in the normal config-deploying phase, before the epic-16 end-of-play 'start consolidated docker compose stack' step." Tracing that literally: `roles/adguard/tasks/main.yml` (the early config-deploying phase, via `gateway`'s meta dependency) runs long before `roles/docker/tasks/start.yml`'s `docker compose up -d`, which only happens at the very end of the play. Had the systemd-resolved change gone into the role's own early tasks as the spec described, the host's resolver would have gone down *before AdGuard's container even existed* — the exact failure mode this ticket exists to prevent, and a direct contradiction of the ticket's own AC #3 ("AdGuard bound to port 53 before... the host listener going down, not after").

**Fix**: the systemd-resolved handover lives in its own task file (`roles/adguard/tasks/free_host_dns_port.yml`), invoked from `site.yml` as a late, end-of-play step — immediately after "Start consolidated docker compose stack," via a bare `include_tasks` (the same pattern already used for conduit's/hermes's own end-of-play provisioning, for the same reason: this needs the container already running, not a meta-dependency re-trigger). A `wait_for` on port 53 gates the whole sequence, so even a slow-starting container doesn't race the resolver change. `tests/check-adguard-dns.sh` asserts this ordering statically (the handover task must appear after the stack-start line in `site.yml`) and also asserts the *reverse* — that the early-phase `tasks/main.yml` contains no systemd-resolved logic at all — so a future "simplification" merging these back together can't silently reintroduce the bug.

**A second, independently-verified detail not in the original research**: disabling `DNSStubListener` alone is not sufficient. `/etc/resolv.conf` is normally symlinked to systemd-resolved's *stub* file (`stub-resolv.conf`, pointing at `127.0.0.53`), and `DNS=` in the drop-in is only ever honored through the *non-stub* file (`/run/systemd/resolve/resolv.conf`) — never through the stub path, in any systemd-resolved version. Without repointing the symlink, the host would keep querying a dead `127.0.0.53` after the stub listener goes down, regardless of the drop-in. Verified against Pi-hole's own official docs (the most common real-world instance of this exact conflict): the correct order is drop-in → repoint the symlink → restart, repointing *before* the restart so there's no window relying on the stale stub symlink. Implemented and tested in that exact order.

- Retroactively closed a ticket #03 documentation gap while adding the new README section this ticket needed anyway: Beszel's agent-pairing manual step was never actually operator-documented (only in code comments and this tracker's own implementation notes, neither of which satisfies "documented... without reading the role's source"). Added alongside AdGuard's new manual step under a new "Manual Post-Deploy Steps" README section.
- New static check script (`tests/check-adguard-dns.sh`) rather than folding into an existing one: this ticket's risk profile (host-level, sequencing-critical, unsafe to execute live in this environment) is different in kind from the render-only tests the existing scripts cover, and deserves its own dedicated, clearly-scoped guard.
