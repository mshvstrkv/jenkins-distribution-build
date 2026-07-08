#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  JENKINS_USER=<user> JENKINS_TOKEN=<token> \
  ./scripts/jenkins-distribution-build.sh \
    --jenkins-url <url> \
    --project-name <name> \
    --template-job <name> \
    --branch <branch>

Required arguments:
  --jenkins-url    Jenkins base URL, for example https://jenkins.example.ru
  --project-name   Jenkins job name to find or create
  --template-job   Existing Jenkins template job used when project job is missing
  --branch         Branch passed to buildWithParameters as BRANCH

Required environment:
  JENKINS_USER
  JENKINS_TOKEN
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
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

JENKINS_URL=""
PROJECT_NAME=""
TEMPLATE_JOB=""
BRANCH=""

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
[[ -n "$TEMPLATE_JOB" ]] || die "Missing required argument: --template-job"
[[ -n "$BRANCH" ]] || die "Missing required argument: --branch"
[[ -n "${JENKINS_USER:-}" ]] || die "Missing required environment variable: JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || die "Missing required environment variable: JENKINS_TOKEN"

command -v curl >/dev/null 2>&1 || die "curl is required but was not found"

HEADERS_FILE="$(mktemp)"
trap 'rm -f "$HEADERS_FILE"' EXIT

JENKINS_URL="${JENKINS_URL%/}"
PROJECT_NAME_ENCODED="$(urlencode "$PROJECT_NAME")"
TEMPLATE_JOB_ENCODED="$(urlencode "$TEMPLATE_JOB")"
JOB_URL="${JENKINS_URL}/job/${PROJECT_NAME_ENCODED}"
TEMPLATE_JOB_URL="${JENKINS_URL}/job/${TEMPLATE_JOB_ENCODED}"

CRUMB_JSON="$(curl --silent --show-error --fail \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "${JENKINS_URL}/crumbIssuer/api/json")" || die "Failed to obtain Jenkins crumb"

CRUMB_FIELD="$(printf '%s' "$CRUMB_JSON" | sed -n 's/.*"crumbRequestField"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
CRUMB_VALUE="$(printf '%s' "$CRUMB_JSON" | sed -n 's/.*"crumb"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -n "$CRUMB_FIELD" && -n "$CRUMB_VALUE" ]] || die "Failed to parse Jenkins crumb response"

JOB_STATUS="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "${JOB_URL}/api/json")"

case "$JOB_STATUS" in
  200)
    echo "Job exists"
    ;;
  404)
    TEMPLATE_CONFIG="$(curl --silent --show-error --fail \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "${TEMPLATE_JOB_URL}/config.xml")" || die "Failed to read template job config.xml"

    curl --silent --show-error --fail --output /dev/null \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      --header "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
      --header "Content-Type: application/xml" \
      --data-binary @- \
      "${JENKINS_URL}/createItem?name=${PROJECT_NAME_ENCODED}" <<<"$TEMPLATE_CONFIG" || die "Failed to create Jenkins job"

    echo "Created job"
    ;;
  401|403)
    die "Jenkins authentication failed or access is denied while checking job"
    ;;
  *)
    die "Unexpected Jenkins response while checking job: HTTP ${JOB_STATUS}"
    ;;
esac

curl --silent --show-error --fail --output /dev/null --dump-header "$HEADERS_FILE" \
  --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
  --header "${CRUMB_FIELD}: ${CRUMB_VALUE}" \
  --data-urlencode "BRANCH=${BRANCH}" \
  "${JOB_URL}/buildWithParameters" || die "Failed to start Jenkins build"

QUEUE_URL="$(sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)[[:space:]]*$/\1/p' "$HEADERS_FILE" | tail -n 1 | tr -d '\r')"

echo "Jenkins job URL: ${JOB_URL}/"
if [[ -n "$QUEUE_URL" ]]; then
  echo "Queue URL: ${QUEUE_URL}"
else
  echo "Queue URL: not returned by Jenkins"
fi
cat <<EOF
Next steps:
  1. Open the Jenkins job URL.
  2. Check the queue item or latest build status.
  3. Use Jenkins logs for build diagnostics.
EOF
