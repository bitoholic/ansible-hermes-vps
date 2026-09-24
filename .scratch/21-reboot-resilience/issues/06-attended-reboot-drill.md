# 06: Attended reboot drill on the production VPS

**What to build:** The real evidence that epic 21 worked: the operator deploys the new code, reboots the production VPS following the drill procedure, and shows — with the live verification script, without running the playbook — that it came back correct. Results are recorded.

**Blocked by:** #05
**Blocks:** #07

**Status:** done (attended drill run 2026-09-24)

- [x] The code from #02–#05 is deployed with a check-mode run first, reviewed before applying
- [x] Pre-flight completed per the procedure: provider console access confirmed, an alternate tailnet SSH path confirmed, baseline captured
- [x] The host is rebooted and SSH returns
- [x] The live verification script passes (or reports *inconclusive* only where the procedure documents it) with no playbook run after the reboot
- [x] After the unit has been observed working, the two staged changes are enabled **one at a time** — first the fail-closed coupling (#02), then the host-DNS ownership change (#04) — each followed by a reboot and a verification run; Docker is confirmed to start only when the rules loaded, and the stopped-AdGuard and paused-AdGuard resolution checks are repeated with the ownership change enabled
- [x] Measured and recorded against the stated bounds: time until the restricted rules are live, until the public front door answers, and until the `caddy-relay` is bound
- [x] AdGuard is stopped and the host still resolves a name within the stated bound; then AdGuard is *paused* (hung) and the host still resolves within the stated bound; AdGuard is restored
- [x] The Docker daemon is restarted (attended, at a quiet time) and the rules are still present afterwards
- [x] Results and any deviations are recorded in this ticket's notes

## Notes

Needs the operator: production access, provider console, and a deliberate reboot. Epic 23's attended validation (#07 there) should preferably be scheduled adjacent to this drill so exit-node reboot survival is verified in the same reboot.

## Implementation notes — results (2026-09-24, attended: operator on the provider VNC console)

**Pre-flight.** Console reachable (operator on it). Alternate tailnet SSH path verified — with a caveat: Tailscale SSH intercepts port 22 on the tailnet and *hangs* until a browser "check" is approved (recorded in the drill doc; follow-up: usable in an incident without a browser). Baseline captured with `verify-live.sh` (9 expected failures on the not-yet-deployed pieces; a **false** "port 53 reachable" from the operator's network, which answers TCP 53 on any address — fixed with a negative control). Code deployed with both switches off after a check-mode run that **found a real bug** (`template` source not found for a raw-path include; fixed and guarded). Deploys ran with `.env` loaded inside the command and all output through a redaction filter, no `--diff`/`-v`.

**Sequence executed.** Deploy (switches off) → verify 33/0 → **reboot 1** → verify without a playbook 33/0 → AdGuard stopped with ownership off (lookup **failed after 40 s**, the finding) → Docker restart (coupling off; rules intact) → enable the coupling (`--tags secrets,tailscale`) → **reboot 2** → verify 33/0 → **fail-closed proof** (rules file removed, `systemctl restart docker`: Docker refused to start, 0 published-port listeners; restored, 13/13 back) → enable host-DNS ownership (`--tags secrets,tailscale,adguard`) → AdGuard stopped (≈0.015 s) and paused (5.0 s; ~20 s for a nonexistent name) → Docker restart with the coupling on (unit re-ran first, no loop) → **reboot 3** with both switches on → verify 33/0, resolver still owned by resolved.

**Measured** (full table in `docs/reboot-resilience.md`, "Results", and the ADR): rules live 4.4–4.8 s before the first container on every reboot and the unit finished ~2 s before Docker started; SSH back at +41–48 s; front door serving at +35–44 s (bound 3 min); 13/13 containers running at +32–41 s (bound 5 min); `caddy-relay` bound on the tailnet address at start; **0 restarts** on every container across all three reboots.

**Outcome.** Every stated bound was met with a large margin, both staged switches are now the defaults (a plain deploy keeps them; before this a deploy without `-e` would have removed the coupling), and the ADR's measurement table is filled in (#07). **Deviations / findings:** NXDOMAIN lookups take ~20 s with AdGuard hung (documented limit); the tailnet SSH browser check; the `hermes-agent` Playwright MCP failure at start is pre-existing and not ordering related; two leftover `ws-spike-*` containers on the host are outside this repository.

