#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${SKILL_ROOT}/.env}"
source "$SCRIPT_DIR/lib/common.sh"

load_skill_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local perms
  perms="$(stat -f "%Lp" "$ENV_FILE" 2>/dev/null || stat -c "%a" "$ENV_FILE" 2>/dev/null || true)"
  if [[ -n "$perms" && "$perms" != "600" && "${SKILL_ENV_WARNING_EMITTED:-}" != "1" ]]; then
    echo "WARNING=.env should have permissions 600"
    export SKILL_ENV_WARNING_EMITTED=1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]] && line="${line#export }"
    [[ "$line" == *"="* ]] || continue
    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 ]]; then
      if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done <"$ENV_FILE"
}

usage() {
  cat <<'EOF'
Usage:
  JENKINS_USER=<user> JENKINS_TOKEN=<token> \
  ARGOCD_AUTH_TOKEN=<token> \
  bash scripts/distribution-delivery.sh \
    --jenkins-url <url> \
    --project-name <name> \
    [--project-dir <path>] \
    --branch <branch> \
    [--job-name <job-name>] \
    [--template-job <job-name>] \
    [--repository-url <url>] \
    --distribution-type <ift|release|test|testing|prod|production> \
    [--version <version>] \
    [--jenkins-branch-param <name>] \
    [--jenkins-version-param <name>] \
    [--jenkins-distribution-type-param <name>] \
    [--timeout-seconds <number>] \
    [--config-repo-url <url>] \
    [--config-repo-branch <branch>] \
    [--config-path <path>] \
    [--config-template-path <path>] \
    [--argocd-server <server>] \
    [--argocd-app-name <name>] \
    [--argocd-project <project>] \
    [--argocd-destination-server <cluster-server>] \
    [--argocd-destination-namespace <namespace>] \
    --environment <environment> \
    [--preflight] \
    [--approve-deployment] \
    [--dry-run] \
    [--no-extra-gitops-changes] \
    [--additional-gitops-changes-required] \
    [--resume-gitops --build-url <url> --version <version> --digest <digest>] \
    [--wait]

Use --approve-deployment to allow the GitOps push and Argo CD stage.
EOF
}

run_self_tests() {
  local failed=0 mode

  [[ "$(normalize_distribution_type test)" == "ift" ]] || { echo "FAIL alias test"; failed=1; }
  [[ "$(normalize_distribution_type testing)" == "ift" ]] || { echo "FAIL alias testing"; failed=1; }
  [[ "$(normalize_distribution_type prod)" == "release" ]] || { echo "FAIL alias prod"; failed=1; }
  [[ "$(normalize_distribution_type production)" == "release" ]] || { echo "FAIL alias production"; failed=1; }

  mode="$(deployment_mode_for_state false false)" || failed=1
  [[ "$mode" == "create" ]] || { echo "FAIL first deployment"; failed=1; }
  mode="$(deployment_mode_for_state true true)" || failed=1
  [[ "$mode" == "update" ]] || { echo "FAIL existing deployment"; failed=1; }
  if deployment_mode_for_state true false >/dev/null; then echo "FAIL inconsistent config-only"; failed=1; fi
  if deployment_mode_for_state false true >/dev/null; then echo "FAIL inconsistent app-only"; failed=1; fi

  has_csv_value "BRANCH,VERSION,DISTRIBUTION_TYPE" "VERSION" || { echo "FAIL parameter mapping version"; failed=1; }
  if has_csv_value "BRANCH,VERSION" "DISTRIBUTION_TYPE"; then echo "FAIL parameter mapping missing distribution"; failed=1; fi

  case "ift:IFT-0.0.1" in ift:IFT-*) ;; *) echo "FAIL ift version match"; failed=1 ;; esac
  case "release:D-00.000.01" in release:D-*) ;; *) echo "FAIL release version match"; failed=1 ;; esac
  case "ift:D-00.000.01" in ift:IFT-*) echo "FAIL version mismatch"; failed=1 ;; *) ;; esac

  local old_project="${PROJECT_NAME:-}" old_env="${ENVIRONMENT:-}" old_dtype="${DISTRIBUTION_TYPE:-}" old_version="${VERSION:-}" old_ns="${ARGOCD_DESTINATION_NAMESPACE:-}" old_app="${ARGOCD_APP_NAME:-}" old_config="${CONFIG_PATH:-}" old_template="${CONFIG_TEMPLATE_PATH:-}" old_charts="${CHARTS_PATH:-}"
  ENVIRONMENT=ift
  DISTRIBUTION_TYPE=ift
  VERSION=IFT-0.0.1
  ARGOCD_DESTINATION_NAMESPACE=ci11366566-sberaipay
  CONFIG_PATH=""
  CHARTS_PATH=""
  PROJECT_NAME=ai-payments-merchant-registry
  CHARTS_PATH="$(render_template 'charts/{{PROJECT_NAME}}')" || failed=1
  CONFIG_PATH="$(render_template 'stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}')" || failed=1
  ARGOCD_APP_NAME="$(render_template 'bdifb2y7-{{PROJECT_NAME}}')" || failed=1
  CHARTS_PATH_TEMPLATE='charts/{{PROJECT_NAME}}'
  CHARTS_PATH=""
  render_template_into CHARTS_PATH "$CHARTS_PATH_TEMPLATE" "charts path" || failed=1
  [[ "$CHARTS_PATH" == "charts/ai-payments-merchant-registry" ]] || { echo "FAIL rendered charts merchant"; failed=1; }
  [[ "$CONFIG_PATH" == "stands/ift/bdifb2y7-ai-payments/ai-payments-merchant-registry" ]] || { echo "FAIL rendered config merchant"; failed=1; }
  [[ "$ARGOCD_APP_NAME" == "bdifb2y7-ai-payments-merchant-registry" ]] || { echo "FAIL rendered app merchant"; failed=1; }

  PROJECT_NAME=payment-orders
  CHARTS_PATH="$(render_template 'charts/{{PROJECT_NAME}}')" || failed=1
  CONFIG_PATH="$(render_template 'stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}')" || failed=1
  ARGOCD_APP_NAME="$(render_template 'bdifb2y7-{{PROJECT_NAME}}')" || failed=1
  [[ "$CHARTS_PATH" == "charts/payment-orders" ]] || { echo "FAIL rendered charts payment"; failed=1; }
  [[ "$CONFIG_PATH" == "stands/ift/bdifb2y7-ai-payments/payment-orders" ]] || { echo "FAIL rendered config payment"; failed=1; }
  [[ "$ARGOCD_APP_NAME" == "bdifb2y7-payment-orders" ]] || { echo "FAIL rendered app payment"; failed=1; }

  local err_file
  err_file="$(mktemp)"
  if render_template 'charts/{{UNKNOWN}}' >/dev/null 2>"$err_file"; then
    echo "FAIL unknown placeholder"
    failed=1
  elif ! grep -q '^STATE=unknown_template_placeholder$' "$err_file"; then
    echo "FAIL unknown placeholder state"
    failed=1
  fi
  rm -f "$err_file"

  if validate_rendered_path "charts/ai-payments-merchant-registry" "test path"; then :; else echo "FAIL safe charts path"; failed=1; fi
  if validate_rendered_path "stands/ift/bdifb2y7-ai-payments/payment-orders" "test path"; then :; else echo "FAIL safe config path"; failed=1; fi
  if ( validate_rendered_path "../charts/project" "test path" ) >/dev/null 2>&1; then echo "FAIL unsafe parent path"; failed=1; fi
  if ( validate_rendered_path "/charts/project" "test path" ) >/dev/null 2>&1; then echo "FAIL unsafe absolute path"; failed=1; fi
  if ( validate_rendered_path "charts/project/../../other" "test path" ) >/dev/null 2>&1; then echo "FAIL unsafe nested parent path"; failed=1; fi

  PROJECT_NAME="$old_project"; ENVIRONMENT="$old_env"; DISTRIBUTION_TYPE="$old_dtype"; VERSION="$old_version"; ARGOCD_DESTINATION_NAMESPACE="$old_ns"; ARGOCD_APP_NAME="$old_app"; CONFIG_PATH="$old_config"; CONFIG_TEMPLATE_PATH="$old_template"; CHARTS_PATH="$old_charts"

  local order_log argo_count
  order_log="$(mktemp)"
  reset_deploy_preconditions
  {
    echo build
    echo digest
  } >>"$order_log"
  DIGEST_BUILD_MATCH=true
  CHARTS_UPDATED=true; echo chart >>"$order_log"
  CONFIGS_UPDATED=true; echo config >>"$order_log"
  FILES_EXPECTED=2
  FILES_VERIFIED=2
  FILES_FAILED=0
  VERSION_APPLIED=true
  DIGEST_APPLIED=true
  COMMIT_CREATED=true; echo commit >>"$order_log"
  COMMIT_SHA=abc123
  PUSH_COMPLETED=true; echo push >>"$order_log"
  REMOTE_GIT_VERIFIED=true; echo remote >>"$order_log"
  REMOTE_COMMIT_SHA=abc123
  refresh_argo_deploy_allowed
  if [[ "$ARGO_DEPLOY_ALLOWED" == "true" ]]; then
    echo argocd >>"$order_log"
  fi
  if [[ "$(tr '\n' ' ' <"$order_log" | sed 's/[[:space:]]*$//')" != "build digest chart config commit push remote argocd" ]]; then
    echo "FAIL deploy order success"
    failed=1
  fi

  : >"$order_log"
  reset_deploy_preconditions
  {
    echo build
    echo digest
  } >>"$order_log"
  DIGEST_BUILD_MATCH=true
  CHARTS_UPDATED=true; echo chart >>"$order_log"
  CONFIGS_UPDATED=true; echo config >>"$order_log"
  FILES_EXPECTED=2
  FILES_VERIFIED=2
  FILES_FAILED=0
  VERSION_APPLIED=true
  DIGEST_APPLIED=true
  COMMIT_CREATED=true; echo commit >>"$order_log"
  COMMIT_SHA=abc123
  PUSH_COMPLETED=false; echo "push FAILED" >>"$order_log"
  REMOTE_GIT_VERIFIED=false
  REMOTE_COMMIT_SHA=""
  refresh_argo_deploy_allowed
  [[ "$ARGO_DEPLOY_ALLOWED" == "false" ]] || { echo "FAIL push failure allowed Argo"; failed=1; }
  argo_count="$(grep -c '^argocd$' "$order_log" || true)"
  [[ "$argo_count" == "0" ]] || { echo "FAIL push failure Argo count"; failed=1; }

  : >"$order_log"
  reset_deploy_preconditions
  {
    echo build
    echo digest
  } >>"$order_log"
  DIGEST_BUILD_MATCH=true
  CHARTS_UPDATED=false
  CONFIGS_UPDATED=true
  FILES_EXPECTED=2
  FILES_VERIFIED=1
  FILES_FAILED=1
  VERSION_APPLIED=true
  DIGEST_APPLIED=true
  COMMIT_CREATED=true
  COMMIT_SHA=abc123
  PUSH_COMPLETED=true
  REMOTE_GIT_VERIFIED=true
  REMOTE_COMMIT_SHA=abc123
  refresh_argo_deploy_allowed
  [[ "$ARGO_DEPLOY_ALLOWED" == "false" ]] || { echo "FAIL chart failure allowed Argo"; failed=1; }
  argo_count="$(grep -c '^argocd$' "$order_log" || true)"
  [[ "$argo_count" == "0" ]] || { echo "FAIL chart failure Argo count"; failed=1; }

  local field
  local output rc expected_state
  for field in DIGEST_BUILD_MATCH CHARTS_UPDATED CONFIGS_UPDATED VERSION_APPLIED DIGEST_APPLIED COMMIT_CREATED PUSH_COMPLETED REMOTE_GIT_VERIFIED; do
    : >"$order_log"
    reset_deploy_preconditions
    DIGEST_BUILD_MATCH=true
    CHARTS_UPDATED=true
    CONFIGS_UPDATED=true
    FILES_EXPECTED=2
    FILES_VERIFIED=2
    FILES_FAILED=0
    VERSION_APPLIED=true
    DIGEST_APPLIED=true
    COMMIT_CREATED=true
    COMMIT_SHA=abc123
    PUSH_COMPLETED=true
    REMOTE_GIT_VERIFIED=true
    REMOTE_COMMIT_SHA=abc123
    printf -v "$field" '%s' false
    refresh_argo_deploy_allowed
    [[ "$ARGO_DEPLOY_ALLOWED" == "false" ]] || { echo "FAIL ${field} failure allowed Argo"; failed=1; }
    argo_count="$(grep -c '^argocd$' "$order_log" || true)"
    [[ "$argo_count" == "0" ]] || { echo "FAIL ${field} Argo count"; failed=1; }
    case "$field" in
      DIGEST_BUILD_MATCH) expected_state="digest_build_mismatch" ;;
      CHARTS_UPDATED|CONFIGS_UPDATED|COMMIT_CREATED) expected_state="gitops_not_updated" ;;
      VERSION_APPLIED) expected_state="gitops_version_not_applied" ;;
      DIGEST_APPLIED) expected_state="gitops_digest_not_applied" ;;
      PUSH_COMPLETED) expected_state="gitops_push_failed" ;;
      REMOTE_GIT_VERIFIED) expected_state="git_remote_not_updated" ;;
      *) expected_state="" ;;
    esac
    set +e
    output="$(require_argo_deploy_allowed)"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] || { echo "FAIL ${field} did not block Argo"; failed=1; }
    grep -q "^STATE=${expected_state}$" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${field} state"; failed=1; }
    grep -q "^ARGO_DEPLOY_ALLOWED=false$" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${field} allowed output"; failed=1; }
  done
  reset_deploy_preconditions
  DIGEST_BUILD_MATCH=true
  CHARTS_UPDATED=true
  CONFIGS_UPDATED=true
  FILES_EXPECTED=2
  FILES_VERIFIED=2
  FILES_FAILED=0
  VERSION_APPLIED=true
  DIGEST_APPLIED=true
  COMMIT_CREATED=true
  COMMIT_SHA=abc123
  PUSH_COMPLETED=true
  REMOTE_GIT_VERIFIED=true
  REMOTE_COMMIT_SHA=def456
  refresh_argo_deploy_allowed
  [[ "$ARGO_DEPLOY_ALLOWED" == "false" ]] || { echo "FAIL remote sha mismatch allowed Argo"; failed=1; }
  set +e
  output="$(require_argo_deploy_allowed)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL remote sha mismatch did not block Argo"; failed=1; }
  grep -q "^STATE=git_remote_not_updated$" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL remote sha mismatch state"; failed=1; }
  rm -f "$order_log"

  local action question_count gitops_count argo_count_mock
  reset_gitops_scope_flags
  action="$(gitops_scope_action)"
  [[ "$action" == "ask" ]] || { echo "FAIL gitops scope initial pause"; failed=1; }
  question_count=1
  NO_EXTRA_GITOPS_CHANGES=true
  action="$(gitops_scope_action)"
  [[ "$action" == "proceed" ]] || { echo "FAIL gitops scope no proceeds"; failed=1; }
  {
    echo build
    echo digest
    echo pause
    echo version+digest
    echo verify
    echo commit
    echo push
    echo remote
    echo argo
  } >"$order_log"
  [[ "$(tr '\n' ' ' <"$order_log" | sed 's/[[:space:]]*$//')" == "build digest pause version+digest verify commit push remote argo" ]] || { echo "FAIL gitops scope no order"; failed=1; }
  [[ "$question_count" == "1" ]] || { echo "FAIL gitops scope question count"; failed=1; }

  reset_gitops_scope_flags
  ADDITIONAL_GITOPS_CHANGES_REQUIRED=true
  action="$(gitops_scope_action)"
  [[ "$action" == "additional_required" ]] || { echo "FAIL gitops scope yes pauses"; failed=1; }
  gitops_count=0
  argo_count_mock=0
  [[ "$gitops_count" == "0" && "$argo_count_mock" == "0" ]] || { echo "FAIL gitops scope yes mutation count"; failed=1; }

  RESUME_GITOPS=true
  action="$(gitops_scope_action)"
  [[ "$action" == "proceed" ]] || { echo "FAIL gitops scope resume proceeds"; failed=1; }
  gitops_count=1
  argo_count_mock=1
  [[ "$gitops_count" == "1" && "$argo_count_mock" == "1" ]] || { echo "FAIL gitops scope resume counts"; failed=1; }

  reset_gitops_scope_flags
  NO_EXTRA_GITOPS_CHANGES=true
  action="$(gitops_scope_action)"
  [[ "$action" == "proceed" ]] || { echo "FAIL gitops scope no repeat first"; failed=1; }
  action="$(gitops_scope_action)"
  [[ "$action" == "proceed" ]] || { echo "FAIL gitops scope no repeat second"; failed=1; }

  local state_tmp state_project state_file saved_project_dir
  local old_project_dir="${PROJECT_DIR:-}" old_project_name="${PROJECT_NAME:-}" old_build_url="${BUILD_URL:-}" old_build_number="${BUILD_NUMBER:-}" old_version_state="${VERSION:-}" old_dtype_state="${DISTRIBUTION_TYPE:-}" old_image_digest="${IMAGE_DIGEST:-}" old_resume_state_file="${RESUME_STATE_FILE:-}" old_resume="${RESUME_GITOPS:-false}" old_no_extra="${NO_EXTRA_GITOPS_CHANGES:-false}" old_additional="${ADDITIONAL_GITOPS_CHANGES_REQUIRED:-false}"
  state_tmp="$(mktemp -d)"
  state_project="$state_tmp/application-service"
  mkdir -p "$state_project"
  git init "$state_project" >/dev/null
  PROJECT_DIR="$state_project"
  PROJECT_NAME="application-service"
  DISTRIBUTION_TYPE="ift"
  VERSION="IFT-0.0.27"
  BUILD_URL="https://jenkins.example/job/application-service-build/47/"
  IMAGE_DIGEST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  RESUME_STATE_FILE="$(resume_state_file)"
  save_resume_state "awaiting-gitops-scope" "false"
  state_file="$RESUME_STATE_FILE"
  [[ -f "$state_file" ]] || { echo "FAIL resume state not created"; failed=1; }
  state_perms="$(stat -f "%Lp" "$state_file" 2>/dev/null || stat -c "%a" "$state_file" 2>/dev/null || true)"
  [[ "$state_perms" == "600" ]] || { echo "FAIL resume state permissions"; failed=1; }
  grep -q '^PAUSE_STATE=awaiting-gitops-scope$' "$state_file" || { echo "FAIL resume state pause"; failed=1; }
  grep -q '^QUESTION_ANSWERED=false$' "$state_file" || { echo "FAIL resume state unanswered"; failed=1; }
  if grep -Eiq '(TOKEN|PASSWORD|SECRET|CREDENTIAL|ARGOCD_AUTH_TOKEN|JENKINS_TOKEN)' "$state_file"; then
    echo "FAIL resume state contains credential key"
    failed=1
  fi

  BUILD_URL=""
  BUILD_NUMBER=""
  VERSION=""
  IMAGE_DIGEST=""
  DISTRIBUTION_TYPE=""
  load_resume_state
  [[ "$BUILD_URL" == "https://jenkins.example/job/application-service-build/47/" ]] || { echo "FAIL resume state build url"; failed=1; }
  [[ "$BUILD_NUMBER" == "47" ]] || { echo "FAIL resume state build number"; failed=1; }
  [[ "$VERSION" == "IFT-0.0.27" ]] || { echo "FAIL resume state version"; failed=1; }
  [[ "$IMAGE_DIGEST" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] || { echo "FAIL resume state digest"; failed=1; }
  [[ "$DISTRIBUTION_TYPE" == "ift" ]] || { echo "FAIL resume state distribution"; failed=1; }

  NO_EXTRA_GITOPS_CHANGES=true
  RESUME_GITOPS=false
  ADDITIONAL_GITOPS_CHANGES_REQUIRED=false
  action="$(gitops_scope_action)"
  [[ "$action" == "proceed" ]] || { echo "FAIL resume no-extra proceeds"; failed=1; }
  save_resume_state "$STATE_PAUSE_STATE" "true"
  load_resume_state
  [[ "$STATE_QUESTION_ANSWERED" == "true" ]] || { echo "FAIL resume no-extra answered"; failed=1; }

  save_resume_state "awaiting-gitops-scope" "false"
  ADDITIONAL_GITOPS_CHANGES_REQUIRED=true
  NO_EXTRA_GITOPS_CHANGES=false
  load_resume_state
  save_resume_state "additional_gitops_changes_required" "true"
  load_resume_state
  [[ "$STATE_PAUSE_STATE" == "additional_gitops_changes_required" && "$STATE_QUESTION_ANSWERED" == "true" ]] || { echo "FAIL resume additional state"; failed=1; }

  RESUME_GITOPS=true
  ADDITIONAL_GITOPS_CHANGES_REQUIRED=false
  action="$(gitops_scope_action)"
  [[ "$action" == "proceed" ]] || { echo "FAIL resume skips repeated question"; failed=1; }

  save_resume_state "additional_gitops_changes_required" "true"
  remove_resume_state
  [[ ! -e "$state_file" ]] || { echo "FAIL resume state not removed"; failed=1; }

  save_resume_state "additional_gitops_changes_required" "true"
  [[ -e "$state_file" ]] || { echo "FAIL failed GitOps did not keep state"; failed=1; }
  rm -rf "$state_tmp"
  PROJECT_DIR="$old_project_dir"
  PROJECT_NAME="$old_project_name"
  BUILD_URL="$old_build_url"
  BUILD_NUMBER="$old_build_number"
  VERSION="$old_version_state"
  DISTRIBUTION_TYPE="$old_dtype_state"
  IMAGE_DIGEST="$old_image_digest"
  RESUME_STATE_FILE="$old_resume_state_file"
  RESUME_GITOPS="$old_resume"
  NO_EXTRA_GITOPS_CHANGES="$old_no_extra"
  ADDITIONAL_GITOPS_CHANGES_REQUIRED="$old_additional"

  if [[ "$failed" == "0" ]]; then
    echo "DISTRIBUTION_DELIVERY_SELF_TESTS=OK"
  else
    echo "DISTRIBUTION_DELIVERY_SELF_TESTS=FAIL"
    exit 1
  fi
}

error_exit() {
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=$1"
  echo "NEXT_REQUIRED_INPUT=${2:-}"
      exit 1
}

sanitize_technical_reason() {
  sed -E 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g; s#(--user[[:space:]]+)[^[:space:]]+#\1***#g'
}

is_network_error() {
  case "$1" in
    *"Could not resolve host"*|*"Failed to connect"*|*"Connection refused"*|*"timed out"*|*"Timeout"*|*"timeout"*|*"SSL_ERROR_SYSCALL"*|*"SSL_connect"*|*"TLS"*|*"No route to host"*|*"Host is down"*|*"Network is unreachable"*|*"Connection reset"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

jenkins_unreachable_exit() {
  local technical_reason="$1"
  technical_reason="$(printf '%s' "$technical_reason" | sanitize_technical_reason)"
  echo "STATUS=ERROR"
  echo "STATE=jenkins_unreachable"
  echo "REASON=Unable to connect to Jenkins"
  echo "NEXT_REQUIRED_INPUT=Jenkins access"
      echo "MUTATIONS_PERFORMED=false"
  [[ -n "$technical_reason" ]] && echo "TECHNICAL_REASON=${technical_reason}"
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "${option}"
}

normalize_distribution_type() {
  case "$1" in
    ift|test|testing) printf 'ift' ;;
    release|prod|production) printf 'release' ;;
    *) return 1 ;;
  esac
}

render_template() {
  local template="$1"
  python3 - "$template" "$PROJECT_NAME" "$ENVIRONMENT" "$DISTRIBUTION_TYPE" "$VERSION" "$ARGOCD_DESTINATION_NAMESPACE" "$ARGOCD_APP_NAME" "$CONFIG_PATH" "$CHARTS_PATH" <<'PY'
import re
import sys

template, project, env, dtype, version, namespace, app_name, config_path, charts_path = sys.argv[1:]
values = {
    "PROJECT_NAME": project,
    "ENVIRONMENT": env,
    "DISTRIBUTION_TYPE": dtype,
    "VERSION": version,
    "NAMESPACE": namespace,
    "ARGOCD_APP_NAME": app_name,
    "CONFIG_PATH": config_path,
    "CHARTS_PATH": charts_path,
}

rendered = template
for key, value in values.items():
    rendered = rendered.replace("{{" + key + "}}", value)

unknown = re.search(r"\{\{([^{}]+)\}\}", rendered)
if unknown:
    print("STATE=unknown_template_placeholder", file=sys.stderr)
    print(f"REASON=Unknown placeholder: {unknown.group(1)}", file=sys.stderr)
    sys.exit(2)

if "{{" in rendered or "}}" in rendered:
    print("STATE=unknown_template_placeholder", file=sys.stderr)
    print("REASON=Unknown placeholder syntax", file=sys.stderr)
    sys.exit(2)
print(rendered)
PY
}

render_template_into() {
  local target_var="$1"
  local template="$2"
  local field="$3"
  local rendered
  local err_file="${WORK_DIR:-/tmp}/render-template.err"
  if ! rendered="$(render_template "$template" 2>"$err_file")"; then
    if grep -q '^STATE=unknown_template_placeholder$' "$err_file" 2>/dev/null; then
      echo "STATUS=ERROR"
      echo "ACTION=blocked"
      echo "STATE=unknown_template_placeholder"
      echo "RENDER_FIELD=${field}"
      if [[ "$field" == "charts path" ]]; then
        echo "CHARTS_PATH_TEMPLATE_PRESENT=true"
        echo "CHARTS_PATH_TEMPLATE_LENGTH=${#template}"
        case "$template" in
          *'{{PROJECT_NAME}}'*) echo "CHARTS_PATH_TEMPLATE_HAS_PROJECT_PLACEHOLDER=true" ;;
          *) echo "CHARTS_PATH_TEMPLATE_HAS_PROJECT_PLACEHOLDER=false" ;;
        esac
        python3 - "$template" <<'PY'
import sys
value = sys.argv[1]
print(f"CHARTS_PATH_TEMPLATE_OPEN_BRACES={value.count('{{')}")
print(f"CHARTS_PATH_TEMPLATE_CLOSE_BRACES={value.count('}}')}")
PY
      fi
      sed -n 's/^REASON=/REASON=/p' "$err_file"
      echo "NEXT_REQUIRED_INPUT=valid path template"
      exit 1
    fi
    local reason
    reason="$(tr '\n' ' ' <"$err_file" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
    error_exit "Failed to render ${field}${reason:+: ${reason}}" "valid path template"
  fi
  printf -v "$target_var" '%s' "$rendered"
}

validate_rendered_path() {
  local path="$1"
  local label="$2"
  if [[ -z "$path" ]]; then
    error_exit "Unsafe ${label}: empty path" "safe repository path"
  fi
  if [[ "$path" == /* ]]; then
    error_exit "Unsafe ${label}: absolute path is not allowed" "safe repository path"
  fi
  if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
    error_exit "Unsafe ${label}: newline is not allowed" "safe repository path"
  fi
  if [[ "$path" =~ \{\{[^{}]+\}\} ]]; then
    error_exit "Unsafe ${label}: unresolved placeholder remains" "valid path template"
  fi
  local segment
  local old_ifs="$IFS"
  IFS='/'
  for segment in $path; do
    if [[ "$segment" == ".." ]]; then
      IFS="$old_ifs"
      error_exit "Unsafe ${label}: parent directory segment is not allowed" "safe repository path"
    fi
  done
  IFS="$old_ifs"
}

urlencode() {
  local value="$1"
  python3 - "$value" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

value_from_output() {
  local key="$1"
  local file="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

run_and_capture() {
  local output_file="$1"
  shift
  set +e
  "$@" >"$output_file"
  local code=$?
  set -e
  cat "$output_file"
  return "$code"
}

validate_config_path() {
  local path
  validate_rendered_path "$CONFIG_PATH" "config path"
  validate_rendered_path "$CONFIG_TEMPLATE_PATH" "config template path"
  validate_rendered_path "$CHARTS_PATH" "charts path"
}

curl_http() {
  local body_file="$1"
  local headers_file="$2"
  shift 2
  local status
  if ! status="$(curl --silent --show-error --output "$body_file" --dump-header "$headers_file" --write-out '%{http_code}' "$@" 2>"$WORK_DIR/curl.err")"; then
    local message
    message="$(tr '\n' ' ' <"$WORK_DIR/curl.err" | sed 's/[[:space:]]\+/ /g')"
    if is_network_error "$message"; then
      jenkins_unreachable_exit "$message"
    fi
    status="000"
  fi
  printf '%s' "$status"
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

jenkins_metadata_error_exit() {
  local technical_reason="$1"
  technical_reason="$(printf '%s' "$technical_reason" | sanitize_technical_reason)"
  echo "STATUS=ERROR"
  echo "STATE=jenkins_unreachable"
  echo "REASON=Failed to connect to Jenkins job metadata endpoint"
  echo "JOB_URL=${lookup_job_url:-}"
  echo "JENKINS_METADATA_URL=${JENKINS_METADATA_URL:-}"
  echo "NEXT_REQUIRED_INPUT=Jenkins API access"
      echo "MUTATIONS_PERFORMED=false"
  [[ -n "$technical_reason" ]] && echo "TECHNICAL_REASON=${technical_reason}"
  exit 1
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
print(f"ARGOCD_EXISTING_PROJECT={spec.get('project', '')}")
print(f"ARGOCD_EXISTING_REPO_URL={source.get('repoURL', '')}")
print(f"ARGOCD_EXISTING_TARGET_REVISION={source.get('targetRevision', '')}")
print(f"ARGOCD_EXISTING_SOURCE_PATH={source.get('path', '')}")
print(f"ARGOCD_EXISTING_DESTINATION_SERVER={dest.get('server', '')}")
print(f"ARGOCD_EXISTING_DESTINATION_NAMESPACE={dest.get('namespace', '')}")
PY
}

destination_server_from_template() {
  local template_path="$1"
  [[ -e "$template_path" ]] || return 1
  python3 - "$template_path" <<'PY'
import os
import re
import sys

root = sys.argv[1]
paths = []
if os.path.isfile(root):
    paths.append(root)
else:
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            paths.append(os.path.join(dirpath, name))

patterns = [
    re.compile(r"server:\s*['\"]?([^'\"\s]+)"),
    re.compile(r"ARGOCD_DESTINATION_SERVER:\s*['\"]?([^'\"\s]+)"),
]
for path in paths:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = fh.read()
    except UnicodeDecodeError:
        continue
    for pattern in patterns:
        match = pattern.search(data)
        if match:
            print(match.group(1))
            sys.exit(0)
sys.exit(1)
PY
}

has_csv_value() {
  local csv="$1"
  local wanted="$2"
  case ",${csv}," in
    *,"${wanted}",*) return 0 ;;
    *) return 1 ;;
  esac
}

deployment_mode_for_state() {
  local config_exists="$1"
  local app_exists="$2"
  if [[ "$config_exists" == "false" && "$app_exists" == "false" ]]; then
    echo "create"
  elif [[ "$config_exists" == "true" && "$app_exists" == "true" ]]; then
    echo "update"
  else
    return 1
  fi
}

build_number_from_url() {
  local url="${1%/}"
  local number="${url##*/}"
  if [[ "$number" =~ ^[0-9]+$ ]]; then
    printf '%s' "$number"
  fi
}

resume_state_file() {
  local git_dir
  git_dir="$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || error_exit "Project directory is not a Git repository: ${PROJECT_DIR}" "Git repository project directory"
  if [[ "$git_dir" != /* ]]; then
    git_dir="$(cd "$PROJECT_DIR" && cd "$git_dir" && pwd)"
  fi
  printf '%s/jenkins-distribution-build-state' "$git_dir"
}

resume_state_error() {
  local state="$1"
  local reason="$2"
  local next_input="${3:-}"
  echo "STATUS=ERROR"
  echo "ACTION=resume-gitops"
  echo "STATE=${state}"
  echo "REASON=${reason}"
  echo "NEXT_REQUIRED_INPUT=${next_input}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

save_resume_state() {
  local pause_state="$1"
  local answered="$2"
  local state_file="${RESUME_STATE_FILE:-}"
  [[ -n "$state_file" ]] || state_file="$(resume_state_file)"
  local tmp_file="${state_file}.$$"
  local project_root
  project_root="$(project_git_root)"
  BUILD_NUMBER="$(build_number_from_url "$BUILD_URL")"
  umask 077
  {
    echo "PROJECT_NAME=${PROJECT_NAME}"
    echo "PROJECT_DIR=${project_root}"
    echo "BUILD_URL=${BUILD_URL}"
    echo "BUILD_NUMBER=${BUILD_NUMBER}"
    echo "VERSION=${VERSION}"
    echo "DIGEST=${IMAGE_DIGEST}"
    echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
    echo "PAUSE_STATE=${pause_state}"
    echo "QUESTION_ANSWERED=${answered}"
  } >"$tmp_file"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$state_file"
  RESUME_STATE_FILE="$state_file"
}

load_resume_state() {
  local state_file="${RESUME_STATE_FILE:-}"
  [[ -n "$state_file" ]] || state_file="$(resume_state_file)"
  [[ -f "$state_file" ]] || resume_state_error "gitops_resume_state_missing" "GitOps resume state file is missing" "resume state"
  local key value
  STATE_PROJECT_NAME=""
  STATE_PROJECT_DIR=""
  STATE_BUILD_URL=""
  STATE_BUILD_NUMBER=""
  STATE_VERSION=""
  STATE_DIGEST=""
  STATE_DISTRIBUTION_TYPE=""
  STATE_PAUSE_STATE=""
  STATE_QUESTION_ANSWERED=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || resume_state_error "gitops_resume_state_invalid" "GitOps resume state is malformed" "valid resume state"
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      PROJECT_NAME) STATE_PROJECT_NAME="$value" ;;
      PROJECT_DIR) STATE_PROJECT_DIR="$value" ;;
      BUILD_URL) STATE_BUILD_URL="$value" ;;
      BUILD_NUMBER) STATE_BUILD_NUMBER="$value" ;;
      VERSION) STATE_VERSION="$value" ;;
      DIGEST) STATE_DIGEST="$value" ;;
      DISTRIBUTION_TYPE) STATE_DISTRIBUTION_TYPE="$value" ;;
      PAUSE_STATE) STATE_PAUSE_STATE="$value" ;;
      QUESTION_ANSWERED) STATE_QUESTION_ANSWERED="$value" ;;
      *) resume_state_error "gitops_resume_state_invalid" "GitOps resume state contains unsupported key" "valid resume state" ;;
    esac
  done <"$state_file"
  [[ -n "$STATE_PROJECT_NAME" && -n "$STATE_PROJECT_DIR" && -n "$STATE_BUILD_URL" && -n "$STATE_BUILD_NUMBER" && -n "$STATE_VERSION" && -n "$STATE_DIGEST" && -n "$STATE_DISTRIBUTION_TYPE" && -n "$STATE_PAUSE_STATE" && -n "$STATE_QUESTION_ANSWERED" ]] || resume_state_error "gitops_resume_state_invalid" "GitOps resume state is incomplete" "valid resume state"
  local project_root
  project_root="$(project_git_root)"
  if [[ "$STATE_PROJECT_NAME" != "$PROJECT_NAME" || "$STATE_PROJECT_DIR" != "$project_root" ]]; then
    resume_state_error "gitops_resume_project_mismatch" "GitOps resume state belongs to a different project" "matching project"
  fi
  BUILD_URL="$STATE_BUILD_URL"
  BUILD_NUMBER="$STATE_BUILD_NUMBER"
  VERSION="$STATE_VERSION"
  IMAGE_DIGEST="$STATE_DIGEST"
  DISTRIBUTION_TYPE="$STATE_DISTRIBUTION_TYPE"
  RESUME_STATE_FILE="$state_file"
}

remove_resume_state() {
  local state_file="${RESUME_STATE_FILE:-}"
  [[ -n "$state_file" ]] || state_file="$(resume_state_file)"
  rm -f "$state_file"
}

reset_gitops_scope_flags() {
  NO_EXTRA_GITOPS_CHANGES=false
  ADDITIONAL_GITOPS_CHANGES_REQUIRED=false
  RESUME_GITOPS=false
}

gitops_scope_action() {
  if [[ "${RESUME_GITOPS:-false}" == "true" || "${NO_EXTRA_GITOPS_CHANGES:-false}" == "true" ]]; then
    echo "proceed"
  elif [[ "${ADDITIONAL_GITOPS_CHANGES_REQUIRED:-false}" == "true" ]]; then
    echo "additional_required"
  else
    echo "ask"
  fi
}

emit_gitops_scope_pause() {
  echo "STATUS=PAUSED"
  echo "ACTION=awaiting-gitops-scope"
  echo "STATE=awaiting_gitops_changes_decision"
  echo "QUESTION=Кроме обновления версии и image digest нужно внести ещё изменения в charts/configs?"
  echo "PROJECT_NAME=${PROJECT_NAME}"
  echo "ENVIRONMENT=${ENVIRONMENT}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
  echo "VERSION=${VERSION}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST:-}"
  echo "DIGEST_BUILD_MATCH=${DIGEST_BUILD_MATCH:-false}"
  echo "STANDARD_GITOPS_UPDATE_READY=true"
  echo "GITOPS_MUTATIONS_PERFORMED=false"
  echo "ARGOCD_SYNC_RUN=false"
  echo "NEXT_REQUIRED_INPUT=additional GitOps changes decision"
  echo "MUTATIONS_PERFORMED=true"
  exit 0
}

emit_additional_gitops_changes_required() {
  echo "STATUS=PAUSED"
  echo "ACTION=awaiting-additional-gitops-changes"
  echo "STATE=additional_gitops_changes_required"
  echo "PROJECT_NAME=${PROJECT_NAME}"
  echo "ENVIRONMENT=${ENVIRONMENT}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
  echo "VERSION=${VERSION}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST:-}"
  echo "DIGEST_BUILD_MATCH=${DIGEST_BUILD_MATCH:-false}"
  echo "STANDARD_GITOPS_UPDATE_READY=true"
  echo "GITOPS_MUTATIONS_PERFORMED=false"
  echo "ARGOCD_SYNC_RUN=false"
  echo "NEXT_REQUIRED_INPUT=exact additional GitOps changes"
  echo "MUTATIONS_PERFORMED=true"
  exit 0
}

reset_deploy_preconditions() {
  DIGEST_BUILD_MATCH=false
  CHARTS_UPDATED=false
  CONFIGS_UPDATED=false
  FILES_EXPECTED=0
  FILES_VERIFIED=0
  FILES_FAILED=0
  VERIFIED_FILES=""
  FAILED_FILES=""
  EXPECTED_VERSION=""
  EXPECTED_DIGEST=""
  ACTUAL_VERSION=""
  ACTUAL_DIGEST=""
  VERSION_APPLIED=false
  DIGEST_APPLIED=false
  COMMIT_CREATED=false
  COMMIT_SHA=""
  PUSH_COMPLETED=false
  REMOTE_GIT_VERIFIED=false
  REMOTE_COMMIT_SHA=""
  ARGO_DEPLOY_ALLOWED=false
}

refresh_argo_deploy_allowed() {
  if [[ "${DIGEST_BUILD_MATCH:-false}" == "true" && "${FILES_FAILED:-0}" == "0" && -n "${FILES_EXPECTED:-}" && -n "${FILES_VERIFIED:-}" && "${FILES_EXPECTED:-0}" != "0" && "${FILES_VERIFIED:-0}" == "${FILES_EXPECTED:-0}" && "${CHARTS_UPDATED:-false}" == "true" && "${CONFIGS_UPDATED:-false}" == "true" && "${VERSION_APPLIED:-false}" == "true" && "${DIGEST_APPLIED:-false}" == "true" && "${COMMIT_CREATED:-false}" == "true" && -n "${COMMIT_SHA:-}" && "${PUSH_COMPLETED:-false}" == "true" && "${REMOTE_GIT_VERIFIED:-false}" == "true" && -n "${REMOTE_COMMIT_SHA:-}" && "${COMMIT_SHA:-}" == "${REMOTE_COMMIT_SHA:-}" ]]; then
    ARGO_DEPLOY_ALLOWED=true
  else
    ARGO_DEPLOY_ALLOWED=false
  fi
}

gitops_gate_error() {
  local state="$1"
  local reason="$2"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "STATE=${state}"
  echo "REASON=${reason}"
  echo "DIGEST_BUILD_MATCH=${DIGEST_BUILD_MATCH:-false}"
  echo "CHARTS_UPDATED=${CHARTS_UPDATED:-false}"
  echo "CONFIGS_UPDATED=${CONFIGS_UPDATED:-false}"
  echo "FILES_EXPECTED=${FILES_EXPECTED:-0}"
  echo "FILES_VERIFIED=${FILES_VERIFIED:-0}"
  echo "FILES_FAILED=${FILES_FAILED:-0}"
  echo "VERIFIED_FILES=${VERIFIED_FILES:-}"
  echo "FAILED_FILES=${FAILED_FILES:-}"
  echo "EXPECTED_VERSION=${EXPECTED_VERSION:-}"
  echo "EXPECTED_DIGEST=${EXPECTED_DIGEST:-}"
  echo "ACTUAL_VERSION=${ACTUAL_VERSION:-}"
  echo "ACTUAL_DIGEST=${ACTUAL_DIGEST:-}"
  echo "VERSION_APPLIED=${VERSION_APPLIED:-false}"
  echo "DIGEST_APPLIED=${DIGEST_APPLIED:-false}"
  echo "COMMIT_CREATED=${COMMIT_CREATED:-false}"
  echo "COMMIT_SHA=${COMMIT_SHA:-}"
  echo "PUSH_COMPLETED=${PUSH_COMPLETED:-false}"
  echo "REMOTE_GIT_VERIFIED=${REMOTE_GIT_VERIFIED:-false}"
  echo "REMOTE_COMMIT_SHA=${REMOTE_COMMIT_SHA:-}"
  echo "ARGO_DEPLOY_ALLOWED=false"
  echo "NEXT_REQUIRED_INPUT=successful GitOps update and push"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

require_argo_deploy_allowed() {
  refresh_argo_deploy_allowed
  [[ "$ARGO_DEPLOY_ALLOWED" == "true" ]] && return 0
  if [[ "${DIGEST_BUILD_MATCH:-false}" != "true" ]]; then
    gitops_gate_error "digest_build_mismatch" "Image digest does not belong to the completed Jenkins build"
  fi
  if [[ "${CHARTS_UPDATED:-false}" != "true" || "${CONFIGS_UPDATED:-false}" != "true" || "${COMMIT_CREATED:-false}" != "true" ]]; then
    gitops_gate_error "gitops_not_updated" "GitOps chart/config update was not completed"
  fi
  if [[ "${FILES_FAILED:-0}" != "0" || "${FILES_EXPECTED:-0}" == "0" || "${FILES_VERIFIED:-0}" != "${FILES_EXPECTED:-0}" ]]; then
    gitops_gate_error "gitops_content_not_verified" "GitOps updated files were not fully verified"
  fi
  if [[ "${VERSION_APPLIED:-false}" != "true" ]]; then
    gitops_gate_error "gitops_version_not_applied" "GitOps files do not contain the built version and image tag"
  fi
  if [[ "${DIGEST_APPLIED:-false}" != "true" ]]; then
    gitops_gate_error "gitops_digest_not_applied" "GitOps files do not contain the built image digest"
  fi
  if [[ "${PUSH_COMPLETED:-false}" != "true" ]]; then
    gitops_gate_error "gitops_push_failed" "GitOps push did not complete successfully"
  fi
  if [[ "${REMOTE_GIT_VERIFIED:-false}" != "true" || -z "${COMMIT_SHA:-}" || -z "${REMOTE_COMMIT_SHA:-}" || "${COMMIT_SHA:-}" != "${REMOTE_COMMIT_SHA:-}" ]]; then
    gitops_gate_error "git_remote_not_updated" "Remote Git repository does not contain pushed commit"
  fi
  gitops_gate_error "gitops_update_failed" "GitOps update did not complete successfully"
}

clone_gitops_repo() {
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git ls-remote --heads "$CONFIG_REPO_URL" "$CONFIG_REPO_BRANCH" >/dev/null 2>"$WORK_DIR/git-ls-remote.err" || {
    local message
    message="$(tr '\n' ' ' <"$WORK_DIR/git-ls-remote.err" | sed 's/[[:space:]]\+/ /g')"
    if is_network_error "$message"; then
      jenkins_unreachable_exit "$message"
    fi
    error_exit "Git SSH authentication failed" "Git SSH credentials or SSH agent"
  }
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git clone --quiet --branch "$CONFIG_REPO_BRANCH" "$CONFIG_REPO_URL" "$WORK_DIR/config-repo" 2>"$WORK_DIR/git-clone.err" || {
    local message
    message="$(tr '\n' ' ' <"$WORK_DIR/git-clone.err" | sed 's/[[:space:]]\+/ /g')"
    error_exit "Git SSH authentication failed: ${message}" "Git SSH credentials or SSH agent"
  }
}

write_initial_config() {
  local target_dir="$WORK_DIR/config-repo/$CONFIG_PATH"
  local template_path="$WORK_DIR/config-repo/$CONFIG_TEMPLATE_PATH"
  if [[ -e "$target_dir" ]]; then
    error_exit "Config path already exists: ${CONFIG_PATH}" "manual config review"
  fi
  [[ -e "$template_path" ]] || error_exit "Config template path does not exist: ${CONFIG_TEMPLATE_PATH}" "config template path"
  mkdir -p "$target_dir"
  if [[ -d "$template_path" ]]; then
    cp -R "${template_path}/." "$target_dir/"
  else
    cp "$template_path" "$target_dir/"
  fi
  python3 - "$target_dir" "$PROJECT_NAME" "$ENVIRONMENT" "$DISTRIBUTION_TYPE" "$VERSION" "$ARGOCD_DESTINATION_NAMESPACE" "$BRANCH" "$CONFIG_PATH" <<'PY'
import os
import sys

root, project, env, dtype, version, namespace, branch, config_path = sys.argv[1:]
replacements = {
    "{{PROJECT_NAME}}": project,
    "{{ENVIRONMENT}}": env,
    "{{DISTRIBUTION_TYPE}}": dtype,
    "{{VERSION}}": version,
    "{{NAMESPACE}}": namespace,
    "{{BRANCH}}": branch,
    "{{CONFIG_PATH}}": config_path,
}
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = fh.read()
        except UnicodeDecodeError:
            continue
        for key, value in replacements.items():
            data = data.replace(key, value)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(data)
PY
}

update_existing_config() {
  local target_file="$WORK_DIR/config-repo/$CONFIG_PATH/distribution.yaml"
  [[ -f "$target_file" ]] || error_exit "Expected config file not found: ${CONFIG_PATH}/distribution.yaml" "manual GitOps config update"
  python3 - "$target_file" "$VERSION" <<'PY'
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

changed = False
out = []
for line in lines:
    if line.startswith("version:"):
        out.append(f"version: {version}\n")
        changed = True
    else:
        out.append(line)

if not changed:
    out.append(f"version: {version}\n")

with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
PY
}

ensure_changes_only_under_config_path() {
  local changed
  changed="$(cd "$WORK_DIR/config-repo" && git diff --name-only)"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
      "$CONFIG_PATH"/*|"$CONFIG_PATH") ;;
      *) error_exit "GitOps diff contains changes outside config path: ${path}" "manual GitOps review" ;;
    esac
  done <<<"$changed"
}

show_deployment_gate() {
  echo "VERSION=${VERSION}"
  echo "CONFIG_REPO=${CONFIG_REPO_URL}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
  echo "ENVIRONMENT=${ENVIRONMENT}"
}

commit_and_push_config() {
  ensure_changes_only_under_config_path
  echo "GITOPS_DIFF_BEGIN"
  (cd "$WORK_DIR/config-repo" && git diff -- "$CONFIG_PATH")
  echo "GITOPS_DIFF_END"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "GITOPS_ACTION=dry-run"
    return 0
  fi

  show_deployment_gate
  if [[ "$APPROVE_DEPLOYMENT" != "true" ]]; then
    echo "DEPLOYMENT_READY=true"
    echo "DEPLOYMENT_MODE=${ARGOCD_MODE}"
    error_exit "Deployment stage requires approval before GitOps push and Argo CD operations" "deployment approval"
  fi

  (
    cd "$WORK_DIR/config-repo"
    git add "$CONFIG_PATH"
    if git diff --cached --quiet; then
      echo "GITOPS_ACTION=no-change"
      return 0
    fi
    git commit -m "Deploy ${PROJECT_NAME} ${VERSION} to ${ENVIRONMENT}" >/dev/null
    git push origin "$CONFIG_REPO_BRANCH" >/dev/null
  )
  echo "GITOPS_ACTION=pushed"
}

load_skill_env

ORIGINAL_ARGS=("$@")
JENKINS_URL="${JENKINS_URL:-}"
PROJECT_NAME=""
PROJECT_DIR="${PROJECT_DIR:-}"
BRANCH=""
JOB_NAME=""
TEMPLATE_JOB="${JENKINS_TEMPLATE_JOB:-}"
DISTRIBUTION_TYPE=""
VERSION=""
BUILD_URL=""
REPOSITORY_URL=""
TIMEOUT_SECONDS=1800
CONFIG_REPO_URL="${CONFIG_REPO_URL:-}"
CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-}"
CHARTS_PATH_TEMPLATE="${CHARTS_PATH_TEMPLATE:-}"
CONFIG_PATH_TEMPLATE="${CONFIG_PATH_TEMPLATE:-}"
CONFIG_TEMPLATE_PATH_TEMPLATE="${CONFIG_TEMPLATE_PATH_TEMPLATE:-}"
ARGOCD_SERVER="${ARGOCD_SERVER:-}"
ARGOCD_APP_NAME_TEMPLATE="${ARGOCD_APP_NAME_TEMPLATE:-}"
ARGOCD_PROJECT="${ARGOCD_PROJECT:-}"
ARGOCD_DESTINATION_SERVER="${ARGOCD_DESTINATION_SERVER:-}"
ARGOCD_DESTINATION_NAMESPACE="${ARGOCD_DESTINATION_NAMESPACE:-}"
CONFIG_PATH=""
CONFIG_TEMPLATE_PATH=""
CHARTS_PATH=""
ARGOCD_APP_NAME=""
ENVIRONMENT="ift"
DRY_RUN=false
PREFLIGHT=false
APPROVE_DEPLOYMENT=false
JENKINS_BRANCH_PARAM="BRANCH"
JENKINS_VERSION_PARAM="VERSION"
JENKINS_DISTRIBUTION_TYPE_PARAM="DISTRIBUTION_TYPE"
IMAGE_DIGEST=""
BUILD_NUMBER=""
RESUME_STATE_FILE=""
RESUME_FROM_STATE=false
DIGEST_BUILD_MATCH=false
CHARTS_UPDATED=false
CONFIGS_UPDATED=false
FILES_EXPECTED=0
FILES_VERIFIED=0
FILES_FAILED=0
VERIFIED_FILES=""
FAILED_FILES=""
EXPECTED_VERSION=""
EXPECTED_DIGEST=""
ACTUAL_VERSION=""
ACTUAL_DIGEST=""
VERSION_APPLIED=false
DIGEST_APPLIED=false
COMMIT_CREATED=false
COMMIT_SHA=""
PUSH_COMPLETED=false
REMOTE_GIT_VERIFIED=false
REMOTE_COMMIT_SHA=""
ARGO_DEPLOY_ALLOWED=false
NO_EXTRA_GITOPS_CHANGES=false
ADDITIONAL_GITOPS_CHANGES_REQUIRED=false
RESUME_GITOPS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --jenkins-url) require_value "$1" "${2:-}"; JENKINS_URL="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --project-dir) require_value "$1" "${2:-}"; PROJECT_DIR="$2"; shift 2 ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME="$2"; shift 2 ;;
    --template-job) require_value "$1" "${2:-}"; TEMPLATE_JOB="$2"; shift 2 ;;
    --repository-url) require_value "$1" "${2:-}"; REPOSITORY_URL="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --build-url) require_value "$1" "${2:-}"; BUILD_URL="$2"; shift 2 ;;
    --digest) require_value "$1" "${2:-}"; IMAGE_DIGEST="$2"; shift 2 ;;
    --timeout-seconds) require_value "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --charts-path) require_value "$1" "${2:-}"; CHARTS_PATH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --config-template-path) require_value "$1" "${2:-}"; CONFIG_TEMPLATE_PATH="$2"; shift 2 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --argocd-project) require_value "$1" "${2:-}"; ARGOCD_PROJECT="$2"; shift 2 ;;
    --argocd-destination-server) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_SERVER="$2"; shift 2 ;;
    --argocd-destination-namespace) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_NAMESPACE="$2"; shift 2 ;;
    --environment) require_value "$1" "${2:-}"; ENVIRONMENT="$2"; shift 2 ;;
    --jenkins-branch-param) require_value "$1" "${2:-}"; JENKINS_BRANCH_PARAM="$2"; shift 2 ;;
    --jenkins-version-param) require_value "$1" "${2:-}"; JENKINS_VERSION_PARAM="$2"; shift 2 ;;
    --jenkins-distribution-type-param) require_value "$1" "${2:-}"; JENKINS_DISTRIBUTION_TYPE_PARAM="$2"; shift 2 ;;
    --preflight) PREFLIGHT=true; shift ;;
    --approve-deployment) APPROVE_DEPLOYMENT=true; shift ;;
    --no-extra-gitops-changes) NO_EXTRA_GITOPS_CHANGES=true; shift ;;
    --additional-gitops-changes-required) ADDITIONAL_GITOPS_CHANGES_REQUIRED=true; shift ;;
    --resume-gitops) RESUME_GITOPS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --wait) shift ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done


if [[ "$PREFLIGHT" == "true" ]]; then
  export SKILL_ENV_WARNING_EMITTED=1
  exec "$SCRIPT_DIR/preflight.sh" "${ORIGINAL_ARGS[@]}"
fi

if [[ "$NO_EXTRA_GITOPS_CHANGES" == "true" && "$ADDITIONAL_GITOPS_CHANGES_REQUIRED" == "true" ]]; then
  error_exit "Conflicting GitOps scope arguments" "choose no extra changes or additional changes"
fi
require_project_dir
resolve_project_name
resolve_branch
RESUME_STATE_FILE="$(resume_state_file)"
if [[ "$RESUME_GITOPS" == "true" ]]; then
  RESUME_FROM_STATE=true
elif [[ "$NO_EXTRA_GITOPS_CHANGES" == "true" || "$ADDITIONAL_GITOPS_CHANGES_REQUIRED" == "true" ]]; then
  [[ -f "$RESUME_STATE_FILE" ]] && RESUME_FROM_STATE=true
fi
if [[ "$RESUME_FROM_STATE" == "true" ]]; then
  load_resume_state
fi
if [[ "$RESUME_FROM_STATE" != "true" ]]; then
  resolve_jenkins_url
fi
if [[ "$RESUME_FROM_STATE" != "true" ]]; then
  [[ -n "$DISTRIBUTION_TYPE" ]] || error_exit "Missing required argument: --distribution-type" "distribution type"
  if ! DISTRIBUTION_TYPE="$(normalize_distribution_type "$DISTRIBUTION_TYPE")"; then
    error_exit "Unsupported distribution type" "ift or release"
  fi
fi
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || error_exit "--timeout-seconds must be a number" "timeout seconds"

if [[ "$ENVIRONMENT" == "ift" ]]; then
  CONFIG_REPO_URL="${CONFIG_REPO_URL:-ssh://git@sbrf-bitbucket.sigma.sbrf.ru:7999/ci11366566/ci11366566_sberaipay_gitopscd.git}"
  CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-ift}"
  if [[ -z "$CHARTS_PATH_TEMPLATE" ]]; then
    CHARTS_PATH_TEMPLATE='charts/{{PROJECT_NAME}}'
  fi
  if [[ -z "$CONFIG_PATH_TEMPLATE" ]]; then
    CONFIG_PATH_TEMPLATE='stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}'
  fi
  if [[ -z "$CONFIG_TEMPLATE_PATH_TEMPLATE" ]]; then
    CONFIG_TEMPLATE_PATH_TEMPLATE='stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}'
  fi
  ARGOCD_SERVER="${ARGOCD_SERVER:-argocd.apps.bbmwbllt.k8s.sigma.sbrf.ru}"
  if [[ -z "$ARGOCD_APP_NAME_TEMPLATE" ]]; then
    ARGOCD_APP_NAME_TEMPLATE='bdifb2y7-{{PROJECT_NAME}}'
  fi
  ARGOCD_PROJECT="${ARGOCD_PROJECT:-bdifb2y7.k8s.delta.sbrf.ru-ci11366566-sberaipay}"
  ARGOCD_DESTINATION_NAMESPACE="${ARGOCD_DESTINATION_NAMESPACE:-ci11366566-sberaipay}"
fi

if [[ -z "$CHARTS_PATH" ]]; then
  render_template_into CHARTS_PATH "$CHARTS_PATH_TEMPLATE" "charts path"
fi
if [[ -z "$CONFIG_PATH" ]]; then
  render_template_into CONFIG_PATH "$CONFIG_PATH_TEMPLATE" "config path"
fi
if [[ -z "$CONFIG_TEMPLATE_PATH" ]]; then
  render_template_into CONFIG_TEMPLATE_PATH "$CONFIG_TEMPLATE_PATH_TEMPLATE" "config template path"
fi
if [[ -z "$ARGOCD_APP_NAME" ]]; then
  render_template_into ARGOCD_APP_NAME "$ARGOCD_APP_NAME_TEMPLATE" "Argo CD app name"
fi

[[ -n "$CONFIG_REPO_URL" ]] || error_exit "Missing required argument: --config-repo-url" "config repo URL"
[[ -n "$CONFIG_REPO_BRANCH" ]] || error_exit "Missing required argument: --config-repo-branch" "config repo branch"
[[ -n "$CONFIG_PATH" ]] || error_exit "Missing required argument: --config-path" "config path"
[[ -n "$CONFIG_TEMPLATE_PATH" ]] || error_exit "Missing required argument: --config-template-path" "config template path"
[[ -n "$ARGOCD_SERVER" ]] || error_exit "Missing required argument: --argocd-server" "Argo CD server"
[[ -n "$ARGOCD_APP_NAME" ]] || error_exit "Missing required argument: --argocd-app-name" "Argo CD app name"
[[ -n "$ARGOCD_PROJECT" ]] || error_exit "Missing required argument: --argocd-project" "Argo CD project"
[[ -n "$ARGOCD_DESTINATION_NAMESPACE" ]] || error_exit "Missing required argument: --argocd-destination-namespace" "Argo CD destination namespace"
[[ -n "$ENVIRONMENT" ]] || error_exit "Missing required argument: --environment" "environment"
validate_config_path

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$RESUME_FROM_STATE" == "true" ]]; then
  reset_deploy_preconditions
  DIGEST_BUILD_MATCH=true
  if [[ "$ADDITIONAL_GITOPS_CHANGES_REQUIRED" == "true" && "$RESUME_GITOPS" != "true" ]]; then
    save_resume_state "additional_gitops_changes_required" "true"
    emit_additional_gitops_changes_required
  fi
  if [[ "$NO_EXTRA_GITOPS_CHANGES" == "true" || "$RESUME_GITOPS" == "true" ]]; then
    save_resume_state "${STATE_PAUSE_STATE:-awaiting-gitops-scope}" "true"
  fi
else
LOOKUP_OUTPUT="$WORK_DIR/jenkins-lookup.out"
lookup_args=(
  "$SCRIPT_DIR/jenkins-lookup.sh"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --project-dir "$PROJECT_DIR"
  --branch "$BRANCH"
)
[[ -n "$JOB_NAME" ]] && lookup_args+=(--job-name "$JOB_NAME")
[[ -n "$TEMPLATE_JOB" ]] && lookup_args+=(--template-job "$TEMPLATE_JOB")
	run_and_capture "$LOOKUP_OUTPUT" bash "${lookup_args[@]}" || exit 1
	JOB_NAME="$(value_from_output JOB_NAME "$LOOKUP_OUTPUT")"
	JOB_URL="$(value_from_output JOB_URL "$LOOKUP_OUTPUT")"
	LOOKUP_EXISTS="$(value_from_output EXISTS "$LOOKUP_OUTPUT")"

VERSION_OUTPUT="$WORK_DIR/version.out"
if [[ "$LOOKUP_EXISTS" == "false" && -z "$VERSION" ]]; then
  case "$DISTRIBUTION_TYPE" in
    ift) VERSION="IFT-0.0.1" ;;
    release) VERSION="D-00.000.01" ;;
    *) error_exit "Unsupported distribution type: ${DISTRIBUTION_TYPE}" "distribution type" ;;
  esac
else
  version_args=(
    "$SCRIPT_DIR/version-resolver.sh"
    --jenkins-url "$JENKINS_URL"
    --project-name "$PROJECT_NAME"
    --project-dir "$PROJECT_DIR"
    --distribution-type "$DISTRIBUTION_TYPE"
  )
  [[ -n "$JOB_NAME" ]] && version_args+=(--job-name "$JOB_NAME")
  [[ -n "$VERSION" ]] && version_args+=(--version "$VERSION")
  run_and_capture "$VERSION_OUTPUT" bash "${version_args[@]}" || exit 1
  DISTRIBUTION_TYPE="$(value_from_output DISTRIBUTION_TYPE "$VERSION_OUTPUT")"
  VERSION="$(value_from_output VERSION "$VERSION_OUTPUT")"
fi

BUILD_OUTPUT="$WORK_DIR/jenkins-build.out"
build_args=(
  "$SCRIPT_DIR/jenkins-build.sh"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --project-dir "$PROJECT_DIR"
  --branch "$BRANCH"
  --distribution-type "$DISTRIBUTION_TYPE"
  --timeout-seconds "$TIMEOUT_SECONDS"
  --jenkins-branch-param "$JENKINS_BRANCH_PARAM"
  --jenkins-version-param "$JENKINS_VERSION_PARAM"
  --jenkins-distribution-type-param "$JENKINS_DISTRIBUTION_TYPE_PARAM"
  --wait
	)
	[[ -n "$JOB_NAME" ]] && build_args+=(--job-name "$JOB_NAME" --skip-lookup)
	[[ -n "$JOB_URL" ]] && build_args+=(--job-url "$JOB_URL")
	if [[ "$LOOKUP_EXISTS" == "false" ]]; then
	  [[ -n "$TEMPLATE_JOB" ]] || error_exit "Template job is required to create missing Jenkins job" "template job"
	  build_args+=(--template-job "$TEMPLATE_JOB" --create-if-missing)
	else
	  build_args+=(--existing-job)
	fi
[[ -n "$VERSION" ]] && build_args+=(--version "$VERSION")
[[ -n "$REPOSITORY_URL" ]] && build_args+=(--repository-url "$REPOSITORY_URL")
[[ "$DRY_RUN" == "true" ]] && build_args+=(--dry-run)
run_and_capture "$BUILD_OUTPUT" bash "${build_args[@]}" || exit 1

build_status="$(value_from_output STATUS "$BUILD_OUTPUT")"
if [[ "$build_status" == "ERROR" ]]; then
  exit 1
fi

VERSION="$(value_from_output VERSION "$BUILD_OUTPUT")"
RESULT="$(value_from_output RESULT "$BUILD_OUTPUT")"
BUILD_URL="$(value_from_output BUILD_URL "$BUILD_OUTPUT")"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "STATUS=OK"
  echo "ACTION=dry-run"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
  echo "VERSION=${VERSION}"
  exit 0
fi

case "$RESULT" in
  SUCCESS)
    ;;
  FAILURE|UNSTABLE|ABORTED)
    bash "$SCRIPT_DIR/jenkins-analyze-failure.sh" --build-url "$BUILD_URL" --max-lines 400
    exit 1
    ;;
  *)
    error_exit "Jenkins build did not return SUCCESS: ${RESULT}" "successful Jenkins build"
    ;;
esac

reset_deploy_preconditions
DIGEST_OUTPUT="$WORK_DIR/digest.out"
run_and_capture "$DIGEST_OUTPUT" bash "$SCRIPT_DIR/jenkins-resolve-digest.sh" \
  --build-url "$BUILD_URL" \
  --expected-version "$VERSION" || exit 1
IMAGE_DIGEST="$(value_from_output IMAGE_DIGEST "$DIGEST_OUTPUT")"
DIGEST_BUILD_IDENTITY_VERIFIED="$(value_from_output DIGEST_BUILD_IDENTITY_VERIFIED "$DIGEST_OUTPUT")"
DIGEST_BUILD_URL="$(value_from_output BUILD_URL "$DIGEST_OUTPUT")"
[[ -n "$IMAGE_DIGEST" ]] || error_exit "Image digest was not resolved" "Jenkins image digest"
if [[ "$DIGEST_BUILD_IDENTITY_VERIFIED" != "true" || "${DIGEST_BUILD_URL%/}" != "${BUILD_URL%/}" ]]; then
  reset_deploy_preconditions
  gitops_gate_error "digest_build_mismatch" "Image digest does not belong to the completed Jenkins build"
fi
DIGEST_BUILD_MATCH=true

case "$(gitops_scope_action)" in
  ask)
    save_resume_state "awaiting-gitops-scope" "false"
    emit_gitops_scope_pause
    ;;
  additional_required)
    save_resume_state "additional_gitops_changes_required" "true"
    emit_additional_gitops_changes_required
    ;;
  proceed)
    save_resume_state "awaiting-gitops-scope" "true"
    ;;
esac
fi

GITOPS_CHECK_OUTPUT="$WORK_DIR/gitops-check.out"
run_and_capture "$GITOPS_CHECK_OUTPUT" bash "$SCRIPT_DIR/gitops-check.sh" \
  --project-name "$PROJECT_NAME" \
  --environment "$ENVIRONMENT" \
  --config-repo-url "$CONFIG_REPO_URL" \
  --config-repo-branch "$CONFIG_REPO_BRANCH" \
  --charts-path "$CHARTS_PATH" \
  --config-path "$CONFIG_PATH" \
  --config-template-path "$CONFIG_TEMPLATE_PATH" || exit 1
CONFIG_EXISTS="$(value_from_output CONFIG_EXISTS "$GITOPS_CHECK_OUTPUT")"
CONFIG_TEMPLATE_EXISTS="$(value_from_output CONFIG_TEMPLATE_EXISTS "$GITOPS_CHECK_OUTPUT")"

ARGO_CHECK_OUTPUT="$WORK_DIR/argocd-check.out"
run_and_capture "$ARGO_CHECK_OUTPUT" bash "$SCRIPT_DIR/argocd-check.sh" \
  --argocd-server "$ARGOCD_SERVER" \
  --argocd-app-name "$ARGOCD_APP_NAME" || exit 1
ARGOCD_APP_EXISTS="$(value_from_output ARGOCD_APP_EXISTS "$ARGO_CHECK_OUTPUT")"
existing_destination_server="$(value_from_output ARGOCD_DESTINATION_SERVER "$ARGO_CHECK_OUTPUT")"
[[ -n "$existing_destination_server" ]] && ARGOCD_DESTINATION_SERVER="$existing_destination_server"

if ! ARGOCD_MODE="$(deployment_mode_for_state "$CONFIG_EXISTS" "$ARGOCD_APP_EXISTS")"; then
  echo "STATUS=ERROR"
  echo "STATE=inconsistent"
  echo "NEXT_REQUIRED_INPUT=manual deployment state repair"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
fi

if [[ "$ARGOCD_MODE" == "create" && "$CONFIG_TEMPLATE_PATH" == "$CONFIG_PATH" ]]; then
  echo "STATUS=ERROR"
  echo "STATE=missing_first_deployment_template"
  echo "NEXT_REQUIRED_INPUT=separate approved config template path"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
fi

GITOPS_UPDATE_OUTPUT="$WORK_DIR/gitops-update.out"
gitops_update_args=(
  "$SCRIPT_DIR/gitops-update.sh"
  --mode "$ARGOCD_MODE"
  --project-name "$PROJECT_NAME"
  --environment "$ENVIRONMENT"
  --distribution-type "$DISTRIBUTION_TYPE"
  --version "$VERSION"
  --config-repo-url "$CONFIG_REPO_URL"
  --config-repo-branch "$CONFIG_REPO_BRANCH"
  --charts-path "$CHARTS_PATH"
  --config-path "$CONFIG_PATH"
  --config-template-path "$CONFIG_TEMPLATE_PATH"
  --namespace "$ARGOCD_DESTINATION_NAMESPACE"
  --argocd-app-name "$ARGOCD_APP_NAME"
  --digest "$IMAGE_DIGEST"
)
if [[ "$APPROVE_DEPLOYMENT" == "true" || "$NO_EXTRA_GITOPS_CHANGES" == "true" || "$RESUME_GITOPS" == "true" ]]; then
  gitops_update_args+=(--approve)
fi
if ! run_and_capture "$GITOPS_UPDATE_OUTPUT" bash "${gitops_update_args[@]}"; then
  gitops_child_state="$(value_from_output STATE "$GITOPS_UPDATE_OUTPUT")"
  CHARTS_UPDATED="$(value_from_output CHARTS_UPDATED "$GITOPS_UPDATE_OUTPUT")"
  CONFIGS_UPDATED="$(value_from_output CONFIGS_UPDATED "$GITOPS_UPDATE_OUTPUT")"
  FILES_EXPECTED="$(value_from_output FILES_EXPECTED "$GITOPS_UPDATE_OUTPUT")"
  FILES_VERIFIED="$(value_from_output FILES_VERIFIED "$GITOPS_UPDATE_OUTPUT")"
  FILES_FAILED="$(value_from_output FILES_FAILED "$GITOPS_UPDATE_OUTPUT")"
  VERIFIED_FILES="$(value_from_output VERIFIED_FILES "$GITOPS_UPDATE_OUTPUT")"
  FAILED_FILES="$(value_from_output FAILED_FILES "$GITOPS_UPDATE_OUTPUT")"
  EXPECTED_VERSION="$(value_from_output EXPECTED_VERSION "$GITOPS_UPDATE_OUTPUT")"
  EXPECTED_DIGEST="$(value_from_output EXPECTED_DIGEST "$GITOPS_UPDATE_OUTPUT")"
  ACTUAL_VERSION="$(value_from_output ACTUAL_VERSION "$GITOPS_UPDATE_OUTPUT")"
  ACTUAL_DIGEST="$(value_from_output ACTUAL_DIGEST "$GITOPS_UPDATE_OUTPUT")"
  VERSION_APPLIED="$(value_from_output VERSION_APPLIED "$GITOPS_UPDATE_OUTPUT")"
  DIGEST_APPLIED="$(value_from_output DIGEST_APPLIED "$GITOPS_UPDATE_OUTPUT")"
  COMMIT_CREATED="$(value_from_output COMMIT_CREATED "$GITOPS_UPDATE_OUTPUT")"
  COMMIT_SHA="$(value_from_output COMMIT_SHA "$GITOPS_UPDATE_OUTPUT")"
  PUSH_COMPLETED="$(value_from_output PUSH_COMPLETED "$GITOPS_UPDATE_OUTPUT")"
  REMOTE_GIT_VERIFIED="$(value_from_output REMOTE_GIT_VERIFIED "$GITOPS_UPDATE_OUTPUT")"
  REMOTE_COMMIT_SHA="$(value_from_output REMOTE_COMMIT_SHA "$GITOPS_UPDATE_OUTPUT")"
  case "$gitops_child_state" in
    gitops_charts_update_failed|gitops_configs_update_failed|gitops_commit_not_created|gitops_not_updated)
      gitops_gate_error "gitops_not_updated" "GitOps chart/config update was not completed"
      ;;
    gitops_required_file_missing)
      gitops_gate_error "gitops_required_file_missing" "A required GitOps file is missing"
      ;;
    gitops_version_not_applied)
      gitops_gate_error "gitops_version_not_applied" "GitOps files do not contain the built version and image tag"
      ;;
    gitops_digest_not_applied)
      gitops_gate_error "gitops_digest_not_applied" "GitOps files do not contain the built image digest"
      ;;
    gitops_version_mismatch)
      gitops_gate_error "gitops_version_mismatch" "GitOps files contain a different version or image tag"
      ;;
    gitops_digest_mismatch)
      gitops_gate_error "gitops_digest_mismatch" "GitOps files contain a different image digest"
      ;;
    gitops_push_failed)
      gitops_gate_error "gitops_push_failed" "GitOps push did not complete successfully"
      ;;
    git_remote_not_updated)
      gitops_gate_error "git_remote_not_updated" "Remote Git repository does not contain pushed commit"
      ;;
  esac
  if [[ "$PUSH_COMPLETED" == "false" ]]; then
    gitops_gate_error "gitops_push_failed" "GitOps push did not complete successfully"
  fi
  gitops_gate_error "gitops_update_failed" "GitOps update failed"
fi
gitops_status="$(value_from_output STATUS "$GITOPS_UPDATE_OUTPUT")"
CHARTS_UPDATED="$(value_from_output CHARTS_UPDATED "$GITOPS_UPDATE_OUTPUT")"
CONFIGS_UPDATED="$(value_from_output CONFIGS_UPDATED "$GITOPS_UPDATE_OUTPUT")"
FILES_EXPECTED="$(value_from_output FILES_EXPECTED "$GITOPS_UPDATE_OUTPUT")"
FILES_VERIFIED="$(value_from_output FILES_VERIFIED "$GITOPS_UPDATE_OUTPUT")"
FILES_FAILED="$(value_from_output FILES_FAILED "$GITOPS_UPDATE_OUTPUT")"
VERIFIED_FILES="$(value_from_output VERIFIED_FILES "$GITOPS_UPDATE_OUTPUT")"
FAILED_FILES="$(value_from_output FAILED_FILES "$GITOPS_UPDATE_OUTPUT")"
EXPECTED_VERSION="$(value_from_output EXPECTED_VERSION "$GITOPS_UPDATE_OUTPUT")"
EXPECTED_DIGEST="$(value_from_output EXPECTED_DIGEST "$GITOPS_UPDATE_OUTPUT")"
ACTUAL_VERSION="$(value_from_output ACTUAL_VERSION "$GITOPS_UPDATE_OUTPUT")"
ACTUAL_DIGEST="$(value_from_output ACTUAL_DIGEST "$GITOPS_UPDATE_OUTPUT")"
VERSION_APPLIED="$(value_from_output VERSION_APPLIED "$GITOPS_UPDATE_OUTPUT")"
DIGEST_APPLIED="$(value_from_output DIGEST_APPLIED "$GITOPS_UPDATE_OUTPUT")"
COMMIT_CREATED="$(value_from_output COMMIT_CREATED "$GITOPS_UPDATE_OUTPUT")"
COMMIT_SHA="$(value_from_output COMMIT_SHA "$GITOPS_UPDATE_OUTPUT")"
PUSH_COMPLETED="$(value_from_output PUSH_COMPLETED "$GITOPS_UPDATE_OUTPUT")"
REMOTE_GIT_VERIFIED="$(value_from_output REMOTE_GIT_VERIFIED "$GITOPS_UPDATE_OUTPUT")"
REMOTE_COMMIT_SHA="$(value_from_output REMOTE_COMMIT_SHA "$GITOPS_UPDATE_OUTPUT")"
if [[ "$gitops_status" != "OK" ]]; then
  gitops_gate_error "gitops_update_failed" "GitOps update failed"
fi
if [[ "$CHARTS_UPDATED" != "true" || "$CONFIGS_UPDATED" != "true" || "$COMMIT_CREATED" != "true" ]]; then
  gitops_gate_error "gitops_not_updated" "GitOps chart/config update was not completed"
fi
if [[ "$FILES_FAILED" != "0" || "$FILES_EXPECTED" == "0" || "$FILES_VERIFIED" != "$FILES_EXPECTED" ]]; then
  gitops_gate_error "gitops_content_not_verified" "GitOps updated files were not fully verified"
fi
if [[ "$VERSION_APPLIED" != "true" ]]; then
  gitops_gate_error "gitops_version_not_applied" "GitOps files do not contain the built version and image tag"
fi
if [[ "$DIGEST_APPLIED" != "true" ]]; then
  gitops_gate_error "gitops_digest_not_applied" "GitOps files do not contain the built image digest"
fi
if [[ "$PUSH_COMPLETED" != "true" ]]; then
  gitops_gate_error "gitops_push_failed" "GitOps push did not complete successfully"
fi
if [[ "$REMOTE_GIT_VERIFIED" != "true" || -z "$COMMIT_SHA" || "$COMMIT_SHA" != "$REMOTE_COMMIT_SHA" ]]; then
  gitops_gate_error "git_remote_not_updated" "Remote Git repository does not contain pushed commit"
fi
refresh_argo_deploy_allowed
if [[ "$APPROVE_DEPLOYMENT" != "true" && "$NO_EXTRA_GITOPS_CHANGES" != "true" && "$RESUME_GITOPS" != "true" ]]; then
  exit 1
fi

require_argo_deploy_allowed

if [[ -z "$ARGOCD_DESTINATION_SERVER" ]]; then
  error_exit "Missing Argo CD destination server" "Argo CD destination server"
fi

argocd_sync_args=(
  "$SCRIPT_DIR/argocd-sync.sh"
  --mode "$ARGOCD_MODE"
  --argocd-server "$ARGOCD_SERVER"
  --argocd-app-name "$ARGOCD_APP_NAME"
  --argocd-project "$ARGOCD_PROJECT"
  --repo-url "$CONFIG_REPO_URL"
  --target-revision "$CONFIG_REPO_BRANCH"
  --source-path "$CONFIG_PATH"
  --destination-server "$ARGOCD_DESTINATION_SERVER"
  --destination-namespace "$ARGOCD_DESTINATION_NAMESPACE"
  --timeout-seconds "$TIMEOUT_SECONDS"
)
if [[ "$APPROVE_DEPLOYMENT" == "true" || "$NO_EXTRA_GITOPS_CHANGES" == "true" || "$RESUME_GITOPS" == "true" ]]; then
  argocd_sync_args+=(--approve)
fi
bash "${argocd_sync_args[@]}"
remove_resume_state

echo "STATUS=OK"
echo "ACTION=delivered"
echo "PROJECT_NAME=${PROJECT_NAME}"
echo "ENVIRONMENT=${ENVIRONMENT}"
echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
echo "VERSION=${VERSION}"
echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
echo "DIGEST_BUILD_MATCH=${DIGEST_BUILD_MATCH}"
echo "CHARTS_UPDATED=${CHARTS_UPDATED}"
echo "CONFIGS_UPDATED=${CONFIGS_UPDATED}"
echo "FILES_EXPECTED=${FILES_EXPECTED}"
echo "FILES_VERIFIED=${FILES_VERIFIED}"
echo "FILES_FAILED=${FILES_FAILED}"
echo "VERIFIED_FILES=${VERIFIED_FILES}"
echo "FAILED_FILES=${FAILED_FILES}"
echo "EXPECTED_VERSION=${EXPECTED_VERSION}"
echo "EXPECTED_DIGEST=${EXPECTED_DIGEST}"
echo "ACTUAL_VERSION=${ACTUAL_VERSION}"
echo "ACTUAL_DIGEST=${ACTUAL_DIGEST}"
echo "VERSION_APPLIED=${VERSION_APPLIED}"
echo "DIGEST_APPLIED=${DIGEST_APPLIED}"
echo "COMMIT_CREATED=${COMMIT_CREATED}"
echo "COMMIT_SHA=${COMMIT_SHA}"
echo "PUSH_COMPLETED=${PUSH_COMPLETED}"
echo "REMOTE_GIT_VERIFIED=${REMOTE_GIT_VERIFIED}"
echo "REMOTE_COMMIT_SHA=${REMOTE_COMMIT_SHA}"
echo "ARGO_DEPLOY_ALLOWED=${ARGO_DEPLOY_ALLOWED}"
