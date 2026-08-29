---
title: Relocate wiki data to a dedicated /opt/wiki volume
status: done
blocked_by: []
depends_on: []
---

# #04 — Relocate wiki data to a dedicated /opt/wiki volume

The wiki currently lives inside the agent's home (`/opt/hermes/wiki`), coupling the second brain to
the agent's state volume. Move it to `/opt/wiki` to match the repo's `/opt/<service>` convention.
`wiki_volume` and `backup` roles already consume `silverbullet_data_dir`, so repointing the var
carries them along.

## Changes

- `group_vars/all/main.yml:10` — `silverbullet_data_dir: /opt/wiki` (was `"{{ hermes_home }}/wiki"`).
- `roles/hermes/templates/docker-compose.yml.j2:41` — add mount
  `- "{{ silverbullet_data_dir }}:/opt/data/wiki"` so the agent still sees the wiki at the same
  container path (`default.terminal_cwd: /opt/data/wiki` stays valid). Silverbullet's `/space` mount
  already follows the var — no change needed there.

## Migration runbook (deploy-time only; VPS untouched this session)

1. `cp -a /opt/hermes/wiki/. /opt/wiki/` (preserves `.git` + git-crypt).
2. Verify the wiki loads at `wiki.{{ secrets.silverbullet_domain }}`.
3. Optionally `rm -rf /opt/hermes/wiki`.
4. Delete the live `/opt/hermes/SOUL.md` (or rely on the #02 `force: true` change) so the new SOUL
   re-renders.

## Acceptance

- [ ] `silverbullet_data_dir` is `/opt/wiki` (no longer under `hermes_home`).
- [ ] Hermes compose mounts `/opt/wiki` at `/opt/data/wiki`.
- [ ] `wiki_volume` creates `/opt/wiki` owned by `llm_wiki`; `backup` targets `/opt/wiki`.
