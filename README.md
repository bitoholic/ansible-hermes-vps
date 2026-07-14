# Hermes VPS

This repository provisions a secure personal "second brain" stack on a bare Ubuntu or Debian VPS using modular Ansible roles. The deployment flow now uses dynamic inline inventory and local environment files to keep secrets out of version control.

## Architecture at a glance

- Common: hardens the OS, locks down SSH and UFW, and enables unattended upgrades
- Docker: installs the official Docker Engine and Compose plugin
- Authelia: provides MFA-backed authentication and local user management
- SilverBullet: deploys a flat-file wiki behind Caddy and binds it to localhost to avoid exposing the app directly
- Hermes: provisions isolated Docker-based Hermes agent instances behind unique ports and volume mounts
- Backup: configures git-crypt, encrypted wiki sync, and nightly cron automation

## Local secrets workflow

Never commit secrets. The recommended workflow is to populate a local `.env` file and source it before running Ansible.

### 1. Create a local environment helper

Run the interactive helper script:

```bash
./setup-env.sh
```

The script will prompt for required values, including sensitive fields, and save them to a local `.env` file that is ignored by Git.

### 2. Run Ansible against the VPS dynamically

Target the host inline instead of relying on a tracked inventory file:

```bash
source .env
ansible-playbook -i "${TARGET_HOST}," site.yml \
  --extra-vars "authelia_admin_password_hash='${AUTHELIA_ADMIN_PASSWORD_HASH}'" \
  --extra-vars "authelia_jwt_secret='${AUTHELIA_JWT_SECRET}'" \
  --extra-vars "authelia_session_secret='${AUTHELIA_SESSION_SECRET}'" \
  --extra-vars "authelia_storage_key='${AUTHELIA_STORAGE_KEY}'" \
  --extra-vars "hermes_provider_api_key='${HERMES_PROVIDER_API_KEY}'" \
  --extra-vars "telegram_bot_token='${TELEGRAM_BOT_TOKEN}'"
```

### 3. Preview changes before applying

```bash
source .env
ansible-playbook -i "${TARGET_HOST}," site.yml --check --diff \
  --extra-vars "authelia_admin_password_hash='${AUTHELIA_ADMIN_PASSWORD_HASH}'" \
  --extra-vars "hermes_provider_api_key='${HERMES_PROVIDER_API_KEY}'" \
  --extra-vars "telegram_bot_token='${TELEGRAM_BOT_TOKEN}'"
```

## Hermes multi-instance deployment

The Hermes role now loops over the `hermes_instances` list in [group_vars/all/main.yml](group_vars/all/main.yml). Each entry creates:

- a unique profile directory under `/home/hermes/.hermes/<name>`
- a unique Compose project under `/opt/hermes/<name>`
- a container named `hermes-agent-<name>` exposing a unique host port
- an isolated workspace bind mount for the instance

## Local testing

Use the included validation script:

```bash
./tests/lint.sh
```

Or run a local dry-run playbook:

```bash
ansible-playbook -i localhost, tests/test_playbook.yml --check --diff
```

## Notes

- The playbook includes pre-flight assertions so deployment stops early if required secrets are missing
- UFW is configured in a lockout-safe order: SSH is allowed first, then defaults are set, then services are allowed, and UFW is enabled last
- The SilverBullet app is bound to localhost so Docker does not expose it directly to the Internet
