# 🏠 Hermes VPS

This repository provisions a personal "second brain" + agent stack on a bare Ubuntu/Debian VPS using modular Ansible roles and Docker Compose. Secrets are kept out of version control via a local `.env` file that is sourced into the shell before running Ansible.

> ⚠️ **Status: pre-production.** This stack has known security and reliability gaps — see [Known Limitations](#-known-limitations--open-issues) before you put real credentials or sensitive wiki content on it.

## 🏗️ Architecture at a Glance

| Role | Purpose |
|---|---|
| `users` | Creates the dedicated `llm_wiki` system user/group that owns all persistent data |
| `ssh_hardening` | Disables password auth, disables root login, deploys `AllowUsers` |
| `common` | Installs base hardening packages, enables unattended-upgrades, configures UFW |
| `docker` | Installs Docker Engine + Compose plugin from the official repo |
| `authelia` + `silverbullet` | Caddy reverse proxy → Authelia (MFA forward-auth) → SilverBullet wiki, bound to `127.0.0.1` |
| `hermes` | Builds and runs the single `hermes-agent` container (see below) |
| `backup` | Real-time wiki→GitHub sync on file change, plus a nightly PR creation cron job |

### 🧩 Hermes agent & profiles

There is **one** `hermes-agent` container, built from the local `Dockerfile` and running three logical "subagents" as profile subdirectories under `/opt/hermes/profiles/`, all sharing the same container filesystem (mounted at `/opt/data`):

- **Jack-O-Rama** (root/default profile) — Chief-of-staff persona, manages the Markdown wiki at `/opt/data/wiki`, reachable over Signal.
- **Compile-O-Rama** (`profiles/coder`) — coding sandbox with Git + GitHub MCP + Context7 MCP + Playwright MCP tools enabled.
- **Intel Scraper** (`profiles/intel`) — background news-scraping agent with `terminal`, `filesystem`, and `git` tools explicitly **disabled**.

The set of agents that exist is defined entirely as **data** in `group_vars/all/main.yml` → `hermes_profiles`. That list is the single source of truth for "which agents exist"; adding or removing an agent is a data change there (model, `tools`, `mcp_servers`, capability scoping), and the `hermes` role renders every profile — including the default — through one identical template loop. Capability scoping (e.g. Intel's disabled `terminal`/`filesystem`/`git`) is declared in the profile's own entry and rendered into its `config.yaml`, so agent behavior is enforced at the profile layer. (True filesystem sandbox isolation between profiles remains a separate, out-of-scope hardening — see the gap noted below.)

Messaging is handled by a standalone `signal-cli-api` REST container on an internal Docker network only (no published port), restricted to your personal number via `SIGNAL_ALLOWED_USERS`. Voice mode (Whisper STT, NeuTTS/Piper TTS) runs fully offline inside the same container via the `ffmpeg`/`hermes-agent[voice]` Dockerfile layer.

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

- [ ] **No real sandbox isolation for Compile-O-Rama.** All profiles share one container and one bind mount (`hermes_home:/opt/data`); there is no `/workspace`-only mount and no `ALLOWED_DIRECTORIES` enforcement. The coder subagent can currently read the wiki and every profile's `.env`.
- [ ] The GitHub token is embedded directly in the wiki's git remote URL (persists in `.git/config` in plaintext) rather than via a scoped deploy key or credential helper.

## 📝 Notes

- Pre-flight `assert` tasks stop the playbook early if core secrets are missing.
- UFW is applied in a lockout-safe order: SSH key is authorized first, hardened `sshd` config is deployed, *then* UFW is enabled.
- SilverBullet is bound to `127.0.0.1` so Docker never exposes it directly — all public traffic goes through Caddy → Authelia.
