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

2. ~~**Location**: `roles/gateway/vars/` (role `vars/`, not `defaults/`)~~ **Filename amended post-implementation — see "Live-deploy finding" below.** Location is still `roles/gateway/vars/` — this is the gateway role's internal contract, not an operator-tunable default, and it's still not in `group_vars/all/gateway.yml` (that file's job is route *assembly*, not shape). The file itself is `vars/main.yml`, not `vars/route_schema.yml` as originally specified.

3. Do not modify `roles/gateway/tasks/validate.yml` or `roles/gateway/templates/Caddyfile.j2` in this ticket — that's ticket #02.

## Acceptance criteria

- `roles/gateway/vars/main.yml` (originally specified as `route_schema.yml` — see Notes) exists and is valid YAML
- The schema declares exactly the 7 fields listed above, each with a `required` flag and a constraint (type or allowed-values)
- A test (new or extended) asserts the schema declares all 7 field names — catches an accidental deletion of a schema entry
- `ansible-playbook --syntax-check` passes
- `roles/gateway/tasks/validate.yml` and `roles/gateway/templates/Caddyfile.j2` are untouched by this ticket

## Notes

- This mirrors the "prerequisite ticket" pattern from epic 12's ticket #00 (Caddyfile template changes landed before OwnTracks was added on top) — a structural enabler, not a user-facing behavior change on its own.
- **Live-deploy finding, not caught by any local test**: the schema file was originally named `vars/route_schema.yml`. Ansible only auto-loads a role's `vars/main.yml` on real invocation (`roles:`/`include_role`/`import_role`) — a differently-named file under `vars/` is never auto-loaded. Every local test happened to explicitly `include_vars` the file itself (a necessary workaround for their own raw `include_tasks`-based invocation style, which bypasses role compilation entirely and wouldn't auto-load `vars/main.yml` either) — so this gap was invisible until a `--check --diff` run against the real VPS failed with `'gateway_route_schema' is undefined`. Fixed by renaming to `vars/main.yml`, the only mechanism that's actually reliable for genuine role invocation regardless of how any individual task file within the role happens to be reached. Filename traded for correctness; the file's role and content are unchanged.
- The 7-field list and `required`/`allowed-values` constraints match what `roles/gateway/tasks/validate.yml` enforces today (see epic 03 and epic 12 history) for `upstream`, `mfa`, `tls_mode`, and `port`. The `string` type constraints on `host`, `basic_auth_user`, and `basic_auth_hash` are a deliberate narrow addition beyond today's checks (today: `host` is checked for definedness only, `basic_auth_user`/`basic_auth_hash` for mutual presence only — none are type-checked) — see the note in step 1 above. Caught in review; correcting an earlier "exact transcription" claim in this ticket that wasn't quite true.
