# 05: Role slimmed to adapter + watcher enabled

**What to build:** The `backup` role becomes a thin *adapter* between Ansible facts (wiki path, branch, resolved secrets) and the `backup_sync` module CLI. It copies the module into place, **enables the previously-commented systemd path/service units** (`llm-wiki-watcher.path/.service`, whose service `ExecStart` calls `backup_sync sync`) so real-time sync finally fires on file change, and switches the nightly cron to `backup_sync create-pr`. The copy-pasted logic in `sync-to-dev.sh.j2` / `create-daily-pr.sh.j2` is deleted. This is the lever that lets the disabled watcher ship with confidence.

**Blocked by:** 02 (sync command), 03 (create-pr command), 04 (git-crypt-init command).

**Status:** ready-for-agent

- [ ] `roles/backup/tasks/main.yml` deploys the `backup_sync` module and enables + starts `llm-wiki-watcher.path` / `llm-wiki-watcher.service` (units uncommented).
- [ ] The watcher service `ExecStart` invokes `backup_sync sync`; the nightly cron invokes `backup_sync create-pr`.
- [ ] `sync-to-dev.sh.j2` and `create-daily-pr.sh.j2` are removed; no remaining Jinja shell carries sync/PR logic.
- [ ] git-crypt init/export/fetch now call `backup_sync git-crypt-init` (role no longer inlines that flow).
- [ ] A `--check --diff` dry run previews exactly the module + units + cron it deploys (faithful preview).
