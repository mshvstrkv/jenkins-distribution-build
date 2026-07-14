#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/version-resolver.sh \
    --jenkins-url <url> \
    --project-name <name> \
    --job-name <name> \
    --distribution-type <ift|release|test|testing|prod|production> \
    [--version <explicit-version>] \
    [--self-test]
EOF
}

run_self_tests() {
  PYTHONPATH="$SKILL_ROOT" python3 - <<'PY'
from scripts.lib.distribution.versioning import resolve_version, normalize_distribution_type

assert resolve_version("ift", []).version == "IFT-0.0.1"
assert resolve_version("ift", ["IFT-0.0.1"]).version == "IFT-0.0.2"
assert resolve_version("ift", ["IFT-0.1.1"]).version == "IFT-0.1.2"
assert resolve_version("ift", ["D-00.000.09"]).version == "IFT-0.0.1"
assert resolve_version("release", []).version == "D-00.000.01"
assert resolve_version("release", ["D-00.000.01"]).version == "D-00.000.02"
assert resolve_version("release", ["D-00.000.09"]).version == "D-00.000.10"
try:
    resolve_version("release", ["D-00.000.99"])
except OverflowError:
    pass
else:
    raise AssertionError("expected release overflow")
assert resolve_version("release", ["IFT-0.1.2"]).version == "D-00.000.01"
assert normalize_distribution_type("test") == "ift"
assert normalize_distribution_type("testing") == "ift"
assert normalize_distribution_type("prod") == "release"
assert normalize_distribution_type("production") == "release"
PY
  echo "VERSION_SELF_TESTS=OK"
}

resolve_with_python() {
  local candidates_file="$1"
  PYTHONPATH="$SKILL_ROOT" python3 - "$DISTRIBUTION_TYPE" "$VERSION" "$candidates_file" "$PROJECT_NAME" <<'PY'
import sys
from scripts.lib.distribution.versioning import resolve_version

distribution_type, explicit_version, candidates_file, project_name = sys.argv[1:]
with open(candidates_file, "r", encoding="utf-8") as fh:
    candidates = [line.strip() for line in fh if line.strip()]

try:
    result = resolve_version(distribution_type, candidates, explicit_version or None)
except OverflowError:
    print("STATUS=ERROR")
    print("STATE=version_overflow")
    print("ACTION=resolve-version")
    print(f"DISTRIBUTION_TYPE={distribution_type}")
    print("NEXT_REQUIRED_INPUT=release version policy")
    print("MUTATIONS_PERFORMED=false")
    sys.exit(1)
except Exception as exc:
    print("STATUS=ERROR")
    print("ACTION=resolve-version")
    print(f"REASON={exc}")
    print("NEXT_REQUIRED_INPUT=valid version input")
    print("MUTATIONS_PERFORMED=false")
    sys.exit(1)

print("STATUS=OK")
print("ACTION=resolve-version")
print(f"PROJECT_NAME={project_name}")
print(f"DISTRIBUTION_TYPE={result.distribution_type}")
print(f"PREVIOUS_VERSION={result.previous_version}")
print(f"VERSION={result.version}")
print(f"VERSION_SOURCE={result.source}")
print("NEXT_REQUIRED_INPUT=")
print("MUTATIONS_PERFORMED=false")
PY
}

curl_http() {
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

version_candidates_from_json() {
  local json_file="$1"
  local out_file="$2"
  PYTHONPATH="$SKILL_ROOT" python3 - "$DISTRIBUTION_TYPE" "$json_file" "$out_file" <<'PY'
import sys
from scripts.lib.distribution.jenkins import load_json, version_candidates_from_builds

distribution_type, json_file, out_file = sys.argv[1:]
payload = load_json(json_file)
candidates = version_candidates_from_builds(payload, distribution_type)
with open(out_file, "w", encoding="utf-8") as fh:
    for candidate in candidates:
        fh.write(candidate + "\n")
PY
}

load_skill_env

JENKINS_URL="${JENKINS_URL:-}"
PROJECT_NAME=""
JOB_NAME=""
DISTRIBUTION_TYPE=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --jenkins-url) require_value "$1" "${2:-}"; JENKINS_URL="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done


resolve_project_name
[[ -n "$DISTRIBUTION_TYPE" ]] || error_exit "Missing required argument: --distribution-type" "distribution type"
DISTRIBUTION_TYPE="$(PYTHONPATH="$SKILL_ROOT" python3 - "$DISTRIBUTION_TYPE" <<'PY'
import sys
from scripts.lib.distribution.versioning import normalize_distribution_type
print(normalize_distribution_type(sys.argv[1]))
PY
)" || error_exit "Unsupported distribution type" "ift or release"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
CANDIDATES_FILE="$WORK_DIR/candidates.txt"
: >"$CANDIDATES_FILE"

if [[ -n "$VERSION" ]]; then
  resolve_with_python "$CANDIDATES_FILE"
  exit $?
fi


resolve_jenkins_url
[[ -n "$JOB_NAME" ]] || error_exit "Missing required argument: --job-name" "Jenkins job name"
[[ -n "${JENKINS_USER:-}" ]] || error_exit "Missing required environment variable: JENKINS_USER" "JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || error_exit "Missing required environment variable: JENKINS_TOKEN" "JENKINS_TOKEN"
command -v curl >/dev/null 2>&1 || error_exit "curl is required but was not found" "curl"

JENKINS_URL="${JENKINS_URL%/}"
encoded_job="$(python3 - "$JOB_NAME" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)"
JOB_URL="${JENKINS_URL}/job/${encoded_job}"
BUILDS_JSON="$WORK_DIR/builds.json"
HEADERS="$WORK_DIR/headers"
ERROR_FILE="$WORK_DIR/curl.err"
status="$(curl_http "$BUILDS_JSON" "$HEADERS" "$ERROR_FILE" --globoff --user "${JENKINS_USER}:${JENKINS_TOKEN}" "${JOB_URL}/api/json?tree=builds[number,url,result,displayName,description,actions[parameters[name,value]]]")"
if [[ "$status" == "000" ]]; then
  message="$(tr '\n' ' ' <"$ERROR_FILE" | sanitize_technical_reason | sed 's/[[:space:]]\+/ /g')"
  echo "STATUS=ERROR"
  echo "STATE=jenkins_unreachable"
  echo "ACTION=resolve-version"
  echo "REASON=Unable to connect to Jenkins"
  echo "NEXT_REQUIRED_INPUT=Jenkins access"
  echo "MUTATIONS_PERFORMED=false"
  [[ -n "$message" ]] && echo "TECHNICAL_REASON=${message}"
  exit 1
fi
if [[ "$status" == "401" || "$status" == "403" ]]; then
  error_exit "Jenkins access denied while resolving version: HTTP ${status}" "valid Jenkins credentials"
fi
if [[ "$status" != "200" ]]; then
  error_exit "Failed to read Jenkins builds for version resolution: HTTP ${status}" "Jenkins API access"
fi

version_candidates_from_json "$BUILDS_JSON" "$CANDIDATES_FILE"
resolve_with_python "$CANDIDATES_FILE"
