# 🏠 Hermes VPS

This repository provisions a personal "second brain" + agent stack on a bare Ubuntu/Debian VPS using modular Ansible roles and Docker Compose. Secrets are kept out of version control via a local `.env` file that is sourced into the shell before running Ansible.

> ⚠️ **Status: pre-production.** This stack has known security and reliability gaps — see [Known Limitations](#-known-limitations--open-issues) before you put real credentials or sensitive wiki content on it.

## 🏗️ Architecture at a Glance

| Role | Purpose |
|---|---|
| `users` | Creates the dedicated `llm_wiki` system user/group that owns all persistent data |
| `ssh_hardening` | Disables password auth, disables root login, deploys `AllowUsers` |
| `common` | Installs base hardening packages, enables unattended-upgrades, configures UFW |
| `docker` | Installs Docker Engine + Compose plugin, owns the consolidated `docker-compose.yml` at `/opt/hermes-vps`, and brings up the full stack (Caddy, Authelia, SilverBullet, Conduit, signal-cli, hermes-agent) on the `gateway` and `internal` networks |
| `authelia` + `silverbullet` | Caddy reverse proxy → Authelia (MFA forward-auth) → SilverBullet wiki, bound to `127.0.0.1` |
| `gateway` | The single writer of the ingress Caddyfile; renders one site block per entry in `gateway_routes` (`group_vars/all/gateway.yml`), wrapping each in the shared `mfa_auth` snippet unless `mfa: false`. |
| `hermes` | Builds and runs the single `hermes-agent` container (see below) |
| `backup` | Real-time wiki→GitHub sync on file change, plus a nightly PR creation cron job |

### 🧩 Hermes agent (second brain)

There is **one** `hermes-agent` container, built from the local `Dockerfile` and running a single "second brain" agent (the `default` profile) mounted at `/opt/data`:

- **Second brain** (default profile) — chief-of-staff persona that also codes, researches, and gatekeeps the Markdown wiki at `/opt/data/wiki`, reachable over Signal. Heavy or parallel work is delegated to anonymous `delegate_task` subagents (each gets its own git worktree via `worktree_isolation`), so there is no need for separate Coder/Intel profiles.

The agent is defined entirely as **data** in `group_vars/all/main.yml` → `hermes_profiles` (a single `default` entry). Model, `tools`, `mcp_servers`, skill auto-load, and capability scoping live in that one entry, and the `hermes` role renders it through a single template loop. (True filesystem sandbox isolation between delegated subagents is provided by git worktree isolation; they share the container filesystem otherwise — see the gap noted below.)

Messaging is handled by a standalone `signal-cli-api` REST container on an internal Docker network only (no published port), restricted to your personal number via `SIGNAL_ALLOWED_USERS`. Voice mode (Whisper STT, NeuTTS/Piper TTS) runs fully offline inside the same container via the `ffmpeg`/`hermes-agent[voice]` Dockerfile layer.

### 🐳 Consolidated Docker Compose Stack

All Docker services are managed by a **single** `docker-compose.yml` at `/opt/hermes-vps/docker-compose.yml`, rendered by the `docker` role. The stack is composed of service fragments in `roles/docker/templates/services/`, each declaring its image, volumes, networks, and dependencies:

- **`caddy`** — Reverse proxy on the `gateway` network; terminates TLS, proxies to backends, and runs Authelia forward-auth for public routes.
- **`authelia`** — MFA provider on the `gateway` network; challenges non-Tailscale clients.
- **`silverbullet`** — Markdown wiki on the `gateway` network, bound to `[IP_ADDRESS]`.
- **`conduit`** — Personal Matrix homeserver on the `internal` network; reachable by Hermes over the shared internal network.
- **`signal-cli`** — Standalone Signal REST API on the `internal` network (no published port).
- **`hermes-agent`** — The single agent container on the `internal` network, depends on `signal-cli`.

The `docker` role owns the consolidated compose file and brings up the full stack via `docker compose up -d`. Each service role (conduit, silverbullet, hermes) reduces to: create directories/volumes with ownership, render config files, and write service fragments.

## 🔐 Local Secrets Workflow

Never commit secrets. Populate a local `.env` and source it before running Ansible.

### 1️⃣ Create your local environment file

```bash
./setup-env.sh
```

This prompts for the credentials it currently knows about (Authelia secrets, Signal account/allowlist, per-profile OpenRouter/Nous/Context7 keys, GitHub token) and saves them to a git-ignored `.env`.

> ⚠️ `setup-env.sh` does **not** yet prompt for everything Ansible requires. Before your first run, also make sure these are set in `.env` (see `.env.template` for the full list):
>
> ```bash
> ADMIN_USERNAME=""
> ADMIN_SSH_PUBLIC_KEY=""
> SILVERBULLET_DOMAIN=""
> AUTHELIA_ADMIN_EMAIL=""
> AUTHELIA_ADMIN_USERNAME=""
> GIT_USERNAME=""
> GIT_EMAIL=""
> ```

### 2️⃣ Run Ansible against the VPS

Because every secret in `group_vars/all/main.yml` is resolved via `lookup('env', ...)`, sourcing `.env` in the same shell is enough — no `--extra-vars` needed:

```bash
source .env
ansible-playbook -i "${TARGET_HOST}," site.yml
```

### 3️⃣ Preview changes before applying

```bash
source .env
ansible-playbook -i "${TARGET_HOST}," site.yml --check --diff
```

### 4️⃣ Selective role skipping (fast redeploys)

You can skip specific roles during deployment using `--skip-tags`:

```bash
# Skip slow roles when only updating hermes configuration
ansible-playbook -i "${TARGET_HOST}," site.yml --skip-tags hermes,backup

# Minimal API deployment: skip everything except conduit and hermes
ansible-playbook -i "${TARGET_HOST}," site.yml --skip-tags tailscale,docker,authelia,gateway,silverbullet,backup

# Full deploy (default, no skips)
ansible-playbook -i "${TARGET_HOST}," site.yml
```

Protected roles that **cannot** be skipped: `secrets`, `users`, `ssh_hardening`, `common`.
Skippable roles: `tailscale`, `docker`, `conduit`, `hermes`, `authelia`, `gateway`, `silverbullet`, `backup`.

## 🧪 Local Testing

```bash
./tests/lint.sh
```

or a local dry-run against `localhost`:

```bash
ansible-playbook -i localhost, tests/test_playbook.yml --check --diff
```

## ⚠️ Known Limitations / Open Issues

Tracked from the last infrastructure audit. Don't consider this deploy-ready until these are resolved:

- [ ] **Delegated subagents share the container filesystem.** The single `hermes-agent` container mounts `hermes_home:/opt/data`; `delegate_task` children get isolated git worktrees (`worktree_isolation: true`) but otherwise share the same bind mount, so a child can read the wiki and the agent's `.env`. Filesystem sandboxing per child is out of scope.
- [x] ~~The GitHub token was embedded directly in the wiki's git remote URL (persists in `.git/config` in plaintext).~~ Closed: the clone now uses a token-less URL and git authenticates via a credential helper / askpass that reads `GITHUB_TOKEN` from the environment (see `roles/backup/files/git-credential-env`). The token value is never written to `.git/config` or any remote URL.

## 📝 Notes

- Pre-flight `assert` tasks stop the playbook early if core secrets are missing.
- UFW is applied in a lockout-safe order: SSH key is authorized first, hardened `sshd` config is deployed, *then* UFW is enabled.
- SilverBullet is bound to `127.0.0.1` so Docker never exposes it directly — all public traffic goes through Caddy → Authelia.
