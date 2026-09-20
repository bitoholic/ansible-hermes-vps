# 01: Spike — how Docker treats a pre-populated DOCKER-USER chain

**What to build:** A recorded, reproducible answer — obtained in a disposable environment, never on the production VPS — to the questions the boot-persistence design depends on: when the Docker daemon starts, and when it restarts, does it preserve, flush or recreate a `DOCKER-USER` chain that already holds rules; can loading the rules *before* the daemon starts close the window in which published ports have no rules; and if not, how long is the window between daemon readiness and the rules being live. Delivers the concrete unit-wiring recommendation that ticket #02 builds.

**Blocked by:** None (can start immediately)
**Blocks:** #02

**Status:** ready-for-agent

- [ ] The experiment runs in a disposable environment that matches the VPS's Docker version and firewall backend (a throwaway VM or nested daemon); if none is available on the workstation, the operator is asked for one — the production VPS is never used
- [ ] Documented, with evidence, what happens to rules already in the chain on daemon start and on daemon restart, for both IPv4 and IPv6
- [ ] Documented whether Docker adds or removes its own jump/return rules around the chain, and whether a rules load done *before* the daemon starts survives the daemon's startup
- [ ] The exposure window between daemon readiness and rules being live is measured for each candidate wiring (before the daemon, after the daemon, a drop-in on the daemon's own unit), with the measuring method stated
- [ ] A concrete wiring recommendation that satisfies the spec's required properties: idempotent, atomic, applied at boot and on every Docker restart, fail closed, and chain populated before containers start if and only if Docker preserves it
- [ ] Findings and raw evidence are recorded in this ticket's notes so the later ADR can cite them

## Notes

See epic 21 spec, "Implementation Decisions" (required properties; mechanism decided by a spike). The existing role comment says the rules are "not persisted across reboot" and that the deployment model restores them by playbook run — that is the decision this epic reverses.
