# Ticket #01: Gateway route schema table

**Blocked by:** none
**Blocks:** #02

## Description

Create the declarative route schema that `validate.yml` will consume in ticket #02. This ticket only introduces the schema table itself — nothing wires it into `validate.yml` or `Caddyfile.j2` yet.

1. **Create `roles/gateway/vars/route_schema.yml`**: a YAML list, one entry per field, covering all 7 currently-live `gateway_routes` fields:
   - `host` — required, string
   - `upstream` — required, string, non-empty
   - `mfa` — required, boolean
   - `tls_mode` — optional, allowed values `["internal", "auto"]`
   - `port` — optional, integer
   - `basic_auth_user` — optional, string
   - `basic_auth_hash` — optional, string

   Each entry declares: field name, `required` (boolean), and a constraint — either a type check (boolean/integer/string) or an allowed-values enum list.

   **Note where this is a narrow behavior expansion, not a pure transcription**: today's `validate.yml` checks `host` only for definedness (never type), and `basic_auth_user`/`basic_auth_hash` only for mutual presence (never type) — see ticket #02's Notes. Declaring these three as `string`-typed here is a deliberate, low-risk addition (nothing in the repo produces a non-string value for any of them, and no existing test exercises non-string values), not a mistake — but it does mean a route with e.g. an integer `host` would newly fail validation where it wouldn't today. Keep the `string` constraints as specified above; just don't describe this ticket as loss-less transcription when it lands.

2. **Location**: `roles/gateway/vars/` (role `vars/`, not `defaults/`) — this is the gateway role's internal contract, not an operator-tunable default. Don't add it to `group_vars/all/gateway.yml`; that file's job is route *assembly* (concatenating the 5 contributing roles' `*_gateway_publish` lists), not shape.

3. Do not modify `roles/gateway/tasks/validate.yml` or `roles/gateway/templates/Caddyfile.j2` in this ticket — that's ticket #02.

## Acceptance criteria

- `roles/gateway/vars/route_schema.yml` exists and is valid YAML
- The schema declares exactly the 7 fields listed above, each with a `required` flag and a constraint (type or allowed-values)
- A test (new or extended) asserts the schema declares all 7 field names — catches an accidental deletion of a schema entry
- `ansible-playbook --syntax-check` passes
- `roles/gateway/tasks/validate.yml` and `roles/gateway/templates/Caddyfile.j2` are untouched by this ticket

## Notes

- This mirrors the "prerequisite ticket" pattern from epic 12's ticket #00 (Caddyfile template changes landed before OwnTracks was added on top) — a structural enabler, not a user-facing behavior change on its own.
- The 7-field list and `required`/`allowed-values` constraints match what `roles/gateway/tasks/validate.yml` enforces today (see epic 03 and epic 12 history) for `upstream`, `mfa`, `tls_mode`, and `port`. The `string` type constraints on `host`, `basic_auth_user`, and `basic_auth_hash` are a deliberate narrow addition beyond today's checks (today: `host` is checked for definedness only, `basic_auth_user`/`basic_auth_hash` for mutual presence only — none are type-checked) — see the note in step 1 above. Caught in review; correcting an earlier "exact transcription" claim in this ticket that wasn't quite true.
