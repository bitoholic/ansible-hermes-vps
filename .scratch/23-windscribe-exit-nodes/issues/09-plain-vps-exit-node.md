# 09: Optional — the VPS's own node as a plain exit node (droppable)

**What to build:** "No Windscribe" becomes one more choice in the Tailscale app: the VPS's own Tailscale node also advertises as an exit node, with egress from the VPS's own public IP — including on a node that is already running, where the existing bring-up step does not run. **Droppable:** removing this ticket affects nothing else.

**Blocked by:** #07
**Blocks:** None

**Status:** ready-for-human (code done; the live traffic test found a real, now-fixed firewall gap — see "Live traffic test: first attempt failed" below; the retest is what's left)

- [x] The VPS's Tailscale node advertises itself as an exit node through an idempotent step that also works when the node is already running (the existing bring-up only runs when it is not), without re-authenticating and without disturbing the node's other settings
- [x] Host routing is unchanged — advertising an exit node does not alter the default route (asserted — see Notes for why no new code path exists to assert over)
- [x] The forwarding settings the exit node depends on are persistent for both address families (the finding of epic 21's runtime-state audit is reused; the check states where each setting is persisted)
- [ ] **Live check, not a render assertion:** the interaction with the `DOCKER-USER` port-class rules — a runtime chain-ordering question — is proven on the real VPS by sending traffic through the plain exit node from a tailnet device and confirming it is forwarded and not dropped; the check is recorded here and added to the live verification script's optional section
- [x] The README notes that the route must be approved in the Tailscale admin console and how to select the node

## Notes

See epic 23 spec, "Implementation Decisions" (optional plain exit node). The admin-console approval and the phone selection are the operator's, noted in the README.

## Implementation

**`roles/tailscale/tasks/main.yml`**: two new tasks after "Set facts for this host's own Tailscale
addresses" — `Check whether this host already advertises itself as an exit node`
(`tailscale status --self --json`, reading `Self.ExitNodeOption`, mirroring the exact field
`scripts/verify-exit-nodes.sh` already reads for the containerized pairs) and
`Advertise this host's own Tailscale node as a plain exit node` (`tailscale set
--advertise-exit-node`, guarded by a `when:` that skips it once already true). Deliberately `set`,
never a second `up`: the existing "Bring up Tailscale" block only runs `tailscale up` when the node
isn't already `Running` (epic 21's runtime-state audit finding — re-running `up` on an
already-logged-in node needs every non-default flag restated or it refuses), so a preference change
on an already-running node needs its own step that can't re-authenticate or touch any other
setting. `tailscale set` is exactly that: it changes only the one flag named, nothing else — the
mechanism this AC's "without disturbing the node's other settings" calls for, not a design choice
invented for this ticket.

**Host routing is unchanged by construction, not by a new runtime check**: this ticket adds no `ip
route`/`ip rule`/sysctl-writing task of its own — `tailscale set` is Tailscale's own preference
mechanism, and the forwarding sysctls it depends on were already made persistent by the Tailscale
installer (epic 21's runtime-state audit, reused here rather than re-solved). The existing
"host routing: unchanged" section of `scripts/verify-exit-nodes.sh` (ticket #06, host-wide, not
per-feature) already covers this generically — re-running it before/after enabling this ticket is
the proof, not a new dedicated check.

**`scripts/verify-exit-nodes.sh`** gets a new optional section (after the fleet-wide checks, before
the summary): reports whether the host advertises itself as an exit node (INCONCLUSIVE, not FAIL,
when it doesn't — "never enabled" and "a real regression" look identical from here alone, the same
honesty discipline the admin-console-approval check already applies) and live-checks both
forwarding sysctls on the host itself (`sudo sysctl -n net.ipv4.ip_forward` /
`net.ipv6.conf.all.forwarding`), stating in the PASS line exactly where each is persisted. The
genuinely unresolvable part — whether traffic from a real tailnet device actually gets forwarded by
the `DOCKER-USER` port-class rules rather than silently dropped — is stated plainly as NOT verified
here, in both the section's own `info` line and the script's closing summary, the same pattern
ticket #07's phone test already established for what a script alone can't prove.

**`tests/check-tailscale.sh`** gets a new section (4) asserting the two new tasks exist, that the
check-before-set guard reads `ExitNodeOption`, and — the one thing that would silently reintroduce
the re-auth risk this design exists to avoid — that the new step never calls `tailscale up`.

**README**: a new manual-post-deploy bullet explaining that this node, unlike the tagged
`exit_nodes` pairs, does **not** match the `tag:exit-node` auto-approver (it's the VPS's own
regular identity) and needs one manual admin-console approval, plus how to select it from the app.

### Review finding, fixed before any deploy

An independent pre-deployment review (explicitly framed as a higher-bar gate, since this touches
the VPS's own primary Tailscale node — the one SSH itself depends on) ran empirical tests against
real ansible-core and found the new block's placement, not its logic, was the real risk: positioned
between the Tailscale bring-up and the "Host firewall" section (as first written), a failure in the
new `when:` clause's `from_json` parse (a pre-existing fragility already present in the older
"Bring up Tailscale" block, not newly introduced here, but newly exposed to it) would abort the
whole play *before* UFW, the SSH rate-limit rule and the DOCKER-USER chain got applied — exactly
backwards for a feature this ticket's own AC calls "droppable: removing this ticket affects nothing
else." Fixed by moving the entire block to the very end of `roles/tailscale/tasks/main.yml`, after
every firewall/SSH task, and adding `failed_when: false` to both new tasks as additional
containment. Any failure here now leaves the host exactly as configured as it would have been
without this ticket at all — never worse. The review found no issue with the idempotency logic
itself (verified live against real ansible-core: a missing `Self` key degrades gracefully; the
`--check`-mode `ignore_errors` is inert but consistent with this file's own existing pattern on
neighboring tasks; `tailscale set` cannot touch `--accept-dns` or any other preference). Full local
suite (`tests/lint.sh`) re-run clean after the move.

### Live traffic test: first attempt failed, root cause found and fixed

The reasoning in the original version of this section turned out to be wrong, and the live test is
exactly why it's an AC item rather than something asserted from the render alone: it assumed the
`--dport`-scoped port-class rules in `docker-user.rules.v4.j2`/`v6.j2` could not coincidentally
match this traffic, because it isn't addressed to one of this host's own published ports. That
assumption missed that `DOCKER-USER` sits in the kernel's `FORWARD` chain, which sees ALL forwarded
traffic — including a tailnet client's own exit-node traffic merely *passing through* this host to
some third-party destination. The operator approved the node in the admin console, selected it as
the exit node from a second tailnet device, and reported: "It's selectable but traffic doesn't
work / times out."

Root-caused live on the VPS via packet counters (not guesswork): the client's DNS (port 53) and
HTTPS (port 443) pass-through traffic coincidentally matched the existing port-only
"tailscale-only service" / "public ingress" rules and was ACCEPTed by `DOCKER-USER` before ever
reaching Tailscale's own `ts-forward` chain. `ts-forward` is what marks a packet for
`ts-postrouting`'s `MASQUERADE`; without that mark, the packet left the host with the client's own
(unroutable, from the wider internet's perspective) tailnet source address, and simply timed out.
This is a pre-existing gap in epic 12/21's own `DOCKER-USER` rules, not a bug in this ticket's new
code — it was latent until this ticket's new traffic pattern (a tailnet client's packets merely
passing through the host) exposed it; the existing exit-node pairs (tickets #01-#08) don't trigger
it the same way because their traffic enters through the dedicated netns/sidecar path, not through
this host's own primary interface.

Getting the fix right took three attempts, each caught by an independent pre-deployment review
before it reached the VPS — logged in full because the mechanism is genuinely subtle and the
history is exactly why each rule now looks the way it does.

**Attempt 1 (rejected, never shipped): scope every per-port rule's ACCEPT and DROP by `-d <this
host's own address>`.** Caught by round-1 review: DOCKER-USER lives in the kernel's `FORWARD`
chain, but Docker's own port-publishing DNAT happens in the `nat` table's `PREROUTING` chain —
*before* routing, *before* `FORWARD` is ever evaluated (this repo's own pre-existing comment at
`roles/tailscale/tasks/main.yml:258-261` already documented this ordering, independently
corroborating the finding). By the time a packet genuinely destined for one of this host's own
published services reaches DOCKER-USER, its destination has already been rewritten to the target
container's bridge IP — so `-d <host's own address>` can never match genuine local traffic, only a
pass-through packet that was never DNATed in the first place. Backwards from the intent: it would
have silently turned every restricted-service and Syncplay rule into dead code, falling through to
Docker's own unconditional per-container ACCEPT and exposing those services to the entire internet.

**Attempt 2 (rejected, never shipped): same idea, but `-m conntrack --ctorigdst <ip>` instead of
`-d`.** `--ctorigdst` matches the connection's *original* (pre-DNAT) destination as recorded by
conntrack in `nat PREROUTING`, which survives the later rewrite — correctly identifying genuine
local traffic while still failing to match pass-through traffic to a third party. This got the
ACCEPT side right, verified by round-2 review. But the DENY side was scoped to only *one* of this
host's two addresses (e.g. `tailscale_ip_v4` for a restricted TCP port) — and every restricted or
Syncplay service in this repo is published with a bare host port (`"3000:3000"`, `"53:53/udp"`,
etc. — `roles/docker/templates/services/*.yml.j2`), which Docker binds to **all** of this host's
addresses, not just the one the service is "meant" to be reached on. So a non-tailnet source could
reach a tailnet-restricted service — or a non-allowlisted source reach Syncplay — simply by
connecting via the host's *other* address (its public IP instead of its tailnet IP, or vice versa):
same DNAT, same port, but the single-address DENY never matched, and the packet fell through to
Docker's own unconditional ACCEPT. The same class of bug as attempt 1, just moved from the ACCEPT
side to the DENY side.

**Attempt 3 (shipped): `--ctorigdst` on the ACCEPT, scoped to the one address that identifies
genuine traffic for that specific ingress path; `--ctorigdst` repeated as TWO separate DENY lines
per restricted/Syncplay port, one per address this host has** (`tailscale_ip_v4`/`v6` and
`ansible_default_ipv4`/`v6.address`), so the DENY keeps its original "deny anyone not already
accepted, no matter which of my addresses they used" meaning. Public-ingress rules (no DENY
counterpart, by original design — meant to be open to everyone) needed no change beyond the ACCEPT
scoping. The IPv6 Syncplay DROP line is deliberately left fully unscoped — it blocks the port
outright on v6 regardless of destination, since the allowlist itself is IPv4-only, so there's no
"this host's own service" case to narrow it to.

A secondary concern was raised and then verified NOT to be a real issue: `tailscale_ip_v4`/
`tailscale_ip_v6` are set via `command: tailscale ip -4/-6` tasks, which Ansible always skips under
`--check` mode, resolving to empty string via the existing `| default('')` fallback — which would
make a `--check` run of the "Render the DOCKER-USER rules" task (an `ansible.builtin.template` task,
which DOES run under `--check`) attempt to render a `--ctorigdst` clause with an empty value.
Checked empirically against real ansible-core: `validate:` (the `iptables-restore --test` step that
would catch malformed syntax) is never invoked under `--check` mode at all — confirmed by giving a
template task an always-failing `validate:` command and observing it still reports `changed` success
under `--check`. A `--check` run renders no real file and never validates one, so this never affects
a live firewall and needed no code change. Also checked and confirmed fine: the VPS does gather a
real `ansible_default_ipv6.address` (a genuine public IPv6 address), a new dependency this fix
introduced for the v6 template that the role never had before.

Tests updated across all three attempts: `tests/test_docker_user_rules.yml` gained fixture facts
(`ansible_default_ipv4`/`ansible_default_ipv6`/`tailscale_ip_v4`/`tailscale_ip_v6`) the harness
previously left undefined (`gather_facts: false`, no real host); `tests/check-docker-user-firewall.sh`
had every `accept_before_drop()` call site and the default-render Python cross-check (section "1b",
which renders against the *real* `group_vars/all/main.yml`) updated for `--ctorigdst`, plus a new
`must_deny_both_addresses()` helper asserting BOTH per-port deny lines exist, for every
restricted/Syncplay class, in both the explicit-fixture section and the default-render check;
`tests/check-adguard-dns.sh` had one cosmetic regex loosened to match a renamed rule comment (no
assertion logic changed there — that lives in check-docker-user-firewall.sh). Full local suite
(`tests/lint.sh`) and `ansible-lint` both re-run clean after the final fix.

Three independent pre-deployment reviews ran in sequence (same higher-bar framing as the
block-placement review above, since this touches the rules gating every published service, not
just exit nodes) — the first two each found the blocking bug described in attempts 1 and 2 above;
the third, reviewing the final attempt 3 state from scratch, found no blocking issues (two
pre-existing, out-of-scope observations noted only: no third address class exists on this
single-NIC host, and an existing `check-docker-user-firewall.sh` gap — the public-port "no drop
rule" assertion only checks the v4 file, not v6 — predates this diff and was left as-is).

### Deployed and re-verified

Deployed to the live VPS via `scripts/deploy --skip-tags docker,conduit,hermes,authelia,gateway,silverbullet,owntracks,backup,beszel,adguard,exit_nodes` after a clean `--check --diff` dry run (the dry run's `-m conntrack --ctorigdst ` entries with an empty value are the already-confirmed-harmless artifact of `tailscale ip -4/-6` being skipped under `--check`; a real run always has the real value by the time these rules render). The real apply rendered and atomically reloaded both IP families' DOCKER-USER chains with no failures. SSH access was never at risk from this specific change — it's enforced entirely by UFW, not DOCKER-USER (confirmed in both the dry run and the real run: the SSH rate-limit task runs and succeeds well before DOCKER-USER is ever touched).

Post-deploy, `scripts/verify-exit-nodes.sh` (41 passed, 0 FAILED, 3 inconclusive — all expected: admin-console approval and the plain exit node's own live traffic test can't be self-checked) and `scripts/verify-live.sh` both ran clean. The first `verify-live.sh` run reported a FAIL — "v4/v6 live chain differs from the rendering" — that turned out to be a test-tooling bug, not a deployment problem: fetching the raw `iptables -S`/`ip6tables -S` output from the VPS and comparing it directly against the deployed rules file showed every rule, IP, port and target matched exactly; only the *textual order* of match clauses within each rule differed, because the kernel always prints `-p <proto>` immediately after a rule's `-s`/leading clause regardless of where it was written, and these new rules write `-m conntrack --ctorigdst <ip>` *before* `-p` (so the match survives Docker's DNAT) for the first time. Fixed `scripts/verify-live.sh`'s `normalize_rules()` to canonicalize `-p`'s position before comparing (two new self-test cases added, `--self-test` passes at 79 assertions), re-ran against the live VPS: both families now report "live chain equals the rendering" (33 and 31 rules respectively). Public ingress (80/443/8443) answers from this workstation; all 13 containers report running with their declared restart policy; SSH/Tailscale/UFW/Docker all enabled and active at boot. The restricted-port outside-in probe and the tailnet-route checks are INCONCLUSIVE only because this workstation isn't on a plain internet path or the tailnet itself — not failures.

What's left: have the operator retry the original failed traffic test — select the VPS's plain exit node from a second tailnet device and confirm real traffic (browsing, a DNS lookup) now works instead of timing out — to confirm the fix actually resolves the reported symptom before this AC is checked off.
