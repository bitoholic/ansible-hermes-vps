# 05: Suppress diffs at the source, with a guard

**What to build:** Tasks that render or write files containing credentials no longer print those credentials in `--diff` or logs, regardless of the wrapper, and a static check stops a future secret-bearing task from omitting the suppression. This is the second layer under output redaction.

**Blocked by:** None (can start immediately)
**Blocks:** #09

**Status:** ready-for-agent

- [ ] Every task that renders or writes a file containing secret values suppresses diff output (and log output where the module would echo the content)
- [ ] A static check in the standard lint run flags a secret-bearing template task lacking suppression, with a negative fixture that proves it fires
- [ ] A full-playbook check-mode run with diff enabled, using fixture secret values, shows none of them
- [ ] Existing render tests pass unchanged

## Notes

See epic 22 spec, "Implementation Decisions" (second layer: suppression at the source) and "Problem Statement" item 3 (the documented preview leaks by construction).
