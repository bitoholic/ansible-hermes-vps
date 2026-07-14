#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
REQUIRED_VARS=(
  "TARGET_HOST"
  "AUTHELIA_ADMIN_PASSWORD_HASH"
  "AUTHELIA_JWT_SECRET"
  "AUTHELIA_SESSION_SECRET"
  "AUTHELIA_STORAGE_KEY"
  "HERMES_PROVIDER_API_KEY"
  "TELEGRAM_BOT_TOKEN"
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
  case "$var_name" in
    "AUTHELIA_ADMIN_PASSWORD_HASH"|"AUTHELIA_JWT_SECRET"|"AUTHELIA_SESSION_SECRET"|"AUTHELIA_STORAGE_KEY"|"HERMES_PROVIDER_API_KEY"|"TELEGRAM_BOT_TOKEN")
      prompt_value "$var_name" "Enter ${var_name}: " "true"
      ;;
    *)
      prompt_value "$var_name" "Enter ${var_name}: " "false"
      ;;
  esac
  echo
 done

printf 'Local environment saved to %s\n' "$ENV_FILE"
printf 'Run Ansible with:\n'
printf '  source .env\n'
printf '  ansible-playbook -i "%s," site.yml\n' "${TARGET_HOST:-<your-vps-host>}"
