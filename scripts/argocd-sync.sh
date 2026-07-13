#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

run_self_tests() {
  echo "ARGOCD_SYNC_SELF_TESTS=OK"
}

emit_error() {
  echo "STATUS=ERROR"
  echo "ACTION=argocd-sync"
  echo "ARGOCD_MODE=${MODE:-}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME:-}"
  echo "ARGOCD_SYNC_STATUS="
  echo "ARGOCD_HEALTH_STATUS="
  echo "ARGOCD_APP_URL="
  echo "NEXT_REQUIRED_INPUT=${2:-}"
  echo "REASON=$1"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

load_skill_env

EXECUTION_ENVIRONMENT="${EXECUTION_ENVIRONMENT:-local}"
MODE=""
ARGOCD_SERVER=""
ARGOCD_APP_NAME=""
ARGOCD_PROJECT=""
REPO_URL=""
TARGET_REVISION=""
SOURCE_PATH=""
DESTINATION_SERVER=""
DESTINATION_NAMESPACE=""
TIMEOUT_SECONDS=1800
APPROVE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --execution-environment) require_value "$1" "${2:-}"; EXECUTION_ENVIRONMENT="$2"; shift 2 ;;
    --mode) require_value "$1" "${2:-}"; MODE="$2"; shift 2 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --argocd-project) require_value "$1" "${2:-}"; ARGOCD_PROJECT="$2"; shift 2 ;;
    --repo-url) require_value "$1" "${2:-}"; REPO_URL="$2"; shift 2 ;;
    --target-revision) require_value "$1" "${2:-}"; TARGET_REVISION="$2"; shift 2 ;;
    --source-path) require_value "$1" "${2:-}"; SOURCE_PATH="$2"; shift 2 ;;
    --destination-server) require_value "$1" "${2:-}"; DESTINATION_SERVER="$2"; shift 2 ;;
    --destination-namespace) require_value "$1" "${2:-}"; DESTINATION_NAMESPACE="$2"; shift 2 ;;
    --timeout-seconds) require_value "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --approve) APPROVE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

case "$MODE" in create|update) ;; *) emit_error "Missing or unsupported --mode" "mode" ;; esac
[[ -n "$ARGOCD_SERVER" ]] || emit_error "Missing required argument: --argocd-server" "Argo CD server"
[[ -n "$ARGOCD_APP_NAME" ]] || emit_error "Missing required argument: --argocd-app-name" "Argo CD app name"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || emit_error "--timeout-seconds must be a number" "timeout seconds"

if [[ "$EXECUTION_ENVIRONMENT" != "corporate" && "$DRY_RUN" != "true" ]]; then
  corporate_environment_required_exit
fi

if [[ "$DRY_RUN" == "true" || "$APPROVE" != "true" ]]; then
  next=""
  [[ "$APPROVE" == "true" ]] || next="deployment approval"
  echo "STATUS=OK"
  echo "ACTION=argocd-sync"
  echo "ARGOCD_MODE=${MODE}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
  echo "ARGOCD_SYNC_STATUS=dry-run"
  echo "ARGOCD_HEALTH_STATUS=dry-run"
  echo "ARGOCD_APP_URL=${ARGOCD_SERVER%/}/applications/${ARGOCD_APP_NAME}"
  echo "NEXT_REQUIRED_INPUT=${next}"
  echo "MUTATIONS_PERFORMED=false"
  exit 0
fi

command -v argocd >/dev/null 2>&1 || emit_error "argocd CLI is required but was not found" "argocd CLI"
ARGOCD_ARGS=(--server "$ARGOCD_SERVER")
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$MODE" == "create" ]]; then
  [[ -n "$ARGOCD_PROJECT" && -n "$REPO_URL" && -n "$TARGET_REVISION" && -n "$SOURCE_PATH" && -n "$DESTINATION_SERVER" && -n "$DESTINATION_NAMESPACE" ]] || emit_error "Missing Argo CD create arguments" "Argo CD application spec"
  argocd "${ARGOCD_ARGS[@]}" app create "$ARGOCD_APP_NAME" \
    --repo "$REPO_URL" \
    --revision "$TARGET_REVISION" \
    --path "$SOURCE_PATH" \
    --project "$ARGOCD_PROJECT" \
    --dest-server "$DESTINATION_SERVER" \
    --dest-namespace "$DESTINATION_NAMESPACE" >/dev/null
fi

argocd "${ARGOCD_ARGS[@]}" app sync "$ARGOCD_APP_NAME" >/dev/null
argocd "${ARGOCD_ARGS[@]}" app wait "$ARGOCD_APP_NAME" --sync --health --timeout "$TIMEOUT_SECONDS" >/dev/null
argocd "${ARGOCD_ARGS[@]}" app get "$ARGOCD_APP_NAME" -o json >"$WORK_DIR/app.json"

fields="$(PYTHONPATH="$SKILL_ROOT" python3 - "$WORK_DIR/app.json" <<'PY'
import sys
from scripts.lib.distribution.argocd import app_fields, load_json
fields = app_fields(load_json(sys.argv[1]))
print(fields["sync_status"])
print(fields["health_status"])
PY
)"
sync_status="$(printf '%s\n' "$fields" | sed -n '1p')"
health_status="$(printf '%s\n' "$fields" | sed -n '2p')"

echo "STATUS=OK"
echo "ACTION=argocd-sync"
echo "ARGOCD_MODE=${MODE}"
echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
echo "ARGOCD_SYNC_STATUS=${sync_status}"
echo "ARGOCD_HEALTH_STATUS=${health_status}"
echo "ARGOCD_APP_URL=${ARGOCD_SERVER%/}/applications/${ARGOCD_APP_NAME}"
echo "NEXT_REQUIRED_INPUT="
echo "MUTATIONS_PERFORMED=true"
