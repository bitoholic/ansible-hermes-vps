# 06: Per-profile secret support

**What to build:** The manifest and resolver gain the ability to scope a secret to a specific Hermes profile, so profile-specific keys (e.g. per-profile OpenRouter/Context7 keys) are not flattened into global vars. This unblocks candidate #2 (Hermes profile module) but is not yet consumed by it.

**Blocked by:** 01 (manifest + resolver must exist first).

**Status:** ready-for-agent

- [ ] Manifest supports declaring a secret scoped to one profile; resolver exposes a per-profile subset (e.g. `secrets.profiles.<name>` or equivalent).
- [ ] A profile-scoped secret is not exposed in the global `secrets` dict.
- [ ] Resolver still fails fast when a required profile secret is unset.
