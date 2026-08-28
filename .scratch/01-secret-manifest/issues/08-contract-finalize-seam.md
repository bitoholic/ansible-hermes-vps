# 08: Contract — finalize the single seam

**What to build:** The final cleanup that confirms the secret-resolution seam is fully consolidated. After every role and the operator tooling consume the resolver, no role calls `lookup('env', …)` directly for secrets, and CI is green end-to-end.

**Blocked by:** 02 (migrate hermes), 03 (migrate backup), 04 (migrate remaining roles), 05 (generate/validate env scripts), 06 (per-profile support), 07 (tests).

**Status:** ready-for-agent

- [ ] No role task or template calls `lookup('env', …)` directly for a secret (verified by a static grep check).
- [ ] `setup-env.sh`, `.env.template`, and `group_vars` derive from the single manifest.
- [ ] Full playbook run and `tests/lint.sh` (+ resolver fail-fast test) are green.
