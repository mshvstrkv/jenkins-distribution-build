#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

run_self_tests() {
  validate_rendered_path "charts/payment-orders" "charts path"
  validate_rendered_path "stands/ift/app/payment-orders" "config path"
  if ( validate_rendered_path "../bad" "bad path" ) >/dev/null 2>&1; then
    echo "GITOPS_CHECK_SELF_TESTS=FAIL"
    exit 1
  fi
  echo "GITOPS_CHECK_SELF_TESTS=OK"
}

emit_error() {
  echo "STATUS=ERROR"
  echo "ACTION=gitops-check"
  echo "CONFIG_REPO_ACCESSIBLE=${CONFIG_REPO_ACCESSIBLE:-false}"
  echo "CONFIG_REPO_BRANCH=${CONFIG_REPO_BRANCH:-}"
  echo "CHARTS_PATH=${CHARTS_PATH:-}"
  echo "CHARTS_EXISTS=${CHARTS_EXISTS:-false}"
  echo "CONFIG_PATH=${CONFIG_PATH:-}"
  echo "CONFIG_EXISTS=${CONFIG_EXISTS:-false}"
  echo "CONFIG_TEMPLATE_PATH=${CONFIG_TEMPLATE_PATH:-}"
  echo "CONFIG_TEMPLATE_EXISTS=${CONFIG_TEMPLATE_EXISTS:-false}"
  echo "GITOPS_REASON=$1"
  echo "GITOPS_NEXT_REQUIRED_INPUT=${2:-}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

load_skill_env

EXECUTION_ENVIRONMENT="${EXECUTION_ENVIRONMENT:-local}"
PROJECT_NAME=""
ENVIRONMENT="ift"
CONFIG_REPO_URL="${CONFIG_REPO_URL:-}"
CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-}"
CHARTS_PATH=""
CONFIG_PATH=""
CONFIG_TEMPLATE_PATH=""
CONFIG_REPO_ACCESSIBLE=false
CHARTS_EXISTS=false
CONFIG_EXISTS=false
CONFIG_TEMPLATE_EXISTS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --execution-environment) require_value "$1" "${2:-}"; EXECUTION_ENVIRONMENT="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --environment) require_value "$1" "${2:-}"; ENVIRONMENT="$2"; shift 2 ;;
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --charts-path) require_value "$1" "${2:-}"; CHARTS_PATH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --config-template-path) require_value "$1" "${2:-}"; CONFIG_TEMPLATE_PATH="$2"; shift 2 ;;
    --help|-h) exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

[[ -n "$CONFIG_REPO_URL" ]] || emit_error "Missing required argument: --config-repo-url" "config repo URL"
[[ -n "$CONFIG_REPO_BRANCH" ]] || emit_error "Missing required argument: --config-repo-branch" "config repo branch"
[[ -n "$CHARTS_PATH" ]] || emit_error "Missing required argument: --charts-path" "charts path"
[[ -n "$CONFIG_PATH" ]] || emit_error "Missing required argument: --config-path" "config path"
[[ -n "$CONFIG_TEMPLATE_PATH" ]] || emit_error "Missing required argument: --config-template-path" "config template path"
validate_rendered_path "$CHARTS_PATH" "charts path"
validate_rendered_path "$CONFIG_PATH" "config path"
validate_rendered_path "$CONFIG_TEMPLATE_PATH" "config template path"

if [[ "$EXECUTION_ENVIRONMENT" != "corporate" ]]; then
  corporate_environment_required_exit
fi

command -v git >/dev/null 2>&1 || emit_error "git is required but was not found" "git"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$CONFIG_REPO_URL" "$CONFIG_REPO_BRANCH" >/dev/null 2>"$WORK_DIR/git-ls-remote.err"; then
  reason="$(tr '\n' ' ' <"$WORK_DIR/git-ls-remote.err" | sanitize_technical_reason | sed 's/[[:space:]]\+/ /g')"
  emit_error "Git SSH authentication failed: ${reason}" "Git SSH credentials or SSH agent"
fi
CONFIG_REPO_ACCESSIBLE=true

if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$CONFIG_REPO_BRANCH" "$CONFIG_REPO_URL" "$WORK_DIR/repo" 2>"$WORK_DIR/git-clone.err"; then
  reason="$(tr '\n' ' ' <"$WORK_DIR/git-clone.err" | sanitize_technical_reason | sed 's/[[:space:]]\+/ /g')"
  emit_error "Git clone failed: ${reason}" "Git SSH credentials or SSH agent"
fi

[[ -e "$WORK_DIR/repo/$CHARTS_PATH" ]] && CHARTS_EXISTS=true || CHARTS_EXISTS=false
[[ -e "$WORK_DIR/repo/$CONFIG_PATH" ]] && CONFIG_EXISTS=true || CONFIG_EXISTS=false
[[ -e "$WORK_DIR/repo/$CONFIG_TEMPLATE_PATH" ]] && CONFIG_TEMPLATE_EXISTS=true || CONFIG_TEMPLATE_EXISTS=false

echo "STATUS=OK"
echo "ACTION=gitops-check"
echo "CONFIG_REPO_ACCESSIBLE=${CONFIG_REPO_ACCESSIBLE}"
echo "CONFIG_REPO_BRANCH=${CONFIG_REPO_BRANCH}"
echo "CHARTS_PATH=${CHARTS_PATH}"
echo "CHARTS_EXISTS=${CHARTS_EXISTS}"
echo "CONFIG_PATH=${CONFIG_PATH}"
echo "CONFIG_EXISTS=${CONFIG_EXISTS}"
echo "CONFIG_TEMPLATE_PATH=${CONFIG_TEMPLATE_PATH}"
echo "CONFIG_TEMPLATE_EXISTS=${CONFIG_TEMPLATE_EXISTS}"
echo "GITOPS_REASON="
echo "GITOPS_NEXT_REQUIRED_INPUT="
echo "MUTATIONS_PERFORMED=false"

