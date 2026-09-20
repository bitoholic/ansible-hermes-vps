# 05: Role wiring — tags, skip-tags and ordering

**What to build:** The new role behaves like every other role in the playbook: it is tagged, can be skipped with `--skip-tags`, runs exactly once in the right order, and the repo's ordering and duplication guards know about it.

**Blocked by:** #03
**Blocks:** #07

**Status:** ready-for-agent

- [ ] The role is tagged and included in the skip-tags validation and in the README's skippable-roles list
- [ ] It is wired with the existing ordering conventions, and the role-ordering and role-duplication tests are updated and pass, including that the exit-node role runs ahead of the compose role so its credential files exist when the compose role validates the file
- [ ] A list-tasks check shows the role executes once per run
- [ ] Skipping the role leaves the rest of the stack unaffected

## Notes

See epic 23 spec, "Implementation Decisions" (role wiring). Prior art: epics 10, 15 and 17.
