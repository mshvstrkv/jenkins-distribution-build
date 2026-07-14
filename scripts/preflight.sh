#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/preflight.sh \
    --jenkins-url <url> \
    --project-name <name> \
    --branch <branch> \
    --distribution-type <ift|release> \
    [--job-name <name>] \
    [--version <version>] \
    [--config-repo-url <url>] \
    [--config-repo-branch <branch>] \
    [--charts-path <path>] \
    [--charts-path-template <template>] \
    [--config-path <path>] \
    [--config-path-template <template>] \
    [--config-template-path <path>] \
    [--config-template-path-template <template>] \
    [--argocd-server <server>] \
    [--argocd-app-name <name>] \
    [--argocd-app-name-template <template>] \
    [--argocd-project <project>] \
    [--argocd-destination-server <server>] \
    [--argocd-destination-namespace <namespace>] \
    --environment <ift|release|test>
EOF
}

run_self_tests() {
  local failed=0

  [[ "$(stage_result_status OK OK OK)" == "OK:SUCCESS" ]] || { echo "FAIL all success"; failed=1; }
  [[ "$(stage_result_status FAILED OK OK)" == "PARTIAL:FAILED" ]] || { echo "FAIL jenkins failed partial"; failed=1; }
  [[ "$(stage_result_status OK FAILED OK)" == "PARTIAL:FAILED" ]] || { echo "FAIL gitops failed partial"; failed=1; }
  [[ "$(deployment_mode_from_values true false)" == "inconsistent:ERROR" ]] || { echo "FAIL inconsistent deployment"; failed=1; }
  [[ "$(deployment_mode_from_values false false)" == "create:OK" ]] || { echo "FAIL create deployment"; failed=1; }
  [[ "$(deployment_mode_from_values true true)" == "update:OK" ]] || { echo "FAIL update deployment"; failed=1; }

  PROJECT_NAME=ai-payments-merchant-registry
  ENVIRONMENT=ift
  DISTRIBUTION_TYPE=ift
  VERSION=IFT-0.0.1
  ARGOCD_DESTINATION_NAMESPACE=ci11366566-sberaipay
  ARGOCD_APP_NAME=""
  CONFIG_PATH=""
  CHARTS_PATH=""
  local rendered
  rendered="$(render_template 'charts/{{PROJECT_NAME}}')" || failed=1
  [[ "$rendered" == "charts/ai-payments-merchant-registry" ]] || { echo "FAIL charts render"; failed=1; }
  rendered="$(render_template 'bdifb2y7-{{PROJECT_NAME}}')" || failed=1
  [[ "$rendered" == "bdifb2y7-ai-payments-merchant-registry" ]] || { echo "FAIL app render"; failed=1; }

  if [[ "$failed" == "0" ]]; then
    echo "PREFLIGHT_SELF_TESTS=OK"
  else
    echo "PREFLIGHT_SELF_TESTS=FAIL"
    exit 1
  fi
}

stage_result_status() {
  local jenkins="$1"
  local gitops="$2"
  local argo="$3"
  if [[ "$jenkins" == "OK" && "$gitops" == "OK" && "$argo" == "OK" ]]; then
    echo "OK:SUCCESS"
  elif [[ "$jenkins" == "NOT_RUN" && "$gitops" == "NOT_RUN" && "$argo" == "NOT_RUN" ]]; then
    echo "ERROR:NOT_RUN"
  else
    echo "PARTIAL:FAILED"
  fi
}

deployment_mode_from_values() {
  local config_exists="$1"
  local app_exists="$2"
  if [[ "$config_exists" == "false" && "$app_exists" == "false" ]]; then
    echo "create:OK"
  elif [[ "$config_exists" == "true" && "$app_exists" == "true" ]]; then
    echo "update:OK"
  else
    echo "inconsistent:ERROR"
  fi
}

set_stage_failed_from_output() {
  local prefix="$1"
  local file="$2"
  local reason next
  reason="$(value_from_output REASON "$file")"
  next="$(value_from_output NEXT_REQUIRED_INPUT "$file")"
  printf -v "${prefix}_REASON" '%s' "$reason"
  printf -v "${prefix}_NEXT_REQUIRED_INPUT" '%s' "$next"
}

curl_http_capture_error() {
  local body_file="$1"
  local headers_file="$2"
  local error_file="$3"
  shift 3
  local status
  if ! status="$(curl --silent --show-error --output "$body_file" --dump-header "$headers_file" --write-out '%{http_code}' "$@" 2>"$error_file")"; then
    status="000"
  fi
  printf '%s' "$status"
}

json_jenkins_parameters() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

names = []
for prop in payload.get("property") or []:
    for definition in prop.get("parameterDefinitions") or []:
        name = definition.get("name")
        if name:
            names.append(name)
print(",".join(names))
PY
}

json_argocd_app_fields() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

spec = payload.get("spec") or {}
source = spec.get("source") or {}
dest = spec.get("destination") or {}
print(f"ARGOCD_PROJECT={spec.get('project', '')}")
print(f"ARGOCD_REPO_URL={source.get('repoURL', '')}")
print(f"ARGOCD_TARGET_REVISION={source.get('targetRevision', '')}")
print(f"ARGOCD_SOURCE_PATH={source.get('path', '')}")
print(f"ARGOCD_DESTINATION_SERVER={dest.get('server', '')}")
print(f"ARGOCD_DESTINATION_NAMESPACE={dest.get('namespace', '')}")
PY
}

apply_ift_defaults() {
  if [[ "$ENVIRONMENT" == "ift" ]]; then
    CONFIG_REPO_URL="${CONFIG_REPO_URL:-ssh://git@sbrf-bitbucket.sigma.sbrf.ru:7999/ci11366566/ci11366566_sberaipay_gitopscd.git}"
    CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-ift}"
    [[ -n "$CHARTS_PATH_TEMPLATE" ]] || CHARTS_PATH_TEMPLATE='charts/{{PROJECT_NAME}}'
    [[ -n "$CONFIG_PATH_TEMPLATE" ]] || CONFIG_PATH_TEMPLATE='stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}'
    [[ -n "$CONFIG_TEMPLATE_PATH_TEMPLATE" ]] || CONFIG_TEMPLATE_PATH_TEMPLATE='stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}'
    ARGOCD_SERVER="${ARGOCD_SERVER:-argocd.apps.bbmwbllt.k8s.sigma.sbrf.ru}"
    [[ -n "$ARGOCD_APP_NAME_TEMPLATE" ]] || ARGOCD_APP_NAME_TEMPLATE='bdifb2y7-{{PROJECT_NAME}}'
    ARGOCD_PROJECT="${ARGOCD_PROJECT:-bdifb2y7.k8s.delta.sbrf.ru-ci11366566-sberaipay}"
    ARGOCD_DESTINATION_NAMESPACE="${ARGOCD_DESTINATION_NAMESPACE:-ci11366566-sberaipay}"
  fi
}

render_config_values() {
  if [[ -z "$CHARTS_PATH" && -n "$CHARTS_PATH_TEMPLATE" ]]; then
    render_template_into CHARTS_PATH "$CHARTS_PATH_TEMPLATE" "charts path"
  fi
  if [[ -z "$CONFIG_PATH" && -n "$CONFIG_PATH_TEMPLATE" ]]; then
    render_template_into CONFIG_PATH "$CONFIG_PATH_TEMPLATE" "config path"
  fi
  if [[ -z "$CONFIG_TEMPLATE_PATH" && -n "$CONFIG_TEMPLATE_PATH_TEMPLATE" ]]; then
    render_template_into CONFIG_TEMPLATE_PATH "$CONFIG_TEMPLATE_PATH_TEMPLATE" "config template path"
  fi
  if [[ -z "$ARGOCD_APP_NAME" && -n "$ARGOCD_APP_NAME_TEMPLATE" ]]; then
    render_template_into ARGOCD_APP_NAME "$ARGOCD_APP_NAME_TEMPLATE" "Argo CD app name"
  fi
  [[ -z "$CHARTS_PATH" ]] || validate_rendered_path "$CHARTS_PATH" "charts path"
  [[ -z "$CONFIG_PATH" ]] || validate_rendered_path "$CONFIG_PATH" "config path"
  [[ -z "$CONFIG_TEMPLATE_PATH" ]] || validate_rendered_path "$CONFIG_TEMPLATE_PATH" "config template path"
}

run_jenkins_stage() {
  if [[ -z "$JENKINS_URL" || -z "$PROJECT_NAME" || -z "$BRANCH" || -z "$DISTRIBUTION_TYPE" ]]; then
    JENKINS_PREFLIGHT=NOT_RUN
    JENKINS_REASON="Missing required Jenkins input"
    JENKINS_NEXT_REQUIRED_INPUT="Jenkins URL, project name, branch, distribution type"
    return 0
  fi

  JENKINS_PREFLIGHT=FAILED
  local lookup_output="$WORK_DIR/jenkins-lookup.out"
  local lookup_args=(
    "$SCRIPT_DIR/jenkins-lookup.sh"
      --jenkins-url "$JENKINS_URL"
    --project-name "$PROJECT_NAME"
    --branch "$BRANCH"
  )
  [[ -n "$JOB_NAME_ARG" ]] && lookup_args+=(--job-name "$JOB_NAME_ARG")
  if ! run_and_capture "$lookup_output" env SKILL_ENV_WARNING_EMITTED=1 bash "${lookup_args[@]}" >/dev/null; then
    JENKINS_LOOKUP=FAILED
    set_stage_failed_from_output JENKINS "$lookup_output"
    return 0
  fi

  JENKINS_LOOKUP=OK
  JENKINS_JOB_EXISTS="$(value_from_output EXISTS "$lookup_output")"
  JOB_NAME="$(value_from_output JOB_NAME "$lookup_output")"
  JOB_URL="$(value_from_output JOB_URL "$lookup_output")"
  if [[ "$JENKINS_JOB_EXISTS" != "true" ]]; then
    JENKINS_REASON="Jenkins job not found"
    JENKINS_NEXT_REQUIRED_INPUT="existing Jenkins job"
    return 0
  fi

  JENKINS_METADATA_URL="${JOB_URL%/}/api/json?tree=property[parameterDefinitions[name]]"
  local meta="$WORK_DIR/jenkins-job.json"
  local headers="$WORK_DIR/jenkins-job.headers"
  local err="$WORK_DIR/jenkins-metadata.err"
  local status
  status="$(curl_http_capture_error "$meta" "$headers" "$err" --globoff --user "${JENKINS_USER}:${JENKINS_TOKEN}" "$JENKINS_METADATA_URL")"
  if [[ "$status" == "000" ]]; then
    JENKINS_METADATA=FAILED
    JENKINS_REASON="Failed to connect to Jenkins job metadata endpoint"
    JENKINS_NEXT_REQUIRED_INPUT="Jenkins API access"
    JENKINS_TECHNICAL_REASON="$(tr '\n' ' ' <"$err" | sanitize_technical_reason | sed 's/[[:space:]]\+/ /g')"
    return 0
  fi
  if [[ "$status" != "200" ]]; then
    JENKINS_METADATA=FAILED
    JENKINS_REASON="Failed to read Jenkins job metadata: HTTP ${status}"
    JENKINS_NEXT_REQUIRED_INPUT="Jenkins API access"
    return 0
  fi
  JENKINS_METADATA=OK

  local param_names
  param_names="$(json_jenkins_parameters "$meta")"
  has_csv_value "$param_names" "$JENKINS_BRANCH_PARAM" && JENKINS_PARAMETER_BRANCH="$JENKINS_BRANCH_PARAM"
  has_csv_value "$param_names" "$JENKINS_VERSION_PARAM" && JENKINS_PARAMETER_VERSION="$JENKINS_VERSION_PARAM"
  has_csv_value "$param_names" "$JENKINS_DISTRIBUTION_TYPE_PARAM" && JENKINS_PARAMETER_DISTRIBUTION_TYPE="$JENKINS_DISTRIBUTION_TYPE_PARAM"
  if [[ -z "$JENKINS_PARAMETER_VERSION" || -z "$JENKINS_PARAMETER_DISTRIBUTION_TYPE" ]]; then
    JENKINS_REASON="Jenkins parameter mapping mismatch"
    JENKINS_NEXT_REQUIRED_INPUT="Jenkins parameter mapping"
    return 0
  fi

  local version_output="$WORK_DIR/version.out"
  local version_args=(
    "$SCRIPT_DIR/version-resolver.sh"
      --jenkins-url "$JENKINS_URL"
    --project-name "$PROJECT_NAME"
    --job-name "$JOB_NAME"
    --distribution-type "$DISTRIBUTION_TYPE"
  )
  [[ -n "$VERSION" ]] && version_args+=(--version "$VERSION")
  if ! run_and_capture "$version_output" env SKILL_ENV_WARNING_EMITTED=1 bash "${version_args[@]}" >/dev/null; then
    set_stage_failed_from_output JENKINS "$version_output"
    return 0
  fi

  PREVIOUS_VERSION="$(value_from_output PREVIOUS_VERSION "$version_output")"
  VERSION="$(value_from_output VERSION "$version_output")"
  VERSION_SOURCE="$(value_from_output VERSION_SOURCE "$version_output")"
  JENKINS_PREFLIGHT=OK
  JENKINS_REASON=""
  JENKINS_NEXT_REQUIRED_INPUT=""
}

run_gitops_stage() {
  if [[ -z "$CONFIG_REPO_URL" || -z "$CONFIG_REPO_BRANCH" || -z "$CONFIG_PATH" || -z "$CONFIG_TEMPLATE_PATH" || -z "$CHARTS_PATH" ]]; then
    GITOPS_PREFLIGHT=NOT_RUN
    GITOPS_REASON="Missing required GitOps input"
    GITOPS_NEXT_REQUIRED_INPUT="config repo URL, branch, charts/config/template paths"
    return 0
  fi

  GITOPS_PREFLIGHT=FAILED
  local output="$WORK_DIR/gitops-check.out"
  if ! run_and_capture "$output" env SKILL_ENV_WARNING_EMITTED=1 bash "$SCRIPT_DIR/gitops-check.sh" \
      --project-name "$PROJECT_NAME" \
    --environment "$ENVIRONMENT" \
    --config-repo-url "$CONFIG_REPO_URL" \
    --config-repo-branch "$CONFIG_REPO_BRANCH" \
    --charts-path "$CHARTS_PATH" \
    --config-path "$CONFIG_PATH" \
    --config-template-path "$CONFIG_TEMPLATE_PATH" >/dev/null; then
    GITOPS_REASON="$(value_from_output GITOPS_REASON "$output")"
    GITOPS_NEXT_REQUIRED_INPUT="$(value_from_output GITOPS_NEXT_REQUIRED_INPUT "$output")"
  else
    GITOPS_PREFLIGHT=OK
    GITOPS_REASON=""
    GITOPS_NEXT_REQUIRED_INPUT=""
  fi
  CONFIG_REPO_ACCESSIBLE="$(value_from_output CONFIG_REPO_ACCESSIBLE "$output")"
  CHARTS_EXISTS="$(value_from_output CHARTS_EXISTS "$output")"
  CONFIG_EXISTS="$(value_from_output CONFIG_EXISTS "$output")"
  CONFIG_TEMPLATE_EXISTS="$(value_from_output CONFIG_TEMPLATE_EXISTS "$output")"
}

run_argo_stage() {
  if [[ -z "$ARGOCD_SERVER" || -z "$ARGOCD_APP_NAME" ]]; then
    ARGO_PREFLIGHT=NOT_RUN
    ARGO_REASON="Missing required Argo CD input"
    ARGO_NEXT_REQUIRED_INPUT="Argo CD server and app name"
    return 0
  fi

  ARGO_PREFLIGHT=FAILED
  local output="$WORK_DIR/argocd-check.out"
  if ! run_and_capture "$output" env SKILL_ENV_WARNING_EMITTED=1 bash "$SCRIPT_DIR/argocd-check.sh" \
      --argocd-server "$ARGOCD_SERVER" \
    --argocd-app-name "$ARGOCD_APP_NAME" >/dev/null; then
    ARGO_REASON="$(value_from_output ARGO_REASON "$output")"
    ARGO_NEXT_REQUIRED_INPUT="$(value_from_output ARGO_NEXT_REQUIRED_INPUT "$output")"
  else
    ARGO_PREFLIGHT=OK
    ARGO_REASON=""
    ARGO_NEXT_REQUIRED_INPUT=""
  fi
  ARGOCD_CLI_AVAILABLE="$(value_from_output ARGOCD_CLI_AVAILABLE "$output")"
  ARGOCD_AUTHENTICATED="$(value_from_output ARGOCD_AUTHENTICATED "$output")"
  ARGOCD_APP_EXISTS="$(value_from_output ARGOCD_APP_EXISTS "$output")"
  ARGOCD_PROJECT="$(value_from_output ARGOCD_PROJECT "$output")"
  ARGOCD_REPO_URL="$(value_from_output ARGOCD_REPO_URL "$output")"
  ARGOCD_TARGET_REVISION="$(value_from_output ARGOCD_TARGET_REVISION "$output")"
  ARGOCD_SOURCE_PATH="$(value_from_output ARGOCD_SOURCE_PATH "$output")"
  ARGOCD_DESTINATION_SERVER="$(value_from_output ARGOCD_DESTINATION_SERVER "$output")"
  ARGOCD_DESTINATION_NAMESPACE="$(value_from_output ARGOCD_DESTINATION_NAMESPACE "$output")"
  ARGOCD_SYNC_STATUS="$(value_from_output ARGOCD_SYNC_STATUS "$output")"
  ARGOCD_HEALTH_STATUS="$(value_from_output ARGOCD_HEALTH_STATUS "$output")"
}

emit_report() {
  local status_pair
  status_pair="$(stage_result_status "$JENKINS_PREFLIGHT" "$GITOPS_PREFLIGHT" "$ARGO_PREFLIGHT")"
  STATUS="${status_pair%%:*}"
  PREFLIGHT_RESULT="${status_pair#*:}"
  if [[ "$COMMON_INPUT_MISSING" == "true" ]]; then
    STATUS=ERROR
    PREFLIGHT_RESULT=NOT_RUN
  fi

  DEPLOYMENT_MODE=unknown
  DEPLOYMENT_STATE=UNKNOWN
  if [[ "$GITOPS_PREFLIGHT" == "OK" && "$ARGO_PREFLIGHT" == "OK" ]]; then
    local mode_pair
    mode_pair="$(deployment_mode_from_values "$CONFIG_EXISTS" "$ARGOCD_APP_EXISTS")"
    DEPLOYMENT_MODE="${mode_pair%%:*}"
    DEPLOYMENT_STATE="${mode_pair#*:}"
    if [[ "$DEPLOYMENT_STATE" == "ERROR" && "$STATUS" == "OK" ]]; then
      STATUS=PARTIAL
      PREFLIGHT_RESULT=FAILED
    fi
  fi

  echo "STATUS=${STATUS}"
  if [[ "$STATUS" == "ERROR" ]]; then
    echo "ACTION=blocked"
  else
    echo "ACTION=preflight"
  fi
  echo "PREFLIGHT_RESULT=${PREFLIGHT_RESULT}"
    echo "PROJECT_NAME=${PROJECT_NAME}"
  echo "BRANCH=${BRANCH}"
  echo "MUTATIONS_PERFORMED=false"

  echo "JENKINS_PREFLIGHT=${JENKINS_PREFLIGHT}"
  echo "JENKINS_LOOKUP=${JENKINS_LOOKUP}"
  echo "JENKINS_JOB_EXISTS=${JENKINS_JOB_EXISTS}"
  echo "JOB_NAME=${JOB_NAME}"
  echo "JOB_URL=${JOB_URL}"
  echo "JENKINS_METADATA_URL=${JENKINS_METADATA_URL}"
  echo "JENKINS_METADATA=${JENKINS_METADATA}"
  echo "JENKINS_PARAMETER_BRANCH=${JENKINS_PARAMETER_BRANCH}"
  echo "JENKINS_PARAMETER_VERSION=${JENKINS_PARAMETER_VERSION}"
  echo "JENKINS_PARAMETER_DISTRIBUTION_TYPE=${JENKINS_PARAMETER_DISTRIBUTION_TYPE}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
  echo "PREVIOUS_VERSION=${PREVIOUS_VERSION}"
  echo "VERSION=${VERSION}"
  echo "VERSION_SOURCE=${VERSION_SOURCE}"
  echo "JENKINS_REASON=${JENKINS_REASON}"
  echo "JENKINS_NEXT_REQUIRED_INPUT=${JENKINS_NEXT_REQUIRED_INPUT}"

  echo "GITOPS_PREFLIGHT=${GITOPS_PREFLIGHT}"
  echo "CONFIG_REPO_ACCESSIBLE=${CONFIG_REPO_ACCESSIBLE}"
  echo "CONFIG_REPO_BRANCH=${CONFIG_REPO_BRANCH}"
  echo "CHARTS_PATH=${CHARTS_PATH}"
  echo "CHARTS_EXISTS=${CHARTS_EXISTS}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "CONFIG_EXISTS=${CONFIG_EXISTS}"
  echo "CONFIG_TEMPLATE_PATH=${CONFIG_TEMPLATE_PATH}"
  echo "CONFIG_TEMPLATE_EXISTS=${CONFIG_TEMPLATE_EXISTS}"
  echo "GITOPS_REASON=${GITOPS_REASON}"
  echo "GITOPS_NEXT_REQUIRED_INPUT=${GITOPS_NEXT_REQUIRED_INPUT}"

  echo "ARGO_PREFLIGHT=${ARGO_PREFLIGHT}"
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
  echo "ARGO_REASON=${ARGO_REASON}"
  echo "ARGO_NEXT_REQUIRED_INPUT=${ARGO_NEXT_REQUIRED_INPUT}"

  echo "DEPLOYMENT_MODE=${DEPLOYMENT_MODE}"
  echo "DEPLOYMENT_STATE=${DEPLOYMENT_STATE}"
  if [[ "$STATUS" == "ERROR" ]]; then
    echo "NEXT_REQUIRED_INPUT=${COMMON_NEXT_REQUIRED_INPUT:-required input}"
    exit 1
  fi
  [[ "$STATUS" == "OK" ]]
}

load_skill_env

JENKINS_URL="${JENKINS_URL:-}"
PROJECT_NAME=""
BRANCH=""
JOB_NAME_ARG=""
DISTRIBUTION_TYPE=""
VERSION=""
CONFIG_REPO_URL="${CONFIG_REPO_URL:-}"
CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-}"
CHARTS_PATH="${CHARTS_PATH:-}"
CHARTS_PATH_TEMPLATE="${CHARTS_PATH_TEMPLATE:-}"
CONFIG_PATH="${CONFIG_PATH:-}"
CONFIG_PATH_TEMPLATE="${CONFIG_PATH_TEMPLATE:-}"
CONFIG_TEMPLATE_PATH="${CONFIG_TEMPLATE_PATH:-}"
CONFIG_TEMPLATE_PATH_TEMPLATE="${CONFIG_TEMPLATE_PATH_TEMPLATE:-}"
ARGOCD_SERVER="${ARGOCD_SERVER:-}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-}"
ARGOCD_APP_NAME_TEMPLATE="${ARGOCD_APP_NAME_TEMPLATE:-}"
ARGOCD_PROJECT="${ARGOCD_PROJECT:-}"
ARGOCD_DESTINATION_SERVER="${ARGOCD_DESTINATION_SERVER:-}"
ARGOCD_DESTINATION_NAMESPACE="${ARGOCD_DESTINATION_NAMESPACE:-}"
ENVIRONMENT="ift"
JENKINS_BRANCH_PARAM="BRANCH"
JENKINS_VERSION_PARAM="VERSION"
JENKINS_DISTRIBUTION_TYPE_PARAM="DISTRIBUTION_TYPE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --jenkins-url) require_value "$1" "${2:-}"; JENKINS_URL="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME_ARG="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --charts-path) require_value "$1" "${2:-}"; CHARTS_PATH="$2"; shift 2 ;;
    --charts-path-template) require_value "$1" "${2:-}"; CHARTS_PATH_TEMPLATE="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --config-path-template) require_value "$1" "${2:-}"; CONFIG_PATH_TEMPLATE="$2"; shift 2 ;;
    --config-template-path) require_value "$1" "${2:-}"; CONFIG_TEMPLATE_PATH="$2"; shift 2 ;;
    --config-template-path-template) require_value "$1" "${2:-}"; CONFIG_TEMPLATE_PATH_TEMPLATE="$2"; shift 2 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --argocd-app-name-template) require_value "$1" "${2:-}"; ARGOCD_APP_NAME_TEMPLATE="$2"; shift 2 ;;
    --argocd-project) require_value "$1" "${2:-}"; ARGOCD_PROJECT="$2"; shift 2 ;;
    --argocd-destination-server) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_SERVER="$2"; shift 2 ;;
    --argocd-destination-namespace) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_NAMESPACE="$2"; shift 2 ;;
    --environment) require_value "$1" "${2:-}"; ENVIRONMENT="$2"; shift 2 ;;
    --jenkins-branch-param) require_value "$1" "${2:-}"; JENKINS_BRANCH_PARAM="$2"; shift 2 ;;
    --jenkins-version-param) require_value "$1" "${2:-}"; JENKINS_VERSION_PARAM="$2"; shift 2 ;;
    --jenkins-distribution-type-param) require_value "$1" "${2:-}"; JENKINS_DISTRIBUTION_TYPE_PARAM="$2"; shift 2 ;;
    --preflight) shift ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

resolve_project_name
resolve_branch

if [[ -n "$DISTRIBUTION_TYPE" ]]; then
  raw_distribution_type="$DISTRIBUTION_TYPE"
  if ! DISTRIBUTION_TYPE="$(normalize_distribution_type "$raw_distribution_type")"; then
    error_exit "Unsupported distribution type: ${raw_distribution_type}" "ift or release"
  fi
fi

apply_ift_defaults

COMMON_INPUT_MISSING=false
COMMON_NEXT_REQUIRED_INPUT=""

JENKINS_PREFLIGHT=NOT_RUN
JENKINS_LOOKUP=NOT_RUN
JENKINS_JOB_EXISTS=false
JOB_NAME=""
JOB_URL=""
JENKINS_METADATA_URL=""
JENKINS_METADATA=NOT_RUN
JENKINS_PARAMETER_BRANCH=""
JENKINS_PARAMETER_VERSION=""
JENKINS_PARAMETER_DISTRIBUTION_TYPE=""
PREVIOUS_VERSION=""
VERSION_SOURCE=""
JENKINS_REASON=""
JENKINS_NEXT_REQUIRED_INPUT=""
JENKINS_TECHNICAL_REASON=""

GITOPS_PREFLIGHT=NOT_RUN
CONFIG_REPO_ACCESSIBLE=false
CHARTS_EXISTS=false
CONFIG_EXISTS=false
CONFIG_TEMPLATE_EXISTS=false
GITOPS_REASON=""
GITOPS_NEXT_REQUIRED_INPUT=""
GITOPS_TECHNICAL_REASON=""

ARGO_PREFLIGHT=NOT_RUN
ARGOCD_CLI_AVAILABLE=false
ARGOCD_AUTHENTICATED=false
ARGOCD_APP_EXISTS=false
ARGOCD_REPO_URL=""
ARGOCD_TARGET_REVISION=""
ARGOCD_SOURCE_PATH=""
ARGO_REASON=""
ARGO_NEXT_REQUIRED_INPUT=""
ARGO_TECHNICAL_REASON=""

if [[ "$COMMON_INPUT_MISSING" == "true" ]]; then
  emit_report
fi

render_config_values


WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

run_jenkins_stage
run_gitops_stage
run_argo_stage
emit_report
