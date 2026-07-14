#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

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

Compatibility wrapper. New read-only flows should use:
  scripts/gitops-check.sh
  scripts/argocd-check.sh
EOF
}

CONFIG_REPO_URL=""
CONFIG_REPO_BRANCH=""
CONFIG_PATH=""
ARGOCD_SERVER=""
ARGOCD_APP_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "blocked" "$1" ;;
  esac
done

[[ -n "$CONFIG_REPO_URL" ]] || error_exit "Missing required argument: --config-repo-url" "blocked" "config repo URL"
[[ -n "$CONFIG_REPO_BRANCH" ]] || error_exit "Missing required argument: --config-repo-branch" "blocked" "config repo branch"
[[ -n "$CONFIG_PATH" ]] || error_exit "Missing required argument: --config-path" "blocked" "config path"
[[ -n "$ARGOCD_SERVER" ]] || error_exit "Missing required argument: --argocd-server" "blocked" "Argo CD server"
[[ -n "$ARGOCD_APP_NAME" ]] || error_exit "Missing required argument: --argocd-app-name" "blocked" "Argo CD app name"

set +e
gitops_output="$(
  bash "$SCRIPT_DIR/gitops-check.sh" \
      --config-repo-url "$CONFIG_REPO_URL" \
    --config-repo-branch "$CONFIG_REPO_BRANCH" \
    --config-path "$CONFIG_PATH" \
    --charts-path "." \
    --config-template-path "$CONFIG_PATH"
)"
gitops_rc=$?
set -e
if [[ $gitops_rc -ne 0 ]]; then
  printf '%s\n' "$gitops_output"
  exit "$gitops_rc"
fi

set +e
argo_output="$(
  bash "$SCRIPT_DIR/argocd-check.sh" \
      --argocd-server "$ARGOCD_SERVER" \
    --argocd-app-name "$ARGOCD_APP_NAME"
)"
argo_rc=$?
set -e
if [[ $argo_rc -ne 0 ]]; then
  printf '%s\n' "$argo_output"
  exit "$argo_rc"
fi

config_exists="$(value_from_output "$gitops_output" "CONFIG_EXISTS")"
argocd_app_exists="$(value_from_output "$argo_output" "ARGOCD_APP_EXISTS")"
deployment_mode="$(deployment_mode_for_state "$config_exists" "$argocd_app_exists")"
first_deployment="false"
[[ "$deployment_mode" == "create" ]] && first_deployment="true"

echo "STATUS=OK"
echo "CONFIG_EXISTS=${config_exists}"
echo "ARGOCD_APP_EXISTS=${argocd_app_exists}"
echo "FIRST_DEPLOYMENT=${first_deployment}"
echo "DEPLOYMENT_MODE=${deployment_mode}"
echo "MUTATIONS_PERFORMED=false"
