# 07: ADR — boot-time firewall persistence

**What to build:** A new ADR (ADR-0006, matching the existing ADR format) that records the decisions of epic 21 and the evidence behind them, so a future change does not undo them for a forgotten reason.

**Blocked by:** #06
**Blocks:** None

**Status:** ready-for-agent

- [ ] Records persistence via a dedicated unit versus snapshotting the whole ruleset, and why snapshotting was rejected
- [ ] Records the fail-closed choice and confirms SSH and UFW are outside its blast radius
- [ ] Records the staged rollout (fail-closed coupling shipped disabled, enabled by the drill) and the deploy-heals-an-unchanged-artifact behavior
- [ ] Cites the spike's findings (#01) on Docker's behavior with a pre-existing chain, the chosen wiring, and the drill's measured windows and convergence times (#06)
- [ ] Records the runtime-state audit's findings and their dispositions (#04)
- [ ] Records the host DNS ownership decision, the fallback mechanism and the measured stopped and hung delays
- [ ] States plainly that the exposure found on the live VPS was masked only by an upstream filter this repo does not manage — luck, not design
- [ ] Cross-references epics 07, 12 (#08) and 20, and updates any documentation that still says the rules are not persisted

## Notes

See epic 21 spec, "Implementation Decisions" (ADR) and "Further Notes".
