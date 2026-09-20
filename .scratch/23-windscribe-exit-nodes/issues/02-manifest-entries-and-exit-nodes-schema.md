# 02: Credentials in the manifest and a validated `exit_nodes` list

**What to build:** The stack knows what an exit location is and refuses a malformed one. The Windscribe credential set and the exit-node Tailscale auth key are required secrets, and the list of exit locations is defined and validated at deploy time, with London and Warsaw as its initial entries.

**Blocked by:** None (can start immediately)
**Blocks:** #03

**Status:** ready-for-agent

- [ ] Required manifest entries exist for the Windscribe credential set (private key, IPv4 address, preshared key) and the exit-node Tailscale auth key; the names-only environment template is regenerated and the sync check passes
- [ ] An `exit_nodes` list holds a `name`, a Windscribe `region` (a country name) and a `city` per entry, initially London and Warsaw
- [ ] Schema-driven validation rejects duplicate names, disallowed characters, and empty region or city — each with a negative case that fails fast at deploy time with a message naming the offending entry
- [ ] A missing credential fails fast, naming the secret only
- [ ] The existing resolver tests pass unchanged

## Notes

See epic 23 spec, "Implementation Decisions" (data model; secrets). Prior art: the gateway route schema's schema-driven validation (epic 13).
