# 04: London and Warsaw, and proof that adding a location is one entry

**What to build:** The default configuration yields the two locations the operator wants, and a test proves the stack scales by list entry: a three-entry fixture yields three pairs with no other change and no per-location secrets.

**Blocked by:** #03
**Blocks:** #06, #07

**Status:** done

- [x] The default list yields two pairs — London (United Kingdom) and Warsaw (Poland) — each with a distinct name, hostname, state directory and environment file
- [x] A three-entry fixture yields three pairs; adding a location is shown to be only a list entry
- [x] No per-location secrets are introduced (one credential set serves every location)
- [x] A per-epic static guard script, in the repo's established convention, is added to the standard lint run: it re-runs the render assertions and adds assertions against the real template and task files, with an honest header stating what it cannot prove (the live behavior)
- [x] Render tests pass, and the consolidated compose still validates

## Notes

See epic 23 spec, "Implementation Decisions" (one credential set serves every location) and user story 3.

## Implementation

Ticket #03 already built the generic list-driven mechanism and, per its own "Testing Decisions," proved it with a synthetic **three-entry** fixture (london/warsaw/zurich) in `tests/test_docker_compose.yml` — so AC1–3 and AC5 were already satisfied structurally before this ticket started work: the real default list (`roles/exit_nodes/defaults/main.yml`) already contains exactly London (United Kingdom) and Warsaw (Poland); `docker_list_fragments` (`group_vars/all/main.yml`) already renders one tunnel+node+sidecar triad per `exit_nodes` entry generically; and one shared, restricted `exit_nodes_credentials_file` already serves every location (ticket #03's own documented decision — see its Implementation section, "Credentials: one shared restricted file, not one per location"). This ticket's own contribution is the one AC item that wasn't yet built: **AC4, the per-epic static guard script**.

### "Distinct ... environment file" (AC1) means distinct *reference*, not distinct *content*

AC1 lists "environment file" among the things each pair has distinctly, immediately followed by AC3's explicit "one credential set serves every location." Read together with ticket #03's own decision (a shared file every service references via `env_file:`, never inlined), "distinct environment file" here means each pair has its own `env_file:` entry pointing at the credentials — not a byte-distinct file per location. Name, hostname (`<prefix>-ws-<name>`) and state directory (`exit_nodes_state_dir/<name>`) are the fields genuinely unique per pair; the guard script below checks all three against the real fragment file, plus that the credentials path stays un-templated (shared) rather than asserting a nonexistent distinctness for it.

### `tests/check-exit-node-locations.sh` (new)

Per AC4: re-runs `tests/check-exit-nodes-render.sh` (schema validation: default 2-entry list + a 3-entry fixture) and `tests/check-docker-compose-render.sh` (compose rendering, which already exercises ticket #03's 3-entry london/warsaw/zurich fixture) — proving the render assertions still hold — then adds assertions directly against the **real** files those tests only exercise indirectly through fixtures:

- `roles/exit_nodes/defaults/main.yml`: exactly 2 default entries, named `london`/`warsaw`, with the correct region/city pairs — pinning the real production default, not just trusting a test fixture that could silently diverge from it.
- `roles/docker/templates/services/exit_node_pair.yml.j2`: contains no location name literally (proving genericity against the real template, not the test's own synthetic entries); references `item.name`/`item.region`/`item.city`; keys the service/container name, the Tailscale hostname and the state-directory mount by `item.name` (distinctness, for real); and does not template the credentials path by `item.name` (sharedness, for real).
- `group_vars/all/main.yml`: `docker_list_fragments` genuinely wires the real `exit_nodes` list and the real fragment template (not a placeholder).
- `roles/docker/defaults/main.yml`: `docker_enabled_services` does not also list an exit-node-shaped service name, so the pair can never double-render via both mechanisms.

Wired into `tests/lint.sh` immediately after `check-exit-nodes-render.sh`. Honest header: this guard is entirely static; it cannot prove a location's tunnel actually reaches Windscribe or that DNS/live routing behaves as the fixture claims for a third real location — that remains ticket #01's live one-location spike and the epic's own attended validation (ticket #07, phone test) for the real fleet.

### Verification

Ran standalone (`./tests/check-exit-node-locations.sh`) — passes cleanly, including both re-run render checks and every new real-file assertion. Ran the full `tests/lint.sh`: it stops, as already documented in ticket #03's own Implementation section, at the pre-existing `tests/check-secrets-store.sh` gap (the real encrypted store still needs the operator to run `scripts/secrets fill` for the four exit-node manifest entries from ticket #02) — not a regression, and this guard script's own correctness was independently confirmed by the standalone run above, since `lint.sh` never reaches it in this environment.

**Review (round 1): PASS, no blocking findings.** The reviewer stress-tested the new guard's assertions against mutated copies of the real files (templating the credentials path by `item.name`, dropping `item.name` from the hostname, adding a third default entry) and confirmed each mutation is genuinely caught — the checks have real teeth, not just tautological passes. Independently confirmed the header's honesty (static-only, defers live behavior to #01/#07), the AC1/AC3 "distinct environment file" reading as consistent with ticket #03's own already-reviewed precedent (not a new rationalization), and that `lint.sh` stopping at the pre-existing secrets-store gap before reaching this script is expected, not introduced here. Two non-blocking nits: (1) the genericity check is pinned to three known fixture names rather than a fully general heuristic — accepted as a regression pin, not fixed. (2) the region/city checks used the whole-file `check_in` helper instead of the block-scoped `entry_has` used beside them for the name checks — **fixed**, switched to `entry_has` for consistency.
