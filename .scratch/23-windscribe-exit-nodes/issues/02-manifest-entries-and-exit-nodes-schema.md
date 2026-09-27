# 02: Credentials in the manifest and a validated `exit_nodes` list

**What to build:** The stack knows what an exit location is and refuses a malformed one. The Windscribe credential set and the exit-node Tailscale auth key are required secrets, and the list of exit locations is defined and validated at deploy time, with London and Warsaw as its initial entries.

**Blocked by:** None (can start immediately)
**Blocks:** #03

**Status:** done

- [x] Required manifest entries exist for the Windscribe credential set (private key, IPv4 address, preshared key) and the exit-node Tailscale auth key; the names-only environment template is regenerated and the sync check passes
- [x] An `exit_nodes` list holds a `name`, a Windscribe `region` (a country name) and a `city` per entry, initially London and Warsaw
- [x] Schema-driven validation rejects duplicate names, names that are not lowercase letters, digits and hyphens (starting and ending with a letter or digit, at most 20 characters, so `<host>-ws-<name>` is always a valid DNS label), and empty region or city — each with a negative case that fails fast at deploy time with a message naming the offending entry
- [x] **The hostname prefix is derived and validated:** a dedicated variable for the `<prefix>` half of each tailnet hostname defaults to the target's first DNS label (the target is in practice a fully-qualified name, and could be an IP address) and is validated like a location name — lowercase letters, digits and hyphens, at most 20 characters, never an IP address — with negative cases (an IP target, an over-long or dotted value) that fail fast at deploy time with a clear message
- [x] A missing credential fails fast, naming the secret only
- [x] The existing resolver tests pass unchanged

## Notes

See epic 23 spec, "Implementation Decisions" (data model; secrets). Prior art: the gateway route schema's schema-driven validation (epic 13).

## Implementation

- **Manifest** (`group_vars/all/secrets.yml`): four new required entries — `exit_node_windscribe_private_key` (`WINDSCRIBE_PRIVATE_KEY`), `exit_node_windscribe_address` (`WINDSCRIBE_ADDRESS`), `exit_node_windscribe_preshared_key` (`WINDSCRIBE_PRESHARED_KEY`), and `exit_node_tailscale_authkey` (`EXIT_NODE_TAILSCALE_AUTHKEY`, deliberately distinct from `TAILSCALE_AUTHKEY` — see the epic 23 spec's trust-boundary decision). `.env.template` regenerated (`python3 scripts/generate-env.py`) under a new "Exit nodes (Windscribe)" section (`scripts/generate-env.py`'s `section_for_key`/`SECTION_ORDER`); `--check` passes.
- **`exit_nodes` list + schema** (new `roles/exit_nodes/` role — `defaults/main.yml`, `vars/main.yml`, `tasks/validate.yml`, `tasks/validate_entry.yml`): same schema-driven, generic-engine shape as the gateway route schema (epic 13), extended with a `pattern` constraint (a full-string regex via `regex_search`) that gateway's schema doesn't need. `exit_node_label_pattern` (`^[a-z0-9](?:[a-z0-9-]{0,18}[a-z0-9])?$`) is shared between the per-entry `name` field and the standalone `exit_node_hostname_prefix` check, since both fill a half of the same composed tailnet hostname `<prefix>-ws-<name>`. Name uniqueness across the list is a relational assert outside the per-field schema, the same reasoning as gateway's basic-auth mutual-presence check.
- **Hostname prefix** (`roles/exit_nodes/defaults/main.yml`): `exit_node_hostname_prefix` defaults to `inventory_hostname`'s first DNS label. An `inventory_hostname` that is itself a dotted-quad IPv4 address is passed through UNCHANGED rather than split (splitting `"203.0.113.5"` on `.` would silently yield the misleading, pattern-valid label `"203"`) — this makes it fail the pattern check loudly, naming the real offending value, instead of silently truncating. An IPv6 target needs no special-casing: it has no `.` to split on, so it also passes through unchanged and fails the pattern on its colons. The role isn't wired into `site.yml` yet (ticket #03 renders from it; ticket #05 does the ordering/skip-tags wiring), so the schema/defaults are exercised directly via `include_vars`, the same pattern `tests/test_gateway_render.yml` already uses for gateway's own schema.
- **Tests**: new `tests/test_exit_nodes_render.yml` / `tests/check-exit-nodes-render.sh` (wired into `tests/lint.sh`) — schema shape, the real default list (London/Warsaw) and a three-entry fixture pass; 11 negative cases (duplicate/invalid-char/leading-hyphen/over-long name, empty region, missing city, empty list, IPv4 target, IPv6 target, dotted/over-long explicit prefix override) each fail fast. `tests/check-resolver.sh` extended with the 4 new secrets in the crafted environment and in the fail-fast loop (matching the precedent every prior epic that added a required secret followed) — each missing-secret case fails fast naming only that secret.
- **Not done here (later tickets' scope):** rendering the actual gluetun/Tailscale/routing-sidecar containers (#03), role wiring into `site.yml`/skip-tags/ordering (#05), and the London/Warsaw-scaling render proof + per-epic static guard script (#04) — ticket #02 only defines and validates the data model.

### Review round 1 (independent fresh-context subagent): no blocking findings

Two non-blocking items, both fixed:
- A doc miscount in this file's own Implementation notes ("12 negative cases" — there are 11).
- `ansible-lint roles/exit_nodes/` flagged `var-naming[no-role-prefix]` on 4 vars: the role directory is `exit_nodes` but the new vars used a singular `exit_node_` prefix, diverging from gateway (the explicit prior art), which passes cleanly because its vars use the exact `gateway_` prefix. Renamed `exit_node_hostname_prefix`/`exit_node_label_pattern`/`exit_node_schema` → `exit_nodes_hostname_prefix`/`exit_nodes_label_pattern`/`exit_nodes_schema`. The `exit_nodes` list itself keeps its bare name (the spec names this list `exit_nodes` throughout every ticket's text) with a `# noqa: var-naming[no-role-prefix]`, the same deliberate exception already used for the `secrets` role's own `secrets` var. `ansible-lint roles/exit_nodes/` now passes cleanly at the `production` profile, matching gateway. Also strengthened 3 negative tests (duplicate/leading-hyphen/over-long name) to assert the failure message names the offending value, matching the pattern the other negative tests already used.

### A known, expected gap this ticket surfaces: the real encrypted store

Adding these 4 required manifest entries means `tests/check-secrets-store.sh`'s very first assertion (`python3 scripts/check_secrets_store.py` against the real, already-committed store from epic 22) now fails:
```
FAIL: secrets/secrets.enc.env: required names missing from the store (by name): EXIT_NODE_TAILSCALE_AUTHKEY, WINDSCRIBE_ADDRESS, WINDSCRIBE_PRESHARED_KEY, WINDSCRIBE_PRIVATE_KEY
```
This is expected and not a bug in this ticket: the real store can only be updated by the operator (an agent cannot decrypt or write to it — `scripts/secrets fill`/`edit` are both in `.claude/settings.json`'s permission denylist, and rightly so). Every other check in `tests/lint.sh` was individually re-run and passes; this is the only failure, and it blocks `tests/lint.sh` end-to-end until the operator runs `scripts/secrets fill` in their own terminal to add the 4 new secrets (throwaway/placeholder values are fine until ticket #01's real credentials exist — the structural guard only checks that a required NAME is present and non-empty, never the value's shape). This mirrors epic 22 ticket #09's own attended-migration pattern.
