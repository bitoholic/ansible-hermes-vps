# 07: ADR — boot-time firewall persistence

**What to build:** A new ADR (ADR-0006, matching the existing ADR format) that records the decisions of epic 21 and the evidence behind them, so a future change does not undo them for a forgotten reason.

**Blocked by:** #06
**Blocks:** None

**Status:** drafted (ADR-0006 written); the measured values in its "Drill measurements" table are filled in after #06

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

## Implementation notes

`docs/adr/0006-boot-time-firewall-persistence.md` written from the spike evidence (#01), the implementations (#02–#04) and the verification design (#05). It records: the dedicated unit versus snapshotting (and why snapshotting is rejected), the load-before-Docker wiring with the spike's measured windows, fail-closed staged behind a variable with SSH/UFW outside the blast radius, deploy-heals-an-unchanged-artifact, restart-policy guard, ordering and late dependencies, host DNS ownership with fallback mechanism and stated bounds, the runtime-state audit dispositions, and — plainly — that the live exposure was masked only by an upstream filter the repo does not manage (luck, not design). Cross-references epics 07, 12 (#08), 18, 20 and 23. No documentation still says the rules are not persisted (the role comment was replaced in #02; the remaining hits are historical text in this epic's own spec/tickets).

**Open until the drill (#06):** the "Drill measurements" table (windows, convergence times, stopped/hung DNS delays, `hermes-agent` convergence mechanism) is `pending`; fill it in from #06's recorded results and change the ADR's status line accordingly.

**Reviews (2 rounds).** Round 1 (three blocking wording items, fixed): the Consequences bullet claimed the ports "can no longer" be left unprotected — now a *design claim, not a verified one*, with the staged-period residual exposure stated (coupling off ⇒ a failed rules load does not stop Docker); "enforced by a test" for the late-dependency bounds — the test only requires a row per enabled service, the bounds are asserted in the drill; a garbled resolv.conf sentence. Round 2: PASS. Applied from its suggestions: the E7 measurement limits, `hermes-agent` no longer listed as certain, atomicity attributed to the nftables transaction (E6 as contrast), and a **new drill step 8 — Docker restart again with the coupling on** (the unit is `PartOf=` Docker and Docker `Requires=` the unit once the coupling is enabled, which step 3 cannot exercise); the README and doc's "no window" statements now say *by design*, verified by the drill.
