# 01: Scaffold backup_sync module

**What to build:** A standalone `backup_sync` shell CLI at the repo root, with a dispatcher that accepts subcommands and explicit arguments (`--repo`, `--branch`, `--message`) and a documented external interface, plus the convention that secrets (the GitHub token) arrive via the environment — never inlined into a remote URL. This is the foundation every other ticket builds on; it establishes the package layout, the test hook, and the interface contract so the `sync` / `create-pr` / `git-crypt-init` commands can land as independent, parallel slices.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] `backup_sync` CLI runs with a `--help` showing `sync`, `create-pr`, `git-crypt-init` subcommands.
- [ ] Each subcommand parses `--repo`, `--branch`, `--message` (where relevant) and errors clearly on missing args.
- [ ] `GITHUB_TOKEN` (or an explicit `--token-env`) is the single token source; no subcommand constructs a token-bearing URL.
- [ ] The module's external interface (commands + args + env contract) is documented in a module README / docstring.
- [ ] A test hook exists (e.g. `tests/check-backup-sync.sh`) that can invoke the module's unit tests, even if no tests exist yet.
