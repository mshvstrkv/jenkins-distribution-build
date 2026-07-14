#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/jenkins-status.sh \
    (--build-url <url> | --job-name <job> --build-number <number>) \
    [--jenkins-url <url>] \
    [--version <version>] \
    [--distribution-type <ift|release>] \
    [--branch <branch>] \
    [--self-test]
EOF
}

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

build_number_from_url() {
  python3 - "$1" <<'PY'
import re, sys
m = re.search(r"/(\d+)/?$", sys.argv[1].rstrip("/"))
print(m.group(1) if m else "")
PY
}

job_build_url() {
  local encoded_job
  encoded_job="$(urlencode "$JOB_NAME")"
  printf '%s/job/%s/%s' "${JENKINS_URL%/}" "$encoded_job" "$BUILD_NUMBER"
}

emit_status() {
  echo "STATUS=${STATUS:-}"
  echo "ACTION=status"
  echo "STATE=${STATE:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-}"
  echo "JOB_NAME=${JOB_NAME:-}"
  echo "BRANCH=${BRANCH:-}"
  echo "VERSION=${VERSION:-}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE:-}"
  echo "BUILDING=${BUILDING:-}"
  echo "RESULT=${RESULT:-}"
  echo "BUILD_STATUS_VERIFIED=${BUILD_STATUS_VERIFIED:-false}"
  echo "NEXT_REQUIRED_INPUT=${NEXT_REQUIRED_INPUT:-}"
  echo "MUTATIONS_PERFORMED=false"
}

fail_status() {
  STATUS=ERROR
  STATE="$1"
  NEXT_REQUIRED_INPUT="${2:-}"
  emit_status
  exit 1
}

parse_build_json() {
  local json_file="$1"
  PYTHONPATH="$SKILL_ROOT" python3 - "$json_file" "$BUILD_URL" "${VERSION:-}" "${DISTRIBUTION_TYPE:-}" "${BRANCH:-}" <<'PY'
import json, re, sys

path, expected_url, expected_version, expected_type, expected_branch = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    payload = json.load(fh)

def param(name):
    for action in payload.get("actions") or []:
        for item in action.get("parameters") or []:
            if item.get("name") == name:
                value = item.get("value")
                return "" if value is None else str(value)
    return ""

api_url = (payload.get("url") or "").rstrip("/")
api_number = "" if payload.get("number") is None else str(payload.get("number"))
building = payload.get("building")
result = payload.get("result")
version = param("VERSION") or param("DISTRIBUTIVE_VERSION") or param("DISTRIBUTION_VERSION")
dtype = param("DISTRIBUTION_TYPE")
branch = param("BRANCH")
expected_number = ""
m = re.search(r"/(\d+)/?$", expected_url.rstrip("/"))
if m:
    expected_number = m.group(1)

print(f"API_BUILD_URL={api_url}")
print(f"API_BUILD_NUMBER={api_number}")
print(f"BUILDING={'true' if building is True else 'false' if building is False else 'invalid'}")
print(f"RESULT={'' if result is None else result}")
print(f"VERSION={version}")
print(f"DISTRIBUTION_TYPE={dtype}")
print(f"BRANCH={branch}")
print(f"EXPECTED_BUILD_NUMBER={expected_number}")

if api_url != expected_url.rstrip("/") or not expected_number or api_number != expected_number:
    print("STATE=jenkins_build_identity_mismatch")
    sys.exit(10)
if expected_version and version != expected_version:
    print("STATE=jenkins_build_identity_mismatch")
    sys.exit(10)
if expected_type and dtype != expected_type:
    print("STATE=jenkins_build_identity_mismatch")
    sys.exit(10)
if expected_branch and branch != expected_branch:
    print("STATE=jenkins_build_identity_mismatch")
    sys.exit(10)
if building is True:
    print("STATE=jenkins_build_not_finished")
    sys.exit(11)
if result != "SUCCESS":
    print("STATE=jenkins_build_not_successful")
    sys.exit(12)
sys.exit(0)
PY
}

run_self_tests() {
  local tmp json out rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  json="$tmp/build.json"
  cat >"$json" <<'JSON'
{"number":47,"url":"https://ci.jenkins/job/x/47/","building":false,"result":"SUCCESS","actions":[{"parameters":[{"name":"BRANCH","value":"develop"},{"name":"VERSION","value":"IFT-0.0.27"},{"name":"DISTRIBUTION_TYPE","value":"ift"}]}]}
JSON
  BUILD_URL="https://ci.jenkins/job/x/47"
  VERSION="IFT-0.0.27"
  DISTRIBUTION_TYPE="ift"
  BRANCH="develop"
  parse_build_json "$json" >/dev/null
  VERSION="IFT-0.0.28"
  set +e
  out="$(parse_build_json "$json")"
  rc=$?
  set -e
  [[ $rc -eq 10 && "$out" == *"STATE=jenkins_build_identity_mismatch"* ]] || { echo "JENKINS_STATUS_SELF_TESTS=FAIL"; exit 1; }
  echo "JENKINS_STATUS_SELF_TESTS=OK"
}

load_skill_env

BUILD_URL=""
JOB_NAME=""
BUILD_NUMBER=""
JENKINS_URL="${JENKINS_URL:-}"
VERSION=""
DISTRIBUTION_TYPE=""
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --build-url) require_value "$1" "${2:-}"; BUILD_URL="${2%/}"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME="$2"; shift 2 ;;
    --build-number) require_value "$1" "${2:-}"; BUILD_NUMBER="$2"; shift 2 ;;
    --jenkins-url) require_value "$1" "${2:-}"; JENKINS_URL="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$(normalize_distribution_type "$2")"; shift 2 ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

if [[ -z "$BUILD_URL" ]]; then
  [[ -n "$JOB_NAME" && -n "$BUILD_NUMBER" ]] || error_exit "Missing build identity" "build URL or job name and build number"
  resolve_jenkins_url
  BUILD_URL="$(job_build_url)"
else
  BUILD_NUMBER="$(build_number_from_url "$BUILD_URL")"
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || error_exit "Invalid build number" "build number"

[[ -n "${JENKINS_USER:-}" ]] || error_exit "Missing required environment variable: JENKINS_USER" "JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || error_exit "Missing required environment variable: JENKINS_TOKEN" "JENKINS_TOKEN"
command -v curl >/dev/null 2>&1 || error_exit "curl is required but was not found" "curl"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
body="$WORK_DIR/build.json"
headers="$WORK_DIR/headers"
err="$WORK_DIR/curl.err"
status="$(curl --silent --show-error --location --globoff --output "$body" --dump-header "$headers" --write-out '%{http_code}' --user "${JENKINS_USER}:${JENKINS_TOKEN}" "${BUILD_URL}/api/json?tree=number,url,result,building,actions[parameters[name,value]]" 2>"$err" || true)"
if [[ "$status" == "000" || -z "$status" ]]; then
  STATE=jenkins_unreachable
  NEXT_REQUIRED_INPUT="Jenkins access"
  STATUS=ERROR
  emit_status
  exit 1
fi
[[ "$status" == "200" ]] || fail_status "jenkins_build_status_unavailable" "Jenkins build status access"

set +e
fields="$(parse_build_json "$body")"
rc=$?
set -e
while IFS= read -r line; do
  key="${line%%=*}"
  value="${line#*=}"
  case "$key" in
    BUILDING) BUILDING="$value" ;;
    RESULT) RESULT="$value" ;;
    VERSION) VERSION="$value" ;;
    DISTRIBUTION_TYPE) DISTRIBUTION_TYPE="$value" ;;
    BRANCH) BRANCH="$value" ;;
    STATE) STATE="$value" ;;
  esac
done <<<"$fields"

case "$rc" in
  0) STATUS=OK; BUILD_STATUS_VERIFIED=true; emit_status ;;
  10) fail_status "jenkins_build_identity_mismatch" "matching Jenkins build" ;;
  11) fail_status "jenkins_build_not_finished" "wait for Jenkins build completion" ;;
  12) fail_status "jenkins_build_not_successful" "successful Jenkins build" ;;
  *) fail_status "jenkins_build_status_unavailable" "Jenkins build status access" ;;
esac
