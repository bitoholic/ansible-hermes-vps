# 02: Consolidate per-profile config.yaml into one parameterized template

**What to build:** The three `config.yaml` shapes (default `config.yaml.j2`, `profiles/coder/config.yaml.j2`, `profiles/intel/config.yaml.j2`) are merged into a single template parameterized by profile data (model/provider/default, `tools_enabled`, `mcp_servers`, `web`, `onboarding`). Each `hermes_profiles` entry supplies the differing fields; shared base (terminal cwd, compression, display, tts/stt, delegation, security, dashboard) lives once. Removing a profile no longer leaves a dead template file.

**Blocked by:** 01.

**Status:** ready-for-agent

- [ ] One `config.yaml.j2` renders correct output for default, coder, intel.
- [ ] Per-profile `config.yaml.j2` template files under `profiles/<name>/` deleted.
- [ ] `hermes_profiles` entries carry the fields the template needs (no per-profile template path required for config).
- [ ] Render-diff test confirms identical output to the previous three templates (guards de-dup).
