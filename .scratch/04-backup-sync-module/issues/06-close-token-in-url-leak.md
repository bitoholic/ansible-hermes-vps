# 06: Close token-in-URL leak

**What to build:** The GitHub token is no longer embedded in the clone remote URL. The role's bootstrap clone uses a token-less URL, and any git auth the module needs is injected via the environment (credential helper / `GIT_ASKPASS` fed by `GITHUB_TOKEN`), consistent with `create-pr` consuming the token from env. This closes the README Known Limitation (token persisted in `.git/config` in plaintext) at the one place that owns how the token reaches git.

**Blocked by:** 03 (create-pr command) — establishes the env-token convention the clone flow now follows.

**Status:** ready-for-agent

- [ ] The wiki repo is cloned with a URL that contains no token; credential injection uses `GITHUB_TOKEN` from the environment.
- [ ] No rendered task or module output writes the token into a remote URL or `.git/config`.
- [ ] README "Known Limitations" entry about the plaintext token-in-URL is removed/updated.
