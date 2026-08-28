# 05: Generate/validate setup-env.sh and .env.template from the manifest

**What to build:** The operator-facing secret catalogs (`setup-env.sh`'s `REQUIRED_VARS` and `.env.template`) are derived from or strictly validated against the manifest so the three copies can no longer drift. A fresh operator who only runs `setup-env.sh` is now prompted for exactly the required set (closing the `DASHBOARD_ADMIN_PASSWORD_HASH` gap).

**Blocked by:** 01 (depends on the manifest's shape).

**Status:** ready-for-agent

- [ ] `setup-env.sh` `REQUIRED_VARS` is generated from, or validated against, the manifest's required set.
- [ ] `.env.template` mirrors the manifest (required + optional) consistently.
- [ ] A lint step asserts both files are supersets of the manifest's required secrets, failing CI on drift.
