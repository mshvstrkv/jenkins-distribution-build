#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

run_self_tests() {
  echo "ARGOCD_CHECK_SELF_TESTS=OK"
}

emit_error() {
  echo "STATUS=ERROR"
  echo "ACTION=argocd-check"
  echo "ARGOCD_CLI_AVAILABLE=${ARGOCD_CLI_AVAILABLE:-false}"
  echo "ARGOCD_AUTHENTICATED=${ARGOCD_AUTHENTICATED:-false}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME:-}"
  echo "ARGOCD_APP_EXISTS=${ARGOCD_APP_EXISTS:-false}"
  echo "ARGOCD_PROJECT=${ARGOCD_PROJECT:-}"
  echo "ARGOCD_REPO_URL=${ARGOCD_REPO_URL:-}"
  echo "ARGOCD_TARGET_REVISION=${ARGOCD_TARGET_REVISION:-}"
  echo "ARGOCD_SOURCE_PATH=${ARGOCD_SOURCE_PATH:-}"
  echo "ARGOCD_DESTINATION_SERVER=${ARGOCD_DESTINATION_SERVER:-}"
  echo "ARGOCD_DESTINATION_NAMESPACE=${ARGOCD_DESTINATION_NAMESPACE:-}"
  echo "ARGOCD_SYNC_STATUS=${ARGOCD_SYNC_STATUS:-}"
  echo "ARGOCD_HEALTH_STATUS=${ARGOCD_HEALTH_STATUS:-}"
  echo "ARGO_REASON=$1"
  echo "ARGO_NEXT_REQUIRED_INPUT=${2:-}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

load_skill_env

ARGOCD_SERVER=""
ARGOCD_APP_NAME=""
ARGOCD_CLI_AVAILABLE=false
ARGOCD_AUTHENTICATED=false
ARGOCD_APP_EXISTS=false
ARGOCD_PROJECT=""
ARGOCD_REPO_URL=""
ARGOCD_TARGET_REVISION=""
ARGOCD_SOURCE_PATH=""
ARGOCD_DESTINATION_SERVER=""
ARGOCD_DESTINATION_NAMESPACE=""
ARGOCD_SYNC_STATUS=""
ARGOCD_HEALTH_STATUS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --help|-h) exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

[[ -n "$ARGOCD_SERVER" ]] || emit_error "Missing required argument: --argocd-server" "Argo CD server"
[[ -n "$ARGOCD_APP_NAME" ]] || emit_error "Missing required argument: --argocd-app-name" "Argo CD app name"


command -v argocd >/dev/null 2>&1 || emit_error "argocd CLI is required but was not found" "argocd CLI"
ARGOCD_CLI_AVAILABLE=true

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ARGOCD_ARGS=(--server "$ARGOCD_SERVER")

if ! argocd "${ARGOCD_ARGS[@]}" account get-user-info >/dev/null 2>"$WORK_DIR/argocd-auth.err"; then
  reason="$(tr '\n' ' ' <"$WORK_DIR/argocd-auth.err" | sanitize_technical_reason | sed 's/[[:space:]]\+/ /g')"
  emit_error "Argo CD authentication failed: ${reason}" "Argo CD login or ARGOCD_AUTH_TOKEN"
fi
ARGOCD_AUTHENTICATED=true

if argocd "${ARGOCD_ARGS[@]}" app get "$ARGOCD_APP_NAME" -o json >"$WORK_DIR/app.json" 2>"$WORK_DIR/app.err"; then
  ARGOCD_APP_EXISTS=true
  fields="$(PYTHONPATH="$SKILL_ROOT" python3 - "$WORK_DIR/app.json" <<'PY'
import sys
from scripts.lib.distribution.argocd import app_fields, load_json
fields = app_fields(load_json(sys.argv[1]))
for key, value in fields.items():
    print(f"{key.upper()}={value}")
PY
)"
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      PROJECT) ARGOCD_PROJECT="$value" ;;
      REPO_URL) ARGOCD_REPO_URL="$value" ;;
      TARGET_REVISION) ARGOCD_TARGET_REVISION="$value" ;;
      SOURCE_PATH) ARGOCD_SOURCE_PATH="$value" ;;
      DESTINATION_SERVER) ARGOCD_DESTINATION_SERVER="$value" ;;
      DESTINATION_NAMESPACE) ARGOCD_DESTINATION_NAMESPACE="$value" ;;
      SYNC_STATUS) ARGOCD_SYNC_STATUS="$value" ;;
      HEALTH_STATUS) ARGOCD_HEALTH_STATUS="$value" ;;
    esac
  done <<<"$fields"
else
  ARGOCD_APP_EXISTS=false
fi

echo "STATUS=OK"
echo "ACTION=argocd-check"
echo "ARGOCD_CLI_AVAILABLE=${ARGOCD_CLI_AVAILABLE}"
echo "ARGOCD_AUTHENTICATED=${ARGOCD_AUTHENTICATED}"
echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
echo "ARGOCD_APP_EXISTS=${ARGOCD_APP_EXISTS}"
echo "ARGOCD_PROJECT=${ARGOCD_PROJECT}"
echo "ARGOCD_REPO_URL=${ARGOCD_REPO_URL}"
echo "ARGOCD_TARGET_REVISION=${ARGOCD_TARGET_REVISION}"
echo "ARGOCD_SOURCE_PATH=${ARGOCD_SOURCE_PATH}"
echo "ARGOCD_DESTINATION_SERVER=${ARGOCD_DESTINATION_SERVER}"
echo "ARGOCD_DESTINATION_NAMESPACE=${ARGOCD_DESTINATION_NAMESPACE}"
echo "ARGOCD_SYNC_STATUS=${ARGOCD_SYNC_STATUS}"
echo "ARGOCD_HEALTH_STATUS=${ARGOCD_HEALTH_STATUS}"
echo "ARGO_REASON="
echo "ARGO_NEXT_REQUIRED_INPUT="
echo "MUTATIONS_PERFORMED=false"

