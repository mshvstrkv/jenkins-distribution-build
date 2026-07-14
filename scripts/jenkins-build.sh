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
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" != *"="* ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
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
    [--branch <branch>] \
    [--job-name <job-name>] \
    [--template-job <job-name>] \
    [--distribution-type <ift|release>] \
    [--version <version>] \
    [--version-source <auto|manual>] \
    [--jenkins-branch-param <name>] \
    [--jenkins-version-param <name>] \
    [--jenkins-distribution-type-param <name>] \
    [--skip-lookup] \
    [--dry-run] \
    [--wait] \
    [--recovery-window-seconds <number>] \
    [--timeout-seconds <number>]

Optional arguments:
  --jenkins-url        Jenkins base or folder URL. Defaults to JENKINS_URL from skill .env.
  --project-name       Project name used to find/create Jenkins job. Defaults to git root/current directory name.
  --branch             Branch passed to Jenkins as BRANCH. Defaults to current git branch.
  --job-name           Explicit Jenkins job name checked before generated candidates
  --template-job       Template job name, required when project job is missing
  --distribution-type  Distributive type: ift|release, aliases: test/testing/prod/production
  --version            Explicit distributive version
  --version-source     Version source hint: auto or manual
  --jenkins-branch-param             Jenkins branch parameter name, default BRANCH
  --jenkins-version-param            Jenkins version parameter name, default VERSION
  --jenkins-distribution-type-param  Jenkins distribution type parameter name, default DISTRIBUTION_TYPE
  --skip-lookup        Use the explicit --job-name without running Jenkins job lookup
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
  echo "BRANCH=${BRANCH:-}"
  echo "JOB_NAME=${JOB_NAME:-}"
  echo "JOB_URL=${JOB_URL:-}"
  echo "QUEUE_URL=${QUEUE_URL:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-}"
  echo "RESULT=${RESULT:-}"
  echo "BUILDING=${BUILDING:-}"
  echo "STATUS_VERIFIED=${STATUS_VERIFIED:-false}"
  echo "STATUS_VERIFIED_AT=${STATUS_VERIFIED_AT:-}"
  echo "API_BUILD_URL=${API_BUILD_URL:-}"
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
  if [[ -n "$PROJECT_NAME" ]]; then
    return 0
  fi
  local git_root
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_root" ]]; then
    PROJECT_NAME="$(basename "$git_root")"
  else
    PROJECT_NAME="$(basename "$(pwd)")"
  fi
  [[ -n "$PROJECT_NAME" ]] || error_exit "Missing project name" "project name"
}

resolve_branch() {
  if [[ -n "$BRANCH" ]]; then
    return 0
  fi
  BRANCH="$(git branch --show-current 2>/dev/null || true)"
  [[ -n "$BRANCH" ]] || error_exit "Missing branch" "branch"
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
  local mode="$1"
  local json_file="$2"
  local root_url="$3"

  local current_time_ms
  current_time_ms="$(($(date +%s) * 1000))"

  python3 - "$mode" "$json_file" "$root_url" "$JOB_NAME" "$JOB_URL" "$JENKINS_BRANCH_PARAM" "$BRANCH" "$JENKINS_VERSION_PARAM" "$VERSION" "$JENKINS_DISTRIBUTION_TYPE_PARAM" "$DISTRIBUTION_TYPE" "$RECOVERY_WINDOW_SECONDS" "$current_time_ms" <<'PY'
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

build_wait_timeout_exit() {
  STATE="build_wait_timeout"
  NEXT_REQUIRED_INPUT="${1:-more time or Jenkins build inspection}"
  echo "STATUS=ERROR"
  echo "ACTION=blocked"
  echo "REASON=Timed out waiting for Jenkins build result"
  emit_common
  exit 1
}

curl_get_jenkins_api_follow_redirect() {
  local current_url="$1"
  local update_build_url="${2:-false}"
  local status location next_url redirect_count=0
  CURL_GET_STATUS=""

  while true; do
    status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
      --request GET \
      --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
      "$current_url")"

    case "$status" in
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
        if [[ "$update_build_url" == "true" ]]; then
          BUILD_URL="$(build_url_from_api_url "$next_url")"
          case "$next_url" in
            */api/json) ;;
            *) next_url="${BUILD_URL}/api/json" ;;
          esac
        fi
        current_url="$next_url"
        redirect_count=$((redirect_count + 1))
        if (( redirect_count > 5 )); then
          CURL_GET_STATUS="562"
          return 0
        fi
        ;;
      *)
        CURL_GET_STATUS="$status"
        return 0
        ;;
    esac
  done
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

  if [[ "${API_BUILD_URL%/}" != "${BUILD_URL%/}" || "$API_BUILD_NUMBER" != "$EXPECTED_BUILD_NUMBER" ]]; then
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

recover_existing_build() {
  [[ "$DRY_RUN" != "true" ]] || return 1
  [[ -n "$JOB_NAME" && -n "$JOB_URL" && -n "$BRANCH" && -n "$VERSION" ]] || return 1

  local root_url status recovery_output queue_url build_url
  root_url="$(jenkins_root_url "$JENKINS_URL")"

  status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
    --globoff \
    --request GET \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    "${root_url}/queue/api/json?tree=items[id,url,params,task[name,url],actions[parameters[name,value]],executable[url]]")"
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

  status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" \
    --globoff \
    --request GET \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    "${JOB_URL}/api/json?tree=builds[number,url,result,building,timestamp,actions[parameters[name,value]]]")"
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
  if [[ -n "$DISTRIBUTION_TYPE" ]]; then
    build_url+="&${encoded_distribution_type_param}=$(urlencode "$DISTRIBUTION_TYPE")"
  fi
  curl_args+=("$build_url")
  status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" "${curl_args[@]}")"

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
    curl_args+=("${JOB_URL}/build")
    status="$(curl_http "$BODY_FILE" "$HEADERS_FILE" "${curl_args[@]}")"
  fi

  case "$status" in
    200|201|202|302)
      QUEUE_URL="$(header_location "$HEADERS_FILE")"
      BUILD_TRIGGERED=true
      MUTATIONS_PERFORMED=true
      ACTION="build"
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

if [[ "$method" == "POST" && "$url" == *"/buildWithParameters"* ]]; then
  count_file="${JENKINS_BUILD_WAIT_TEST_DIR}/trigger-count"
  count=0
  [[ -f "$count_file" ]] && count="$(cat "$count_file")"
  count=$((count + 1))
  echo "$count" >"$count_file"
  printf 'Location: https://aipay.ci.jenkins.sberbank.ru/queue/item/1/\r\n' >"$headers"
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
    confirmed-success|recovery-recent-success|recovery-old-success|recovery-not-found|recovery-aborted|recovery-dtype-mismatch|repeated-restart)
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
        --distribution-type ift \
        --version IFT-0.0.1 \
        --wait \
        --timeout-seconds "$timeout_seconds"
    )"
    rc=$?
    set -e
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

wait_for_build() {
  [[ "$WAIT" == "true" && "$DRY_RUN" != "true" ]] || return 0
  [[ -n "$QUEUE_URL" || -n "$BUILD_URL" ]] || error_exit "Build was triggered but Jenkins did not return queue or build URL" "queue or build URL"

  local start now status executable_url result status_fields
  start="$(date +%s)"

  if [[ -z "$BUILD_URL" ]]; then
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
BRANCH=""
TEMPLATE_JOB=""
JOB_NAME_ARG=""
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
DRY_RUN=false
WAIT=false
TIMEOUT_SECONDS=1800
RECOVERY_WINDOW_SECONDS=3600
ACTION=""
JOB_NAME=""
JOB_URL=""
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
resolve_project_name
resolve_branch
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || error_exit "--timeout-seconds must be a number" "timeout seconds"
[[ "$RECOVERY_WINDOW_SECONDS" =~ ^[0-9]+$ ]] || error_exit "--recovery-window-seconds must be a number" "recovery window seconds"
if [[ "$SKIP_LOOKUP" == "true" && -z "$JOB_NAME_ARG" ]]; then
  error_exit "--skip-lookup requires --job-name" "job name"
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

if [[ "$DRY_RUN" == "true" ]]; then
  build_candidate_job_names
  JOB_NAME="${JOB_NAME_ARG:-$PROJECT_NAME}"
  JOB_URL="$(job_url_for "$JOB_NAME")"
  resolve_version
  ACTION="dry-run"
else
  if [[ "$SKIP_LOOKUP" == "true" ]]; then
    JOB_NAME="$JOB_NAME_ARG"
    JOB_URL="$(job_url_for "$JOB_NAME")"
    ACTION="reused"
    build_candidate_job_names
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
  if ! recover_existing_build; then
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
