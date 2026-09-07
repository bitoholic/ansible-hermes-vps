# Ticket #02: Schema-driven validate.yml + regression coverage

**Blocked by:** #01
**Blocks:** none (epic 13 completion)

## Description

Rewrite `roles/gateway/tasks/validate.yml` from a hand-written list of `assert` clauses into a generic engine that walks `roles/gateway/vars/route_schema.yml` (ticket #01) against every entry in `gateway_routes`. This is the ticket that delivers the actual behavior change: validation can no longer silently go incomplete relative to itself, because there's no second hand-copied assert list left to drift from the schema.

1. **Generic per-field validation loop** in `validate.yml`: for every route in `gateway_routes`, for every field declared in `route_schema.yml`, enforce:
   - `required` fields are present
   - Type constraints (boolean/integer/string, non-empty where declared)
   - Allowed-values constraints (e.g. `tls_mode` must be `internal` or `auto`)

2. **Per-field failure messages**: on violation, name the offending route's `host`, the field, the constraint, and the value that failed — replacing today's single combined `fail_msg` covering all rules at once.

3. **`basic_auth_user`/`basic_auth_hash` mutual-presence check**: keep as one small, explicit `assert` appended *after* the generic per-field loop — not folded into the schema vocabulary as a generic `requires: <field>` constraint type. This is the only relational rule among the 7 fields; don't generalize it for a single instance.

4. **`validate.yml` stays a distinct pre-flight task**, invoked the same way it is today (via `include_tasks`, before the Caddyfile deploy directory or file are touched) — this ticket changes the internals, not the external contract or its place in the gateway role's task sequence.

5. **`Caddyfile.j2` is not touched** by this ticket — its render side (address line, port suffix, `tls_mode` scheme logic, `log` line, `import mfa_auth`, `basic_auth` block) is explicitly out of scope for the whole epic and stays exactly as it renders today.

6. **Test coverage** (extend `tests/test_gateway_render.yml`, mirroring its existing structure):
   - The existing four negative tests (missing `upstream`, non-boolean `mfa`, invalid `tls_mode`, non-integer `port`) must keep passing unchanged via the same `include_tasks` + `rescue` pattern.
   - The existing `basic_auth_user`-without-`basic_auth_hash` negative test (from the OwnTracks fix) must keep passing unchanged.
   - Add at least one new assertion that a schema-violating route's failure message names the specific field it violated — spot-check one or two fields, not all 7 exhaustively.
   - The existing byte-exact Caddyfile rendering assertions (wiki, dash, auth, matrix, owntracks) must keep passing unchanged — proof this is a pure internal refactor of validation, not a rendering behavior change.

## Acceptance criteria

- `roles/gateway/tasks/validate.yml` enforces all 7 schema-declared fields generically, driven by `roles/gateway/vars/route_schema.yml` — no hand-written per-field `assert` clause remains for any of the 7 fields
- Validation failure messages name the specific route, field, and constraint violated (spot-checked by test, not all 7 fields)
- The `basic_auth_user`/`basic_auth_hash` pairing check still fires as a one-off explicit assert, not schema-table-driven
- All four pre-existing "malformed route fails fast" negative tests pass unchanged
- The pre-existing `basic_auth_user`-without-hash negative test passes unchanged
- `tests/test_gateway_render.yml`'s byte-exact Caddyfile assertions for every route pass unchanged
- `tests/lint.sh` passes end to end
- `roles/gateway/templates/Caddyfile.j2` has zero diff from its state before this ticket

## Notes

- The framing to keep in mind while implementing: this is not "3 hand-synced edits become 1." Adding a future field is still a schema-table row (ticket #01's file) plus a `Caddyfile.j2` `{% if %}` block plus the data key in a contributing role's `defaults/main.yml` — same edit count as today for render + data. What this ticket buys is that `validate.yml` can't silently omit a check for a field the schema declares.
- No custom Python filter plugin — this stays pure Ansible/YAML/Jinja2, consistent with the rest of the repo's test/lint story (see spec's Implementation Decisions for why this was explicitly rejected).
- Open question from the spec's Further Notes, left to the implementer: whether a route with multiple simultaneous field violations should report all of them in one message or fail on the first. Existing tests only assert pass/fail, not exact message content, so either is acceptable — pick whichever is simpler to write correctly in Jinja and note the choice here once decided.
