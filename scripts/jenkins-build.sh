#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  JENKINS_USER=<user> JENKINS_TOKEN=<token> \
  bash scripts/jenkins-build.sh \
    --jenkins-url <url> \
    --project-name <name> \
    --branch <branch> \
    [--job-name <job-name>] \
    [--template-job <job-name>] \
    [--distribution-type <ift|release>] \
    [--version <version>] \
    [--version-source <auto|manual>] \
    [--dry-run] \
    [--wait] \
    [--timeout-seconds <number>]

Required arguments:
  --jenkins-url        Jenkins base or folder URL
  --project-name       Project name used to find/create Jenkins job
  --branch             Branch passed to Jenkins as BRANCH

Optional arguments:
  --job-name           Explicit Jenkins job name checked before generated candidates
  --template-job       Template job name, required when project job is missing
  --distribution-type  Distributive type: ift or release
  --version            Explicit distributive version
  --version-source     Version source hint: auto or manual
  --dry-run            Print intended actions without changing Jenkins
  --wait               Wait until the queued build completes
  --timeout-seconds    Wait timeout, default 1800

Credentials are read only from:
  JENKINS_USER
  JENKINS_TOKEN
EOF
}

emit_common() {
  echo "JENKINS_URL=${JENKINS_URL:-}"
  echo "PROJECT_NAME=${PROJECT_NAME:-}"
  echo "BRANCH=${BRANCH:-}"
  echo "JOB_NAME=${JOB_NAME:-}"
  echo "JOB_URL=${JOB_URL:-}"
  echo "QUEUE_URL=${QUEUE_URL:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "RESULT=${RESULT:-}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE:-}"
  echo "VERSION=${VERSION:-}"
  echo "VERSION_SOURCE=${VERSION_SOURCE:-}"
  echo "PREVIOUS_VERSION=${PREVIOUS_VERSION:-}"
  echo "NEXT_REQUIRED_INPUT=${NEXT_REQUIRED_INPUT:-}"
  echo "CHECKED_JOB_NAMES=${CHECKED_JOB_NAMES_CSV:-}"
}

error_exit() {
  local reason="$1"
  local next_input="${2:-}"

  NEXT_REQUIRED_INPUT="$next_input"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=${reason}"
  emit_common
  exit 1
}

warn() {
  echo "WARNING=$*"
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

value = payload
for part in os.environ["FIELD"].split("."):
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
        break

if value is None:
    value = ""
print(value)
PY
}

json_artifact_urls() {
  local json_file="$1"

  python3 - "$json_file" <<'PY'
import json
import sys
import urllib.parse

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    sys.exit(0)

base = payload.get("url") or ""
for artifact in payload.get("artifacts") or []:
    path = artifact.get("relativePath")
    if path and base:
        print(urllib.parse.urljoin(base, "artifact/" + path))
PY
}

version_from_builds_json() {
  local distribution_type="$1"
  local json_file="$2"

  python3 - "$distribution_type" "$json_file" <<'PY'
import json
import re
import sys

distribution_type = sys.argv[1]
json_file = sys.argv[2]

if distribution_type == "ift":
    pattern = re.compile(r"IFT-(\d+)\.(\d+)\.(\d+)")
elif distribution_type == "release":
    pattern = re.compile(r"D-(\d{2})\.(\d{3})\.(\d{2})(?!\d)")
else:
    print(f"ERROR: unsupported distribution type: {distribution_type}", file=sys.stderr)
    sys.exit(2)

try:
    with open(json_file, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception as exc:
    print(f"ERROR: failed to parse Jenkins builds JSON: {exc}", file=sys.stderr)
    sys.exit(2)

texts = []
for build in payload.get("builds") or []:
    for field in ("displayName", "description"):
        value = build.get(field)
        if value:
            texts.append(str(value))
    for action in build.get("actions") or []:
        for param in action.get("parameters") or []:
            if param.get("name") in {"VERSION", "DISTRIBUTIVE_VERSION", "DISTRIBUTION_VERSION"}:
                value = param.get("value")
                if value:
                    texts.append(str(value))

versions = []
for text in texts:
    for match in pattern.finditer(text):
        version = match.group(0)
        numeric = tuple(int(part) for part in match.groups())
        versions.append((numeric, version))

if not versions:
    print("")
    sys.exit(0)

versions.sort(key=lambda item: item[0])
print(versions[-1][1])
PY
}

next_version() {
  local distribution_type="$1"
  local previous_version="$2"

  python3 - "$distribution_type" "$previous_version" <<'PY'
import re
import sys

distribution_type = sys.argv[1]
previous_version = sys.argv[2]

if distribution_type == "ift":
    if not previous_version:
        print("IFT-0.0.1")
        sys.exit(0)
    match = re.fullmatch(r"IFT-(\d+)\.(\d+)\.(\d+)", previous_version)
    if not match:
        print(f"invalid IFT version: {previous_version}", file=sys.stderr)
        sys.exit(1)
    major, minor, patch = (int(part) for part in match.groups())
    print(f"IFT-{major}.{minor}.{patch + 1}")
    sys.exit(0)

if distribution_type == "release":
    if not previous_version:
        print("D-00.000.01")
        sys.exit(0)
    match = re.fullmatch(r"D-(\d{2})\.(\d{3})\.(\d{2})", previous_version)
    if not match:
        print(f"invalid release version: {previous_version}", file=sys.stderr)
        sys.exit(1)
    major, minor, patch = match.groups()
    next_patch = int(patch) + 1
    if next_patch > 99:
        print(f"release version patch overflow: {previous_version}", file=sys.stderr)
        sys.exit(3)
    print(f"D-{major}.{minor}.{next_patch:02d}")
    sys.exit(0)

print(f"unsupported distribution type: {distribution_type}", file=sys.stderr)
sys.exit(1)
PY
}

validate_version_format() {
  local distribution_type="$1"
  local version="$2"

  case "$distribution_type" in
    ift)
      [[ "$version" =~ ^IFT-[0-9]+\.[0-9]+\.[0-9]+$ ]] || error_exit "Invalid IFT version format: ${version}" "valid IFT version"
      ;;
    release)
      [[ "$version" =~ ^D-[0-9]{2}\.[0-9]{3}\.[0-9]{2}$ ]] || error_exit "Invalid release version format: ${version}" "valid release version"
      ;;
    "")
      ;;
    *)
      error_exit "Unsupported distribution type: ${distribution_type}" "distribution type"
      ;;
  esac
}

resolve_version() {
  if [[ -n "$VERSION" ]]; then
    validate_version_format "$DISTRIBUTION_TYPE" "$VERSION"
    VERSION_SOURCE="manual"
    return 0
  fi

  [[ -n "$DISTRIBUTION_TYPE" ]] || error_exit "--distribution-type is required when --version is not provided" "distribution type"
  validate_version_format "$DISTRIBUTION_TYPE" "$(next_version "$DISTRIBUTION_TYPE" "")"

  if [[ "$DRY_RUN" == "true" ]]; then
    PREVIOUS_VERSION=""
    VERSION="$(next_version "$DISTRIBUTION_TYPE" "")"
    VERSION_SOURCE="default"
    return 0
  fi

  local status previous
  status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    "${JOB_URL}/api/json?tree=builds[number,url,result,displayName,description,actions[parameters[name,value]]]")"

  case "$status" in
    200)
      previous="$(version_from_builds_json "$DISTRIBUTION_TYPE" "$BODY_FILE" 2>"$ERROR_FILE")" || {
        local message
        message="$(tr '\n' ' ' <"$ERROR_FILE" | sed 's/[[:space:]]\+/ /g')"
        error_exit "$message" "valid Jenkins builds JSON"
      }
      PREVIOUS_VERSION="$previous"
      VERSION="$(next_version "$DISTRIBUTION_TYPE" "$PREVIOUS_VERSION" 2>"$ERROR_FILE")" || {
        local message
        message="$(tr '\n' ' ' <"$ERROR_FILE" | sed 's/[[:space:]]\+/ /g')"
        error_exit "$message" "valid previous version"
      }
      if [[ -n "$PREVIOUS_VERSION" ]]; then
        VERSION_SOURCE="auto"
      else
        VERSION_SOURCE="default"
      fi
      ;;
    401|403)
      error_exit "Jenkins access denied while resolving version: HTTP ${status}" "valid Jenkins credentials"
      ;;
    *)
      warn "Could not read previous Jenkins builds for version resolution: HTTP ${status}; using initial version"
      PREVIOUS_VERSION=""
      VERSION="$(next_version "$DISTRIBUTION_TYPE" "")"
      VERSION_SOURCE="default"
      ;;
  esac
}

curl_http() {
  local body_file="$1"
  local headers_file="$2"
  shift 2

  local status
  if ! status="$(curl --silent --show-error --output "$body_file" --dump-header "$headers_file" --write-out '%{http_code}' "$@" 2>"$ERROR_FILE")"; then
    status="000"
  fi

  printf '%s' "$status"
}

curl_download() {
  local output_file="$1"
  shift

  if ! curl --silent --show-error --fail --output "$output_file" "$@" 2>"$ERROR_FILE"; then
    local message
    message="$(tr '\n' ' ' <"$ERROR_FILE" | sed 's/[[:space:]]\+/ /g')"
    [[ -n "$message" ]] || message="curl failed"
    error_exit "${message}" "Jenkins access"
  fi
}

header_location() {
  local headers_file="$1"
  sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)[[:space:]]*$/\1/p' "$headers_file" | tail -n 1 | tr -d '\r'
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

ensure_crumb() {
  if [[ "$CRUMB_RESOLVED" == "true" ]]; then
    return 0
  fi

  CRUMB_RESOLVED=true

  local status
  status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    "${JENKINS_URL}/crumbIssuer/api/json")"

  case "$status" in
    200)
      local crumb_field crumb_value
      crumb_field="$(json_field "crumbRequestField" "$BODY_FILE" || true)"
      crumb_value="$(json_field "crumb" "$BODY_FILE" || true)"
      if [[ -n "$crumb_field" && -n "$crumb_value" ]]; then
        CRUMB_HEADER=(--header "${crumb_field}: ${crumb_value}")
      else
        warn "Crumb issuer response could not be parsed; continuing without crumb"
        CRUMB_HEADER=()
      fi
      ;;
    404)
      warn "Crumb issuer is unavailable; continuing without crumb"
      CRUMB_HEADER=()
      ;;
    401|403)
      error_exit "Jenkins access denied while obtaining crumb: HTTP ${status}" "valid Jenkins credentials"
      ;;
    *)
      warn "Crumb issuer returned HTTP ${status}; continuing without crumb"
      CRUMB_HEADER=()
      ;;
  esac
}

find_existing_job() {
  local candidate status candidate_url

  build_candidate_job_names

  for candidate in "${CHECKED_JOB_NAMES[@]}"; do
    candidate_url="$(job_url_for "$candidate")"
    status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "${candidate_url}/api/json")"

    case "$status" in
      200)
        JOB_NAME="$candidate"
        JOB_URL="$candidate_url"
        ACTION="reused"
        return 0
        ;;
      404)
        ;;
      401|403)
        error_exit "Jenkins access denied while checking job ${candidate}: HTTP ${status}" "valid Jenkins credentials"
        ;;
      *)
        error_exit "Unexpected Jenkins response while checking job ${candidate}: HTTP ${status}" "Jenkins access"
        ;;
    esac
  done

  return 1
}

create_job_from_template() {
  if [[ -z "$TEMPLATE_JOB" ]]; then
    error_exit "Jenkins job not found. Checked: ${CHECKED_JOB_NAMES[*]}. --template-job is required to create a missing job." "template job"
  fi

  JOB_NAME="$PROJECT_NAME"
  JOB_URL="$(job_url_for "$JOB_NAME")"

  if [[ "$DRY_RUN" == "true" ]]; then
    ACTION="dry-run"
    return 0
  fi

  local template_url create_status create_name_encoded
  template_url="$(job_url_for "$TEMPLATE_JOB")"
  curl_download "$TEMPLATE_CONFIG_FILE" \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    "${template_url}/config.xml"

  ensure_crumb

  create_name_encoded="$(urlencode "$JOB_NAME")"
  local curl_args=(
    --request POST \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    --header "Content-Type: application/xml" \
    --data-binary "@${TEMPLATE_CONFIG_FILE}"
  )
  if ((${#CRUMB_HEADER[@]} > 0)); then
    curl_args+=("${CRUMB_HEADER[@]}")
  fi
  curl_args+=("${JENKINS_URL}/createItem?name=${create_name_encoded}")
  create_status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" "${curl_args[@]}")"

  case "$create_status" in
    200|201|302)
      ACTION="created"
      ;;
    400)
      error_exit "Jenkins refused to create job ${JOB_NAME}: HTTP ${create_status}. It may already exist." "Jenkins job name or template job"
      ;;
    401|403)
      error_exit "Jenkins access denied while creating job ${JOB_NAME}: HTTP ${create_status}" "valid Jenkins credentials"
      ;;
    *)
      error_exit "Unexpected Jenkins response while creating job ${JOB_NAME}: HTTP ${create_status}" "Jenkins access"
      ;;
  esac
}

trigger_build() {
  if [[ "$DRY_RUN" == "true" ]]; then
    QUEUE_URL=""
    return 0
  fi

  local status encoded_branch
  encoded_branch="$(urlencode "$BRANCH")"

  ensure_crumb

  local curl_args=(
    --request POST \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}"
  )
  if ((${#CRUMB_HEADER[@]} > 0)); then
    curl_args+=("${CRUMB_HEADER[@]}")
  fi
  local build_url="${JOB_URL}/buildWithParameters?BRANCH=${encoded_branch}"
  if [[ -n "$VERSION" ]]; then
    build_url+="&VERSION=$(urlencode "$VERSION")"
  fi
  if [[ -n "$DISTRIBUTION_TYPE" ]]; then
    build_url+="&DISTRIBUTION_TYPE=$(urlencode "$DISTRIBUTION_TYPE")"
  fi
  curl_args+=("$build_url")
  status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" "${curl_args[@]}")"

  if [[ "$status" == "400" || "$status" == "404" || "$status" == "405" ]]; then
    curl_args=(
      --request POST \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}"
    )
    if ((${#CRUMB_HEADER[@]} > 0)); then
      curl_args+=("${CRUMB_HEADER[@]}")
    fi
    curl_args+=("${JOB_URL}/build")
    status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" "${curl_args[@]}")"
  fi

  case "$status" in
    200|201|202|302)
      QUEUE_URL="$(header_location "$HEADERS_FILE")"
      ;;
    401|403)
      error_exit "Jenkins access denied while triggering build: HTTP ${status}" "valid Jenkins credentials"
      ;;
    *)
      error_exit "Unexpected Jenkins response while triggering build: HTTP ${status}" "Jenkins build access"
      ;;
  esac
}

run_version_self_tests() {
  local tmp_dir json_file previous actual failed=0
  tmp_dir="$(mktemp -d)"
  json_file="${tmp_dir}/builds.json"

  printf '{"builds":[]}\n' >"$json_file"
  previous="$(version_from_builds_json ift "$json_file")"
  actual="$(next_version ift "$previous")"
  [[ "$actual" == "IFT-0.0.1" ]] || { echo "FAIL ift none: ${actual}"; failed=1; }

  printf '{"builds":[{"actions":[{"parameters":[{"name":"VERSION","value":"IFT-0.0.1"}]}]}]}\n' >"$json_file"
  previous="$(version_from_builds_json ift "$json_file")"
  actual="$(next_version ift "$previous")"
  [[ "$actual" == "IFT-0.0.2" ]] || { echo "FAIL ift patch: ${actual}"; failed=1; }

  printf '{"builds":[{"displayName":"IFT-0.1.1"},{"description":"D-00.000.09"}]}\n' >"$json_file"
  previous="$(version_from_builds_json ift "$json_file")"
  actual="$(next_version ift "$previous")"
  [[ "$actual" == "IFT-0.1.2" ]] || { echo "FAIL ift ignores release: ${actual}"; failed=1; }

  printf '{"builds":[]}\n' >"$json_file"
  previous="$(version_from_builds_json release "$json_file")"
  actual="$(next_version release "$previous")"
  [[ "$actual" == "D-00.000.01" ]] || { echo "FAIL release none: ${actual}"; failed=1; }

  printf '{"builds":[{"actions":[{"parameters":[{"name":"DISTRIBUTIVE_VERSION","value":"D-00.000.01"}]}]}]}\n' >"$json_file"
  previous="$(version_from_builds_json release "$json_file")"
  actual="$(next_version release "$previous")"
  [[ "$actual" == "D-00.000.02" ]] || { echo "FAIL release patch: ${actual}"; failed=1; }

  printf '{"builds":[{"displayName":"D-00.000.09"},{"description":"IFT-0.9.9"}]}\n' >"$json_file"
  previous="$(version_from_builds_json release "$json_file")"
  actual="$(next_version release "$previous")"
  [[ "$actual" == "D-00.000.10" ]] || { echo "FAIL release ignores ift: ${actual}"; failed=1; }

  printf '{"builds":[{"displayName":"D-00.001.99"}]}\n' >"$json_file"
  previous="$(version_from_builds_json release "$json_file")"
  if actual="$(next_version release "$previous" 2>/dev/null)"; then
    echo "FAIL release overflow: ${actual}"
    failed=1
  fi

  if [[ "$failed" == "0" ]]; then
    echo "VERSION_SELF_TESTS=OK"
    rm -rf "$tmp_dir"
  else
    echo "VERSION_SELF_TESTS=FAIL"
    rm -rf "$tmp_dir"
    exit 1
  fi
}

wait_for_build() {
  [[ "$WAIT" == "true" && "$DRY_RUN" != "true" ]] || return 0
  [[ -n "$QUEUE_URL" ]] || error_exit "Build was triggered but Jenkins did not return queue URL" "queue URL"

  local start now status executable_url result
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    if (( now - start > TIMEOUT_SECONDS )); then
      error_exit "Timed out waiting for Jenkins queue item. Queue URL: ${QUEUE_URL}" "more time or Jenkins queue inspection"
    fi

    status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "${QUEUE_URL%/}/api/json")"

    case "$status" in
      200)
        executable_url="$(json_field "executable.url" "$BODY_FILE" || true)"
        if [[ -n "$executable_url" ]]; then
          BUILD_URL="${executable_url%/}"
          break
        fi
        ;;
      401|403)
        error_exit "Jenkins access denied while reading queue item: HTTP ${status}" "valid Jenkins credentials"
        ;;
      *)
        error_exit "Unexpected Jenkins response while reading queue item: HTTP ${status}" "Jenkins queue access"
        ;;
    esac

    sleep 5
  done

  while true; do
    now="$(date +%s)"
    if (( now - start > TIMEOUT_SECONDS )); then
      error_exit "Timed out waiting for Jenkins build. Build URL: ${BUILD_URL}" "more time or Jenkins build inspection"
    fi

    status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "${BUILD_URL}/api/json")"

    case "$status" in
      200)
        result="$(json_field "result" "$BODY_FILE" || true)"
        if [[ -n "$result" ]]; then
          RESULT="$result"
          ARTIFACT_URLS="$(json_artifact_urls "$BODY_FILE" | paste -sd ',' - || true)"
          return 0
        fi
        ;;
      401|403)
        error_exit "Jenkins access denied while reading build result: HTTP ${status}" "valid Jenkins credentials"
        ;;
      *)
        error_exit "Unexpected Jenkins response while reading build result: HTTP ${status}" "Jenkins build access"
        ;;
    esac

    sleep 10
  done
}

JENKINS_URL=""
PROJECT_NAME=""
BRANCH=""
TEMPLATE_JOB=""
JOB_NAME_ARG=""
DISTRIBUTION_TYPE=""
VERSION=""
VERSION_SOURCE=""
VERSION_SOURCE_ARG=""
PREVIOUS_VERSION=""
DRY_RUN=false
WAIT=false
TIMEOUT_SECONDS=1800
ACTION=""
JOB_NAME=""
JOB_URL=""
QUEUE_URL=""
BUILD_URL=""
RESULT=""
NEXT_REQUIRED_INPUT=""
ARTIFACT_URLS=""
CHECKED_JOB_NAMES=()
CHECKED_JOB_NAMES_CSV=""
CRUMB_HEADER=()
CRUMB_RESOLVED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test-versions)
      run_version_self_tests
      exit 0
      ;;
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
    --distribution-type)
      require_value "$1" "${2:-}"
      DISTRIBUTION_TYPE="$2"
      shift 2
      ;;
    --version)
      require_value "$1" "${2:-}"
      VERSION="$2"
      shift 2
      ;;
    --version-source)
      require_value "$1" "${2:-}"
      VERSION_SOURCE_ARG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --wait)
      WAIT=true
      shift
      ;;
    --timeout-seconds)
      require_value "$1" "${2:-}"
      TIMEOUT_SECONDS="$2"
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
[[ -n "$BRANCH" ]] || error_exit "Missing required argument: --branch" "branch"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || error_exit "--timeout-seconds must be a number" "timeout seconds"
case "$DISTRIBUTION_TYPE" in
  ""|ift|release) ;;
  *) error_exit "Unsupported distribution type: ${DISTRIBUTION_TYPE}" "distribution type" ;;
esac
case "$VERSION_SOURCE_ARG" in
  ""|auto|manual) ;;
  *) error_exit "Unsupported version source: ${VERSION_SOURCE_ARG}" "version source" ;;
esac
[[ -n "${JENKINS_USER:-}" ]] || error_exit "Missing required environment variable: JENKINS_USER" "JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || error_exit "Missing required environment variable: JENKINS_TOKEN" "JENKINS_TOKEN"
command -v curl >/dev/null 2>&1 || error_exit "curl is required but was not found" "curl"
command -v python3 >/dev/null 2>&1 || error_exit "python3 is required but was not found" "python3"

JENKINS_URL="${JENKINS_URL%/}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
BODY_FILE="${TMP_DIR}/body"
HEADERS_FILE="${TMP_DIR}/headers"
ERROR_FILE="${TMP_DIR}/curl-error"
TEMPLATE_CONFIG_FILE="${TMP_DIR}/template-config.xml"

if [[ "$DRY_RUN" == "true" ]]; then
  build_candidate_job_names
  JOB_NAME="${JOB_NAME_ARG:-$PROJECT_NAME}"
  JOB_URL="$(job_url_for "$JOB_NAME")"
  resolve_version
  ACTION="dry-run"
else
  if ! find_existing_job; then
    create_job_from_template
  fi
  resolve_version
  trigger_build
  wait_for_build
fi

echo "STATUS=OK"
echo "ACTION=${ACTION}"
emit_common
if [[ -n "$ARTIFACT_URLS" ]]; then
  echo "ARTIFACT_URLS=${ARTIFACT_URLS}"
fi
