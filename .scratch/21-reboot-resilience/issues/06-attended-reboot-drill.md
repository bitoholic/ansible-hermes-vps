# 06: Attended reboot drill on the production VPS

**What to build:** The real evidence that epic 21 worked: the operator deploys the new code, reboots the production VPS following the drill procedure, and shows — with the live verification script, without running the playbook — that it came back correct. Results are recorded.

**Blocked by:** #05
**Blocks:** #07

**Status:** ready-for-human

- [ ] The code from #02–#05 is deployed with a check-mode run first, reviewed before applying
- [ ] Pre-flight completed per the procedure: provider console access confirmed, an alternate tailnet SSH path confirmed, baseline captured
- [ ] The host is rebooted and SSH returns
- [ ] The live verification script passes (or reports *inconclusive* only where the procedure documents it) with no playbook run after the reboot
- [ ] After the unit has been observed working, the two staged changes are enabled **one at a time** — first the fail-closed coupling (#02), then the host-DNS ownership change (#04) — each followed by a reboot and a verification run; Docker is confirmed to start only when the rules loaded, and the stopped-AdGuard and paused-AdGuard resolution checks are repeated with the ownership change enabled
- [ ] Measured and recorded against the stated bounds: time until the restricted rules are live, until the public front door answers, and until the `caddy-relay` is bound
- [ ] AdGuard is stopped and the host still resolves a name within the stated bound; then AdGuard is *paused* (hung) and the host still resolves within the stated bound; AdGuard is restored
- [ ] The Docker daemon is restarted (attended, at a quiet time) and the rules are still present afterwards
- [ ] Results and any deviations are recorded in this ticket's notes

## Notes

Needs the operator: production access, provider console, and a deliberate reboot. Epic 23's attended validation (#07 there) should preferably be scheduled adjacent to this drill so exit-node reboot survival is verified in the same reboot.
