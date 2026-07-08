#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  JENKINS_USER=<user> JENKINS_TOKEN=<token> \
  scripts/jenkins-distribution-build.sh \
    --jenkins-url <url> \
    --project-name <name> \
    --branch <branch> \
    [--template-job <name>] \
    [--dry-run]

Required arguments:
  --jenkins-url    Jenkins base URL or folder URL
  --project-name   Jenkins job name to find or create
  --branch         Branch passed to buildWithParameters as BRANCH

Optional arguments:
  --template-job   Existing Jenkins template job used when project job is missing
  --dry-run        Print resolved inputs without contacting Jenkins

Required environment unless --dry-run is used:
  JENKINS_USER
  JENKINS_TOKEN
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

blocked() {
  echo "Blocked by environment or Jenkins permissions: $*" >&2
  exit 2
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "Missing value for ${option}"
}

urlencode() {
  local value="$1"
  local length="${#value}"
  local i char

  for ((i = 0; i < length; i++)); do
    char="${value:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
      *) printf '%%%02X' "'$char" ;;
    esac
  done
}

json_field() {
  local field="$1"
  local json="$2"

  if command -v python3 >/dev/null 2>&1; then
    FIELD="$field" python3 -c '
import json
import os
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

value = payload.get(os.environ["FIELD"], "")
if value is None:
    value = ""
print(value)
' <<<"$json"
  elif command -v jq >/dev/null 2>&1; then
    jq -r --arg field "$field" '.[$field] // ""' <<<"$json"
  else
    die "python3 or jq is required to parse Jenkins JSON"
  fi
}

curl_capture() {
  local output_file="$1"
  local error_file="$2"
  shift 2

  if ! curl "$@" >"$output_file" 2>"$error_file"; then
    local error
    error="$(tr '\n' ' ' <"$error_file" | sed 's/[[:space:]]\+/ /g')"
    [[ -n "$error" ]] || error="curl failed"
    blocked "$error"
  fi
}

curl_status() {
  local error_file="$1"
  shift

  local status
  if ! status="$(curl "$@" 2>"$error_file")"; then
    local error
    error="$(tr '\n' ' ' <"$error_file" | sed 's/[[:space:]]\+/ /g')"
    [[ -n "$error" ]] || error="curl failed"
    blocked "$error"
  fi

  printf '%s' "$status"
}

JENKINS_URL=""
PROJECT_NAME=""
TEMPLATE_JOB=""
BRANCH=""
DRY_RUN=false

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
    --template-job)
      require_value "$1" "${2:-}"
      TEMPLATE_JOB="$2"
      shift 2
      ;;
    --branch)
      require_value "$1" "${2:-}"
      BRANCH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$JENKINS_URL" ]] || die "Missing required argument: --jenkins-url"
[[ -n "$PROJECT_NAME" ]] || die "Missing required argument: --project-name"
[[ -n "$BRANCH" ]] || die "Missing required argument: --branch"

command -v curl >/dev/null 2>&1 || die "curl is required but was not found"
if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
  die "python3 or jq is required to parse Jenkins JSON"
fi

JENKINS_URL="${JENKINS_URL%/}"
PROJECT_NAME_ENCODED="$(urlencode "$PROJECT_NAME")"
JOB_URL="${JENKINS_URL}/job/${PROJECT_NAME_ENCODED}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run"
  echo "Project: ${PROJECT_NAME}"
  echo "Branch: ${BRANCH}"
  echo "Jenkins URL: ${JENKINS_URL}"
  echo "Job name: ${PROJECT_NAME}"
  echo "Job URL: ${JOB_URL}/"
  if [[ -n "$TEMPLATE_JOB" ]]; then
    echo "Template job: ${TEMPLATE_JOB}"
  else
    echo "Template job: not provided"
  fi
  echo "Status: Jenkins was not contacted"
  exit 0
fi

[[ -n "${JENKINS_USER:-}" ]] || blocked "missing required environment variable JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || blocked "missing required environment variable JENKINS_TOKEN"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HEADERS_FILE="${TMP_DIR}/headers"
BODY_FILE="${TMP_DIR}/body"
ERROR_FILE="${TMP_DIR}/curl-error"
CRUMB_HEADER=()

CRUMB_STATUS="$(curl_status "$ERROR_FILE" \
  --silent --show-error --output "$BODY_FILE" --write-out '%{http_code}' \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "${JENKINS_URL}/crumbIssuer/api/json")"

case "$CRUMB_STATUS" in
  200)
    CRUMB_JSON="$(cat "$BODY_FILE")"
    CRUMB_FIELD="$(json_field "crumbRequestField" "$CRUMB_JSON")"
    CRUMB_VALUE="$(json_field "crumb" "$CRUMB_JSON")"
    [[ -n "$CRUMB_FIELD" && -n "$CRUMB_VALUE" ]] || blocked "failed to parse Jenkins crumb response"
    CRUMB_HEADER=(--header "${CRUMB_FIELD}: ${CRUMB_VALUE}")
    ;;
  404)
    CRUMB_HEADER=()
    ;;
  401|403)
    blocked "Jenkins returned HTTP ${CRUMB_STATUS} while obtaining crumb"
    ;;
  *)
    blocked "unexpected Jenkins response while obtaining crumb: HTTP ${CRUMB_STATUS}"
    ;;
esac

JOB_STATUS="$(curl_status "$ERROR_FILE" \
  --silent --show-error --output "$BODY_FILE" --write-out '%{http_code}' \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "${JOB_URL}/api/json")"

ACTION=""

case "$JOB_STATUS" in
  200)
    ACTION="reused existing job"
    echo "Job exists"
    ;;
  404)
    [[ -n "$TEMPLATE_JOB" ]] || die "Jenkins job does not exist and --template-job was not provided"

    TEMPLATE_JOB_ENCODED="$(urlencode "$TEMPLATE_JOB")"
    TEMPLATE_JOB_URL="${JENKINS_URL}/job/${TEMPLATE_JOB_ENCODED}"
    TEMPLATE_CONFIG="${TMP_DIR}/template-config.xml"

    curl_capture "$TEMPLATE_CONFIG" "$ERROR_FILE" \
      --silent --show-error --fail \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "${TEMPLATE_JOB_URL}/config.xml"

    curl_capture "$BODY_FILE" "$ERROR_FILE" \
      --silent --show-error --fail --output "$BODY_FILE" \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "${CRUMB_HEADER[@]}" \
      --header "Content-Type: application/xml" \
      --data-binary "@${TEMPLATE_CONFIG}" \
      "${JENKINS_URL}/createItem?name=${PROJECT_NAME_ENCODED}"

    ACTION="created new job"
    echo "Created job"
    ;;
  401|403)
    blocked "Jenkins returned HTTP ${JOB_STATUS} while checking job"
    ;;
  *)
    blocked "unexpected Jenkins response while checking job: HTTP ${JOB_STATUS}"
    ;;
esac

curl_capture "$BODY_FILE" "$ERROR_FILE" \
  --silent --show-error --fail --output "$BODY_FILE" --dump-header "$HEADERS_FILE" \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "${CRUMB_HEADER[@]}" \
  --data-urlencode "BRANCH=${BRANCH}" \
  "${JOB_URL}/buildWithParameters"

QUEUE_URL="$(sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)[[:space:]]*$/\1/p' "$HEADERS_FILE" | tail -n 1 | tr -d '\r')"

echo "Project: ${PROJECT_NAME}"
echo "Branch: ${BRANCH}"
echo "Jenkins URL: ${JENKINS_URL}"
echo "Job name: ${PROJECT_NAME}"
echo "Action: ${ACTION}"
echo "Job URL: ${JOB_URL}/"
if [[ -n "$QUEUE_URL" ]]; then
  echo "Queue URL: ${QUEUE_URL}"
else
  echo "Queue URL: not returned by Jenkins"
fi
echo "Status: queued"
