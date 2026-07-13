#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_skill_env

usage() {
  cat <<'EOF'
Usage:
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
    [--execution-environment <local|corporate>] \
    [--approve] \
    [--dry-run]

Compatibility wrapper. New flows should use scripts/argocd-sync.sh.
EOF
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
EXECUTION_ENVIRONMENT="${EXECUTION_ENVIRONMENT:-local}"
APPROVE_ARGS=()
DRY_RUN_ARGS=()

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
    --approve) APPROVE_ARGS=(--approve); shift ;;
    --dry-run) DRY_RUN_ARGS=(--dry-run); shift ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "blocked" "$1" ;;
  esac
done

exec bash "$SCRIPT_DIR/argocd-sync.sh" \
  --execution-environment "$EXECUTION_ENVIRONMENT" \
  --mode "$MODE" \
  --argocd-server "$ARGOCD_SERVER" \
  --argocd-app-name "$ARGOCD_APP_NAME" \
  --argocd-project "$ARGOCD_PROJECT" \
  --repo-url "$CONFIG_REPO_URL" \
  --target-revision "$CONFIG_REPO_BRANCH" \
  --source-path "$CONFIG_PATH" \
  --destination-server "$ARGOCD_DESTINATION_SERVER" \
  --destination-namespace "$ARGOCD_DESTINATION_NAMESPACE" \
  --timeout-seconds "$TIMEOUT_SECONDS" \
  "${APPROVE_ARGS[@]}" \
  "${DRY_RUN_ARGS[@]}"
