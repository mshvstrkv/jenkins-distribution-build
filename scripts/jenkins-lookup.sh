#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${SKILL_ROOT}/.env}"

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
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" != *"="* ]] && continue
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
    [[ -n "${!key:-}" ]] || export "$key=$value"
  done <"$ENV_FILE"
}

load_skill_env

usage() {
  cat <<'EOF'
Usage:
  JENKINS_USER=<user> JENKINS_TOKEN=<token> \
  bash scripts/jenkins-lookup.sh \
    [--jenkins-url <url>] \
    [--project-name <name>] \
    [--project-dir <path>] \
    [--branch <branch>] \
    [--job-name <job-name>] \
    [--template-job <job-name>]

Optional arguments:
  --jenkins-url     Jenkins base or folder URL. Defaults to JENKINS_URL from skill .env.
  --project-name    Project name used to find Jenkins job. Defaults to git root/current directory name from --project-dir.
  --project-dir     Application repository directory used to resolve project name.
  --branch         Optional. Accepted for interface compatibility with jenkins-build.sh. Ignored by lookup.
  --job-name        Explicit Jenkins job name checked before generated candidates
  --template-job    Template job name available for later creation

Credentials are read only from:
  JENKINS_USER
  JENKINS_TOKEN
EOF
}

emit_common() {
  echo "PROJECT_NAME=${PROJECT_NAME:-}"
  echo "PROJECT_DIR=${PROJECT_DIR:-}"
  echo "BRANCH=${BRANCH:-}"
  echo "JOB_NAME=${JOB_NAME:-}"
  echo "JOB_URL=${JOB_URL:-}"
  echo "JENKINS_URL=${JENKINS_URL:-}"
  echo "EXISTS=${EXISTS:-}"
  echo "TEMPLATE_JOB=${TEMPLATE_JOB:-}"
  echo "CHECKED_JOB_NAMES=${CHECKED_JOB_NAMES_CSV:-}"
}

error_exit() {
  local reason="$1"
  local next_input="${2:-}"

  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=${reason}"
  echo "NEXT_REQUIRED_INPUT=${next_input}"
  emit_common
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
    *) return 1 ;;
  esac
}

jenkins_unreachable_exit() {
  local technical_reason="$1"
  technical_reason="$(printf '%s' "$technical_reason" | sanitize_technical_reason)"
  echo "STATUS=ERROR"
  echo "STATE=jenkins_unreachable"
  echo "REASON=Unable to connect to Jenkins"
  echo "NEXT_REQUIRED_INPUT=Jenkins access"
  emit_common
  echo "MUTATIONS_PERFORMED=false"
  [[ -n "$technical_reason" ]] && echo "TECHNICAL_REASON=${technical_reason}"
  exit 1
}

resolve_project_name() {
  if [[ -n "$PROJECT_NAME" ]]; then
    return 0
  fi
  local git_root
  git_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_root" ]]; then
    PROJECT_NAME="$(basename "$git_root")"
  else
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
  fi
  [[ -n "$PROJECT_NAME" ]] || error_exit "Missing project name" "project name"
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "${option}"
}

urlencode() {
  local value="$1"
  python3 - "$value" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

json_field() {
  local field="$1"
  local json_file="$2"

  FIELD="$field" python3 - "$json_file" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    sys.exit(1)

value = payload.get(os.environ["FIELD"], "")
if value is None:
    value = ""
print(value)
PY
}

job_url_for() {
  local name="$1"
  local encoded
  encoded="$(urlencode "$name")"
  printf '%s/job/%s' "$JENKINS_URL" "$encoded"
}

build_candidate_job_names() {
  CHECKED_JOB_NAMES=()
  if [[ -n "$JOB_NAME_ARG" ]]; then
    CHECKED_JOB_NAMES+=("$JOB_NAME_ARG")
  fi
  CHECKED_JOB_NAMES+=(
    "$PROJECT_NAME"
    "${PROJECT_NAME}-build"
    "${PROJECT_NAME}-distributive"
    "CI11366566_${PROJECT_NAME}"
  )
  CHECKED_JOB_NAMES_CSV="$(IFS=,; echo "${CHECKED_JOB_NAMES[*]}")"
}

curl_get_status() {
  local body_file="$1"
  local headers_file="$2"
  local url="$3"

  CURL_ERROR_MESSAGE=""
  if ! CURL_STATUS="$(curl --silent --show-error --request GET --output "$body_file" --dump-header "$headers_file" --write-out '%{http_code}' --user "${JENKINS_USER}:${JENKINS_TOKEN}" "$url" 2>"$ERROR_FILE")"; then
    CURL_ERROR_MESSAGE="$(tr '\n' ' ' <"$ERROR_FILE" | sed 's/[[:space:]]\+/ /g')"
    [[ -n "$CURL_ERROR_MESSAGE" ]] || CURL_ERROR_MESSAGE="curl failed"
    return 1
  fi

  return 0
}

JENKINS_URL="${JENKINS_URL:-}"
PROJECT_NAME=""
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRANCH=""
TEMPLATE_JOB="${JENKINS_TEMPLATE_JOB:-}"
JOB_NAME_ARG=""
JOB_NAME=""
JOB_URL=""
EXISTS=""
CHECKED_JOB_NAMES=()
CHECKED_JOB_NAMES_CSV=""
CURL_STATUS=""
CURL_ERROR_MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jenkins-url)
      require_value "$1" "${2:-}"
      JENKINS_URL="$2"
      shift 2
      ;;
    --project-name)
      require_value "$1" "${2:-}"
      PROJECT_NAME="$2"
      shift 2
      ;;
    --project-dir)
      require_value "$1" "${2:-}"
      PROJECT_DIR="$2"
      shift 2
      ;;
    --branch)
      require_value "$1" "${2:-}"
      BRANCH="$2"
      shift 2
      ;;
    --job-name)
      require_value "$1" "${2:-}"
      JOB_NAME_ARG="$2"
      shift 2
      ;;
    --template-job)
      require_value "$1" "${2:-}"
      TEMPLATE_JOB="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      error_exit "Unknown argument: $1" "$1"
      ;;
  esac
done

JENKINS_URL="${JENKINS_URL:-${JENKINS_URL:-}}"
[[ -n "$JENKINS_URL" ]] || error_exit "Missing Jenkins URL" "JENKINS_URL"
resolve_project_name
[[ -n "${JENKINS_USER:-}" ]] || error_exit "Missing required environment variable: JENKINS_USER" "JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || error_exit "Missing required environment variable: JENKINS_TOKEN" "JENKINS_TOKEN"
command -v curl >/dev/null 2>&1 || error_exit "curl is required but was not found" "curl"
command -v python3 >/dev/null 2>&1 || error_exit "python3 is required but was not found" "python3"

JENKINS_URL="${JENKINS_URL%/}"
build_candidate_job_names

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
BODY_FILE="${TMP_DIR}/body"
HEADERS_FILE="${TMP_DIR}/headers"
ERROR_FILE="${TMP_DIR}/curl-error"

for candidate in "${CHECKED_JOB_NAMES[@]}"; do
  candidate_url="$(job_url_for "$candidate")"
  if ! curl_get_status "$BODY_FILE" "$HEADERS_FILE" "${candidate_url}/api/json"; then
    if is_network_error "$CURL_ERROR_MESSAGE"; then
      jenkins_unreachable_exit "$CURL_ERROR_MESSAGE"
    fi
    error_exit "$CURL_ERROR_MESSAGE" "Jenkins access"
  fi

  case "$CURL_STATUS" in
    200)
      JOB_NAME="$candidate"
      JOB_URL="$candidate_url"
      api_job_url="$(json_field "url" "$BODY_FILE" || true)"
      [[ -n "$api_job_url" ]] && JOB_URL="${api_job_url%/}"
      EXISTS="true"
      echo "STATUS=OK"
      echo "ACTION=lookup"
      emit_common
      echo "NEXT_REQUIRED_INPUT="
      exit 0
      ;;
    404)
      ;;
    401|403)
      error_exit "Jenkins access denied: HTTP ${CURL_STATUS}" "valid Jenkins credentials"
      ;;
    *)
      error_exit "Unexpected Jenkins response while checking job ${candidate}: HTTP ${CURL_STATUS}" "Jenkins access"
      ;;
  esac
done

EXISTS="false"

if [[ -z "$TEMPLATE_JOB" ]]; then
  error_exit "Job not found" "template job"
fi

JOB_NAME="${JOB_NAME_ARG:-${PROJECT_NAME}-build}"
JOB_URL="$(job_url_for "$JOB_NAME")"
echo "STATUS=OK"
echo "ACTION=lookup"
emit_common
echo "MESSAGE=Job does not exist. Template is available for creation."
echo "NEXT_REQUIRED_INPUT="
