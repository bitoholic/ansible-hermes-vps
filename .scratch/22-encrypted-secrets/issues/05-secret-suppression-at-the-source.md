# 05: Keep secrets out of arguments, results and diffs at the source, with a guard

**What to build:** No task leaks a credential through its arguments, its result, its registered output or its diff, regardless of the wrapper — covering not only file-rendering tasks but the other known leaks — and a static check stops a future task from omitting the suppression. This is the second layer under output redaction.

**Blocked by:** None (can start immediately)
**Blocks:** #09

**Status:** ready-for-agent

- [ ] Every task that renders or writes a file containing secret values suppresses diff output (and log output where the module would echo the content)
- [ ] **The Tailscale login no longer puts the auth key in the process arguments** (Tailscale accepts a file reference for its auth key, so the value never appears in the command line, the task result or a process listing), and the task's output is suppressed
- [ ] **The resolver's accumulation loop suppresses its output**, so verbose runs no longer print the whole secrets structure — its contract (environment in, the same secrets structure out) is unchanged and the existing resolver test passes untouched
- [ ] **The compose validation task no longer registers or prints the fully rendered, secret-bearing compose file** (quiet validation or suppressed output), while still failing loudly and usefully on an invalid file
- [ ] A static check in the standard lint run flags a task that renders or passes a secret without suppression, with negative fixtures for a rendered template, a command argument and a registered result
- [ ] A full-playbook check-mode run with fixture secret values **at verbosity, and** with diff enabled, shows none of them in output or process arguments
- [ ] Existing render tests pass unchanged

## Notes

See epic 22 spec, "Implementation Decisions" (second layer: suppression at the source) and "Problem Statement" item 3. Verified against the current roles: the Tailscale auth key is passed as a command argument, and neither the resolver, tailscale nor docker roles use output suppression anywhere.
