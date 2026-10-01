# 06: Read-only live verification script for the exit nodes

**What to build:** A read-only script the operator runs from a workstation that confirms, for each exit location, that the exit node is healthy, exits in the right country and not via the VPS, is correctly firewalled, and that the host's routing is unchanged — automating everything checkable without a phone.

**Blocked by:** #04
**Blocks:** #07

**Status:** done

- [x] For each configured location it verifies: the pair is running and healthy; the Tailscale exit node is advertised and online (**admin-console approval specifically is reported INCONCLUSIVE, honestly, not PASS — see "Advertised vs. approved" below**); the exit IP is in the configured country and differs from the VPS's public IP
- [x] It verifies the tunnel firewall's forward rules are exactly the expected ones (**presence of Tailscale's own `ts-forward`/`ts-postrouting` chains, not a byte-exact ruleset diff — see "Forward-rules check" below**) and that IPv6 forwarding is denied
- [x] It verifies the return-path rule is present for both address families
- [x] It verifies the host's default route and rule count match a recorded baseline (an operator-supplied baseline; honestly INCONCLUSIVE without one — see "Route/rule baseline" below) and that no ports are published for the feature
- [x] It verifies the trust boundary: from inside each pair, the VPS's own tailnet address and other tailnet devices are unreachable, and the pair is attached to no network other than its own dedicated one
- [x] It verifies the firewall interplay for the pairs: the `DOCKER-USER` chain holds no entries specific to them, and each tunnel is up — showing the container-bridge early return lets the tunnel's UDP egress through without any per-pair rule
- [x] It runs only read-only commands, prints no credentials, takes the target host from an argument, the environment or epic 22's wrapper in script mode, and states plainly that it cannot verify the phone experience or an active tunnel-down test (those are attended, #07)

## Notes

See epic 23 spec, "Testing Decisions". Style prior art: epic 21's live verification script (#05 there).

## Implementation

`scripts/verify-exit-nodes.sh`, modelled closely on `scripts/verify-live.sh` (epic 21 #05): same `remote()`-only allowlist design (refuses anything not on `ALLOWED_REMOTE` or containing a shell metacharacter, before any connection), the same one-multiplexed-SSH-connection convention (UFW rate-limits SSH), the same PASS/FAIL/INCONCLUSIVE/SKIPPED bookkeeping where inconclusive and skipped are never counted as passes, and the same `--self-test` (56 assertions, no network). Registered with the deploy wrapper's script mode (`scripts/registered-scripts.conf`), matching that file's own comment anticipating this entry.

### Per-location checks

For each entry in the real `roles/exit_nodes/defaults/main.yml` list (read via `configured_locations()`, a small python/yaml helper — the same pattern `verify-live.sh` already uses for `expected_services()`/`public_ports()`/etc.):

- **Health**: `docker inspect` the tunnel/node/sidecar trio for running state and `restart=unless-stopped`, matching `verify-live.sh`'s own container-health idiom exactly.
- **No published port**: `docker inspect --format '{{json .NetworkSettings.Ports}}'` per service, counting only entries with a **non-null** value (an image-level `EXPOSE` with no host binding appears in this map with a `null` value and must not count as published — a naive `len()` on the map would false-FAIL on any image that `EXPOSE`s a port in its Dockerfile).
- **Isolation**: `docker inspect --format '{{json .NetworkSettings.Networks}}'` per service — exactly one key, and it names `exit_nodes_net`.
- **Tailscale**: `docker exec <node> tailscale status --self --json` — `Self.Online` and `Self.ExitNodeOption` both true.
- **Exit IP/country**: `docker exec <tunnel> curl -s --max-time 10 https://ifconfig.co/json` (one request gets both fields) — the exit IP must differ from the VPS's own public IP (`ip -4 route show`'s `src` address, the same technique `verify-live.sh` uses), and the reported country must match the entry's own `region` field (already a full country name, e.g. `United Kingdom`/`Poland` — no separate mapping table needed). A GeoIP fetch failure is INCONCLUSIVE, never a FAIL or a silent pass.
- **Firewall**: `sudo nsenter -t <tunnel-pid> -n sysctl -n net.ipv6.conf.all.forwarding` must read `0`; `sudo nsenter -t <pid> -n nft list ruleset` must show Tailscale's own `ts-forward`/`ts-postrouting` chains (ticket #01/#03's own finding: nothing manual is needed).
- **Return-path rule**: `sudo nsenter -t <pid> -n ip rule show` / `ip -6 rule show`, matched against `to <tailscale_subnet> lookup <exit_nodes_return_route_table>` — the table/priority/subnets are read from the real `roles/exit_nodes/defaults/main.yml` / `group_vars/all/main.yml` via helpers, never hardcoded twice.
- **Trust boundary**: `docker exec <sidecar> nc -zv -w5 <ip> 22` (matching ticket #01's own proven method) against the VPS's own tailnet address (always available, via `tailscale ip -4` on the host) and, optionally, another tailnet device's address via `HERMES_VERIFY_OTHER_TAILNET_IP` — **SKIPPED, not a pass, when unset**, since no single other-device address is stable or safe to hardcode generically.

### Fleet-wide checks

`DOCKER-USER` (`sudo iptables -S` / `ip6tables -S`) must contain no entry naming the feature, for both address families — the tunnels' own UDP egress (Windscribe) and the pair's isolation both already work via the container-bridge early return alone (ticket #03's own design), so a per-pair firewall entry appearing at all would itself be a regression to investigate. Host route/rule counts (`ip -4/-6 route show`, `ip -4/-6 rule show`) are always reported (`info`), but only *compared* against `HERMES_VERIFY_ROUTE4_BASELINE`/`HERMES_VERIFY_RULE4_BASELINE` when the operator has set them.

### Advertised vs. approved

The ticket's own AC asks the script to confirm the exit node is "advertised **and approved**." Only "advertised" (self-reported: `ExitNodeOption: true`, node online) is actually checkable from the node's own local status — Tailscale admin-console **approval** of an exit node changes nothing observable in that same local status; it only changes whether another client's exit-node picker can select it. This repo provisions no Tailscale API key (checked: `group_vars/all/secrets.yml` has no such entry), so there is no way to query approval state directly either. The script reports this explicitly as `INCONCLUSIVE ... admin-console approval cannot be confirmed ... only a client's exit-node picker can tell — see #07's phone test`, rather than silently treating "advertised" as if it proved "approved." This is the same honesty discipline `verify-live.sh` already applies everywhere it cannot prove something (e.g. an unroutable-address negative control for outside-in probes).

### Route/rule baseline

A single hardcoded expected route/rule count cannot be correct generically — it depends on how many other docker networks and VPN-style interfaces already exist on the specific host, which varies by deployment and changes over time as other epics add services. Rather than fabricate a number, the script reports the current counts as `info` always, and only asserts equality against `HERMES_VERIFY_ROUTE4_BASELINE`/`HERMES_VERIFY_RULE4_BASELINE` when the operator has recorded one from a known-good run — INCONCLUSIVE, not a silent pass, when neither is set. This mirrors `verify-live.sh`'s own treatment of anything it cannot determine safely (e.g. "could not determine the VPS's public address").

### `tests/check-exit-node-verification.sh` (new)

A fake-`ssh` black-box test of the whole script, modelled on `tests/check-live-verification.sh`: asserts a healthy 2-location (london/warsaw) fleet passes with every check present per location; a fault scenario per failure mode (stopped/misconfigured container, an extra attached network, a published port, a non-online/non-advertising node, an exit IP equal to the VPS's own, a wrong exit country, IPv6 forwarding enabled, a missing Tailscale forward chain, a missing return-path rule in either family, a reachable trust boundary, a `DOCKER-USER` entry naming the feature) each FAILs and names the problem; a GeoIP fetch failure and a missing route/rule baseline are INCONCLUSIVE, never a FAIL or a silent pass; the other-tailnet-device probe is SKIPPED without an address and has teeth with one; an unreachable host aborts after exactly one attempt; no IP address or host is printed on any path; the summary states plainly what ticket #07 still has to verify; and a read-only audit confirms every command the fake ssh received is on the script's own allowlist.

One real bug the test suite caught during development: `configured_locations()`'s first version emitted space-separated `name region city` — broken the moment a region contains a space (`United Kingdom`), since a 3-variable `read` absorbs all extra words into the last variable. Fixed with a `|`-delimited format instead. A second real bug the test caught: the return-path-rule FAIL messages originally embedded the literal subnet (`to 100.64.0.0/10 lookup 52`) in the printed text, which the test's own no-address-leak check correctly flagged (a CIDR block matches the same "looks like an IP" regex an address does) — fixed by dropping the parenthetical entirely, consistent with this script's (and `verify-live.sh`'s) blanket "no address is ever printed" rule.

### Forward-rules check: presence, not a byte-exact diff

Unlike `verify-live.sh`'s `normalize_rules()`/diff for `DOCKER-USER` (a small, fully-owned, rendered ruleset that can be compared byte-for-byte), Tailscale's own nftables ruleset inside the tunnel's netns carries internal bookkeeping that varies by version — a byte-exact comparison would be far more brittle than useful. The check confirms `ts-forward`/`ts-postrouting` exist (so fix #2 stays unnecessary, per #01/#03), which is a real but narrower guarantee than "exactly the expected rules": it would not catch an unrelated extra forwarding rule added elsewhere in the same ruleset. Documented directly in the script as a comment and reflected in the AC checkbox above, rather than left implicit.

### Verification

`./scripts/verify-exit-nodes.sh --self-test` — 56 assertions, OK. `./tests/check-exit-node-verification.sh` — OK (39 commands audited, all allowlisted). `bash -n` clean on both files. `ansible-lint` unaffected by the script/test changes.

### Round 2: three real bugs found running it against the live fleet (ticket #07)

Running this script for real, against the genuine deployed london/warsaw fleet (ticket #07's live attended validation), found three bugs no amount of fake-`ssh` testing had caught — all fixed, re-verified live, and covered by new/updated fake-`ssh` test cases:

1. **Only london was ever checked; warsaw silently vanished.** Root cause: `while IFS='|' read -r name region city; do ...; done <<<"$LOCATIONS"` — a classic shell pitfall where the loop body's own `ssh` call (even for a remote command needing no input) shares and drains the same stdin as the `<<<"$LOCATIONS"` heredoc, starving the next `read` after the first iteration. Fixed by reading all lines into an array first (`readarray -t LOCATION_LINES <<<"$LOCATIONS"`) and `for`-looping over the array instead of `read`ing from a shared stream.
2. **Node/sidecar's own isolation check false-FAILed** ("attached to 0 network(s), expected exactly 1") on a genuinely healthy, correctly isolated fleet. Root cause: the script's own assumption that every service reports exactly one Docker network was wrong for `network_mode: service:X` dependents — Docker really does report `{}` (zero networks) for a container that only shares another's netns, confirmed directly against the live containers. Fixed by splitting the check: the tunnel is still checked for exactly one network (`exit_nodes_net`); node/sidecar are now checked for zero networks of their own **and** `HostConfig.NetworkMode` starting with `container:` — correctly asserting the isolation property that's actually true for a `network_mode: service:` dependent, rather than a property that was never true for it.
3. **Exit-IP/country check was silently INCONCLUSIVE on every real run.** Root cause: gluetun's official image (Alpine-based) has no `curl` at all — `docker exec <tunnel> curl ...` failed with `executable file not found in $PATH`. Fixed by switching to `wget -q -T <n> -O -` (confirmed working live: revealed the real Windscribe UK exit IP and `United Kingdom` as the reported country, matching the location's configured `region`).

Also added the real live check for "no published host port" that had been deferred to a static test only — `docker inspect --format '{{json .NetworkSettings.Ports}}'`, counting only non-null map values via a small `python3 -c` helper, correctly distinguishing an image-level `EXPOSE` (`null` value) from an actual host publish (a non-null list), matching the design already described above.

`./scripts/verify-exit-nodes.sh --self-test` now covers 57 assertions. Re-run against the real live fleet after all three fixes: 38 checks passed, 0 FAILED (remaining non-pass results are the expected INCONCLUSIVE/SKIPPED ones — admin-console approval, no route/rule baseline recorded yet, no other-tailnet-device address supplied).

**Review (round 1): PASS WITH NITS, no blocking findings.** The reviewer ran both scripts directly (not just reading them), confirmed the read-only allowlist is fully anchored with tight character classes and cannot be widened via a smuggled command, verified the published-port JSON logic against Docker's real null-vs-list shape, confirmed the "advertised vs. approved" reasoning is consistent with actual Tailscale behavior, and confirmed the test's final audit loop reads the correct (not stale) command log. Three non-blocking findings, all addressed: (1) the forward-rules AC bullet overstated what's checked (presence, not an exact diff) — **fixed**, caveated in the AC text, the Implementation section (above), and a code comment. (2) `region`/`city` had no character-class pattern, so the new `|`-delimited parsing was only really closed for `name` — **fixed**, added `pattern: "^[^|]+$"` to both fields in `roles/exit_nodes/vars/main.yml` (ticket #02's schema file) plus a new negative test case in `tests/test_exit_nodes_render.yml`, closing the hazard at the schema level rather than by convention alone. (3) `region_matches_country`'s exact-string match could conflate a real wrong-country result with a GeoIP service format drift — **fixed**, documented as a known, low-risk limitation in a code comment; not changed behaviorally since ifconfig.co has consistently used full country names matching this repo's own `region` convention.
