# 08: Documentation and ADR

**What to build:** The operator can set up, use, extend, bump and troubleshoot exit nodes from the documentation alone, and an ADR records the design, the threat model and the evidence behind them.

**Blocked by:** #07
**Blocks:** None

**Status:** done

- [x] README manual post-deploy steps cover: generating the dedicated Windscribe config, creating the Tailscale tag and auto-approver, creating the key, and approving nodes when no auto-approver exists
- [x] **The tailnet access-control rules are documented as required, not optional:** members may use the tagged nodes as exit nodes; the tagged nodes are a source for nothing — with the reason (everything on the VPS trusts every tailnet source, and these are third-party images with elevated network capability), and the **safe-rollout procedure**: confirm an alternate path first, save the current policy, preview with the policy test facility, apply, re-verify, roll back on any failure
- [x] **Auth-key expiry is documented:** Tailscale auth keys expire (at most 90 days), already-registered nodes keep working because their identity persists, and adding a location or re-registering a node after expiry needs a fresh key (or an OAuth client that mints them); the rotation steps are in the runbook
- [x] **A version-bump procedure is documented** for gluetun and Tailscale (which to change, how to validate a bump against the recovery and kill-switch checks, how to roll back), and the server-list update policy is described
- [x] Documented: how to switch location on Android, and how to add a location (one list entry)
- [x] A troubleshooting guide covers the three known failure modes (Tailscale firewall backend, forward rules, return-path routing) and the expectation that the phone-to-node path is relayed
- [x] The measured resource cost per pair is documented so the box can be sized for more locations
- [x] A new ADR (ADR-0008) records the per-location design, the rejected alternatives (host-level WireGuard with policy routing; a single roaming node), the trust-boundary threat note (tailnet members running third-party images with elevated capability, and the three controls), the resilience findings from #01 and the attended validation's measurements

## Notes

See epic 23 spec, "Implementation Decisions" (trust boundary; Tailscale identity; docs and ADR) and "Further Notes".

## Implementation

Two new files plus two README additions, following this repo's existing documentation split
(README gives a short, linked pointer; a standalone `docs/` file holds the full runbook — the same
pattern `docs/secrets-runbooks.md` and `docs/reboot-resilience.md` already establish):

- **`docs/exit-nodes-runbook.md`** (new): one-time setup (Windscribe config generation, the
  Tailscale tag/auto-approver/key, the real ACL JSON this tailnet actually runs under today, the
  safe-rollout procedure with the real SSH-over-tailnet regression ticket #07 hit as a concrete
  worked example of why the procedure matters), everyday use (switching location on Android, adding
  a location — one list entry), auth-key expiry and rotation, a version-bump procedure for both
  pinned images (including validating a bump against the live kill-switch/recovery checks, not just
  a render test), the server-list update policy, a troubleshooting guide for the three failure modes
  ticket #01 found plus the recovery-healthcheck mechanism ticket #07 added, and the measured
  resource cost (≈31 MB + ≈53 MB ≈ 84 MB per pair, from ticket #01's spike).
- **`docs/adr/0008-windscribe-exit-node-pairs.md`** (new): records the per-location design, both
  rejected alternatives with the concrete reason each was rejected, the three-control trust-boundary
  threat model, ticket #01's three required fixes and its measurements, and — treated as a first-class
  part of the design's evidence, not an afterthought — the full story of the recovery-gap ticket #07
  found live (the spike never tested a tunnel-only restart) and the three rounds it took to actually
  fix it (Compose's own `$` interpolation, then PID-1 signal immunity per `pid_namespaces(7)`).
- **`README.md`**: one new "Manual Post-Deploy Steps" bullet (Windscribe/Tailscale one-time setup
  plus the required ACL change, pointing to the runbook and the ADR for full detail) and one new
  "Known Limitations" entry recording the one AC this epic did not close — the reboot test, which
  ticket #07 deferred pending its own explicit scheduling.

All factual claims in both new documents (image digests, variable names, the real deployed ACL JSON,
the exact fixes and their root causes) were cross-checked against the actual current repo state
(`roles/exit_nodes/defaults/main.yml`, `group_vars/all/secrets.yml`) and against tickets #01, #06
and #07's own recorded findings, rather than re-derived from memory — the resource-cost and
server-list-policy numbers in particular are the exact figures ticket #01 measured, not estimates.

### Verification

`./tests/lint.sh` — full suite clean (docs-only change; no code path touches markdown). No new
automated test was added for documentation content itself, consistent with this repo's existing
practice for `docs/secrets-runbooks.md` and `docs/reboot-resilience.md` (neither has one).
