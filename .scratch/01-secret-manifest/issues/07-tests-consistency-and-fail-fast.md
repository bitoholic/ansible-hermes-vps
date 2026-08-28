# 07: Tests — manifest-consistency lint and resolver fail-fast

**What to build:** The test harness gains two checks: (1) a manifest-consistency lint asserting the manifest's required set matches `setup-env.sh` and `.env.template`, and (2) a resolver fail-fast test that, with a crafted environment, confirms an unset required secret raises a clear, named failure (also under `--check`).

**Blocked by:** 01 (resolver + manifest must exist; pairs naturally with 05).

**Status:** ready-for-agent

- [ ] Manifest-consistency check runs in `tests/lint.sh` and fails on drift between manifest / `setup-env.sh` / `.env.template`.
- [ ] A unit-style resolver test asserts the resolved `secrets` dict matches expectations for a crafted environment.
- [ ] A missing required secret produces a named failure; test covers the `--check` path.
