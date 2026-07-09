#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  JENKINS_USER=<user> JENKINS_TOKEN=<token> \
  bash scripts/jenkins-lookup.sh \
    --jenkins-url <url> \
    --project-name <name> \
    [--branch <branch>] \
    [--job-name <job-name>] \
    [--template-job <job-name>]

Required arguments:
  --jenkins-url     Jenkins base or folder URL
  --project-name    Project name used to find Jenkins job

Optional arguments:
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

JENKINS_URL=""
PROJECT_NAME=""
BRANCH=""
TEMPLATE_JOB=""
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

[[ -n "$JENKINS_URL" ]] || error_exit "Missing required argument: --jenkins-url" "Jenkins URL"
[[ -n "$PROJECT_NAME" ]] || error_exit "Missing required argument: --project-name" "project name"
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

JOB_NAME="$PROJECT_NAME"
JOB_URL="$(job_url_for "$JOB_NAME")"
echo "STATUS=OK"
echo "ACTION=lookup"
emit_common
echo "MESSAGE=Job does not exist. Template is available for creation."
echo "NEXT_REQUIRED_INPUT="
