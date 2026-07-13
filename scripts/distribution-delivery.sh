#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SKILL_ROOT}/.env"

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
    --branch <branch> \
    [--job-name <job-name>] \
    [--template-job <job-name>] \
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
    [--execution-environment <local|corporate>] \
    [--approve-deployment] \
    [--dry-run] \
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
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT:-local}"
  echo "CHILD_EXECUTION_ENVIRONMENT=${CHILD_EXECUTION_ENVIRONMENT:-}"
  exit 1
}

sanitize_technical_reason() {
  sed -E 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g; s#(--user[[:space:]]+)[^[:space:]]+#\1***#g'
}

is_corporate_network_error() {
  case "$1" in
    *"Could not resolve host"*|*"Failed to connect"*|*"Connection refused"*|*"timed out"*|*"Timeout"*|*"timeout"*|*"SSL_ERROR_SYSCALL"*|*"SSL_connect"*|*"TLS"*|*"No route to host"*|*"Host is down"*|*"Network is unreachable"*|*"Connection reset"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

corporate_environment_required_exit() {
  echo "STATUS=ERROR"
  echo "STATE=corporate_environment_required"
  echo "REASON=This operation requires corporate network access"
  echo "NEXT_REQUIRED_INPUT=run inside corporate network"
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT:-local}"
  echo "CHILD_EXECUTION_ENVIRONMENT=${CHILD_EXECUTION_ENVIRONMENT:-}"
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
  echo "CHILD_EXECUTION_ENVIRONMENT=${CHILD_EXECUTION_ENVIRONMENT:-}"
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
    if is_corporate_network_error "$message"; then
      corporate_network_unavailable_exit "$message"
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
  echo "STATE=corporate_network_unavailable"
  echo "REASON=Failed to connect to Jenkins job metadata endpoint"
  echo "JOB_URL=${lookup_job_url:-}"
  echo "JENKINS_METADATA_URL=${JENKINS_METADATA_URL:-}"
  echo "NEXT_REQUIRED_INPUT=Jenkins API access"
  echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT:-local}"
  echo "CHILD_EXECUTION_ENVIRONMENT=${CHILD_EXECUTION_ENVIRONMENT:-}"
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

clone_gitops_repo() {
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git ls-remote --heads "$CONFIG_REPO_URL" "$CONFIG_REPO_BRANCH" >/dev/null 2>"$WORK_DIR/git-ls-remote.err" || {
    local message
    message="$(tr '\n' ' ' <"$WORK_DIR/git-ls-remote.err" | sed 's/[[:space:]]\+/ /g')"
    if is_corporate_network_error "$message"; then
      corporate_network_unavailable_exit "$message"
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
JENKINS_URL=""
PROJECT_NAME=""
BRANCH=""
JOB_NAME=""
TEMPLATE_JOB=""
DISTRIBUTION_TYPE=""
VERSION=""
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
EXECUTION_ENVIRONMENT="${EXECUTION_ENVIRONMENT:-local}"
CHILD_EXECUTION_ENVIRONMENT=""
EXECUTION_ENVIRONMENT_CLI=""
DRY_RUN=false
PREFLIGHT=false
APPROVE_DEPLOYMENT=false
JENKINS_BRANCH_PARAM="BRANCH"
JENKINS_VERSION_PARAM="VERSION"
JENKINS_DISTRIBUTION_TYPE_PARAM="DISTRIBUTION_TYPE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --jenkins-url) require_value "$1" "${2:-}"; JENKINS_URL="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME="$2"; shift 2 ;;
    --template-job) require_value "$1" "${2:-}"; TEMPLATE_JOB="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
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
    --execution-environment) require_value "$1" "${2:-}"; EXECUTION_ENVIRONMENT_CLI="$2"; shift 2 ;;
    --jenkins-branch-param) require_value "$1" "${2:-}"; JENKINS_BRANCH_PARAM="$2"; shift 2 ;;
    --jenkins-version-param) require_value "$1" "${2:-}"; JENKINS_VERSION_PARAM="$2"; shift 2 ;;
    --jenkins-distribution-type-param) require_value "$1" "${2:-}"; JENKINS_DISTRIBUTION_TYPE_PARAM="$2"; shift 2 ;;
    --preflight) PREFLIGHT=true; shift ;;
    --approve-deployment) APPROVE_DEPLOYMENT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --wait) shift ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

if [[ -n "$EXECUTION_ENVIRONMENT_CLI" ]]; then
  EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT_CLI"
fi
case "$EXECUTION_ENVIRONMENT" in
  local|corporate) ;;
  *) error_exit "Unsupported execution environment: ${EXECUTION_ENVIRONMENT}" "local or corporate" ;;
esac

if [[ "$PREFLIGHT" == "true" ]]; then
  export SKILL_ENV_WARNING_EMITTED=1
  exec "$SCRIPT_DIR/preflight.sh" "${ORIGINAL_ARGS[@]}"
fi

[[ -n "$JENKINS_URL" ]] || error_exit "Missing required argument: --jenkins-url" "Jenkins URL"
[[ -n "$PROJECT_NAME" ]] || error_exit "Missing required argument: --project-name" "project name"
[[ -n "$BRANCH" ]] || error_exit "Missing required argument: --branch" "branch"
[[ -n "$DISTRIBUTION_TYPE" ]] || error_exit "Missing required argument: --distribution-type" "distribution type"
if ! DISTRIBUTION_TYPE="$(normalize_distribution_type "$DISTRIBUTION_TYPE")"; then
  error_exit "Unsupported distribution type" "ift or release"
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

if [[ "$EXECUTION_ENVIRONMENT" != "corporate" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "STATUS=OK"
    echo "ACTION=dry-run"
    echo "PROJECT_NAME=${PROJECT_NAME}"
    echo "BRANCH=${BRANCH}"
    echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
    echo "CHARTS_PATH=${CHARTS_PATH}"
    echo "CONFIG_PATH=${CONFIG_PATH}"
    echo "CONFIG_TEMPLATE_PATH=${CONFIG_TEMPLATE_PATH}"
    echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
    echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT}"
    echo "MUTATIONS_PERFORMED=false"
    exit 0
  fi
  corporate_environment_required_exit
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

LOOKUP_OUTPUT="$WORK_DIR/jenkins-lookup.out"
lookup_args=(
  "$SCRIPT_DIR/jenkins-lookup.sh"
  --execution-environment "$EXECUTION_ENVIRONMENT"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --branch "$BRANCH"
)
[[ -n "$JOB_NAME" ]] && lookup_args+=(--job-name "$JOB_NAME")
[[ -n "$TEMPLATE_JOB" ]] && lookup_args+=(--template-job "$TEMPLATE_JOB")
run_and_capture "$LOOKUP_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${lookup_args[@]}" || exit 1
JOB_NAME="$(value_from_output JOB_NAME "$LOOKUP_OUTPUT")"

VERSION_OUTPUT="$WORK_DIR/version.out"
version_args=(
  "$SCRIPT_DIR/version-resolver.sh"
  --execution-environment "$EXECUTION_ENVIRONMENT"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --distribution-type "$DISTRIBUTION_TYPE"
)
[[ -n "$JOB_NAME" ]] && version_args+=(--job-name "$JOB_NAME")
[[ -n "$VERSION" ]] && version_args+=(--version "$VERSION")
run_and_capture "$VERSION_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${version_args[@]}" || exit 1
DISTRIBUTION_TYPE="$(value_from_output DISTRIBUTION_TYPE "$VERSION_OUTPUT")"
VERSION="$(value_from_output VERSION "$VERSION_OUTPUT")"

BUILD_OUTPUT="$WORK_DIR/jenkins-build.out"
build_args=(
  "$SCRIPT_DIR/jenkins-build.sh"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --branch "$BRANCH"
  --distribution-type "$DISTRIBUTION_TYPE"
  --timeout-seconds "$TIMEOUT_SECONDS"
  --jenkins-branch-param "$JENKINS_BRANCH_PARAM"
  --jenkins-version-param "$JENKINS_VERSION_PARAM"
  --jenkins-distribution-type-param "$JENKINS_DISTRIBUTION_TYPE_PARAM"
  --execution-environment "$EXECUTION_ENVIRONMENT"
  --wait
)
[[ -n "$JOB_NAME" ]] && build_args+=(--job-name "$JOB_NAME")
[[ -n "$TEMPLATE_JOB" ]] && build_args+=(--template-job "$TEMPLATE_JOB")
[[ -n "$VERSION" ]] && build_args+=(--version "$VERSION")
[[ "$DRY_RUN" == "true" ]] && build_args+=(--dry-run)
CHILD_EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT"
run_and_capture "$BUILD_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${build_args[@]}" || exit 1

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
    env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "$SCRIPT_DIR/jenkins-analyze-failure.sh" --build-url "$BUILD_URL" --max-lines 400
    exit 1
    ;;
  *)
    error_exit "Jenkins build did not return SUCCESS: ${RESULT}" "successful Jenkins build"
    ;;
esac

GITOPS_CHECK_OUTPUT="$WORK_DIR/gitops-check.out"
run_and_capture "$GITOPS_CHECK_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "$SCRIPT_DIR/gitops-check.sh" \
  --execution-environment "$EXECUTION_ENVIRONMENT" \
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
run_and_capture "$ARGO_CHECK_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "$SCRIPT_DIR/argocd-check.sh" \
  --execution-environment "$EXECUTION_ENVIRONMENT" \
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
  --execution-environment "$EXECUTION_ENVIRONMENT"
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
)
[[ "$APPROVE_DEPLOYMENT" == "true" ]] && gitops_update_args+=(--approve)
run_and_capture "$GITOPS_UPDATE_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${gitops_update_args[@]}" || exit 1
if [[ "$APPROVE_DEPLOYMENT" != "true" ]]; then
  exit 1
fi

if [[ -z "$ARGOCD_DESTINATION_SERVER" ]]; then
  error_exit "Missing Argo CD destination server" "Argo CD destination server"
fi

argocd_sync_args=(
  "$SCRIPT_DIR/argocd-sync.sh"
  --execution-environment "$EXECUTION_ENVIRONMENT"
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
[[ "$APPROVE_DEPLOYMENT" == "true" ]] && argocd_sync_args+=(--approve)
env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${argocd_sync_args[@]}"

echo "STATUS=OK"
echo "ACTION=delivered"
echo "EXECUTION_ENVIRONMENT=${EXECUTION_ENVIRONMENT}"
echo "CHILD_EXECUTION_ENVIRONMENT=${CHILD_EXECUTION_ENVIRONMENT}"
echo "PROJECT_NAME=${PROJECT_NAME}"
echo "ENVIRONMENT=${ENVIRONMENT}"
echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE}"
echo "VERSION=${VERSION}"
