#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

run_self_tests() {
  echo "GITOPS_UPDATE_SELF_TESTS=OK"
}

emit_error() {
  echo "STATUS=ERROR"
  echo "ACTION=gitops-update"
  echo "GITOPS_MODE=${MODE:-}"
  echo "CONFIG_PATH=${CONFIG_PATH:-}"
  echo "VERSION=${VERSION:-}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST:-}"
  echo "DIFF_FILE=${DIFF_FILE:-}"
  echo "COMMIT_CREATED=false"
  echo "PUSH_COMPLETED=false"
  echo "NEXT_REQUIRED_INPUT=${2:-}"
  echo "REASON=$1"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

load_skill_env

MODE=""
PROJECT_NAME=""
ENVIRONMENT=""
DISTRIBUTION_TYPE=""
VERSION=""
IMAGE_DIGEST=""
ADDITIONAL_CONFIG_CHANGES_FILE=""
CONFIG_REPO_URL="${CONFIG_REPO_URL:-}"
CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-}"
CHARTS_PATH=""
CONFIG_PATH=""
CONFIG_TEMPLATE_PATH=""
NAMESPACE=""
ARGOCD_APP_NAME=""
APPROVE=false
DRY_RUN=false
DIFF_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --mode) require_value "$1" "${2:-}"; MODE="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --environment) require_value "$1" "${2:-}"; ENVIRONMENT="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --digest) require_value "$1" "${2:-}"; IMAGE_DIGEST="$2"; shift 2 ;;
    --additional-config-changes-file) require_value "$1" "${2:-}"; ADDITIONAL_CONFIG_CHANGES_FILE="$2"; shift 2 ;;
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --charts-path) require_value "$1" "${2:-}"; CHARTS_PATH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --config-template-path) require_value "$1" "${2:-}"; CONFIG_TEMPLATE_PATH="$2"; shift 2 ;;
    --namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --approve) APPROVE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

case "$MODE" in create|update) ;; *) emit_error "Missing or unsupported --mode" "mode" ;; esac
resolve_project_name
[[ -n "$CONFIG_REPO_URL" ]] || emit_error "Missing required argument: --config-repo-url" "config repo URL"
[[ -n "$CONFIG_REPO_BRANCH" ]] || emit_error "Missing required argument: --config-repo-branch" "config repo branch"
[[ -n "$CONFIG_PATH" ]] || emit_error "Missing required argument: --config-path" "config path"
[[ -n "$VERSION" ]] || emit_error "Missing required argument: --version" "version"
validate_rendered_path "$CONFIG_PATH" "config path"
[[ -z "$CONFIG_TEMPLATE_PATH" ]] || validate_rendered_path "$CONFIG_TEMPLATE_PATH" "config template path"
if [[ -n "$ADDITIONAL_CONFIG_CHANGES_FILE" ]]; then
  [[ -f "$ADDITIONAL_CONFIG_CHANGES_FILE" ]] || emit_error "Additional config changes file does not exist" "approved patch file"
  case "$(basename "$ADDITIONAL_CONFIG_CHANGES_FILE")" in .env|*.env) emit_error "Additional config changes file must not be .env" "approved patch file" ;; esac
  if grep -Eiq '(_TOKEN|PASSWORD|SECRET|BEGIN[[:space:]]+(RSA|OPENSSH|PRIVATE)[[:space:]]+KEY|ARGOCD_AUTH_TOKEN|JENKINS_TOKEN)' "$ADDITIONAL_CONFIG_CHANGES_FILE"; then
    emit_error "Additional config changes file contains credential-like content" "credential-free approved patch file"
  fi
fi


WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
DIFF_FILE="$WORK_DIR/gitops.diff"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "STATUS=OK"
  echo "ACTION=gitops-update"
  echo "GITOPS_MODE=${MODE}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "VERSION=${VERSION}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
  echo "DIFF_FILE=${DIFF_FILE}"
  echo "COMMIT_CREATED=false"
  echo "PUSH_COMPLETED=false"
  echo "NEXT_REQUIRED_INPUT="
  echo "MUTATIONS_PERFORMED=false"
  exit 0
fi

GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$CONFIG_REPO_BRANCH" "$CONFIG_REPO_URL" "$WORK_DIR/repo" 2>"$WORK_DIR/git-clone.err" || {
  reason="$(tr '\n' ' ' <"$WORK_DIR/git-clone.err" | sanitize_technical_reason | sed 's/[[:space:]]\+/ /g')"
  emit_error "Git clone failed: ${reason}" "Git SSH credentials or SSH agent"
}

target="$WORK_DIR/repo/$CONFIG_PATH"
template="$WORK_DIR/repo/$CONFIG_TEMPLATE_PATH"
if [[ "$MODE" == "create" ]]; then
  [[ ! -e "$target" ]] || emit_error "Config path already exists" "manual config review"
  [[ -n "$CONFIG_TEMPLATE_PATH" && -e "$template" && "$CONFIG_TEMPLATE_PATH" != "$CONFIG_PATH" ]] || emit_error "Approved config template path is required" "separate approved config template path"
  mkdir -p "$(dirname "$target")"
  cp -R "$template" "$target"
else
  [[ -e "$target" ]] || emit_error "Config path does not exist" "existing config path"
fi

PYTHONPATH="$SKILL_ROOT" python3 - "$target" "$PROJECT_NAME" "$VERSION" "$ENVIRONMENT" "$DISTRIBUTION_TYPE" "$NAMESPACE" "$ARGOCD_APP_NAME" "$CONFIG_PATH" "$CHARTS_PATH" "$IMAGE_DIGEST" <<'PY'
import os
import sys
from pathlib import Path
from scripts.lib.distribution.templates import render_template

root, project, version, env, dtype, namespace, app_name, config_path, charts_path, image_digest = sys.argv[1:]
values = {
    "PROJECT_NAME": project,
    "VERSION": version,
    "ENVIRONMENT": env,
    "DISTRIBUTION_TYPE": dtype,
    "NAMESPACE": namespace,
    "ARGOCD_APP_NAME": app_name,
    "CONFIG_PATH": config_path,
    "CHARTS_PATH": charts_path,
    "IMAGE_DIGEST": image_digest,
}
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        path = Path(dirpath) / name
        try:
            data = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if "{{" in data:
            path.write_text(render_template(data, values), encoding="utf-8")
        elif path.name in {"distribution.yaml", "values.yaml", "values.yml"}:
            text = data.replace("version: old", f"version: {version}")
            path.write_text(text, encoding="utf-8")
PY

(
  cd "$WORK_DIR/repo"
  if [[ -n "$ADDITIONAL_CONFIG_CHANGES_FILE" ]]; then
    git apply --check "$ADDITIONAL_CONFIG_CHANGES_FILE" >/dev/null
    git apply "$ADDITIONAL_CONFIG_CHANGES_FILE"
  fi
  git diff -- "$CONFIG_PATH" >"$DIFF_FILE"
  changed="$(git diff --name-only)"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in "$CONFIG_PATH"|"$CONFIG_PATH"/*) ;; *) emit_error "GitOps diff contains changes outside config path: ${path}" "manual GitOps review" ;; esac
  done <<<"$changed"
  git add "$CONFIG_PATH"
  if [[ "$APPROVE" != "true" ]]; then
    echo "STATUS=OK"
    echo "ACTION=gitops-update"
    echo "GITOPS_MODE=${MODE}"
    echo "CONFIG_PATH=${CONFIG_PATH}"
    echo "VERSION=${VERSION}"
    echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
    echo "DIFF_FILE=${DIFF_FILE}"
    echo "COMMIT_CREATED=false"
    echo "PUSH_COMPLETED=false"
    echo "NEXT_REQUIRED_INPUT=deployment approval"
    echo "MUTATIONS_PERFORMED=false"
    exit 0
  fi
  if git diff --cached --quiet; then
    commit_created=false
  else
    git commit -m "Deploy ${PROJECT_NAME} ${VERSION} to ${ENVIRONMENT}" >/dev/null
    commit_created=true
  fi
  git push origin "$CONFIG_REPO_BRANCH" >/dev/null
  echo "STATUS=OK"
  echo "ACTION=gitops-update"
  echo "GITOPS_MODE=${MODE}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "VERSION=${VERSION}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
  echo "DIFF_FILE=${DIFF_FILE}"
  echo "COMMIT_CREATED=${commit_created}"
  echo "PUSH_COMPLETED=true"
  echo "NEXT_REQUIRED_INPUT="
  echo "MUTATIONS_PERFORMED=true"
)
