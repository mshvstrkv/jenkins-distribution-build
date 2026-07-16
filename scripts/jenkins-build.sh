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
  bash scripts/jenkins-build.sh \
    [--jenkins-url <url>] \
    [--project-name <name>] \
    [--project-dir <path>] \
	    [--branch <branch>] \
	    [--job-name <job-name>] \
	    [--job-url <url>] \
	    [--template-job <job-name>] \
    [--repository-url <url>] \
    [--distribution-type <ift|release>] \
    [--version <version>] \
    [--version-source <auto|manual>] \
    [--jenkins-branch-param <name>] \
    [--jenkins-version-param <name>] \
    [--jenkins-distribution-type-param <name>] \
	    [--skip-lookup] \
	    [--existing-job] \
	    [--create-if-missing] \
    [--dry-run] \
    [--wait] \
    [--recovery-window-seconds <number>] \
    [--timeout-seconds <number>]

Optional arguments:
  --jenkins-url        Jenkins base or folder URL. Defaults to JENKINS_URL from skill .env.
  --project-name       Project name used to find/create Jenkins job. Defaults to git root/current directory name from --project-dir.
  --project-dir        Application repository directory used to resolve project name, branch, and repository URL.
  --branch             Branch passed to Jenkins as BRANCH. Defaults to current git branch in --project-dir.
	  --job-name           Explicit Jenkins job name checked before generated candidates
	  --job-url            Exact Jenkins job URL to use with --job-name and --skip-lookup
	  --template-job       Template job name, defaults to JENKINS_TEMPLATE_JOB from skill .env when project job is missing
  --repository-url     Repository URL for rendering a new job config. Defaults to git remote origin in --project-dir.
  --distribution-type  Distributive type: ift|release, aliases: test/testing/prod/production
  --version            Explicit distributive version
  --version-source     Version source hint: auto or manual
  --jenkins-branch-param             Jenkins branch parameter name, default BRANCH
  --jenkins-version-param            Jenkins version parameter name, default VERSION
	  --jenkins-distribution-type-param  Jenkins distribution type parameter name, default DISTRIBUTION_TYPE
	  --skip-lookup        Use the explicit --job-name without running Jenkins job lookup
	  --existing-job       Verify and build an existing --job-name; forbids --template-job and createItem
	  --create-if-missing  Create --job-name from --template-job after lookup proved the job is missing
  --dry-run            Print intended actions without changing Jenkins
  --wait               Wait until the queued build completes
  --recovery-window-seconds  Completed build recovery window, default 3600
  --timeout-seconds    Wait timeout, default 1800

Credentials are read only from:
  JENKINS_USER
  JENKINS_TOKEN
EOF
}

emit_common() {
  echo "STATE=${STATE:-}"
  echo "JENKINS_URL=${JENKINS_URL:-}"
  echo "PROJECT_NAME=${PROJECT_NAME:-}"
  echo "PROJECT_DIR=${PROJECT_DIR:-}"
  echo "BRANCH=${BRANCH:-}"
  echo "REPOSITORY_URL=${REPOSITORY_URL:-}"
  echo "JOB_CREATED=${JOB_CREATED:-false}"
  echo "JOB_EXISTS=${JOB_EXISTS:-false}"
  echo "JOB_MODE=${JOB_MODE:-}"
  echo "REQUESTED_JOB_NAME=${REQUESTED_JOB_NAME:-}"
  echo "CREATED_JOB_NAME=${CREATED_JOB_NAME:-}"
  echo "JOB_NAME_SOURCE=${JOB_NAME_SOURCE:-}"
  echo "JOB_NAME=${JOB_NAME:-}"
  echo "JOB_URL=${JOB_URL:-}"
  echo "JOB_CONFIGURATION_VERIFIED=${JOB_CONFIGURATION_VERIFIED:-false}"
  echo "JOB_IDENTITY_VERIFIED=${JOB_IDENTITY_VERIFIED:-false}"
  echo "REQUIRED_PARAMETERS_OK=${REQUIRED_PARAMETERS_OK:-false}"
  echo "REQUIRED_PARAMETERS=${REQUIRED_PARAMETERS:-}"
  echo "SUPPORTED_PARAMETERS=${SUPPORTED_PARAMETERS:-}"
  echo "OPTIONAL_PARAMETERS=${OPTIONAL_PARAMETERS:-}"
  echo "MISSING_REQUIRED_PARAMETERS=${MISSING_REQUIRED_PARAMETERS:-}"
  echo "DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=${DISTRIBUTION_TYPE_PARAMETER_SUPPORTED:-false}"
  echo "SCRIPT_PATH=${SCRIPT_PATH:-}"
  echo "APPLICATION_REPOSITORY_URL=${APPLICATION_REPOSITORY_URL:-}"
  echo "ENV_REPO_URL=${ENV_REPO_URL:-}"
  echo "BRANCH_PARAMETER_REPOSITORY_URL=${BRANCH_PARAMETER_REPOSITORY_URL:-}"
  echo "PIPELINE_REPOSITORY_URL=${PIPELINE_REPOSITORY_URL:-}"
  echo "EXPECTED_PIPELINE_REPOSITORY_URL=${EXPECTED_PIPELINE_REPOSITORY_URL:-}"
  echo "ACTUAL_PIPELINE_REPOSITORY_URL=${ACTUAL_PIPELINE_REPOSITORY_URL:-}"
  echo "PIPELINE_BRANCH_SPEC=${PIPELINE_BRANCH_SPEC:-}"
  echo "PIPELINE_SCRIPT_PATH=${PIPELINE_SCRIPT_PATH:-}"
  echo "CONFIG_DIFF_PATHS=${CONFIG_DIFF_PATHS:-}"
  echo "REPOSITORY_MISMATCH_PATHS=${REPOSITORY_MISMATCH_PATHS:-}"
  echo "PIPELINE_SCM_BRANCH_SPEC=${PIPELINE_SCM_BRANCH_SPEC:-}"
  echo "WARNING=${WARNING:-}"
  echo "HTTP_STATUS=${HTTP_STATUS:-}"
  echo "CREATED_JOB_REQUIRES_REVIEW=${CREATED_JOB_REQUIRES_REVIEW:-false}"
  echo "EXPECTED_REPOSITORY_URL=${EXPECTED_REPOSITORY_URL:-}"
  echo "ACTUAL_REPOSITORY_URL=${ACTUAL_REPOSITORY_URL:-}"
  echo "EXPECTED_JOB_NAME=${EXPECTED_JOB_NAME:-}"
  echo "ACTUAL_JOB_NAME=${ACTUAL_JOB_NAME:-}"
  echo "EXPECTED_JOB_URL=${EXPECTED_JOB_URL:-}"
  echo "TEMPLATE_REFERENCE_PATHS=${TEMPLATE_REFERENCE_PATHS:-}"
  echo "TRIGGER_URL=${TRIGGER_URL:-}"
  echo "QUEUE_URL=${QUEUE_URL:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-}"
  echo "RESULT=${RESULT:-}"
  echo "BUILDING=${BUILDING:-}"
  echo "STATUS_VERIFIED=${STATUS_VERIFIED:-false}"
  echo "STATUS_VERIFIED_AT=${STATUS_VERIFIED_AT:-}"
  echo "EXPECTED_BUILD_NUMBER=${EXPECTED_BUILD_NUMBER:-}"
  echo "API_BUILD_NUMBER=${API_BUILD_NUMBER:-}"
  echo "BUILD_TRIGGERED=${BUILD_TRIGGERED:-false}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE:-}"
  echo "VERSION=${VERSION:-}"
  echo "VERSION_SOURCE=${VERSION_SOURCE:-}"
  echo "PREVIOUS_VERSION=${PREVIOUS_VERSION:-}"
  echo "NEXT_REQUIRED_INPUT=${NEXT_REQUIRED_INPUT:-}"
  echo "CHECKED_JOB_NAMES=${CHECKED_JOB_NAMES_CSV:-}"
  echo "JENKINS_PARAMETER_BRANCH=${JENKINS_BRANCH_PARAM:-}"
  echo "JENKINS_PARAMETER_VERSION=${JENKINS_VERSION_PARAM:-}"
  echo "JENKINS_PARAMETER_DISTRIBUTION_TYPE=${JENKINS_DISTRIBUTION_TYPE_PARAM:-}"
  echo "MUTATIONS_PERFORMED=${MUTATIONS_PERFORMED:-false}"
}

project_directory_required_exit() {
  STATE="project_directory_required"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Missing required argument: --project-dir"
  NEXT_REQUIRED_INPUT="project directory"
  emit_common
  exit 1
}

require_project_dir() {
  [[ -n "${PROJECT_DIR:-}" ]] || project_directory_required_exit
  [[ -d "$PROJECT_DIR" ]] || error_exit "Project directory does not exist: ${PROJECT_DIR}" "project directory"
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
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
  NEXT_REQUIRED_INPUT="Jenkins access"
  emit_common
  echo "MUTATIONS_PERFORMED=false"
  [[ -n "$technical_reason" ]] && echo "TECHNICAL_REASON=${technical_reason}"
  exit 1
}

warn() {
  echo "WARNING=$*"
}

resolve_project_name() {
  local git_root
  require_project_dir
  git_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$git_root" ]] || error_exit "Project directory is not a Git repository: ${PROJECT_DIR}" "Git repository project directory"
  PROJECT_NAME="$(basename "$git_root")"
  [[ -n "$PROJECT_NAME" ]] || error_exit "Missing project name" "project name"
}

resolve_branch() {
  require_project_dir
  BRANCH="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)"
  [[ -n "$BRANCH" ]] || error_exit "Missing branch" "branch"
}

resolve_repository_url() {
  require_project_dir
  REPOSITORY_URL="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
  [[ -n "$REPOSITORY_URL" ]] || {
    echo "STATUS=ERROR"
    echo "ACTION=blocked"
    echo "STATE=repository_url_required"
    echo "REASON=Repository URL is required to render Jenkins job config"
    NEXT_REQUIRED_INPUT="repository URL"
    emit_common
    exit 1
  }
}

normalize_distribution_type() {
  local value="$1"

  case "$value" in
    "")
      printf ''
      ;;
    ift|test|testing)
      printf 'ift'
      ;;
    release|prod|production)
      printf 'release'
      ;;
    *)
      return 1
      ;;
  esac
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

json_recovery_match() {
  local recovery_source="$1"
  local json_file="$2"
  local root_url="$3"

  local current_time_ms
  current_time_ms="$(($(date +%s) * 1000))"

  python3 - "$recovery_source" "$json_file" "$root_url" "$JOB_NAME" "$JOB_URL" "$JENKINS_BRANCH_PARAM" "$BRANCH" "$JENKINS_VERSION_PARAM" "$VERSION" "$JENKINS_DISTRIBUTION_TYPE_PARAM" "$DISTRIBUTION_TYPE" "$RECOVERY_WINDOW_SECONDS" "$current_time_ms" <<'PY'
import json
import sys
import urllib.parse

(
    mode,
    json_file,
    root_url,
    job_name,
    job_url,
    branch_param,
    branch,
    version_param,
    version,
    distribution_type_param,
    distribution_type,
    recovery_window_seconds,
    current_time_ms,
) = sys.argv[1:]
recovery_window_ms = int(recovery_window_seconds) * 1000
current_time_ms = int(current_time_ms)

try:
    with open(json_file, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    sys.exit(1)

def norm_url(value):
    return (value or "").rstrip("/")

def parameters_from_actions(actions):
    values = {}
    for action in actions or []:
        for parameter in action.get("parameters") or []:
            name = str(parameter.get("name") or "")
            if name:
                values[name] = str(parameter.get("value") or "")
    return values

def parameters_from_queue_text(text):
    values = {}
    for line in str(text or "").splitlines():
        if "=" in line:
            name, value = line.split("=", 1)
            values[name.strip()] = value.strip()
    return values

def matches_params(values):
    return (
        values.get(branch_param) == branch
        and values.get(version_param) == version
        and values.get(distribution_type_param) == distribution_type
    )

if mode == "queue":
    for item in payload.get("items") or []:
        task = item.get("task") or {}
        task_url = norm_url(task.get("url"))
        task_name = str(task.get("name") or "")
        if task_url and task_url != norm_url(job_url):
            continue
        if not task_url and task_name != job_name:
            continue
        values = parameters_from_actions(item.get("actions"))
        values.update(parameters_from_queue_text(item.get("params")))
        if not matches_params(values):
            continue
        queue_url = item.get("url") or ""
        if not queue_url and item.get("id") is not None:
            queue_url = urllib.parse.urljoin(root_url.rstrip("/") + "/", f"queue/item/{item['id']}/")
        executable = item.get("executable") or {}
        print(f"QUEUE_URL={queue_url.rstrip('/')}")
        print(f"BUILD_URL={norm_url(executable.get('url'))}")
        sys.exit(0)
    sys.exit(1)

if mode == "builds":
    for build in payload.get("builds") or []:
        values = parameters_from_actions(build.get("actions"))
        if not matches_params(values):
            continue
        building = bool(build.get("building"))
        result = build.get("result")
        if result == "ABORTED":
            continue
        if not building:
            timestamp = build.get("timestamp")
            if timestamp is None:
                continue
            try:
                timestamp = int(timestamp)
            except (TypeError, ValueError):
                continue
            if current_time_ms - timestamp > recovery_window_ms:
                continue
        print("QUEUE_URL=")
        print(f"BUILD_URL={norm_url(build.get('url'))}")
        print(f"RESULT={'' if result is None else result}")
        sys.exit(0)
    sys.exit(1)

sys.exit(2)
PY
}

build_number_from_url() {
  local url="$1"
  python3 - "$url" <<'PY'
import re
import sys

match = re.search(r"/(\d+)/?$", sys.argv[1].rstrip("/"))
print(match.group(1) if match else "")
PY
}

json_build_status_fields() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    sys.exit(1)

building = payload.get("building")
if isinstance(building, bool):
    building_value = "true" if building else "false"
else:
    building_value = "invalid"

result = payload.get("result")
if result is None:
    result = ""

print(f"API_BUILD_URL={(payload.get('url') or '').rstrip('/')}")
print(f"API_BUILD_NUMBER={'' if payload.get('number') is None else payload.get('number')}")
print(f"BUILDING={building_value}")
print(f"RESULT={result}")
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

emit_version_resolution() {
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE:-}"
  echo "PREVIOUS_VERSION=${PREVIOUS_VERSION:-}"
  echo "VERSION=${VERSION:-}"
  echo "VERSION_SOURCE=${VERSION_SOURCE:-}"
}

resolve_version() {
  if [[ -n "$VERSION" ]]; then
    validate_version_format "$DISTRIBUTION_TYPE" "$VERSION"
    VERSION_SOURCE="manual"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    PREVIOUS_VERSION=""
    case "$DISTRIBUTION_TYPE" in
      ift) VERSION="IFT-0.0.1" ;;
      release) VERSION="D-00.000.01" ;;
      *) error_exit "Unsupported distribution type: ${DISTRIBUTION_TYPE}" "distribution type" ;;
    esac
    VERSION_SOURCE="default"
    return 0
  fi

  error_exit "--version is required; run scripts/version-resolver.sh first" "resolved version"
}

curl_http() {
  local body_file="$1"
  local headers_file="$2"
  shift 2

  local status
  : >"$body_file"
  : >"$headers_file"
  if ! status="$(curl --silent --show-error --output "$body_file" --dump-header "$headers_file" --write-out '%{http_code}' "$@" 2>"$ERROR_FILE")"; then
    local message
    message="$(tr '\n' ' ' <"$ERROR_FILE" | sed 's/[[:space:]]\+/ /g')"
    if is_network_error "$message"; then
      jenkins_unreachable_exit "$message"
    fi
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
    if is_network_error "$message"; then
      jenkins_unreachable_exit "$message"
    fi
    error_exit "${message}" "Jenkins access"
  fi
}

jenkins_get_follow_redirect() {
  local current_url="$1"
  local output_file="$2"
  local require_body="${3:-true}"
  local update_build_url="${4:-false}"
  local status location next_url redirect_count=0

  CURL_GET_STATUS=""
  CURL_GET_TECHNICAL_REASON=""
  while true; do
    status="$(curl_http "$output_file" "$HEADERS_FILE" \
      --globoff \
      --request GET \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "$current_url")"
    HTTP_STATUS="$status"

    case "$status" in
      200)
        CURL_GET_STATUS="$status"
        if [[ "$require_body" == "true" && ! -s "$output_file" ]]; then
          CURL_GET_STATUS="563"
        fi
        return 0
        ;;
      301|302|303|307|308)
        location="$(header_location "$HEADERS_FILE")"
        if [[ -z "$location" ]]; then
          CURL_GET_STATUS="562"
          return 0
        fi
        next_url="$(absolute_url "$current_url" "$location")"
        if ! approved_jenkins_redirect_url "$next_url"; then
          CURL_GET_STATUS="561"
          return 0
        fi
        [[ "$update_build_url" == "true" && "$next_url" != */api/json ]] && next_url="${BUILD_URL}/api/json"
        current_url="$next_url"
        redirect_count=$((redirect_count + 1))
        if (( redirect_count > 5 )); then
          CURL_GET_STATUS="562"
          return 0
        fi
        ;;
      *)
        CURL_GET_STATUS="$status"
        if [[ -f "$ERROR_FILE" ]]; then
          CURL_GET_TECHNICAL_REASON="$(tr '\n' ' ' <"$ERROR_FILE" | sed 's/[[:space:]]\+/ /g' | sanitize_technical_reason)"
        fi
        return 0
        ;;
    esac
  done
}

curl_get_jenkins_api_follow_redirect() {
  local current_url="$1"
  local update_build_url="${2:-false}"
  jenkins_get_follow_redirect "$current_url" "$BODY_FILE" true "$update_build_url"
}

download_jenkins_config_xml() {
  local output_file="$1"
  local current_url="$2"

  jenkins_get_follow_redirect "$current_url" "$output_file" true false
  case "$CURL_GET_STATUS" in
    200)
      return 0
      ;;
    401|403)
      error_exit "Jenkins access denied while reading job config.xml: HTTP ${CURL_GET_STATUS}" "valid Jenkins credentials"
      ;;
    561)
      jenkins_redirect_failed_exit "Jenkins job config.xml redirected to an unapproved host"
      ;;
    562)
      jenkins_redirect_failed_exit "Jenkins job config.xml redirect failed"
      ;;
    563)
      job_config_unavailable_exit "Jenkins job config.xml response is empty" "$HTTP_STATUS"
      ;;
    *)
      job_config_unavailable_exit "Failed to read Jenkins job config.xml: HTTP ${CURL_GET_STATUS}" "$CURL_GET_STATUS"
      ;;
  esac
}

xml_first_repository_url() {
  local xml_file="$1"
  python3 - "$xml_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

def lname(elem):
    return elem.tag.rsplit("}", 1)[-1].lower()

def looks_like_repo_url(value):
    return bool(
        value
        and (
            value.startswith(("ssh://", "git@", "http://", "https://"))
            or ".git" in value
            or "bitbucket" in value.lower()
        )
    )

def properties_content_value(value, key):
    for line in (value or "").splitlines():
        current_key, sep, current_value = line.partition("=")
        if sep and current_key.strip() == key:
            return current_value.strip()
    return ""

def branch_parameter_remote_url(root):
    for container in root.iter():
        if lname(container) != "parameterDefinitions":
            continue
        for param in list(container):
            param_name = ""
            for child in list(param):
                if lname(child) == "name" and child.text:
                    param_name = child.text.strip()
                    break
            if param_name != "BRANCH":
                continue
            for child in list(param):
                if lname(child) == "remoteURL":
                    value = (child.text or "").strip()
                    if looks_like_repo_url(value):
                        return value
    return ""

try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(1)

for elem in root.iter():
    if lname(elem) == "propertiescontent":
        value = properties_content_value(elem.text or "", "REPO_URL")
        if looks_like_repo_url(value):
            print(value)
            sys.exit(0)

branch_remote_url = branch_parameter_remote_url(root)
if branch_remote_url:
    print(branch_remote_url)
    sys.exit(0)

for elem in root.iter():
    if lname(elem) in {"url", "remote", "repositoryurl", "repository"}:
        value = (elem.text or "").strip()
        if looks_like_repo_url(value):
            print(value)
            sys.exit(0)
sys.exit(1)
PY
}

repo_slug_from_url() {
  local repo_url="$1"
  python3 - "$repo_url" <<'PY'
import sys
import urllib.parse

value = sys.argv[1]
parsed = urllib.parse.urlparse(value)
path = parsed.path if parsed.scheme else value
path = path.rstrip("/")
if ":" in path and "/" in path and not parsed.scheme:
    path = path.split(":", 1)[-1]
base = path.rsplit("/", 1)[-1]
if base.endswith(".git"):
    base = base[:-4]
print(base)
PY
}

job_verification_exit() {
  local state="$1"
  local reason="$2"
  local next_input="${3:-review created Jenkins job configuration}"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "STATE=${state}"
  echo "REASON=${reason}"
  JOB_CONFIGURATION_VERIFIED=false
  CREATED_JOB_REQUIRES_REVIEW=true
  if [[ "${JOB_CREATED:-false}" == "true" ]]; then
    MUTATIONS_PERFORMED=true
  fi
  NEXT_REQUIRED_INPUT="$next_input"
  emit_common
  exit 1
}

created_job_mismatch_exit() {
  job_verification_exit "jenkins_created_job_mismatch" "$1" "review or remove invalid Jenkins job"
}

config_mismatch_exit() {
  job_verification_exit "jenkins_created_job_config_mismatch" "$1" "review created Jenkins job configuration"
}

identity_mismatch_exit() {
  job_verification_exit "jenkins_created_job_identity_mismatch" "$1" "review created Jenkins job identity"
}

jenkins_redirect_failed_exit() {
  job_verification_exit "jenkins_redirect_failed" "$1" "Jenkins redirect access"
}

repository_mismatch_exit() {
  job_verification_exit "jenkins_created_job_repository_mismatch" "$1" "review created Jenkins job repository"
}

parameter_mismatch_exit() {
  job_verification_exit "jenkins_created_job_parameter_mismatch" "$1" "review created Jenkins job parameters"
}

script_path_mismatch_exit() {
  job_verification_exit "jenkins_created_job_script_path_mismatch" "$1" "review created Jenkins job script path"
}

pipeline_scm_mismatch_exit() {
  job_verification_exit "jenkins_pipeline_scm_mismatch" "$1" "review Jenkins pipeline SCM configuration"
}

job_config_unavailable_exit() {
  local reason="$1"
  HTTP_STATUS="${2:-}"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "STATE=jenkins_job_config_unavailable"
  echo "REASON=${reason}"
  JOB_CONFIGURATION_VERIFIED=false
  if [[ "${JOB_CREATED:-false}" == "true" ]]; then
    CREATED_JOB_REQUIRES_REVIEW=true
    MUTATIONS_PERFORMED=true
  fi
  NEXT_REQUIRED_INPUT="Jenkins job configuration access"
  emit_common
  exit 1
}

verify_created_config() {
  local config_file="$1"
  local verify_output="$2"
  set +e
  python3 - "$config_file" "$REPOSITORY_URL" "$TEMPLATE_PROJECT_SLUG" "$PROJECT_NAME" >"$verify_output" <<'PY'
import sys
import xml.etree.ElementTree as ET

config_file, expected_repo, template_slug, project_name = sys.argv[1:]
required_params = {"BRANCH", "VERSION"}
optional_params = {"DISTRIBUTION_TYPE"}

def csv(values):
    return ",".join(sorted(values))

def lname(elem):
    return elem.tag.rsplit("}", 1)[-1]

def path_join(parent, elem):
    return f"{parent}/{lname(elem)}"

def iter_with_path(elem, path=""):
    current = path_join(path, elem)
    yield elem, current
    for child in list(elem):
        yield from iter_with_path(child, current)

def looks_like_repo_url(value):
    return bool(
        value
        and (
            value.startswith(("ssh://", "git@", "http://", "https://"))
            or ".git" in value
            or "bitbucket" in value.lower()
        )
    )

try:
    root = ET.parse(config_file).getroot()
except Exception as exc:
    print(f"VERIFY_REASON=Created job config.xml could not be parsed: {exc}")
    sys.exit(1)

repos = []
for elem in root.iter():
    if lname(elem).lower() in {"url", "remote", "repositoryurl", "repository"}:
        value = (elem.text or "").strip()
        if looks_like_repo_url(value):
            repos.append(value)

actual_repo = repos[0] if repos else ""
print(f"ACTUAL_REPOSITORY_URL={actual_repo}")
if actual_repo != expected_repo:
    print("VERIFY_REASON=Created job repository URL does not match current project repository")
    sys.exit(1)

params = set()
for container in root.iter():
    if lname(container) != "parameterDefinitions":
        continue
    for param in list(container):
        for child in list(param):
            if lname(child) == "name" and child.text:
                params.add(child.text.strip())
                break

missing = sorted(required_params - params)
print(f"REQUIRED_PARAMETERS={csv(required_params)}")
print(f"SUPPORTED_PARAMETERS={csv(params)}")
print(f"OPTIONAL_PARAMETERS={csv(optional_params)}")
print(f"MISSING_REQUIRED_PARAMETERS={','.join(missing)}")
print(f"DISTRIBUTION_TYPE_PARAMETER_SUPPORTED={'true' if 'DISTRIBUTION_TYPE' in params else 'false'}")
if missing:
    print(f"MISSING_PARAMETERS={','.join(missing)}")
    print("VERIFY_REASON=Created job is missing required build parameters")
    sys.exit(1)

approved_text_fields = {"displayName", "description", "defaultValue"}
if template_slug and template_slug != project_name:
    for elem in root.iter():
        if lname(elem) in approved_text_fields and elem.text and template_slug in elem.text:
            print("VERIFY_REASON=Template project reference remains in created job config")
            sys.exit(1)

sys.exit(0)
PY
  local code=$?
  set -e
  return "$code"
}

verify_job_url_identity() {
  local expected_folder_url="$1"
  local actual_url="$2"
  local expected_name="$3"
  python3 - "$expected_folder_url" "$actual_url" "$expected_name" <<'PY'
import sys
import urllib.parse

expected_folder_url, actual_url, expected_name = sys.argv[1:]
approved_hosts = {
    "aipay.ci.jenkins.sberbank.ru",
    "ci.jenkins.sberbank.ru",
}
expected = urllib.parse.urlparse(expected_folder_url)
actual = urllib.parse.urlparse(actual_url)
if expected.hostname:
    approved_hosts.add(expected.hostname)
if actual.hostname not in approved_hosts:
    sys.exit(1)
expected_folder_path = urllib.parse.unquote(expected.path.rstrip("/"))
expected_path = f"{expected_folder_path}/job/{expected_name}"
actual_path = urllib.parse.unquote(actual.path.rstrip("/"))
if actual_path != expected_path:
    sys.exit(1)
PY
}

verify_job_identity_from_api() {
  EXPECTED_JOB_NAME="$JOB_NAME"
  EXPECTED_JOB_URL="$(job_url_for "$EXPECTED_JOB_NAME")"
  local actual_job_url
  ACTUAL_JOB_NAME="$(json_field "name" "$BODY_FILE" || true)"
  actual_job_url="$(json_field "url" "$BODY_FILE" || true)"
  [[ -n "$actual_job_url" ]] && actual_job_url="${actual_job_url%/}"

  if [[ "$ACTUAL_JOB_NAME" != "$EXPECTED_JOB_NAME" ]]; then
    identity_mismatch_exit "Created Jenkins job name does not match requested job name"
  fi

  if ! verify_job_url_identity "$JENKINS_URL" "$actual_job_url" "$EXPECTED_JOB_NAME" 2>/dev/null; then
    identity_mismatch_exit "Created Jenkins job URL does not point to the requested job name"
  fi

  JOB_IDENTITY_VERIFIED=true
}

inspect_job_config() {
  local config_file="$1"
  local rendered_config="${2:-}"
  local out_file="$3"
  python3 - "$config_file" "$rendered_config" "$REPOSITORY_URL" "$BRANCH" >"$out_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

config_file, rendered_config, expected_repo, expected_branch = sys.argv[1:]
required = {"BRANCH", "VERSION"}
optional = {"DISTRIBUTION_TYPE"}

def csv(values):
    return ",".join(sorted(values))

def lname(elem):
    return elem.tag.rsplit("}", 1)[-1]

def path_join(parent, elem):
    return f"{parent}/{lname(elem)}"

def iter_with_path(elem, path=""):
    current = path_join(path, elem)
    yield elem, current
    for child in list(elem):
        yield from iter_with_path(child, current)

def looks_like_repo_url(value):
    return bool(
        value
        and (
            value.startswith(("ssh://", "git@", "http://", "https://"))
            or ".git" in value
            or "bitbucket" in value.lower()
        )
    )

def properties_content_value(value, key):
    for line in (value or "").splitlines():
        current_key, sep, current_value = line.partition("=")
        if sep and current_key.strip() == key:
            return current_value.strip()
    return ""

def application_repository_fields(root):
    fields = []
    seen = set()

    def add(path, value):
        value = (value or "").strip()
        if not value:
            return
        item = (path, value)
        if item not in seen:
            fields.append(item)
            seen.add(item)

    for elem, path in iter_with_path(root):
        name = lname(elem)
        if name == "propertiesContent":
            repo_url = properties_content_value(elem.text or "", "REPO_URL")
            if repo_url:
                add(f"{path}/REPO_URL", repo_url)

    for container, container_path in iter_with_path(root):
        if lname(container) != "parameterDefinitions":
            continue
        for param in list(container):
            param_path = path_join(container_path, param)
            param_name = ""
            for child in list(param):
                if lname(child) == "name" and child.text:
                    param_name = child.text.strip()
                    break
            if param_name != "BRANCH":
                continue
            for child in list(param):
                if lname(child) == "remoteURL":
                    add(path_join(param_path, child), child.text or "")
    return fields

def pipeline_definition(root):
    for elem in root.iter():
        if lname(elem) == "definition":
            return elem
    return None

def first_repo_url(root):
    if root is None:
        return ""
    for elem in root.iter():
        if lname(elem).lower() in {"url", "remote", "remoteurl", "repositoryurl", "repository"}:
            value = (elem.text or "").strip()
            if looks_like_repo_url(value):
                return value
    return ""

def first_script_path(root):
    if root is None:
        return ""
    for elem in root.iter():
        if lname(elem) == "scriptPath":
            return (elem.text or "").strip()
    return ""

def first_branch_spec(root):
    if root is None:
        return ""
    for elem in root.iter():
        if not lname(elem).endswith("BranchSpec"):
            continue
        for child in list(elem):
            if lname(child) == "name":
                return (child.text or "").strip()
    return ""

def params(root):
    values = {}
    for container in root.iter():
        if lname(container) != "parameterDefinitions":
            continue
        for param in list(container):
            name = ""
            default = ""
            for child in list(param):
                if lname(child) == "name" and child.text:
                    name = child.text.strip()
                elif lname(child) == "defaultValue" and child.text:
                    default = child.text.strip()
            if name:
                values[name] = default
    return values

try:
    root = ET.parse(config_file).getroot()
except Exception as exc:
    print(f"VERIFY_REASON=Created job config.xml could not be parsed: {exc}")
    sys.exit(1)

repo_fields = application_repository_fields(root)
actual_repo = repo_fields[0][1] if repo_fields else ""
env_repo = next((value for path, value in repo_fields if path.endswith("/REPO_URL")), "")
branch_remote_repo = next((value for path, value in repo_fields if path.endswith("/remoteURL")), "")
pipeline_root = pipeline_definition(root)
pipeline_repo = first_repo_url(pipeline_root)
actual_script = first_script_path(pipeline_root)
pipeline_branch_spec = first_branch_spec(pipeline_root)
parameter_values = params(root)
missing = sorted(required - set(parameter_values))
repo_mismatches = sorted(path for path, value in repo_fields if expected_repo and value != expected_repo)

print(f"ACTUAL_REPOSITORY_URL={actual_repo}")
print(f"APPLICATION_REPOSITORY_URL={expected_repo}")
print(f"ENV_REPO_URL={env_repo}")
print(f"BRANCH_PARAMETER_REPOSITORY_URL={branch_remote_repo}")
print(f"PIPELINE_REPOSITORY_URL={pipeline_repo}")
print(f"PIPELINE_BRANCH_SPEC={pipeline_branch_spec}")
print(f"PIPELINE_SCRIPT_PATH={actual_script}")
print(f"REPOSITORY_MISMATCH_PATHS={','.join(repo_mismatches)}")
print(f"SCRIPT_PATH={actual_script}")
print(f"PIPELINE_SCM_BRANCH_SPEC={pipeline_branch_spec}")
print(f"REQUIRED_PARAMETERS_OK={'false' if missing else 'true'}")
print(f"REQUIRED_PARAMETERS={csv(required)}")
print(f"SUPPORTED_PARAMETERS={csv(parameter_values)}")
print(f"OPTIONAL_PARAMETERS={csv(optional)}")
print(f"MISSING_REQUIRED_PARAMETERS={','.join(missing)}")
print(f"DISTRIBUTION_TYPE_PARAMETER_SUPPORTED={'true' if 'DISTRIBUTION_TYPE' in parameter_values else 'false'}")
print(f"MISSING_PARAMETERS={','.join(missing)}")
print(f"BRANCH_DEFAULT={parameter_values.get('BRANCH', '')}")

if repo_mismatches:
    print("VERIFY_STATE=jenkins_created_job_repository_mismatch")
    print("VERIFY_REASON=Created Jenkins job repository URL does not match current project repository")
    sys.exit(1)

if missing:
    print("VERIFY_STATE=jenkins_created_job_parameter_mismatch")
    print("VERIFY_REASON=Created Jenkins job is missing required build parameters")
    sys.exit(1)

if rendered_config:
    try:
        rendered_root = ET.parse(rendered_config).getroot()
    except Exception as exc:
        print("VERIFY_STATE=jenkins_created_job_config_mismatch")
        print(f"VERIFY_REASON=Rendered job config.xml could not be parsed: {exc}")
        sys.exit(1)
    rendered_pipeline_root = pipeline_definition(rendered_root)
    rendered_pipeline_repo = first_repo_url(rendered_pipeline_root)
    if rendered_pipeline_repo != pipeline_repo:
        print("VERIFY_STATE=jenkins_pipeline_scm_mismatch")
        print("VERIFY_REASON=Created Jenkins job pipeline SCM differs from rendered template")
        print(f"EXPECTED_PIPELINE_REPOSITORY_URL={rendered_pipeline_repo}")
        print(f"ACTUAL_PIPELINE_REPOSITORY_URL={pipeline_repo}")
        sys.exit(1)
    rendered_script = first_script_path(rendered_pipeline_root)
    if rendered_script != actual_script:
        print("VERIFY_STATE=jenkins_created_job_script_path_mismatch")
        print("VERIFY_REASON=Created Jenkins job scriptPath differs from rendered config")
        print(f"EXPECTED_SCRIPT_PATH={rendered_script}")
        print(f"ACTUAL_SCRIPT_PATH={actual_script}")
        sys.exit(1)
    rendered_branch_spec = first_branch_spec(rendered_pipeline_root)
    if rendered_branch_spec != pipeline_branch_spec:
        print("WARNING=Pipeline SCM BranchSpec differs from rendered template")
elif expected_repo and pipeline_repo == expected_repo:
    print("VERIFY_STATE=jenkins_pipeline_scm_mismatch")
    print("VERIFY_REASON=Jenkins job pipeline SCM points to the application repository")
    print("EXPECTED_PIPELINE_REPOSITORY_URL=")
    print(f"ACTUAL_PIPELINE_REPOSITORY_URL={pipeline_repo}")
    sys.exit(1)

sys.exit(0)
PY
}

verify_config_scan() {
  local config_file="$1"
  local scan_output="$2"
  bash "$SCRIPT_DIR/jenkins-render-job-config.sh" \
    --scan-config "$config_file" \
    --template-project-name "$TEMPLATE_PROJECT_SLUG" \
    --template-repository-url "$TEMPLATE_REPOSITORY_URL" \
    --project-name "$PROJECT_NAME" \
    --repository-url "$REPOSITORY_URL" >"$scan_output"
}

compare_rendered_to_created_config() {
  local compare_output="$1"
  bash "$SCRIPT_DIR/jenkins-render-job-config.sh" \
    --compare-config "$RENDERED_CONFIG_FILE" \
    --created-config "$READBACK_CONFIG_FILE" >"$compare_output"
}

apply_parameter_metadata() {
  local verify_output="$1"
  REQUIRED_PARAMETERS="$(sed -n 's/^REQUIRED_PARAMETERS=//p' "$verify_output" | tail -n 1)"
  SUPPORTED_PARAMETERS="$(sed -n 's/^SUPPORTED_PARAMETERS=//p' "$verify_output" | tail -n 1)"
  OPTIONAL_PARAMETERS="$(sed -n 's/^OPTIONAL_PARAMETERS=//p' "$verify_output" | tail -n 1)"
  MISSING_REQUIRED_PARAMETERS="$(sed -n 's/^MISSING_REQUIRED_PARAMETERS=//p' "$verify_output" | tail -n 1)"
  DISTRIBUTION_TYPE_PARAMETER_SUPPORTED="$(sed -n 's/^DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=//p' "$verify_output" | tail -n 1)"
  [[ -n "$REQUIRED_PARAMETERS" ]] || REQUIRED_PARAMETERS="BRANCH,VERSION"
  [[ -n "$OPTIONAL_PARAMETERS" ]] || OPTIONAL_PARAMETERS="DISTRIBUTION_TYPE"
  [[ -n "$DISTRIBUTION_TYPE_PARAMETER_SUPPORTED" ]] || DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=false
}

apply_config_verification_metadata() {
  local verify_output="$1"
  ACTUAL_REPOSITORY_URL="$(sed -n 's/^ACTUAL_REPOSITORY_URL=//p' "$verify_output" | tail -n 1)"
  APPLICATION_REPOSITORY_URL="$(sed -n 's/^APPLICATION_REPOSITORY_URL=//p' "$verify_output" | tail -n 1)"
  ENV_REPO_URL="$(sed -n 's/^ENV_REPO_URL=//p' "$verify_output" | tail -n 1)"
  BRANCH_PARAMETER_REPOSITORY_URL="$(sed -n 's/^BRANCH_PARAMETER_REPOSITORY_URL=//p' "$verify_output" | tail -n 1)"
  PIPELINE_REPOSITORY_URL="$(sed -n 's/^PIPELINE_REPOSITORY_URL=//p' "$verify_output" | tail -n 1)"
  EXPECTED_PIPELINE_REPOSITORY_URL="$(sed -n 's/^EXPECTED_PIPELINE_REPOSITORY_URL=//p' "$verify_output" | tail -n 1)"
  ACTUAL_PIPELINE_REPOSITORY_URL="$(sed -n 's/^ACTUAL_PIPELINE_REPOSITORY_URL=//p' "$verify_output" | tail -n 1)"
  PIPELINE_BRANCH_SPEC="$(sed -n 's/^PIPELINE_BRANCH_SPEC=//p' "$verify_output" | tail -n 1)"
  PIPELINE_SCRIPT_PATH="$(sed -n 's/^PIPELINE_SCRIPT_PATH=//p' "$verify_output" | tail -n 1)"
  REPOSITORY_MISMATCH_PATHS="$(sed -n 's/^REPOSITORY_MISMATCH_PATHS=//p' "$verify_output" | tail -n 1)"
  SCRIPT_PATH="$(sed -n 's/^SCRIPT_PATH=//p' "$verify_output" | tail -n 1)"
  PIPELINE_SCM_BRANCH_SPEC="$(sed -n 's/^PIPELINE_SCM_BRANCH_SPEC=//p' "$verify_output" | tail -n 1)"
  REQUIRED_PARAMETERS_OK="$(sed -n 's/^REQUIRED_PARAMETERS_OK=//p' "$verify_output" | tail -n 1)"
  WARNING="$(sed -n 's/^WARNING=//p' "$verify_output" | tail -n 1)"
  apply_parameter_metadata "$verify_output"
}

verify_created_job_config() {
  local verify_output="$1"
  local scan_output="$2"
  local compare_output="$3"

  if ! inspect_job_config "$READBACK_CONFIG_FILE" "$RENDERED_CONFIG_FILE" "$verify_output"; then
    apply_config_verification_metadata "$verify_output"
    local state reason
    state="$(sed -n 's/^VERIFY_STATE=//p' "$verify_output" | tail -n 1)"
    reason="$(sed -n 's/^VERIFY_REASON=//p' "$verify_output" | tail -n 1)"
    case "$state" in
      jenkins_created_job_repository_mismatch) repository_mismatch_exit "$reason" ;;
      jenkins_created_job_parameter_mismatch) parameter_mismatch_exit "$reason" ;;
      jenkins_pipeline_scm_mismatch) pipeline_scm_mismatch_exit "$reason" ;;
      jenkins_created_job_script_path_mismatch) script_path_mismatch_exit "$reason" ;;
      *) config_mismatch_exit "${reason:-Created Jenkins job config verification failed}" ;;
    esac
  fi
  apply_config_verification_metadata "$verify_output"

  if ! verify_config_scan "$READBACK_CONFIG_FILE" "$scan_output"; then
    TEMPLATE_REFERENCE_PATHS="$(sed -n 's/^TEMPLATE_REFERENCE_PATHS=//p' "$scan_output" | tail -n 1)"
    config_mismatch_exit "Template contains project-specific references outside approved fields"
  fi

  if ! compare_rendered_to_created_config "$compare_output"; then
    CONFIG_DIFF_PATHS="$(sed -n 's/^CONFIG_DIFF_PATHS=//p' "$compare_output" | tail -n 1)"
    config_mismatch_exit "Created Jenkins job config differs from rendered config"
  fi

  JOB_CONFIGURATION_VERIFIED=true
}

verify_existing_job_before_build() {
  if [[ "$JOB_CONFIGURATION_VERIFIED" == "true" ]]; then
    return 0
  fi

  EXPECTED_JOB_NAME="$JOB_NAME"
  EXPECTED_JOB_URL="$(job_url_for "$EXPECTED_JOB_NAME")"

  local status verify_output
  curl_get_jenkins_api_follow_redirect "${JOB_URL}/api/json" false
  status="$CURL_GET_STATUS"
  case "$status" in
    200)
      verify_job_identity_from_api
      ;;
    401|403)
      error_exit "Jenkins access denied while verifying job ${JOB_NAME}: HTTP ${status}" "valid Jenkins credentials"
      ;;
    561|562)
      jenkins_redirect_failed_exit "Jenkins job identity redirect failed"
      ;;
    563)
      identity_mismatch_exit "Jenkins job API response is empty"
      ;;
    *)
      identity_mismatch_exit "Jenkins job identity could not be verified: HTTP ${status}"
      ;;
  esac

  if [[ -z "$REPOSITORY_URL" ]]; then
    REPOSITORY_URL="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
  fi
  EXPECTED_REPOSITORY_URL="$REPOSITORY_URL"

  download_jenkins_config_xml "$READBACK_CONFIG_FILE" "${JOB_URL}/config.xml"

  verify_output="${TMP_DIR}/verify-existing-job.out"
  if ! inspect_job_config "$READBACK_CONFIG_FILE" "" "$verify_output"; then
    apply_config_verification_metadata "$verify_output"
    local state reason
    state="$(sed -n 's/^VERIFY_STATE=//p' "$verify_output" | tail -n 1)"
    reason="$(sed -n 's/^VERIFY_REASON=//p' "$verify_output" | tail -n 1)"
    case "$state" in
      jenkins_created_job_repository_mismatch) repository_mismatch_exit "$reason" ;;
      jenkins_created_job_parameter_mismatch) parameter_mismatch_exit "$reason" ;;
      jenkins_pipeline_scm_mismatch) pipeline_scm_mismatch_exit "$reason" ;;
      *) config_mismatch_exit "${reason:-Existing Jenkins job config verification failed}" ;;
    esac
  fi
  apply_config_verification_metadata "$verify_output"
  JOB_EXISTS=true
  JOB_CREATED=false
  [[ -n "$JOB_MODE" ]] || JOB_MODE="existing"
  ACTION="existing-job-verified"
  JOB_CONFIGURATION_VERIFIED=true
}

emit_job_ready() {
  echo "STATUS=READY"
  echo "ACTION=jenkins-job-verified"
  echo "PROJECT_NAME=${PROJECT_NAME}"
  echo "JOB_NAME=${JOB_NAME}"
  echo "JOB_URL=${JOB_URL}"
  echo "REPOSITORY_URL=${REPOSITORY_URL:-}"
  echo "BRANCH=${BRANCH}"
  echo "SCRIPT_PATH=${SCRIPT_PATH:-}"
  echo "PIPELINE_SCM_BRANCH_SPEC=${PIPELINE_SCM_BRANCH_SPEC:-}"
  echo "REPOSITORY_MISMATCH_PATHS=${REPOSITORY_MISMATCH_PATHS:-}"
  echo "WARNING=${WARNING:-}"
  echo "REQUIRED_PARAMETERS_OK=${REQUIRED_PARAMETERS_OK:-false}"
  echo "REQUIRED_PARAMETERS=${REQUIRED_PARAMETERS:-}"
  echo "SUPPORTED_PARAMETERS=${SUPPORTED_PARAMETERS:-}"
  echo "OPTIONAL_PARAMETERS=${OPTIONAL_PARAMETERS:-}"
  echo "MISSING_REQUIRED_PARAMETERS=${MISSING_REQUIRED_PARAMETERS:-}"
  echo "DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=${DISTRIBUTION_TYPE_PARAMETER_SUPPORTED:-false}"
  echo "JOB_IDENTITY_VERIFIED=${JOB_IDENTITY_VERIFIED:-false}"
  echo "JOB_CONFIGURATION_VERIFIED=${JOB_CONFIGURATION_VERIFIED:-false}"
  echo "BUILD_TRIGGERED=false"
}

header_location() {
  local headers_file="$1"
  sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)[[:space:]]*$/\1/p' "$headers_file" | tail -n 1 | tr -d '\r'
}

absolute_url() {
  local base="$1"
  local location="$2"
  python3 - "$base" "$location" <<'PY'
import sys
import urllib.parse

print(urllib.parse.urljoin(sys.argv[1], sys.argv[2]))
PY
}

url_host() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
import urllib.parse

print(urllib.parse.urlparse(sys.argv[1]).hostname or "")
PY
}

approved_jenkins_redirect_url() {
  local url="$1"
  local host
  host="$(url_host "$url")"
  case "$host" in
    aipay.ci.jenkins.sberbank.ru|ci.jenkins.sberbank.ru)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_queue_url() {
  local base_url="$1"
  local location="$2"
  python3 - "$base_url" "$location" <<'PY'
import re
import sys
import urllib.parse

base_url, location = sys.argv[1:]
approved_hosts = {
    "aipay.ci.jenkins.sberbank.ru",
    "ci.jenkins.sberbank.ru",
}
url = urllib.parse.urljoin(base_url, location)
parsed = urllib.parse.urlparse(url)
path = urllib.parse.unquote(parsed.path)
if parsed.hostname not in approved_hosts:
    sys.exit(1)
if path.endswith("/build") or path.endswith("/buildWithParameters"):
    sys.exit(1)
if not re.fullmatch(r".*/queue/item/[0-9]+/?", path):
    sys.exit(1)
normalized_path = path.rstrip("/") + "/"
print(urllib.parse.urlunparse((parsed.scheme, parsed.netloc, normalized_path, "", "", "")))
PY
}

same_jenkins_url_path() {
  local expected_url="$1"
  local actual_url="$2"
  python3 - "$expected_url" "$actual_url" <<'PY'
import sys
import urllib.parse

expected_url, actual_url = sys.argv[1:]
approved_hosts = {
    "aipay.ci.jenkins.sberbank.ru",
    "ci.jenkins.sberbank.ru",
}
expected = urllib.parse.urlparse(expected_url)
actual = urllib.parse.urlparse(actual_url)
if expected.hostname not in approved_hosts or actual.hostname not in approved_hosts:
    sys.exit(1)
if urllib.parse.unquote(expected.path.rstrip("/")) != urllib.parse.unquote(actual.path.rstrip("/")):
    sys.exit(1)
PY
}

build_url_from_api_url() {
  local url="$1"
  case "$url" in
    */api/json) printf '%s' "${url%/api/json}" ;;
    *) printf '%s' "${url%/}" ;;
  esac
}

jenkins_root_url() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
import urllib.parse

parsed = urllib.parse.urlparse(sys.argv[1])
print(f"{parsed.scheme}://{parsed.netloc}")
PY
}

jenkins_status_unavailable_exit() {
  STATE="${1:-jenkins_build_status_unavailable}"
  NEXT_REQUIRED_INPUT="${2:-Jenkins build status access}"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Failed to read Jenkins build status"
  emit_common
  exit 1
}

jenkins_build_identity_mismatch_exit() {
  STATE="jenkins_build_identity_mismatch"
  NEXT_REQUIRED_INPUT="Jenkins build status access"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Jenkins returned status for a different build"
  emit_common
  exit 1
}

queue_location_missing_exit() {
  STATE="jenkins_queue_location_missing"
  NEXT_REQUIRED_INPUT="check Jenkins queue"
  BUILD_TRIGGERED="unknown"
  QUEUE_URL=""
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Jenkins accepted the build request but did not return a queue item URL"
  emit_common
  exit 1
}

queue_location_unknown_exit() {
  STATE="jenkins_queue_location_unknown"
  NEXT_REQUIRED_INPUT="check Jenkins queue for matching build"
  BUILD_TRIGGERED="unknown"
  QUEUE_URL=""
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Jenkins trigger response did not return a queue item URL"
  emit_common
  exit 1
}

invalid_queue_url_exit() {
  STATE="jenkins_invalid_queue_url"
  NEXT_REQUIRED_INPUT="valid Jenkins queue item URL"
  BUILD_TRIGGERED="unknown"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Jenkins returned an invalid queue item URL"
  emit_common
  exit 1
}

build_wait_timeout_exit() {
  STATE="build_wait_timeout"
  NEXT_REQUIRED_INPUT="${1:-more time or Jenkins build inspection}"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Timed out waiting for Jenkins build result"
  emit_common
  exit 1
}

verify_build_identity_chain() {
  local queue_build_number

  EXPECTED_BUILD_NUMBER="$(build_number_from_url "$BUILD_URL")"
  if [[ -z "$EXPECTED_BUILD_NUMBER" ]]; then
    jenkins_build_identity_mismatch_exit
  fi

  if [[ -n "$QUEUE_EXECUTABLE_URL" ]]; then
    queue_build_number="$(build_number_from_url "$QUEUE_EXECUTABLE_URL")"
    if [[ -z "$queue_build_number" || "$queue_build_number" != "$EXPECTED_BUILD_NUMBER" ]]; then
      jenkins_build_identity_mismatch_exit
    fi
  fi

  if [[ "$API_BUILD_NUMBER" != "$EXPECTED_BUILD_NUMBER" ]]; then
    jenkins_build_identity_mismatch_exit
  fi

  if ! same_jenkins_url_path "$BUILD_URL" "$API_BUILD_URL"; then
    jenkins_build_identity_mismatch_exit
  fi
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
    curl_get_jenkins_api_follow_redirect "${candidate_url}/api/json" false
    status="$CURL_GET_STATUS"

    case "$status" in
	    200)
	      JOB_NAME="$candidate"
	      JOB_URL="$candidate_url"
	      JOB_EXISTS=true
	      JOB_CREATED=false
	      JOB_MODE="existing"
	      ACTION="reused"
	      return 0
        ;;
      404)
        ;;
      401|403)
	      error_exit "Jenkins access denied while checking job ${candidate}: HTTP ${status}" "valid Jenkins credentials"
	      ;;
      561|562)
        STATE="jenkins_redirect_failed"
        error_exit "Jenkins redirect failed while checking job ${candidate}" "Jenkins job access"
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

  JOB_NAME="${JOB_NAME_ARG:-${PROJECT_NAME}-build}"
  REQUESTED_JOB_NAME="$JOB_NAME"
  CREATED_JOB_NAME="$JOB_NAME"
	  if [[ -n "$JOB_NAME_ARG" ]]; then
	    JOB_NAME_SOURCE="explicit"
	  else
	    JOB_NAME_SOURCE="generated"
	  fi
	  JOB_URL="${JOB_URL_ARG:-$(job_url_for "$JOB_NAME")}"
	  EXPECTED_JOB_NAME="$JOB_NAME"
	  JOB_EXISTS=false
	  JOB_MODE="create"

  if [[ "$DRY_RUN" == "true" ]]; then
    ACTION="dry-run"
    return 0
  fi

  [[ -n "$REPOSITORY_URL" ]] || resolve_repository_url
  EXPECTED_REPOSITORY_URL="$REPOSITORY_URL"

  local template_url create_status create_name_encoded render_output verify_output readback_status api_job_url
  template_url="$(job_url_for "$TEMPLATE_JOB")"
  curl_download "$TEMPLATE_CONFIG_FILE" \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    "${template_url}/config.xml"

  TEMPLATE_REPOSITORY_URL="$(xml_first_repository_url "$TEMPLATE_CONFIG_FILE" || true)"
  TEMPLATE_PROJECT_SLUG="$(repo_slug_from_url "$TEMPLATE_REPOSITORY_URL")"

  render_output="${TMP_DIR}/render-job-config.out"
  if ! bash "$SCRIPT_DIR/jenkins-render-job-config.sh" \
    --template-config "$TEMPLATE_CONFIG_FILE" \
    --project-name "$PROJECT_NAME" \
    --job-name "$JOB_NAME" \
    --repository-url "$REPOSITORY_URL" \
    --branch "$BRANCH" \
    --output "$RENDERED_CONFIG_FILE" >"$render_output"; then
    cat "$render_output"
    exit 1
  fi

  ensure_crumb

  create_name_encoded="$(urlencode "$JOB_NAME")"
  local curl_args=(
    --request POST \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    --header "Content-Type: application/xml" \
    --data-binary "@${RENDERED_CONFIG_FILE}"
  )
  if ((${#CRUMB_HEADER[@]} > 0)); then
    curl_args+=("${CRUMB_HEADER[@]}")
  fi
  curl_args+=("${JENKINS_URL}/createItem?name=${create_name_encoded}")
  create_status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" "${curl_args[@]}")"

	  case "$create_status" in
	    200|201|302)
	      ACTION="created"
	      JOB_CREATED=true
	      JOB_EXISTS=true
	      MUTATIONS_PERFORMED=true
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

  curl_get_jenkins_api_follow_redirect "${JOB_URL}/api/json" false
  readback_status="$CURL_GET_STATUS"
  case "$readback_status" in
    200)
      verify_job_identity_from_api
      ;;
    401|403)
      error_exit "Jenkins access denied while verifying created job ${JOB_NAME}: HTTP ${readback_status}" "valid Jenkins credentials"
      ;;
    561|562)
      jenkins_redirect_failed_exit "Created Jenkins job read-back redirect failed"
      ;;
    563)
      created_job_mismatch_exit "Created Jenkins job API response is empty"
      ;;
    *)
      created_job_mismatch_exit "Created Jenkins job could not be read back: HTTP ${readback_status}"
      ;;
  esac

  download_jenkins_config_xml "$READBACK_CONFIG_FILE" "${JOB_URL}/config.xml"

  verify_output="${TMP_DIR}/verify-created-job.out"
  scan_output="${TMP_DIR}/scan-created-job.out"
  compare_output="${TMP_DIR}/compare-created-job.out"
  verify_created_job_config "$verify_output" "$scan_output" "$compare_output"
}

TRIGGER_FINAL_STATUS=""
TRIGGER_FINAL_LOCATION=""
TRIGGER_FINAL_URL=""
TRIGGER_AMBIGUOUS=false

jenkins_post_trigger_follow_redirect() {
  local current_url="$1"
  shift
  local redirect_count=0
  local status location next_url normalized_queue_url

  TRIGGER_FINAL_STATUS=""
  TRIGGER_FINAL_LOCATION=""
  TRIGGER_FINAL_URL="$current_url"
  TRIGGER_AMBIGUOUS=false

  while true; do
    status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" "$@" "$current_url")"
    HTTP_STATUS="$status"
    TRIGGER_FINAL_STATUS="$status"
    TRIGGER_FINAL_URL="$current_url"

    case "$status" in
      301|302|303|307|308)
        location="$(header_location "$HEADERS_FILE")"
        if [[ -z "$location" ]]; then
          TRIGGER_AMBIGUOUS=true
          return 0
        fi
        if normalized_queue_url="$(normalize_queue_url "$current_url" "$location" 2>/dev/null)"; then
          TRIGGER_FINAL_LOCATION="$normalized_queue_url"
          return 0
        fi
        next_url="$(absolute_url "$current_url" "$location")"
        if ! approved_jenkins_redirect_url "$next_url"; then
          TRIGGER_AMBIGUOUS=true
          return 0
        fi
        redirect_count=$((redirect_count + 1))
        if (( redirect_count > 5 )); then
          TRIGGER_AMBIGUOUS=true
          return 0
        fi
        current_url="$next_url"
        ;;
      201|202)
        location="$(header_location "$HEADERS_FILE")"
        if [[ -n "$location" ]] && normalized_queue_url="$(normalize_queue_url "$current_url" "$location" 2>/dev/null)"; then
          TRIGGER_FINAL_LOCATION="$normalized_queue_url"
        else
          TRIGGER_AMBIGUOUS=true
        fi
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  done
}

recover_existing_build() {
  [[ "$DRY_RUN" != "true" ]] || return 1
  [[ -n "$JOB_NAME" && -n "$JOB_URL" && -n "$BRANCH" && -n "$VERSION" ]] || return 1

  local root_url status recovery_output queue_url build_url
  root_url="$(jenkins_root_url "$JENKINS_URL")"

  curl_get_jenkins_api_follow_redirect "${root_url}/queue/api/json?tree=items[id,url,params,task[name,url],actions[parameters[name,value]],executable[url]]" false
  status="$CURL_GET_STATUS"
  case "$status" in
    200)
      if recovery_output="$(json_recovery_match queue "$BODY_FILE" "$root_url" 2>/dev/null)"; then
        queue_url="$(sed -n 's/^QUEUE_URL=//p' <<<"$recovery_output" | tail -n 1)"
        build_url="$(sed -n 's/^BUILD_URL=//p' <<<"$recovery_output" | tail -n 1)"
        QUEUE_URL="$queue_url"
        BUILD_URL="$build_url"
        BUILD_TRIGGERED=true
        ACTION="recovered"
        MUTATIONS_PERFORMED=false
        return 0
      fi
      ;;
    401|403)
      error_exit "Jenkins access denied while checking existing queue items: HTTP ${status}" "valid Jenkins credentials"
      ;;
    *)
      ;;
  esac

  curl_get_jenkins_api_follow_redirect "${JOB_URL}/api/json?tree=builds[number,url,result,building,timestamp,actions[parameters[name,value]]]" false
  status="$CURL_GET_STATUS"
  case "$status" in
    200)
      if recovery_output="$(json_recovery_match builds "$BODY_FILE" "$root_url" 2>/dev/null)"; then
        queue_url="$(sed -n 's/^QUEUE_URL=//p' <<<"$recovery_output" | tail -n 1)"
        build_url="$(sed -n 's/^BUILD_URL=//p' <<<"$recovery_output" | tail -n 1)"
        QUEUE_URL="$queue_url"
        BUILD_URL="$build_url"
        BUILD_TRIGGERED=true
        ACTION="recovered"
        MUTATIONS_PERFORMED=false
        return 0
      fi
      ;;
    401|403)
      error_exit "Jenkins access denied while checking existing builds: HTTP ${status}" "valid Jenkins credentials"
      ;;
    *)
      ;;
  esac

  return 1
}

trigger_build() {
  if [[ "$DRY_RUN" == "true" ]]; then
    QUEUE_URL=""
    return 0
  fi

  [[ "$JOB_CONFIGURATION_VERIFIED" == "true" ]] || error_exit "Jenkins job must be verified before triggering build" "verified Jenkins job"
  [[ "$JOB_IDENTITY_VERIFIED" == "true" ]] || error_exit "Jenkins job identity must be verified before triggering build" "verified Jenkins job identity"
  [[ "$REQUIRED_PARAMETERS_OK" == "true" ]] || error_exit "Jenkins job parameters must be verified before triggering build" "verified Jenkins job parameters"

  local status encoded_branch encoded_branch_param encoded_version_param encoded_distribution_type_param
  encoded_branch="$(urlencode "$BRANCH")"
  encoded_branch_param="$(urlencode "$JENKINS_BRANCH_PARAM")"
  encoded_version_param="$(urlencode "$JENKINS_VERSION_PARAM")"
  encoded_distribution_type_param="$(urlencode "$JENKINS_DISTRIBUTION_TYPE_PARAM")"

  ensure_crumb

  local curl_args=(
    --request POST \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}"
  )
  if ((${#CRUMB_HEADER[@]} > 0)); then
    curl_args+=("${CRUMB_HEADER[@]}")
  fi
  local build_url="${JOB_URL}/buildWithParameters?${encoded_branch_param}=${encoded_branch}"
  if [[ -n "$VERSION" ]]; then
    build_url+="&${encoded_version_param}=$(urlencode "$VERSION")"
  fi
  if [[ -n "$DISTRIBUTION_TYPE" && "$DISTRIBUTION_TYPE_PARAMETER_SUPPORTED" == "true" ]]; then
    build_url+="&${encoded_distribution_type_param}=$(urlencode "$DISTRIBUTION_TYPE")"
  fi
  TRIGGER_URL="$build_url"
  jenkins_post_trigger_follow_redirect "$build_url" "${curl_args[@]}"
  status="$TRIGGER_FINAL_STATUS"

  if [[ "$status" == "400" || "$status" == "404" || "$status" == "405" ]]; then
    if [[ -n "$VERSION" || -n "$DISTRIBUTION_TYPE" ]]; then
      error_exit "Parameterized Jenkins build failed: HTTP ${status}" "Jenkins parameter mapping"
    fi
    curl_args=(
      --request POST \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}"
    )
    if ((${#CRUMB_HEADER[@]} > 0)); then
      curl_args+=("${CRUMB_HEADER[@]}")
    fi
    TRIGGER_URL="${JOB_URL}/build"
    jenkins_post_trigger_follow_redirect "$TRIGGER_URL" "${curl_args[@]}"
    status="$TRIGGER_FINAL_STATUS"
  fi

  case "$status" in
    201|202|302)
      if [[ -n "$TRIGGER_FINAL_LOCATION" ]]; then
        QUEUE_URL="$TRIGGER_FINAL_LOCATION"
        BUILD_TRIGGERED=true
        MUTATIONS_PERFORMED=true
        ACTION="build"
        return 0
      fi
      MUTATIONS_PERFORMED=true
      if recover_existing_build; then
        MUTATIONS_PERFORMED=true
        return 0
      fi
      queue_location_unknown_exit
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
  bash "$SCRIPT_DIR/version-resolver.sh" --self-test
}

run_build_wait_self_tests() {
  local tmp bin mock_curl mock_sleep mock_date
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  mock_curl="$bin/curl"
  mock_sleep="$bin/sleep"
  mock_date="$bin/date"

  cat >"$mock_sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%s" ]]; then
  count_file="${JENKINS_BUILD_WAIT_TEST_DIR}/date-count"
  count=0
  [[ -f "$count_file" ]] && count="$(cat "$count_file")"
  count=$((count + 1))
  echo "$count" >"$count_file"
  if [[ "${JENKINS_BUILD_WAIT_SCENARIO}" == "timeout" ]]; then
    if (( count <= 3 )); then
      echo 0
    else
      echo 20
    fi
  else
    echo "$count"
  fi
else
  /bin/date "$@"
fi
EOF

  cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
output=""
headers=""
method="GET"
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --request) method="$2"; shift 2 ;;
    --user) shift 2 ;;
    --header) shift 2 ;;
    --data-binary) shift 2 ;;
    --silent|--show-error|--fail|--globoff) shift ;;
    *) url="$1"; shift ;;
  esac
done

: >"$headers"
mkdir -p "$(dirname "$output")"
printf '%s %s\n' "$method" "$url" >>"${JENKINS_BUILD_WAIT_TEST_DIR}/requests.log"

build_json() {
  local number="$1"
  local building="$2"
  local result="$3"
  local result_json timestamp_part api_url host
  if [[ "$result" == "null" ]]; then
    result_json="null"
  else
    result_json="\"$result\""
  fi
  timestamp_part=""
  if [[ -n "${4:-}" ]]; then
    timestamp_part=",\"timestamp\":$4"
  fi
  host="aipay.ci.jenkins.sberbank.ru"
  case "$url" in
    https://ci.jenkins.sberbank.ru/*) host="ci.jenkins.sberbank.ru" ;;
  esac
  api_url="https://${host}/job/aipay/job/SberAiPay_CI/job/test-project-build/${number}/"
  printf '{"number":%s,"url":"%s","building":%s,"result":%s%s,"artifacts":[]}\n' "$number" "$api_url" "$building" "$result_json" "$timestamp_part"
}

builds_json() {
  local number="$1"
  local building="$2"
  local result="$3"
  local dtype="$4"
  local timestamp="$5"
  local result_json timestamp_part
  if [[ "$result" == "null" ]]; then
    result_json="null"
  else
    result_json="\"$result\""
  fi
  timestamp_part=""
  if [[ -n "$timestamp" ]]; then
    timestamp_part=",\"timestamp\":$timestamp"
  fi
  printf '{"builds":[{"number":%s,"url":"https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/%s/","building":%s,"result":%s%s,"actions":[{"parameters":[{"name":"BRANCH","value":"develop"},{"name":"VERSION","value":"IFT-0.0.1"},{"name":"DISTRIBUTION_TYPE","value":"%s"}]}]}]}\n' "$number" "$number" "$building" "$result_json" "$timestamp_part" "$dtype"
}

if [[ "$url" == *"/crumbIssuer/api/json" ]]; then
  printf '{}\n' >"$output"
  printf '404'
  exit 0
fi

if [[ "$url" == *"/queue/api/json?tree="* ]]; then
  case "$JENKINS_BUILD_WAIT_SCENARIO" in
    recovery-queue)
      printf '{"items":[{"id":1,"url":"https://aipay.ci.jenkins.sberbank.ru/queue/item/1/","task":{"name":"test-project-build","url":"https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/"},"actions":[{"parameters":[{"name":"BRANCH","value":"develop"},{"name":"VERSION","value":"IFT-0.0.1"},{"name":"DISTRIBUTION_TYPE","value":"ift"}]}]}]}\n' >"$output"
      ;;
    recovery-after-ambiguous-trigger)
      if [[ -f "${JENKINS_BUILD_WAIT_TEST_DIR}/trigger-count" ]]; then
        printf '{"items":[{"id":1,"url":"https://aipay.ci.jenkins.sberbank.ru/queue/item/1/","task":{"name":"test-project-build","url":"https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/"},"actions":[{"parameters":[{"name":"BRANCH","value":"develop"},{"name":"VERSION","value":"IFT-0.0.1"},{"name":"DISTRIBUTION_TYPE","value":"ift"}]}]}]}\n' >"$output"
      else
        printf '{"items":[]}\n' >"$output"
      fi
      ;;
    *)
      printf '{"items":[]}\n' >"$output"
      ;;
  esac
  printf '200'
  exit 0
fi

if [[ "$url" == *"/job/aipay/job/SberAiPay_CI/job/test-project-build/api/json?tree=builds"* ]]; then
  case "$JENKINS_BUILD_WAIT_SCENARIO" in
    recovery-running)
      builds_json 44 true null ift "" >"$output"
      ;;
    recovery-recent-success)
      builds_json 44 false SUCCESS ift 0 >"$output"
      ;;
    recovery-old-success)
      builds_json 44 false SUCCESS ift -999999999 >"$output"
      ;;
    recovery-recent-failure)
      builds_json 44 false FAILURE ift 0 >"$output"
      ;;
    recovery-old-failure)
      builds_json 44 false FAILURE ift -999999999 >"$output"
      ;;
    recovery-aborted)
      builds_json 44 false ABORTED ift 0 >"$output"
      ;;
    recovery-dtype-mismatch)
      builds_json 44 true null release "" >"$output"
      ;;
    repeated-restart)
      if [[ -f "${JENKINS_BUILD_WAIT_TEST_DIR}/trigger-count" ]]; then
        builds_json 44 false SUCCESS ift 0 >"$output"
      else
        printf '{"builds":[]}\n' >"$output"
      fi
      ;;
    *)
      printf '{"builds":[]}\n' >"$output"
      ;;
  esac
  printf '200'
  exit 0
fi

if [[ "$url" == *"/job/aipay/job/SberAiPay_CI/job/test-project-build/api/json" ]]; then
  printf '{"name":"test-project-build","url":"https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/"}\n' >"$output"
  printf '200'
  exit 0
fi

if [[ "$url" == *"/job/aipay/job/SberAiPay_CI/job/test-project-build/config.xml" ]]; then
  cat >"$output" <<'XML'
<project>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://git@example.org/team/test-project.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop</defaultValue></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>VERSION</name><defaultValue>IFT-0.0.1</defaultValue></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>DISTRIBUTION_TYPE</name><defaultValue>ift</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
</project>
XML
  printf '200'
  exit 0
fi

if [[ "$method" == "POST" && "$url" == *"/buildWithParameters"* ]]; then
  count_file="${JENKINS_BUILD_WAIT_TEST_DIR}/trigger-count"
  count=0
  [[ -f "$count_file" ]] && count="$(cat "$count_file")"
  count=$((count + 1))
  echo "$count" >"$count_file"
  case "$JENKINS_BUILD_WAIT_SCENARIO" in
    alias-redirect-then-queue)
      if [[ "$count" == "1" ]]; then
        printf 'Location: https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/buildWithParameters?BRANCH=develop&VERSION=IFT-0.0.1&DISTRIBUTION_TYPE=ift\r\n' >"$headers"
        printf '{}\n' >"$output"
        printf '302'
        exit 0
      fi
      printf 'Location: https://aipay.ci.jenkins.sberbank.ru/queue/item/123/\r\n' >"$headers"
      printf '{}\n' >"$output"
      printf '201'
      exit 0
      ;;
    redirect-only-no-queue|recovery-after-ambiguous-trigger)
      if [[ "$count" == "1" ]]; then
        printf 'Location: https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/buildWithParameters?BRANCH=develop&VERSION=IFT-0.0.1&DISTRIBUTION_TYPE=ift\r\n' >"$headers"
        printf '{}\n' >"$output"
        printf '302'
        exit 0
      fi
      : >"$headers"
      printf '{}\n' >"$output"
      printf '201'
      exit 0
      ;;
    missing-location)
      : >"$headers"
      ;;
    invalid-queue-url)
      printf 'Location: %s\r\n' "$url" >"$headers"
      ;;
    *)
      printf 'Location: https://aipay.ci.jenkins.sberbank.ru/queue/item/1/\r\n' >"$headers"
      ;;
  esac
  printf '{}\n' >"$output"
  printf '201'
  exit 0
fi

if [[ "$url" == *"/queue/item/1/api/json" ]]; then
  if [[ "$JENKINS_BUILD_WAIT_SCENARIO" == "queue-executable-mismatch" ]]; then
    printf '{"executable":{"url":"https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/45/"}}\n' >"$output"
    printf '200'
    exit 0
  fi
  printf '{"executable":{"url":"https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/44/"}}\n' >"$output"
  printf '200'
  exit 0
fi

if [[ "$url" == *"/queue/item/123/api/json" ]]; then
  printf '{"executable":{"url":"https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/44/"}}\n' >"$output"
  printf '200'
  exit 0
fi

if [[ "$url" == *"/job/aipay/job/SberAiPay_CI/job/test-project-build/45/api/json" ]]; then
  case "$JENKINS_BUILD_WAIT_SCENARIO" in
    queue-executable-mismatch)
      build_json 44 false SUCCESS >"$output"
      printf '200'
      ;;
    *)
      printf '{}\n' >"$output"
      printf '500'
      ;;
  esac
  exit 0
fi

if [[ "$url" == *"/job/aipay/job/SberAiPay_CI/job/test-project-build/44/api/json" ]]; then
  count_file="${JENKINS_BUILD_WAIT_TEST_DIR}/build-count"
  count=0
  [[ -f "$count_file" ]] && count="$(cat "$count_file")"
  count=$((count + 1))
  echo "$count" >"$count_file"
  case "$JENKINS_BUILD_WAIT_SCENARIO" in
    redirect-success)
      if [[ "$count" == "1" ]]; then
        printf 'Location: https://ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/44/api/json\r\n' >"$headers"
        printf '{}\n' >"$output"
        printf '302'
      elif [[ "$count" == "2" ]]; then
        build_json 44 true null >"$output"
        printf '200'
      else
        build_json 44 false SUCCESS >"$output"
        printf '200'
      fi
      ;;
    redirect-failure)
      if [[ "$count" == "1" ]]; then
        printf 'Location: https://ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-project-build/44/api/json\r\n' >"$headers"
        printf '{}\n' >"$output"
        printf '302'
      else
        build_json 44 false FAILURE >"$output"
        printf '200'
      fi
      ;;
    transient-404)
      if [[ "$count" -lt "3" ]]; then
        printf '{}\n' >"$output"
        printf '404'
      else
        build_json 44 false SUCCESS >"$output"
        printf '200'
      fi
      ;;
    timeout)
      build_json 44 true null >"$output"
      printf '200'
      ;;
    redirect-rejected)
      printf 'Location: https://not-jenkins.example.org/job/test/44/api/json\r\n' >"$headers"
      printf '{}\n' >"$output"
      printf '302'
      ;;
    recovery-queue|recovery-running)
      if [[ "$count" == "1" ]]; then
        build_json 44 true null >"$output"
        printf '200'
      else
        build_json 44 false SUCCESS >"$output"
        printf '200'
      fi
      ;;
    confirmed-success|alias-redirect-then-queue|recovery-after-ambiguous-trigger|recovery-recent-success|recovery-old-success|recovery-not-found|recovery-aborted|recovery-dtype-mismatch|repeated-restart)
      build_json 44 false SUCCESS >"$output"
      printf '200'
      ;;
    recovery-recent-failure|recovery-old-failure)
      build_json 44 false FAILURE >"$output"
      printf '200'
      ;;
    stale-previous-success)
      build_json 45 false SUCCESS >"$output"
      printf '200'
      ;;
    inconsistent-success)
      if [[ "$count" == "1" ]]; then
        build_json 44 true SUCCESS >"$output"
      else
        build_json 44 false SUCCESS >"$output"
      fi
      printf '200'
      ;;
    stale-body-curl-failure)
      if [[ "$count" == "1" ]]; then
        build_json 44 false SUCCESS >"$output"
        printf '302'
      else
        printf '{}\n' >"$output"
        printf '500'
      fi
      ;;
  esac
  exit 0
fi

printf '{}\n' >"$output"
printf '500'
EOF

  chmod +x "$mock_curl" "$mock_sleep" "$mock_date"

  run_case() {
    local scenario="$1"
    local expected_status="$2"
    local expected_pattern="$3"
    local timeout_seconds="${4:-100}"
    local expected_trigger_count="${5:-1}"
    local expected_build_count="${6:-}"
    local case_dir output rc trigger_count build_count
    case_dir="$tmp/$scenario"
    mkdir -p "$case_dir"
    set +e
    output="$(
      PATH="$bin:$PATH" \
      JENKINS_BUILD_WAIT_TEST_DIR="$case_dir" \
      JENKINS_BUILD_WAIT_SCENARIO="$scenario" \
      JENKINS_USER=dummy \
      JENKINS_TOKEN=dummy \
      bash "$0" \
        --jenkins-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI" \
        --project-name test-project \
        --branch develop \
        --job-name test-project-build \
        --skip-lookup \
        --repository-url ssh://git@example.org/team/test-project.git \
        --distribution-type ift \
        --version IFT-0.0.1 \
        --wait \
        --timeout-seconds "$timeout_seconds"
    )"
	    rc=$?
	    set -e
	    printf '%s\n' "$output" >"$case_dir/output"
	    if [[ "$expected_status" == "success" && $rc -ne 0 ]]; then
      printf '%s\n' "$output"
      echo "FAIL ${scenario} expected success"
      exit 1
    fi
    if [[ "$expected_status" == "failure" && $rc -eq 0 ]]; then
      printf '%s\n' "$output"
      echo "FAIL ${scenario} expected failure"
      exit 1
    fi
    grep -q "$expected_pattern" <<<"$output" || {
      printf '%s\n' "$output"
      echo "FAIL ${scenario} missing ${expected_pattern}"
      exit 1
    }
    grep -q "BUILD_TRIGGERED=true" <<<"$output" || {
      printf '%s\n' "$output"
      echo "FAIL ${scenario} missing BUILD_TRIGGERED=true"
      exit 1
    }
    trigger_count="$(cat "$case_dir/trigger-count" 2>/dev/null || echo 0)"
    [[ "$trigger_count" == "$expected_trigger_count" ]] || {
      printf '%s\n' "$output"
      echo "FAIL ${scenario} trigger count ${trigger_count}"
      exit 1
    }
    if [[ -n "$expected_build_count" ]]; then
      build_count="$(cat "$case_dir/build-count" 2>/dev/null || echo 0)"
      [[ "$build_count" == "$expected_build_count" ]] || {
        printf '%s\n' "$output"
        echo "FAIL ${scenario} build poll count ${build_count}"
        exit 1
      }
    fi
  }

  run_trigger_error_case() {
    local scenario="$1"
    local expected_pattern="$2"
    local expect_empty_queue="${3:-false}"
    local expected_trigger_count="${4:-1}"
    local case_dir output rc trigger_count build_count
    case_dir="$tmp/$scenario"
    mkdir -p "$case_dir"
    set +e
    output="$(
      PATH="$bin:$PATH" \
      JENKINS_BUILD_WAIT_TEST_DIR="$case_dir" \
      JENKINS_BUILD_WAIT_SCENARIO="$scenario" \
      JENKINS_USER=dummy \
      JENKINS_TOKEN=dummy \
      bash "$0" \
        --jenkins-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI" \
        --project-name test-project \
        --branch develop \
        --job-name test-project-build \
        --skip-lookup \
        --repository-url ssh://git@example.org/team/test-project.git \
        --distribution-type ift \
        --version IFT-0.0.1 \
        --wait \
        --timeout-seconds 100
    )"
    rc=$?
    set -e
    printf '%s\n' "$output" >"$case_dir/output"
    [[ $rc -ne 0 ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} expected failure"; exit 1; }
    grep -q "$expected_pattern" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${scenario} missing ${expected_pattern}"; exit 1; }
    grep -q "BUILD_TRIGGERED=unknown" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${scenario} trigger state"; exit 1; }
    if [[ "$expect_empty_queue" == "true" ]]; then
      grep -q "^QUEUE_URL=$" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${scenario} queue URL not empty"; exit 1; }
    fi
    trigger_count="$(cat "$case_dir/trigger-count" 2>/dev/null || echo 0)"
    [[ "$trigger_count" == "$expected_trigger_count" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} trigger count ${trigger_count}"; exit 1; }
    if [[ "$expected_pattern" == *"jenkins_queue_location_unknown"* ]]; then
      grep -q "MUTATIONS_PERFORMED=true" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${scenario} mutation not reported"; exit 1; }
    fi
    build_count="$(cat "$case_dir/build-count" 2>/dev/null || echo 0)"
    [[ "$build_count" == "0" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} build polling count ${build_count}"; exit 1; }
    ! grep -q '^GET .*buildWithParameters' "$case_dir/requests.log" || { cat "$case_dir/requests.log"; echo "FAIL ${scenario} polled buildWithParameters"; exit 1; }
    ! grep -q '^GET .*/build$' "$case_dir/requests.log" || { cat "$case_dir/requests.log"; echo "FAIL ${scenario} polled build"; exit 1; }
  }

  run_restart_case() {
    local case_dir output1 output2 rc trigger_count
    case_dir="$tmp/repeated-restart"
    mkdir -p "$case_dir"
    set +e
    output1="$(
      PATH="$bin:$PATH" \
      JENKINS_BUILD_WAIT_TEST_DIR="$case_dir" \
      JENKINS_BUILD_WAIT_SCENARIO="repeated-restart" \
      JENKINS_USER=dummy \
      JENKINS_TOKEN=dummy \
      bash "$0" \
        --jenkins-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI" \
        --project-name test-project \
        --branch develop \
        --job-name test-project-build \
        --skip-lookup \
        --repository-url ssh://git@example.org/team/test-project.git \
        --distribution-type ift \
        --version IFT-0.0.1 \
        --wait \
        --timeout-seconds 100
    )"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || { printf '%s\n' "$output1"; echo "FAIL repeated-restart first run"; exit 1; }

    set +e
    output2="$(
      PATH="$bin:$PATH" \
      JENKINS_BUILD_WAIT_TEST_DIR="$case_dir" \
      JENKINS_BUILD_WAIT_SCENARIO="repeated-restart" \
      JENKINS_USER=dummy \
      JENKINS_TOKEN=dummy \
      bash "$0" \
        --jenkins-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI" \
        --project-name test-project \
        --branch develop \
        --job-name test-project-build \
        --skip-lookup \
        --repository-url ssh://git@example.org/team/test-project.git \
        --distribution-type ift \
        --version IFT-0.0.1 \
        --wait \
        --timeout-seconds 100
    )"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || { printf '%s\n' "$output2"; echo "FAIL repeated-restart second run"; exit 1; }
    grep -q "ACTION=recovered" <<<"$output2" || { printf '%s\n' "$output2"; echo "FAIL repeated-restart not recovered"; exit 1; }
    trigger_count="$(cat "$case_dir/trigger-count" 2>/dev/null || echo 0)"
    [[ "$trigger_count" == "1" ]] || {
      printf '%s\n%s\n' "$output1" "$output2"
      echo "FAIL repeated-restart trigger count ${trigger_count}"
      exit 1
    }
  }

  run_case redirect-success success "RESULT=SUCCESS"
  grep -q "QUEUE_URL=https://aipay.ci.jenkins.sberbank.ru/queue/item/1/" "$tmp/redirect-success/output" || { cat "$tmp/redirect-success/output"; echo "FAIL valid trigger queue URL"; exit 1; }
  ! grep -q "https://ci.jenkins.sberbank.ru" "$tmp/redirect-success/output" || { cat "$tmp/redirect-success/output"; echo "FAIL redirected Jenkins host emitted"; exit 1; }
  ! grep -q '^GET .*buildWithParameters' "$tmp/redirect-success/requests.log" || { cat "$tmp/redirect-success/requests.log"; echo "FAIL buildWithParameters was polled"; exit 1; }
  ! grep -q '^GET .*/build$' "$tmp/redirect-success/requests.log" || { cat "$tmp/redirect-success/requests.log"; echo "FAIL build endpoint was polled"; exit 1; }
  run_case alias-redirect-then-queue success "RESULT=SUCCESS" 100 2
  grep -q "QUEUE_URL=https://aipay.ci.jenkins.sberbank.ru/queue/item/123/" "$tmp/alias-redirect-then-queue/output" || { cat "$tmp/alias-redirect-then-queue/output"; echo "FAIL alias redirect queue URL"; exit 1; }
  run_trigger_error_case missing-location "STATE=jenkins_queue_location_unknown" true
  run_trigger_error_case invalid-queue-url "STATE=jenkins_queue_location_unknown"
  run_trigger_error_case redirect-only-no-queue "STATE=jenkins_queue_location_unknown" true 2
  run_case confirmed-success success "STATUS_VERIFIED=true"
  run_case redirect-failure success "RESULT=FAILURE"
  run_case transient-404 success "RESULT=SUCCESS"
  run_case timeout failure "STATE=build_wait_timeout" 1
  run_case redirect-rejected failure "STATE=jenkins_redirect_rejected"
  run_case stale-previous-success failure "STATE=jenkins_build_identity_mismatch" 100 1
  run_case queue-executable-mismatch failure "STATE=jenkins_build_identity_mismatch" 100 1
  run_case inconsistent-success success "STATUS_VERIFIED=true" 100 1 2
  run_case stale-body-curl-failure failure "STATE=jenkins_build_status_unavailable" 100 1
  run_case recovery-queue success "ACTION=recovered" 100 0
  run_case recovery-after-ambiguous-trigger success "ACTION=recovered" 100 2
  run_case recovery-running success "ACTION=recovered" 100 0
  run_case recovery-recent-success success "ACTION=recovered" 100 0
  run_case recovery-old-success success "RESULT=SUCCESS" 100 1
  run_case recovery-recent-failure success "ACTION=recovered" 100 0
  run_case recovery-old-failure success "RESULT=FAILURE" 100 1
  run_case recovery-aborted success "RESULT=SUCCESS" 100 1
  run_case recovery-dtype-mismatch success "RESULT=SUCCESS" 100 1
  run_case recovery-not-found success "RESULT=SUCCESS" 100 1
  run_restart_case
  rm -rf "$tmp"
  echo "JENKINS_BUILD_WAIT_SELF_TESTS=OK"
}

run_job_create_self_tests() {
  local tmp bin mock_curl mock_sleep
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  mock_curl="$bin/curl"
  mock_sleep="$bin/sleep"

  cat >"$mock_sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
output=""
headers=""
method="GET"
url=""
data_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --request) method="$2"; shift 2 ;;
    --user) shift 2 ;;
    --header) shift 2 ;;
    --data-binary) data_file="${2#@}"; shift 2 ;;
    --silent|--show-error|--fail|--globoff) shift ;;
    *) url="$1"; shift ;;
  esac
done

: >"$headers"
mkdir -p "$(dirname "$output")"
log="${JENKINS_JOB_CREATE_TEST_DIR}/calls.log"

	template_xml() {
  if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "incompatible-template" ]]; then
    cat <<'XML'
<project>
  <displayName>ai-payments-merchant-registry</displayName>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://git@example.org/team/ai-payments-merchant-registry.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop-corp</defaultValue></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>DISTRIBUTION_TYPE</name><defaultValue>ift</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
</project>
XML
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "missing-branch-template" ]]; then
    cat <<'XML'
<project>
  <displayName>ai-payments-merchant-registry</displayName>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://git@example.org/team/ai-payments-merchant-registry.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>VERSION</name><defaultValue>IFT-0.0.1</defaultValue></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>DISTRIBUTION_TYPE</name><defaultValue>ift</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
</project>
XML
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "no-distribution-type-template" ]]; then
    cat <<'XML'
<project>
  <displayName>ai-payments-merchant-registry</displayName>
  <description>Build ai-payments-merchant-registry</description>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><EnvInjectJobProperty><info><propertiesContent>REPO_URL=ssh://git@example.org/team/ai-payments-merchant-registry.git
SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-merchant-registry</propertiesContent></info></EnvInjectJobProperty><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop-corp</defaultValue><remoteURL>ssh://git@example.org/team/ai-payments-merchant-registry.git</remoteURL></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>VERSION</name><defaultValue>D-00.000.</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
  <definition><scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs><branches><hudson.plugins.git.BranchSpec><name>2.0</name></hudson.plugins.git.BranchSpec></branches></scm><scriptPath>pipeline/csdo/universal-sbrf-nexus-deploy.groovy</scriptPath></definition>
</project>
XML
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "properties-content-reference" ]]; then
    cat <<'XML'
<project>
  <displayName>ai-payments-merchant-registry</displayName>
  <description>Build ai-payments-merchant-registry</description>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><EnvInjectJobProperty><info><propertiesContent>REPO_URL=ssh://git@example.org/team/ai-payments-merchant-registry.git
SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-merchant-registry
CUSTOM_PROJECT=ai-payments-merchant-registry</propertiesContent></info></EnvInjectJobProperty><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop-corp</defaultValue><remoteURL>ssh://git@example.org/team/ai-payments-merchant-registry.git</remoteURL></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>VERSION</name><defaultValue>IFT-0.0.1</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
</project>
XML
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "hidden-shell-reference" ]]; then
    cat <<'XML'
<project>
  <displayName>ai-payments-merchant-registry</displayName>
  <description>Build ai-payments-merchant-registry</description>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><EnvInjectJobProperty><info><propertiesContent>REPO_URL=ssh://git@example.org/team/ai-payments-merchant-registry.git
SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-merchant-registry</propertiesContent></info></EnvInjectJobProperty><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop-corp</defaultValue><remoteURL>ssh://git@example.org/team/ai-payments-merchant-registry.git</remoteURL></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>VERSION</name><defaultValue>IFT-0.0.1</defaultValue></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>DISTRIBUTION_TYPE</name><defaultValue>ift</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
  <builders><hudson.tasks.Shell><command>build ai-payments-merchant-registry</command></hudson.tasks.Shell></builders>
</project>
XML
  else
    cat <<'XML'
<project>
  <displayName>ai-payments-merchant-registry</displayName>
  <description>Build ai-payments-merchant-registry</description>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><EnvInjectJobProperty><info><propertiesContent>REPO_URL=ssh://git@example.org/team/ai-payments-merchant-registry.git
SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-merchant-registry</propertiesContent></info></EnvInjectJobProperty><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop-corp</defaultValue><remoteURL>ssh://git@example.org/team/ai-payments-merchant-registry.git</remoteURL></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>VERSION</name><defaultValue>D-00.000.</defaultValue></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>DISTRIBUTION_TYPE</name><defaultValue>ift</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
  <definition><scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs><branches><hudson.plugins.git.BranchSpec><name>2.0</name></hudson.plugins.git.BranchSpec></branches></scm><scriptPath>pipeline/csdo/universal-sbrf-nexus-deploy.groovy</scriptPath></definition>
</project>
XML
  fi
	}

existing_job_xml() {
  cat <<'XML'
<project>
  <displayName>ai-payments-auth</displayName>
  <description>Build ai-payments-auth</description>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><EnvInjectJobProperty><info><propertiesContent>REPO_URL=ssh://git@example.org/team/ai-payments-auth.git
SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-auth</propertiesContent></info></EnvInjectJobProperty><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop-corp</defaultValue><remoteURL>ssh://git@example.org/team/ai-payments-auth.git</remoteURL></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>VERSION</name><defaultValue>D-00.000.</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
  <definition><scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs><branches><hudson.plugins.git.BranchSpec><name>2.0</name></hudson.plugins.git.BranchSpec></branches></scm><scriptPath>pipeline/csdo/universal-sbrf-nexus-deploy.groovy</scriptPath></definition>
</project>
XML
}

if [[ "$url" == *"/crumbIssuer/api/json" ]]; then
  printf 'crumb\n' >>"$log"
  printf '{}\n' >"$output"
  printf '404'
  exit 0
fi

if [[ "$url" == *"/job/template-job/config.xml" ]]; then
  printf 'fetch-template\n' >>"$log"
  template_xml >"$output"
  printf '200'
  exit 0
fi

if [[ "$method" == "POST" && "$url" == *"/createItem?name="* ]]; then
  printf 'createItem\n' >>"$log"
  count_file="${JENKINS_JOB_CREATE_TEST_DIR}/create-count"
  count=0
  [[ -f "$count_file" ]] && count="$(cat "$count_file")"
  echo "$((count + 1))" >"$count_file"
  cp "$data_file" "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml"
  printf '{}\n' >"$output"
  printf '201'
  exit 0
fi

if [[ "$url" == *"/queue/api/json"* || "$url" == *"/api/json?tree=builds"* ]]; then
  printf '{"items":[],"builds":[]}\n' >"$output"
  printf '200'
  exit 0
fi

if [[ "$method" == "POST" && "$url" == *"/buildWithParameters"* ]]; then
  printf 'buildWithParameters\n' >>"$log"
  printf '%s\n' "$url" >"${JENKINS_JOB_CREATE_TEST_DIR}/trigger-url"
  count_file="${JENKINS_JOB_CREATE_TEST_DIR}/build-count"
  count=0
  [[ -f "$count_file" ]] && count="$(cat "$count_file")"
  echo "$((count + 1))" >"$count_file"
  printf 'Location: https://aipay.ci.jenkins.sberbank.ru/queue/item/1/\r\n' >"$headers"
  printf '{}\n' >"$output"
  printf '201'
  exit 0
fi

if [[ "$url" == *"/api/json" ]]; then
  case "$url" in
    *"/job/template-job/api/json"*)
      printf '{}\n' >"$output"
      printf '404'
      exit 0
      ;;
    *)
		      if [[ ! -f "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" ]]; then
		        if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-job-redirect" && "$url" == https://aipay.ci.jenkins.sberbank.ru/* ]]; then
		          printf 'Location: https://ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/ai-payments-auth-build/api/json\r\n' >"$headers"
		          : >"$output"
		          printf '302'
		          exit 0
		        fi
		        if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "wrong-path-redirect" && "$url" == https://example.invalid/* ]]; then
		          printf 'Location: https://ci.jenkins.sberbank.ru/job/other/job/ai-payments-auth-build/api/json\r\n' >"$headers"
		          : >"$output"
		          printf '302'
		          exit 0
		        fi
		        if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-incompatible" || "$JENKINS_JOB_CREATE_SCENARIO" == "existing-compatible" || "$JENKINS_JOB_CREATE_SCENARIO" == "existing-empty-config" || "$JENKINS_JOB_CREATE_SCENARIO" == "existing-config-redirect" || "$JENKINS_JOB_CREATE_SCENARIO" == "existing-job-redirect" || "$JENKINS_JOB_CREATE_SCENARIO" == "wrong-path-redirect" ]]; then
		          printf 'readback-api\n' >>"$log"
		          if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-job-redirect" ]]; then
		            printf '{"name":"ai-payments-auth-build","url":"https://ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/ai-payments-auth-build/"}\n' >"$output"
		          elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "wrong-path-redirect" ]]; then
		            printf '{"name":"ai-payments-auth-build","url":"https://ci.jenkins.sberbank.ru/job/other/job/ai-payments-auth-build/"}\n' >"$output"
		          else
		            printf '{"name":"ai-payments-auth-build","url":"https://example.invalid/job/folder/job/ai-payments-auth-build/"}\n' >"$output"
		          fi
	          printf '200'
	          exit 0
	        fi
        printf '{}\n' >"$output"
        printf '404'
        exit 0
      fi
      printf 'readback-api\n' >>"$log"
      name="$(python3 - "$url" <<'PY'
import sys
from urllib.parse import unquote
parts = sys.argv[1].split("/job/")
print(unquote(parts[-1].split("/api/json", 1)[0]))
PY
)"
      if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-name-mismatch" ]]; then
        name="wrong-job"
      fi
      if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "canonical-host-alias" ]]; then
        printf '{"name":"%s","url":"https://ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/%s/"}\n' "$name" "$name" >"$output"
      elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "wrong-canonical-folder" ]]; then
        printf '{"name":"%s","url":"https://ci.jenkins.sberbank.ru/job/aipay/job/OtherFolder/job/%s/"}\n' "$name" "$name" >"$output"
      elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "wrong-created-job-url" ]]; then
        printf '{"name":"%s","url":"https://example.invalid/job/other-folder/job/%s/"}\n' "$name" "$name" >"$output"
      else
        printf '{"name":"%s","url":"https://example.invalid/job/folder/job/%s/"}\n' "$name" "$name" >"$output"
      fi
      printf '200'
      exit 0
      ;;
  esac
fi

	if [[ "$url" == *"/config.xml" ]]; then
	  printf 'readback-config\n' >>"$log"
		  if [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-compatible" || "$JENKINS_JOB_CREATE_SCENARIO" == "existing-job-redirect" ]]; then
		    existing_job_xml >"$output"
	  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-empty-config" ]]; then
	    : >"$output"
	  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-config-redirect" && "$url" == https://example.invalid/* ]]; then
	    printf 'Location: https://ci.jenkins.sberbank.ru/job/folder/job/ai-payments-auth-build/config.xml\r\n' >"$headers"
	    : >"$output"
	    printf '302'
	    exit 0
	  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-config-redirect" ]]; then
	    existing_job_xml >"$output"
	  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-repo-mismatch" ]]; then
    template_xml >"$output"
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-harmless-metadata" ]]; then
    python3 - "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" "$output" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("<project>", "<project><actions><hudson.model.CauseAction /></actions>", 1)
open(target, "w", encoding="utf-8").write(text)
PY
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-script-path-mismatch" ]]; then
    python3 - "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" "$output" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace(
    "<scriptPath>pipeline/csdo/universal-sbrf-nexus-deploy.groovy</scriptPath>",
    "<scriptPath>Jenkinsfile.other</scriptPath>",
)
open(target, "w", encoding="utf-8").write(text)
PY
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-missing-version" ]]; then
    python3 - "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" "$output" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
start = text.find("<hudson.model.StringParameterDefinition><name>VERSION</name>")
if start != -1:
    end = text.find("</hudson.model.StringParameterDefinition>", start)
    if end != -1:
        end += len("</hudson.model.StringParameterDefinition>")
        text = text[:start] + text[end:]
open(target, "w", encoding="utf-8").write(text)
PY
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-injected-reference" ]]; then
    python3 - "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" "$output" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("</project>", "<builders><hudson.tasks.Shell><command>build ai-payments-merchant-registry</command></hudson.tasks.Shell></builders></project>")
open(target, "w", encoding="utf-8").write(text)
PY
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-hidden-difference" ]]; then
    python3 - "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" "$output" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("</project>", "<publishers><custom.Plugin><value>custom hidden change</value></custom.Plugin></publishers></project>")
open(target, "w", encoding="utf-8").write(text)
PY
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "readback-pipeline-scm-mismatch" ]]; then
    python3 - "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" "$output" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace(
    "ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git",
    "ssh://git@example.org/team/ai-payments-auth.git",
)
open(target, "w", encoding="utf-8").write(text)
PY
  elif [[ "$JENKINS_JOB_CREATE_SCENARIO" == "existing-incompatible" ]]; then
    cat >"$output" <<'XML'
<project>
  <scm><userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>ssh://git@example.org/team/ai-payments-auth.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs></scm>
  <properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions>
    <hudson.model.StringParameterDefinition><name>BRANCH</name><defaultValue>develop-corp</defaultValue></hudson.model.StringParameterDefinition>
    <hudson.model.StringParameterDefinition><name>DISTRIBUTION_TYPE</name><defaultValue>ift</defaultValue></hudson.model.StringParameterDefinition>
  </parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties>
</project>
XML
  else
    cp "${JENKINS_JOB_CREATE_TEST_DIR}/created-config.xml" "$output"
  fi
  printf '200'
  exit 0
fi

printf '{}\n' >"$output"
printf '404'
EOF

  chmod +x "$mock_curl" "$mock_sleep"

  run_create_case() {
    local scenario="$1"
    local expected_status="$2"
    local expected_pattern="$3"
    shift 3
    local case_dir output rc create_count build_count
    case_dir="$tmp/$scenario"
    mkdir -p "$case_dir/project"
    set +e
    output="$(
      PATH="$bin:$PATH" \
      JENKINS_JOB_CREATE_TEST_DIR="$case_dir" \
      JENKINS_JOB_CREATE_SCENARIO="$scenario" \
      JENKINS_USER=dummy \
      JENKINS_TOKEN=dummy \
      bash "$0" \
        --jenkins-url "https://example.invalid/job/folder" \
        --project-name ai-payments-auth \
        --project-dir "$case_dir/project" \
	        --branch develop-corp \
	        --template-job template-job \
	        --create-if-missing \
	        --distribution-type ift \
        --version IFT-0.0.1 \
        "$@"
	    )"
	    rc=$?
	    set -e
	    printf '%s\n' "$output" >"$case_dir/output"
	    if [[ "$expected_status" == "success" && $rc -ne 0 ]]; then
      printf '%s\n' "$output"
      echo "FAIL ${scenario} expected success"
      exit 1
    fi
    if [[ "$expected_status" == "failure" && $rc -eq 0 ]]; then
      printf '%s\n' "$output"
      echo "FAIL ${scenario} expected failure"
      exit 1
    fi
    grep -q "$expected_pattern" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${scenario} missing ${expected_pattern}"; exit 1; }
    create_count="$(cat "$case_dir/create-count" 2>/dev/null || echo 0)"
    build_count="$(cat "$case_dir/build-count" 2>/dev/null || echo 0)"
    case "$scenario" in
      missing-repository-url|incompatible-template|missing-branch-template|hidden-shell-reference|properties-content-reference)
        [[ "$create_count" == "0" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} create before review"; exit 1; }
        [[ "$build_count" == "0" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} build before verification"; exit 1; }
        ;;
      readback-repo-mismatch|readback-script-path-mismatch|readback-missing-version|wrong-created-job-url|wrong-canonical-folder|readback-injected-reference|readback-hidden-difference|readback-pipeline-scm-mismatch)
        [[ "$create_count" == "1" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} create count ${create_count}"; exit 1; }
        [[ "$build_count" == "0" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} build before verification"; exit 1; }
        ;;
      *)
        [[ "$create_count" == "1" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} create count ${create_count}"; exit 1; }
        [[ "$build_count" == "1" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} build count ${build_count}"; exit 1; }
        ;;
    esac
  }

	  run_existing_case() {
	    local scenario="$1"
	    local expected_pattern="$2"
    local case_dir output rc create_count build_count
    case_dir="$tmp/$scenario"
    mkdir -p "$case_dir/project"
    set +e
    output="$(
      PATH="$bin:$PATH" \
      JENKINS_JOB_CREATE_TEST_DIR="$case_dir" \
      JENKINS_JOB_CREATE_SCENARIO="$scenario" \
      JENKINS_USER=dummy \
      JENKINS_TOKEN=dummy \
      bash "$0" \
        --jenkins-url "https://example.invalid/job/folder" \
        --project-name ai-payments-auth \
        --project-dir "$case_dir/project" \
	        --branch develop-corp \
	        --job-name ai-payments-auth-build \
	        --skip-lookup \
	        --existing-job \
	        --repository-url ssh://git@example.org/team/ai-payments-auth.git \
        --distribution-type ift \
        --version IFT-0.0.1
    )"
    rc=$?
    set -e
    printf '%s\n' "$output" >"$case_dir/output"
    [[ $rc -ne 0 ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} expected failure"; exit 1; }
    grep -q "$expected_pattern" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${scenario} missing ${expected_pattern}"; exit 1; }
    create_count="$(cat "$case_dir/create-count" 2>/dev/null || echo 0)"
    build_count="$(cat "$case_dir/build-count" 2>/dev/null || echo 0)"
    [[ "$create_count" == "0" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} unexpected create"; exit 1; }
	    [[ "$build_count" == "0" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} unexpected build"; exit 1; }
	  }

	  run_existing_success_case() {
	    local scenario="$1"
	    local expected_pattern="$2"
	    local case_dir output rc create_count build_count jenkins_url
	    case_dir="$tmp/$scenario"
	    jenkins_url="https://example.invalid/job/folder"
	    if [[ "$scenario" == "existing-job-redirect" ]]; then
	      jenkins_url="https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI"
	    fi
	    mkdir -p "$case_dir/project"
	    set +e
	    output="$(
	      PATH="$bin:$PATH" \
	      JENKINS_JOB_CREATE_TEST_DIR="$case_dir" \
	      JENKINS_JOB_CREATE_SCENARIO="$scenario" \
	      JENKINS_TEMPLATE_JOB=template-job \
	      JENKINS_USER=dummy \
	      JENKINS_TOKEN=dummy \
	      bash "$0" \
		        --jenkins-url "$jenkins_url" \
	        --project-name ai-payments-auth \
	        --project-dir "$case_dir/project" \
	        --branch develop-corp \
	        --job-name ai-payments-auth-build \
	        --skip-lookup \
	        --existing-job \
	        --repository-url ssh://git@example.org/team/ai-payments-auth.git \
	        --distribution-type ift \
	        --version IFT-0.0.1
	    )"
	    rc=$?
	    set -e
	    printf '%s\n' "$output" >"$case_dir/output"
	    [[ $rc -eq 0 ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} expected success"; exit 1; }
	    grep -q "$expected_pattern" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL ${scenario} missing ${expected_pattern}"; exit 1; }
	    create_count="$(cat "$case_dir/create-count" 2>/dev/null || echo 0)"
	    build_count="$(cat "$case_dir/build-count" 2>/dev/null || echo 0)"
	    [[ "$create_count" == "0" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} unexpected create"; exit 1; }
	    [[ "$build_count" == "1" ]] || { printf '%s\n' "$output"; echo "FAIL ${scenario} build count ${build_count}"; exit 1; }
	  }

	  run_create_case explicit-job-name success "CREATED_JOB_NAME=ai-payments-auth-build" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git
  ! grep -q "ai-payments-merchant-registry" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL template project remains after render"; exit 1; }
  grep -q "ssh://git@example.org/team/ai-payments-auth.git" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL rendered repository missing"; exit 1; }
  grep -q "REPO_URL=ssh://git@example.org/team/ai-payments-auth.git" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL EnvInject REPO_URL missing"; exit 1; }
  grep -q "SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-auth" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL SONAR_PROJECT_KEY missing"; exit 1; }
  grep -q "<remoteURL>ssh://git@example.org/team/ai-payments-auth.git</remoteURL>" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL BRANCH remoteURL missing"; exit 1; }
  grep -q "ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL pipeline repository changed"; exit 1; }
  grep -q "<name>2.0</name>" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL BranchSpec changed"; exit 1; }
  grep -q "<scriptPath>pipeline/csdo/universal-sbrf-nexus-deploy.groovy</scriptPath>" "$tmp/explicit-job-name/created-config.xml" || { echo "FAIL scriptPath changed"; exit 1; }
  grep -q "VERSION=IFT-0.0.1" "$tmp/explicit-job-name/trigger-url" || { echo "FAIL trigger did not contain exact version"; exit 1; }

  run_create_case generated-job-name success "CREATED_JOB_NAME=ai-payments-auth-build" \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case no-distribution-type-template success "DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=false" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git
  ! grep -q "DISTRIBUTION_TYPE" "$tmp/no-distribution-type-template/trigger-url" || { echo "FAIL unsupported distribution type parameter sent"; exit 1; }

	  run_create_case canonical-host-alias success "JOB_IDENTITY_VERIFIED=true" \
	    --jenkins-url https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI \
	    --job-name ai-payments-auth-build \
	    --skip-lookup \
	    --repository-url ssh://git@example.org/team/ai-payments-auth.git
	  grep -q "JOB_URL=https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/ai-payments-auth-build" "$tmp/canonical-host-alias/output" || { echo "FAIL user Jenkins job URL not preserved"; exit 1; }
	  ! grep -q '^CANONICAL' "$tmp/canonical-host-alias/output" || { echo "FAIL canonical field emitted"; exit 1; }
	  ! grep -q "https://ci.jenkins.sberbank.ru" "$tmp/canonical-host-alias/output" || { echo "FAIL redirected Jenkins host emitted"; exit 1; }

  run_create_case readback-harmless-metadata success "JOB_CONFIGURATION_VERIFIED=true" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case missing-repository-url failure "STATE=repository_url_required" \
    --job-name ai-payments-auth-build \
    --skip-lookup

  run_create_case incompatible-template failure "STATE=jenkins_template_incompatible" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case missing-branch-template failure "MISSING_REQUIRED_PARAMETERS=BRANCH" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case hidden-shell-reference failure "STATE=jenkins_template_requires_review" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case properties-content-reference failure "STATE=jenkins_template_requires_review" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case readback-repo-mismatch failure "STATE=jenkins_created_job_repository_mismatch" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git
  grep -q "MUTATIONS_PERFORMED=true" "$tmp/readback-repo-mismatch/output" || { echo "FAIL created job mutation not reported"; exit 1; }
  grep -q "CREATED_JOB_REQUIRES_REVIEW=true" "$tmp/readback-repo-mismatch/output" || { echo "FAIL created job review flag missing"; exit 1; }
  grep -q "REPOSITORY_MISMATCH_PATHS=/project" "$tmp/readback-repo-mismatch/output" || { echo "FAIL repository mismatch paths missing"; exit 1; }

  run_create_case wrong-canonical-folder failure "STATE=jenkins_created_job_identity_mismatch" \
    --jenkins-url https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case readback-script-path-mismatch failure "STATE=jenkins_created_job_script_path_mismatch" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case readback-missing-version failure "STATE=jenkins_created_job_parameter_mismatch" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case wrong-created-job-url failure "STATE=jenkins_created_job_identity_mismatch" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case readback-injected-reference failure "TEMPLATE_REFERENCE_PATHS=/project/builders/hudson.tasks.Shell/command" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case readback-hidden-difference failure "STATE=jenkins_created_job_config_mismatch" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

  run_create_case readback-pipeline-scm-mismatch failure "STATE=jenkins_pipeline_scm_mismatch" \
    --job-name ai-payments-auth-build \
    --skip-lookup \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git

	  run_existing_case existing-incompatible "STATE=jenkins_created_job_parameter_mismatch"

		  run_existing_success_case existing-compatible "JOB_CONFIGURATION_VERIFIED=true"
		  grep -q "JOB_CREATED=false" "$tmp/existing-compatible/output" || { echo "FAIL existing job reported created"; exit 1; }
		  grep -q "JOB_EXISTS=true" "$tmp/existing-compatible/output" || { echo "FAIL existing job existence missing"; exit 1; }
		  grep -q "BUILD_TRIGGERED=true" "$tmp/existing-compatible/output" || { echo "FAIL existing job trigger not reported"; exit 1; }
		  grep -q "QUEUE_URL=https://aipay.ci.jenkins.sberbank.ru/queue/item/1/" "$tmp/existing-compatible/output" || { echo "FAIL existing job queue URL missing"; exit 1; }
		  grep -q "VERSION=IFT-0.0.1" "$tmp/existing-compatible/trigger-url" || { echo "FAIL existing job trigger exact version"; exit 1; }
		  ! grep -q "DISTRIBUTION_TYPE" "$tmp/existing-compatible/trigger-url" || { echo "FAIL existing unsupported distribution type sent"; exit 1; }

		  run_existing_success_case existing-job-redirect "JOB_IDENTITY_VERIFIED=true"
		  grep -q "JOB_URL=https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/ai-payments-auth-build" "$tmp/existing-job-redirect/output" || { echo "FAIL existing job user URL was not preserved"; exit 1; }
		  ! grep -q '^CANONICAL' "$tmp/existing-job-redirect/output" || { echo "FAIL existing job canonical field emitted"; exit 1; }
		  ! grep -q "https://ci.jenkins.sberbank.ru" "$tmp/existing-job-redirect/output" || { echo "FAIL existing job redirected host emitted"; exit 1; }

		  run_existing_success_case existing-config-redirect "JOB_CONFIGURATION_VERIFIED=true"

		  run_existing_case wrong-path-redirect "STATE=jenkins_created_job_identity_mismatch"

		  run_existing_case existing-empty-config "STATE=jenkins_job_config_unavailable"
		  grep -q "BUILD_TRIGGERED=false" "$tmp/existing-empty-config/output" || { echo "FAIL pre-trigger error claimed build"; exit 1; }
		  grep -q "^QUEUE_URL=$" "$tmp/existing-empty-config/output" || { echo "FAIL pre-trigger error kept queue URL"; exit 1; }
		  grep -q "^BUILD_URL=$" "$tmp/existing-empty-config/output" || { echo "FAIL pre-trigger error kept build URL"; exit 1; }

	  set +e
	  output="$(
	    PATH="$bin:$PATH" \
	    JENKINS_JOB_CREATE_TEST_DIR="$tmp/conflicting-mode" \
	    JENKINS_JOB_CREATE_SCENARIO=existing-compatible \
	    JENKINS_USER=dummy \
	    JENKINS_TOKEN=dummy \
	    bash "$0" \
	      --jenkins-url "https://example.invalid/job/folder" \
	      --project-name ai-payments-auth \
	      --project-dir "$tmp/conflicting-mode/project" \
	      --branch develop-corp \
	      --job-name ai-payments-auth-build \
	      --skip-lookup \
	      --existing-job \
	      --template-job template-job \
	      --repository-url ssh://git@example.org/team/ai-payments-auth.git \
	      --distribution-type ift \
	      --version IFT-0.0.1
	  )"
	  rc=$?
	  set -e
	  [[ $rc -ne 0 ]] || { printf '%s\n' "$output"; echo "FAIL conflicting job mode accepted"; exit 1; }
	  grep -q "STATE=conflicting_job_mode" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL conflicting job mode state"; exit 1; }

	  expected_order=$'fetch-template\ncrumb\ncreateItem\nreadback-api\nreadback-config\nbuildWithParameters'
  actual_order="$(cat "$tmp/explicit-job-name/calls.log")"
  [[ "$actual_order" == "$expected_order" ]] || {
    printf 'Expected order:\n%s\nActual order:\n%s\n' "$expected_order" "$actual_order"
    echo "FAIL create call order"
    exit 1
  }

  rm -rf "$tmp"
  echo "JENKINS_JOB_CREATE_SELF_TESTS=OK"
}

wait_for_build() {
  [[ "$WAIT" == "true" && "$DRY_RUN" != "true" ]] || return 0
  [[ -n "$QUEUE_URL" || -n "$BUILD_URL" ]] || error_exit "Build was triggered but Jenkins did not return queue or build URL" "queue or build URL"

  local start now status executable_url result status_fields normalized_queue_url
  start="$(date +%s)"

  if [[ -z "$BUILD_URL" ]]; then
    if ! normalized_queue_url="$(normalize_queue_url "${JENKINS_URL}/" "$QUEUE_URL" 2>/dev/null)"; then
      invalid_queue_url_exit
    fi
    QUEUE_URL="$normalized_queue_url"

    while true; do
      now="$(date +%s)"
      if (( now - start > TIMEOUT_SECONDS )); then
        build_wait_timeout_exit "more time or Jenkins queue inspection"
      fi

      curl_get_jenkins_api_follow_redirect "${QUEUE_URL%/}/api/json" false
      status="$CURL_GET_STATUS"

      case "$status" in
        200)
          executable_url="$(json_field "executable.url" "$BODY_FILE" || true)"
          if [[ -n "$executable_url" ]]; then
            QUEUE_EXECUTABLE_URL="${executable_url%/}"
            BUILD_URL="$QUEUE_EXECUTABLE_URL"
            break
          fi
          ;;
        401|403)
          error_exit "Jenkins access denied while reading queue item: HTTP ${status}" "valid Jenkins credentials"
          ;;
        405)
          invalid_queue_url_exit
          ;;
        561)
          jenkins_status_unavailable_exit "jenkins_redirect_rejected" "approved Jenkins redirect host"
          ;;
        562)
          jenkins_status_unavailable_exit "jenkins_build_status_unavailable" "Jenkins queue access"
          ;;
        *)
          jenkins_status_unavailable_exit "jenkins_build_status_unavailable" "Jenkins queue access"
          ;;
      esac

      sleep 10
    done
  else
    case "${BUILD_URL%/}" in
      */build|*/buildWithParameters)
        invalid_queue_url_exit
        ;;
    esac
  fi

  while true; do
    now="$(date +%s)"
    if (( now - start > TIMEOUT_SECONDS )); then
      build_wait_timeout_exit "more time or Jenkins build inspection"
    fi

    curl_get_jenkins_api_follow_redirect "${BUILD_URL}/api/json" true
    status="$CURL_GET_STATUS"

    case "$status" in
      200)
        status_fields="$(json_build_status_fields "$BODY_FILE" || true)"
        if [[ -z "$status_fields" ]]; then
          jenkins_status_unavailable_exit "jenkins_build_status_unavailable" "Jenkins build status access"
        fi
        API_BUILD_URL="$(sed -n 's/^API_BUILD_URL=//p' <<<"$status_fields" | tail -n 1)"
        API_BUILD_NUMBER="$(sed -n 's/^API_BUILD_NUMBER=//p' <<<"$status_fields" | tail -n 1)"
        BUILDING="$(sed -n 's/^BUILDING=//p' <<<"$status_fields" | tail -n 1)"
        result="$(sed -n 's/^RESULT=//p' <<<"$status_fields" | tail -n 1)"
        verify_build_identity_chain
        BUILD_NUMBER="$API_BUILD_NUMBER"
        case "$BUILDING:$result" in
          false:SUCCESS|false:FAILURE|false:UNSTABLE|false:ABORTED)
            RESULT="$result"
            STATUS_VERIFIED=true
            STATUS_VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            ARTIFACT_URLS="$(json_artifact_urls "$BODY_FILE" | paste -sd ',' - || true)"
            return 0
            ;;
          true:*|false:)
            ;;
          *)
            jenkins_status_unavailable_exit "jenkins_build_status_unavailable" "Jenkins build status access"
            ;;
        esac
        ;;
      404)
        ;;
      401|403)
        error_exit "Jenkins access denied while reading build result: HTTP ${status}" "valid Jenkins credentials"
        ;;
      561)
        jenkins_status_unavailable_exit "jenkins_redirect_rejected" "approved Jenkins redirect host"
        ;;
      562)
        jenkins_status_unavailable_exit "jenkins_build_status_unavailable" "Jenkins build status access"
        ;;
      *)
        jenkins_status_unavailable_exit "jenkins_build_status_unavailable" "Jenkins build status access"
        ;;
    esac

    sleep 10
  done
}

JENKINS_URL="${JENKINS_URL:-}"
PROJECT_NAME=""
PROJECT_DIR="${PROJECT_DIR:-}"
BRANCH=""
REPOSITORY_URL=""
TEMPLATE_JOB="${JENKINS_TEMPLATE_JOB:-}"
TEMPLATE_JOB_EXPLICIT=false
JOB_NAME_ARG=""
JOB_URL_ARG=""
DISTRIBUTION_TYPE=""
VERSION=""
VERSION_SOURCE=""
VERSION_SOURCE_ARG=""
PREVIOUS_VERSION=""
JENKINS_BRANCH_PARAM="BRANCH"
JENKINS_VERSION_PARAM="VERSION"
JENKINS_DISTRIBUTION_TYPE_PARAM="DISTRIBUTION_TYPE"
RESOLVE_VERSION_ONLY=false
SKIP_LOOKUP=false
EXISTING_JOB=false
CREATE_IF_MISSING=false
DRY_RUN=false
WAIT=false
TIMEOUT_SECONDS=1800
RECOVERY_WINDOW_SECONDS=3600
ACTION=""
JOB_CREATED=false
JOB_EXISTS=false
JOB_MODE=""
JOB_NAME=""
JOB_URL=""
REQUESTED_JOB_NAME=""
CREATED_JOB_NAME=""
JOB_NAME_SOURCE=""
EXPECTED_JOB_NAME=""
ACTUAL_JOB_NAME=""
EXPECTED_JOB_URL=""
EXPECTED_REPOSITORY_URL=""
ACTUAL_REPOSITORY_URL=""
TEMPLATE_REPOSITORY_URL=""
TEMPLATE_PROJECT_SLUG=""
TEMPLATE_REFERENCE_PATHS=""
CONFIG_DIFF_PATHS=""
REPOSITORY_MISMATCH_PATHS=""
SCRIPT_PATH=""
PIPELINE_SCM_BRANCH_SPEC=""
WARNING=""
HTTP_STATUS=""
JOB_IDENTITY_VERIFIED=false
REQUIRED_PARAMETERS_OK=false
REQUIRED_PARAMETERS=""
SUPPORTED_PARAMETERS=""
OPTIONAL_PARAMETERS=""
MISSING_REQUIRED_PARAMETERS=""
DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=false
JOB_CONFIGURATION_VERIFIED=false
CREATED_JOB_REQUIRES_REVIEW=false
TRIGGER_URL=""
QUEUE_URL=""
BUILD_URL=""
QUEUE_EXECUTABLE_URL=""
BUILD_NUMBER=""
RESULT=""
BUILDING=""
CURL_GET_STATUS=""
STATUS_VERIFIED=false
STATUS_VERIFIED_AT=""
API_BUILD_URL=""
EXPECTED_BUILD_NUMBER=""
API_BUILD_NUMBER=""
STATE=""
BUILD_TRIGGERED=false
MUTATIONS_PERFORMED=false
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
    --self-test-build-wait)
      run_build_wait_self_tests
      exit 0
      ;;
    --self-test-job-create)
      run_job_create_self_tests
      exit 0
      ;;
    --resolve-version-only)
      RESOLVE_VERSION_ONLY=true
      shift
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
	    --job-url)
	      require_value "$1" "${2:-}"
	      JOB_URL_ARG="${2%/}"
	      shift 2
	      ;;
	    --template-job)
	      require_value "$1" "${2:-}"
	      TEMPLATE_JOB="$2"
	      TEMPLATE_JOB_EXPLICIT=true
	      shift 2
	      ;;
    --repository-url)
      require_value "$1" "${2:-}"
      REPOSITORY_URL="$2"
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
    --jenkins-branch-param)
      require_value "$1" "${2:-}"
      JENKINS_BRANCH_PARAM="$2"
      shift 2
      ;;
    --jenkins-version-param)
      require_value "$1" "${2:-}"
      JENKINS_VERSION_PARAM="$2"
      shift 2
      ;;
    --jenkins-distribution-type-param)
      require_value "$1" "${2:-}"
      JENKINS_DISTRIBUTION_TYPE_PARAM="$2"
      shift 2
      ;;
	    --skip-lookup)
	      SKIP_LOOKUP=true
	      shift
	      ;;
	    --existing-job)
	      EXISTING_JOB=true
	      shift
	      ;;
	    --create-if-missing)
	      CREATE_IF_MISSING=true
	      shift
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
    --recovery-window-seconds)
      require_value "$1" "${2:-}"
      RECOVERY_WINDOW_SECONDS="$2"
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

[[ -n "$JENKINS_URL" ]] || error_exit "Missing Jenkins URL" "JENKINS_URL"
[[ -n "$PROJECT_NAME" ]] || resolve_project_name
[[ -n "$BRANCH" ]] || resolve_branch
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || error_exit "--timeout-seconds must be a number" "timeout seconds"
[[ "$RECOVERY_WINDOW_SECONDS" =~ ^[0-9]+$ ]] || error_exit "--recovery-window-seconds must be a number" "recovery window seconds"
if [[ "$SKIP_LOOKUP" == "true" && -z "$JOB_NAME_ARG" ]]; then
  error_exit "--skip-lookup requires --job-name" "job name"
fi
if [[ "$EXISTING_JOB" == "true" && -z "$JOB_NAME_ARG" ]]; then
  error_exit "--existing-job requires --job-name" "job name"
fi
if [[ "$EXISTING_JOB" == "true" && "$CREATE_IF_MISSING" == "true" ]]; then
  STATE="conflicting_job_mode"
  error_exit "Conflicting Jenkins job modes: --existing-job and --create-if-missing" "choose existing or create mode"
fi
if [[ "$EXISTING_JOB" == "true" && "$TEMPLATE_JOB_EXPLICIT" == "true" ]]; then
  STATE="conflicting_job_mode"
  error_exit "Conflicting Jenkins job modes: --existing-job and --template-job" "choose existing or create mode"
fi
if [[ "$EXISTING_JOB" == "true" ]]; then
  TEMPLATE_JOB=""
fi
if [[ "$CREATE_IF_MISSING" == "true" && -z "$TEMPLATE_JOB" ]]; then
  error_exit "--create-if-missing requires --template-job" "template job"
fi
raw_distribution_type="$DISTRIBUTION_TYPE"
if ! DISTRIBUTION_TYPE="$(normalize_distribution_type "$raw_distribution_type")"; then
  error_exit "Unsupported distribution type: ${raw_distribution_type}" "distribution type"
fi
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
RENDERED_CONFIG_FILE="${TMP_DIR}/rendered-config.xml"
READBACK_CONFIG_FILE="${TMP_DIR}/readback-config.xml"

if [[ "$DRY_RUN" == "true" ]]; then
  build_candidate_job_names
  JOB_NAME="${JOB_NAME_ARG:-${PROJECT_NAME}-build}"
  REQUESTED_JOB_NAME="$JOB_NAME"
  CREATED_JOB_NAME="$JOB_NAME"
  if [[ -n "$JOB_NAME_ARG" ]]; then
    JOB_NAME_SOURCE="explicit"
  else
    JOB_NAME_SOURCE="generated"
  fi
  JOB_URL="$(job_url_for "$JOB_NAME")"
  resolve_version
  ACTION="dry-run"
else
	  if [[ "$SKIP_LOOKUP" == "true" ]]; then
	    JOB_NAME="$JOB_NAME_ARG"
	    JOB_URL="${JOB_URL_ARG:-$(job_url_for "$JOB_NAME")}"
	    build_candidate_job_names
	    if [[ "$EXISTING_JOB" == "true" ]]; then
	      REQUESTED_JOB_NAME="$JOB_NAME"
	      JOB_NAME_SOURCE="explicit"
	      JOB_EXISTS=true
	      JOB_CREATED=false
	      JOB_MODE="existing"
	      ACTION="existing-job-verified"
	    elif [[ "$CREATE_IF_MISSING" == "true" ]]; then
	      create_job_from_template
	    else
	      REQUESTED_JOB_NAME="$JOB_NAME"
	      JOB_NAME_SOURCE="explicit"
	      JOB_EXISTS=true
	      JOB_CREATED=false
	      JOB_MODE="legacy"
	      ACTION="reused"
	    fi
  elif ! find_existing_job; then
    if [[ "$RESOLVE_VERSION_ONLY" == "true" ]]; then
      error_exit "Jenkins job not found. Checked: ${CHECKED_JOB_NAMES[*]}." "existing Jenkins job"
    fi
    create_job_from_template
  fi
  resolve_version
  emit_version_resolution
  if [[ "$RESOLVE_VERSION_ONLY" == "true" ]]; then
    echo "STATUS=OK"
    echo "ACTION=version"
    emit_common
    exit 0
  fi
  verify_existing_job_before_build
  if ! recover_existing_build; then
    emit_job_ready
    trigger_build
  fi
  wait_for_build
fi

echo "STATUS=OK"
echo "ACTION=${ACTION}"
emit_common
if [[ -n "$ARTIFACT_URLS" ]]; then
  echo "ARTIFACT_URLS=${ARTIFACT_URLS}"
fi
