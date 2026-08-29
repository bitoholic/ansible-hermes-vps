#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
REQUIRED_VARS=(
  # >>> GENERATED_REQUIRED_VARS >>>
  "TARGET_HOST"
  "AUTHELIA_ADMIN_EMAIL"
  "AUTHELIA_ADMIN_USERNAME"
  "AUTHELIA_ADMIN_PASSWORD_HASH"
  "AUTHELIA_SESSION_SECRET"
  "AUTHELIA_STORAGE_KEY"
  "SILVERBULLET_ADMIN_USERNAME"
  "SILVERBULLET_ADMIN_PASSWORD"
  "SILVERBULLET_DOMAIN"
  "SIGNAL_ACCOUNT"
  "SIGNAL_ALLOWED_USERS"
  "CONDUIT_REGISTRATION_SECRET"
  "MATRIX_BOT_PASSWORD"
  "MATRIX_ALLOWED_USERS"
  "MATRIX_ALLOWED_ROOMS"
  "OPENROUTER_API_KEY_WIKI"
  "NOUS_PORTAL_API_KEY"
  "GITHUB_TOKEN"
  "RESEND_API_KEY"
  "CONTEXT7_API_KEY_CODER"
  "DASHBOARD_ADMIN_PASSWORD_HASH"
  "GITHUB_REPO_SLUG"
  "ADMIN_USERNAME"
  "ADMIN_SSH_PUBLIC_KEY"
  "GIT_USERNAME"
  "GIT_EMAIL"
  "OPENROUTER_API_KEY_CODER"
  "OPENROUTER_API_KEY_INTEL"
  # <<< GENERATED_REQUIRED_VARS <<<
)

# Variable names whose values are sensitive and should be read without echo.
SECRET_VARS=(
  # >>> GENERATED_SECRET_VARS >>>
  "AUTHELIA_ADMIN_PASSWORD_HASH"
  "AUTHELIA_SESSION_SECRET"
  "AUTHELIA_STORAGE_KEY"
  "SILVERBULLET_ADMIN_PASSWORD"
  "CONDUIT_REGISTRATION_SECRET"
  "MATRIX_BOT_PASSWORD"
  "OPENROUTER_API_KEY_WIKI"
  "NOUS_PORTAL_API_KEY"
  "GITHUB_TOKEN"
  "RESEND_API_KEY"
  "CONTEXT7_API_KEY_CODER"
  "DASHBOARD_ADMIN_PASSWORD_HASH"
  "ADMIN_SSH_PUBLIC_KEY"
  "OPENROUTER_API_KEY_CODER"
  "OPENROUTER_API_KEY_INTEL"
  # <<< GENERATED_SECRET_VARS <<<
)

prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local is_secret="$3"
  local value=""

  if [[ -n "${!var_name:-}" ]]; then
    echo "${var_name} is already set; keeping current value"
    return 0
  fi

  if [[ -f "$ENV_FILE" ]]; then
    local env_value
    env_value="$(grep -E "^${var_name}=" "$ENV_FILE" | head -n 1 | cut -d '=' -f 2- || true)"
    if [[ -n "$env_value" ]]; then
      export "$var_name=$env_value"
      echo "${var_name} loaded from $ENV_FILE"
      return 0
    fi
  fi

  if [[ "$is_secret" == "true" ]]; then
    read -r -s -p "$prompt_text" value
    echo
  else
    read -r -p "$prompt_text" value
  fi

  if [[ -z "$value" ]]; then
    echo "Skipping ${var_name}; empty values are not stored"
    return 0
  fi

  export "$var_name=$value"
  echo "$var_name=$value" >> "$ENV_FILE"
}

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

for var_name in "${REQUIRED_VARS[@]}"; do
  if [[ " ${SECRET_VARS[*]} " == *" ${var_name} "* ]]; then
    prompt_value "$var_name" "Enter ${var_name}: " "true"
  else
    prompt_value "$var_name" "Enter ${var_name}: " "false"
  fi
  echo
 done

printf 'Local environment saved to %s\n' "$ENV_FILE"
printf 'Run Ansible with:\n'
printf '  source .env\n'
printf '  ansible-playbook -i "%s," site.yml\n' "${TARGET_HOST:-<your-vps-host>}"
