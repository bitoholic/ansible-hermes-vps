# 03: create-pr command + unit test

**What to build:** The `backup_sync create-pr` command, which ports the nightly PR logic (from `roles/backup/templates/create-daily-pr.sh.j2`) into the module, but with the GitHub token supplied via the `GITHUB_TOKEN` environment variable — never embedded in the remote URL or the API call URL. It opens a PR from the working branch to `main`, and treats the existing idempotency cases (PR already exists, no new commits) as success. A unit test asserts correct PR metadata and idempotent handling against a mocked GitHub API, with no live token.

**Blocked by:** 01 (Scaffold backup_sync module).

**Status:** ready-for-agent

- [ ] `backup_sync create-pr --repo <dir> --branch <b> --message <m>` posts a PR via the GitHub API using `GITHUB_TOKEN` from the environment.
- [ ] HTTP 201 → success; HTTP 422 "already exists" / "no commits between" → success (idempotent).
- [ ] Any other non-2xx surfaces a clear error and a non-zero exit (nightly PR breakage is visible, not silently dropped).
- [ ] Unit test mocks the GitHub API (stub server or curl substitute) and asserts title/head/base and idempotency; no live token.
- [ ] No token appears in any URL the command constructs.
