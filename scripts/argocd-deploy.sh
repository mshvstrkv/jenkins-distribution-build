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
  ARGOCD_AUTH_TOKEN=<token> \
  bash scripts/argocd-deploy.sh \
    --mode <create|update> \
    --argocd-server <server> \
    --argocd-app-name <name> \
    --argocd-project <project> \
    --argocd-destination-server <cluster-server> \
    --argocd-destination-namespace <namespace> \
    --config-repo-url <url> \
    --config-repo-branch <branch> \
    --config-path <path> \
    [--timeout-seconds <number>] \
    [--dry-run]
EOF
}

error_exit() {
  echo "STATUS=ERROR"
  echo "STATE=blocked"
  echo "ARGOCD_ACTION=${MODE:-}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME:-}"
  echo "ARGOCD_SYNC_STATUS="
  echo "ARGOCD_HEALTH_STATUS="
  echo "ARGOCD_APP_URL="
  echo "REASON=$1"
  echo "NEXT_REQUIRED_INPUT=${2:-}"
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT:-local}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

sanitize_technical_reason() {
  sed -E 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g; s#(--user[[:space:]]+)[^[:space:]]+#\1***#g'
}

is_corporate_network_error() {
  case "$1" in
    *"Could not resolve host"*|*"Failed to connect"*|*"Connection refused"*|*"timed out"*|*"Timeout"*|*"timeout"*|*"SSL_ERROR_SYSCALL"*|*"SSL_connect"*|*"TLS"*|*"No route to host"*|*"Host is down"*|*"Network is unreachable"*|*"Connection reset"*|*"Unavailable"*|*"connection error"*)
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
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "${option}"
}

json_app_status() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

status = payload.get("status") or {}
sync = status.get("sync") or {}
health = status.get("health") or {}
metadata = payload.get("metadata") or {}
print(sync.get("status", ""))
print(health.get("status", ""))
print(metadata.get("name", ""))
PY
}

MODE=""
ARGOCD_SERVER=""
ARGOCD_APP_NAME=""
ARGOCD_PROJECT=""
ARGOCD_DESTINATION_SERVER=""
ARGOCD_DESTINATION_NAMESPACE=""
CONFIG_REPO_URL=""
CONFIG_REPO_BRANCH=""
CONFIG_PATH=""
TIMEOUT_SECONDS=1800
DRY_RUN=false
EXECUTION_ENVIRONMENT="${EXECUTION_ENVIRONMENT:-local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) require_value "$1" "${2:-}"; MODE="$2"; shift 2 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --argocd-project) require_value "$1" "${2:-}"; ARGOCD_PROJECT="$2"; shift 2 ;;
    --argocd-destination-server) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_SERVER="$2"; shift 2 ;;
    --argocd-destination-namespace) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_NAMESPACE="$2"; shift 2 ;;
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --timeout-seconds) require_value "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --execution-environment) require_value "$1" "${2:-}"; EXECUTION_ENVIRONMENT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

case "$MODE" in create|update) ;; *) error_exit "Missing or unsupported --mode" "mode" ;; esac
[[ -n "$ARGOCD_SERVER" ]] || error_exit "Missing required argument: --argocd-server" "Argo CD server"
[[ -n "$ARGOCD_APP_NAME" ]] || error_exit "Missing required argument: --argocd-app-name" "Argo CD app name"
[[ -n "$ARGOCD_PROJECT" ]] || error_exit "Missing required argument: --argocd-project" "Argo CD project"
[[ -n "$ARGOCD_DESTINATION_SERVER" ]] || error_exit "Missing required argument: --argocd-destination-server" "Argo CD destination server"
[[ -n "$ARGOCD_DESTINATION_NAMESPACE" ]] || error_exit "Missing required argument: --argocd-destination-namespace" "Argo CD destination namespace"
[[ -n "$CONFIG_REPO_URL" ]] || error_exit "Missing required argument: --config-repo-url" "config repo URL"
[[ -n "$CONFIG_REPO_BRANCH" ]] || error_exit "Missing required argument: --config-repo-branch" "config repo branch"
[[ -n "$CONFIG_PATH" ]] || error_exit "Missing required argument: --config-path" "config path"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || error_exit "--timeout-seconds must be a number" "timeout seconds"
case "$EXECUTION_ENVIRONMENT" in
  local|corporate) ;;
  *) error_exit "Unsupported execution environment: ${EXECUTION_ENVIRONMENT}" "local or corporate" ;;
esac
command -v argocd >/dev/null 2>&1 || error_exit "argocd CLI is required but was not found" "argocd CLI"

ARGOCD_ARGS=(--server "$ARGOCD_SERVER")

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$EXECUTION_ENVIRONMENT" != "corporate" && "$DRY_RUN" != "true" ]]; then
  corporate_environment_required_exit
fi

if [[ "$EXECUTION_ENVIRONMENT" != "corporate" && "$DRY_RUN" == "true" ]]; then
  echo "STATUS=OK"
  echo "ARGOCD_ACTION=${MODE}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
  echo "ARGOCD_SYNC_STATUS=dry-run"
  echo "ARGOCD_HEALTH_STATUS=dry-run"
  echo "ARGOCD_APP_URL=${ARGOCD_SERVER%/}/applications/${ARGOCD_APP_NAME}"
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT}"
  echo "MUTATIONS_PERFORMED=false"
  exit 0
fi

APP_EXISTS=false
if argocd "${ARGOCD_ARGS[@]}" app get "$ARGOCD_APP_NAME" >/dev/null 2>"$WORK_DIR/get.err"; then
  APP_EXISTS=true
else
  message="$(tr '\n' ' ' <"$WORK_DIR/get.err" | sed 's/[[:space:]]\+/ /g')"
  if is_corporate_network_error "$message"; then
    corporate_network_unavailable_exit "$message"
  fi
fi

if [[ "$MODE" == "create" && "$APP_EXISTS" == "true" ]]; then
  error_exit "Argo CD application already exists" "different app name or update mode"
fi
if [[ "$MODE" == "update" && "$APP_EXISTS" == "false" ]]; then
  error_exit "Argo CD application does not exist" "create mode"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "STATUS=OK"
  echo "ARGOCD_ACTION=${MODE}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
  echo "ARGOCD_SYNC_STATUS=dry-run"
  echo "ARGOCD_HEALTH_STATUS=dry-run"
  echo "ARGOCD_APP_URL=${ARGOCD_SERVER%/}/applications/${ARGOCD_APP_NAME}"
  exit 0
fi

if [[ "$MODE" == "create" ]]; then
  argocd "${ARGOCD_ARGS[@]}" app create "$ARGOCD_APP_NAME" \
    --repo "$CONFIG_REPO_URL" \
    --revision "$CONFIG_REPO_BRANCH" \
    --path "$CONFIG_PATH" \
    --project "$ARGOCD_PROJECT" \
    --dest-server "$ARGOCD_DESTINATION_SERVER" \
    --dest-namespace "$ARGOCD_DESTINATION_NAMESPACE" >/dev/null
fi

argocd "${ARGOCD_ARGS[@]}" app sync "$ARGOCD_APP_NAME" >/dev/null
argocd "${ARGOCD_ARGS[@]}" app wait "$ARGOCD_APP_NAME" --sync --health --timeout "$TIMEOUT_SECONDS" >/dev/null
argocd "${ARGOCD_ARGS[@]}" app get "$ARGOCD_APP_NAME" -o json >"$WORK_DIR/app.json"

status_output="$(json_app_status "$WORK_DIR/app.json")"
sync_status="$(printf '%s\n' "$status_output" | sed -n '1p')"
health_status="$(printf '%s\n' "$status_output" | sed -n '2p')"

echo "STATUS=OK"
echo "ARGOCD_ACTION=${MODE}"
echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
echo "ARGOCD_SYNC_STATUS=${sync_status}"
echo "ARGOCD_HEALTH_STATUS=${health_status}"
echo "ARGOCD_APP_URL=${ARGOCD_SERVER%/}/applications/${ARGOCD_APP_NAME}"
