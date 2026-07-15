#!/usr/bin/env bash

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "${COMMON_LIB_DIR}/.." && pwd)}"
SKILL_ROOT="${SKILL_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ENV_FILE="${ENV_FILE:-${SKILL_ROOT}/.env}"
PROJECT_DIR="${PROJECT_DIR:-}"

warn() {
  echo "WARNING=$*"
}

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

project_directory_required_exit() {
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "STATE=project_directory_required"
  echo "REASON=Missing required argument: --project-dir"
  echo "NEXT_REQUIRED_INPUT=project directory"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

require_project_dir() {
  [[ -n "${PROJECT_DIR:-}" ]] || project_directory_required_exit
  [[ -d "$PROJECT_DIR" ]] || error_exit "Project directory does not exist: ${PROJECT_DIR}" "project directory"
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
}

project_git_root() {
  require_project_dir
  local git_root
  git_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$git_root" ]] || error_exit "Project directory is not a Git repository: ${PROJECT_DIR}" "Git repository project directory"
  printf '%s' "$git_root"
}

error_exit() {
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=$1"
  echo "NEXT_REQUIRED_INPUT=${2:-}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "${option}"
}

sanitize_technical_reason() {
  sed -E 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g; s#(--user[[:space:]]+)[^[:space:]]+#\1***#g'
}

is_network_error() {
  case "$1" in
    *"Could not resolve host"*|*"Could not resolve hostname"*|*"Failed to connect"*|*"Connection refused"*|*"timed out"*|*"Timeout"*|*"timeout"*|*"SSL_ERROR_SYSCALL"*|*"SSL_connect"*|*"TLS"*|*"No route to host"*|*"Host is down"*|*"Network is unreachable"*|*"Connection reset"*|*"Unavailable"*|*"connection error"*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

jenkins_unreachable_exit() {
  local technical_reason="${1:-}"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "STATE=jenkins_unreachable"
  echo "REASON=Unable to connect to Jenkins"
  [[ -n "$technical_reason" ]] && echo "TECHNICAL_REASON=${technical_reason}"
  echo "NEXT_REQUIRED_INPUT=Jenkins access"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

resolve_jenkins_url() {
  if [[ -z "${JENKINS_URL:-}" ]]; then
    JENKINS_URL="${JENKINS_URL:-}"
  fi
  [[ -n "${JENKINS_URL:-}" ]] || error_exit "Missing Jenkins URL" "JENKINS_URL"
  JENKINS_URL="${JENKINS_URL%/}"
}

resolve_project_name() {
  local git_root
  git_root="$(project_git_root)"
  PROJECT_NAME="$(basename "$git_root")"
  [[ -n "$PROJECT_NAME" && "$PROJECT_NAME" != "/" && "$PROJECT_NAME" != "." ]] || error_exit "Missing project name" "project name"
}

resolve_branch() {
  require_project_dir
  BRANCH="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)"
  [[ -n "$BRANCH" ]] || error_exit "Missing branch" "branch"
}

resolve_repository_url() {
  require_project_dir
  REPOSITORY_URL="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
  [[ -n "$REPOSITORY_URL" ]] || error_exit "Missing repository URL" "repository URL"
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
  python3 - "$template" "${PROJECT_NAME:-}" "${ENVIRONMENT:-}" "${DISTRIBUTION_TYPE:-}" "${VERSION:-}" "${ARGOCD_DESTINATION_NAMESPACE:-}" "${ARGOCD_APP_NAME:-}" "${CONFIG_PATH:-}" "${CHARTS_PATH:-}" <<'PY'
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
      sed -n 's/^REASON=/REASON=/p' "$err_file"
      echo "NEXT_REQUIRED_INPUT=valid path template"
      echo "MUTATIONS_PERFORMED=false"
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
  local segment old_ifs
  old_ifs="$IFS"
  IFS='/'
  for segment in $path; do
    if [[ "$segment" == ".." ]]; then
      IFS="$old_ifs"
      error_exit "Unsafe ${label}: parent directory segment is not allowed" "safe repository path"
    fi
  done
  IFS="$old_ifs"
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
    echo "inconsistent"
    return 1
  fi
}
