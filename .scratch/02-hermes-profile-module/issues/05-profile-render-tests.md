# 05: Profile render tests

**What to build:** Add a `tests/test_hermes_profile.yml` (or extend `tests/test_playbook.yml`) that asserts the external behavior of the render loop: for N profiles exactly N `config.yaml`/`SOUL.md`/`.env`/`skills/` sets exist under their `target_dir`, the default profile is among them, the `.env` template produces identical output to the previous blocks, and the `intel` profile receives only its scoped secrets while `coder` receives its context7/github tokens from `secrets`. Hook into `tests/lint.sh`.

**Blocked by:** 01, 02, 03, 04.

**Status:** ready-for-agent

- [ ] Test asserts N profiles → N file sets; default present.
- [ ] `.env` regression test: consolidated template == previous two blocks for default + coder.
- [ ] Per-profile secret scoping test: intel gets only its secrets; coder gets context7/github from `secrets`.
- [ ] `tests/lint.sh` runs the profile test.
