#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SKILL_ROOT}/.env"

load_skill_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local perms
  perms="$(stat -f "%Lp" "$ENV_FILE" 2>/dev/null || stat -c "%a" "$ENV_FILE" 2>/dev/null || true)"
  if [[ -n "$perms" && "$perms" != "600" ]]; then
    echo "WARNING=.env should have permissions 600"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" != *"="* ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] || export "$key=$value"
  done <"$ENV_FILE"
}

load_skill_env

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deployment-lookup.sh \
    --config-repo-url <url> \
    --config-repo-branch <branch> \
    --config-path <path> \
    --argocd-server <server> \
    --argocd-app-name <name>

Credentials are read only from env when needed:
  ARGOCD_AUTH_TOKEN
EOF
}

error_exit() {
  echo "STATUS=ERROR"
  echo "STATE=${2:-blocked}"
  echo "REASON=$1"
  echo "NEXT_REQUIRED_INPUT=${3:-}"
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT:-local}"
  echo "CONFIG_EXISTS=${CONFIG_EXISTS:-}"
  echo "ARGOCD_APP_EXISTS=${ARGOCD_APP_EXISTS:-}"
  echo "FIRST_DEPLOYMENT=${FIRST_DEPLOYMENT:-}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

sanitize_technical_reason() {
  sed -E 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g; s#(--user[[:space:]]+)[^[:space:]]+#\1***#g'
}

is_corporate_network_error() {
  case "$1" in
    *"Could not resolve host"*|*"Failed to connect"*|*"Connection refused"*|*"timed out"*|*"Timeout"*|*"timeout"*|*"SSL_ERROR_SYSCALL"*|*"SSL_connect"*|*"TLS"*|*"No route to host"*|*"Host is down"*|*"Network is unreachable"*|*"Connection reset"*|*"Could not resolve hostname"*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

corporate_environment_required_exit() {
  echo "STATUS=ERROR"
  echo "STATE=corporate_environment_required"
  echo "REASON=This operation requires corporate network access"
  echo "NEXT_REQUIRED_INPUT=run inside corporate network"
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT:-local}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

corporate_network_unavailable_exit() {
  local technical_reason="$1"
  technical_reason="$(printf '%s' "$technical_reason" | sanitize_technical_reason)"
  echo "STATUS=ERROR"
  echo "STATE=corporate_network_unavailable"
  echo "REASON=Corporate service is unreachable from the current environment"
  echo "NEXT_REQUIRED_INPUT=run inside corporate network"
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT:-local}"
  echo "MUTATIONS_PERFORMED=false"
  [[ -n "$technical_reason" ]] && echo "TECHNICAL_REASON=${technical_reason}"
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "blocked" "${option}"
}

CONFIG_REPO_URL=""
CONFIG_REPO_BRANCH=""
CONFIG_PATH=""
ARGOCD_SERVER=""
ARGOCD_APP_NAME=""
CONFIG_EXISTS=""
ARGOCD_APP_EXISTS=""
FIRST_DEPLOYMENT=""
EXECUTION_ENVIRONMENT="${EXECUTION_ENVIRONMENT:-local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --execution-environment) require_value "$1" "${2:-}"; EXECUTION_ENVIRONMENT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "blocked" "$1" ;;
  esac
done

[[ -n "$CONFIG_REPO_URL" ]] || error_exit "Missing required argument: --config-repo-url" "blocked" "config repo URL"
[[ -n "$CONFIG_REPO_BRANCH" ]] || error_exit "Missing required argument: --config-repo-branch" "blocked" "config repo branch"
[[ -n "$CONFIG_PATH" ]] || error_exit "Missing required argument: --config-path" "blocked" "config path"
[[ -n "$ARGOCD_SERVER" ]] || error_exit "Missing required argument: --argocd-server" "blocked" "Argo CD server"
[[ -n "$ARGOCD_APP_NAME" ]] || error_exit "Missing required argument: --argocd-app-name" "blocked" "Argo CD app name"
case "$EXECUTION_ENVIRONMENT" in
  local|corporate) ;;
  *) error_exit "Unsupported execution environment: ${EXECUTION_ENVIRONMENT}" "blocked" "local or corporate" ;;
esac
command -v git >/dev/null 2>&1 || error_exit "git is required but was not found" "blocked" "git"
command -v argocd >/dev/null 2>&1 || error_exit "argocd CLI is required but was not found" "blocked" "argocd CLI"

if [[ "$EXECUTION_ENVIRONMENT" != "corporate" ]]; then
  corporate_environment_required_exit
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$CONFIG_REPO_BRANCH" "$CONFIG_REPO_URL" "$WORK_DIR/repo" 2>"$WORK_DIR/git.err"; then
  message="$(tr '\n' ' ' <"$WORK_DIR/git.err" | sed 's/[[:space:]]\+/ /g')"
  if is_corporate_network_error "$message"; then
    corporate_network_unavailable_exit "$message"
  fi
  error_exit "Git SSH authentication failed: ${message}" "blocked" "Git SSH credentials or SSH agent"
fi

if [[ -e "$WORK_DIR/repo/$CONFIG_PATH" ]]; then
  CONFIG_EXISTS="true"
else
  CONFIG_EXISTS="false"
fi

ARGOCD_ARGS=(--server "$ARGOCD_SERVER")

if argocd "${ARGOCD_ARGS[@]}" app get "$ARGOCD_APP_NAME" >/dev/null 2>"$WORK_DIR/argocd.err"; then
  ARGOCD_APP_EXISTS="true"
else
  message="$(tr '\n' ' ' <"$WORK_DIR/argocd.err" | sed 's/[[:space:]]\+/ /g')"
  if is_corporate_network_error "$message"; then
    corporate_network_unavailable_exit "$message"
  fi
  ARGOCD_APP_EXISTS="false"
fi

if [[ "$CONFIG_EXISTS" == "false" && "$ARGOCD_APP_EXISTS" == "false" ]]; then
  FIRST_DEPLOYMENT="true"
elif [[ "$CONFIG_EXISTS" == "true" && "$ARGOCD_APP_EXISTS" == "true" ]]; then
  FIRST_DEPLOYMENT="false"
else
  FIRST_DEPLOYMENT="false"
  error_exit "GitOps config and Argo CD application state are inconsistent" "inconsistent" "manual deployment state repair"
fi

echo "STATUS=OK"
echo "CONFIG_EXISTS=${CONFIG_EXISTS}"
echo "ARGOCD_APP_EXISTS=${ARGOCD_APP_EXISTS}"
echo "FIRST_DEPLOYMENT=${FIRST_DEPLOYMENT}"
echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT}"
echo "MUTATIONS_PERFORMED=false"
