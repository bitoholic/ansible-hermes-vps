# 01: Profile render loop + default-as-entry (behavior-preserving)

**What to build:** Replace the dual code path in `roles/hermes/tasks/main.yml` with a single render loop over `hermes_profiles`. The default "Jack-O-Rama" profile becomes a list entry (deployed to `hermes_home/`), not a separate task block. Each profile entry carries optional `target_dir`, `config_template`, `soul_template`, `env_template`, `skills_src` so the loop is data-driven. The two copy-pasted per-profile `.env` blocks are extracted into shared templates (`env_default.j2` for the full default shape, `env_profile.j2` for the scoped coder/intel shape) — this removes the coder/intel duplication. Output files are byte-for-byte identical to today.

**Blocked by:** 01-secret-manifest (done). Pairs with this epic's later tickets.

**Status:** ready-for-agent

- [ ] `group_vars/all/main.yml` `hermes_profiles` gains a `default` entry (target_dir `hermes_home`, templates `config.yaml.j2`/`SOUL.md.j2`/`env_default.j2`).
- [ ] `roles/hermes/tasks/main.yml` deploys config/SOUL/.env/skills for every profile from one loop, computing `target_dir` (default → `hermes_home`, others → `hermes_home/profiles/<name>`).
- [ ] The separate default code path (top-level `config.yaml`/`SOUL.md`/`.env`) is removed; no behavior change.
- [ ] `env_default.j2` and `env_profile.j2` added; `env_profile.j2` is shared by coder + intel (dedup).
- [ ] `ansible-lint` + syntax-check green; new templates render without error.
