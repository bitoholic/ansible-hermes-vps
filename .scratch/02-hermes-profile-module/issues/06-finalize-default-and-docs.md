# 06: Finalize default profile + capability scoping docs

**What to build:** The default "Jack-O-Rama" profile's full behavior (tools, persona, mcp) is expressed as a complete data entry with no special-cased code path. The `intel` profile's reduced capability (`terminal`/`filesystem`/`git` off) is enforceable in its data entry (not just documented), closing the README sandbox-isolation gap *at the profile layer* (the actual isolation fix stays out of scope). Update README/notes to reflect the data-driven profile list as the source of truth for "which agents exist."

**Blocked by:** 02, 03, 04.

**Status:** ready-for-agent

- [ ] Default profile is a full data entry; no leftover special-casing in the role.
- [ ] `intel` capability reduction declared in its entry and rendered into config.
- [ ] README notes updated: profile list = source of truth for agents; capability scoping declared at profile layer.
- [ ] `ansible-playbook site.yml --check --diff` previews every profile file identically to a real run.
