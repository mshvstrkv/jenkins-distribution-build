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
  bash scripts/jenkins-analyze-failure.sh \
    --build-url <url> \
    [--max-lines <number>]

Required arguments:
  --build-url   Jenkins build URL

Optional arguments:
  --max-lines   Number of tail console lines to analyze, default 400
EOF
}

error_exit() {
  echo "STATUS=ERROR"
  echo "FAILURE_CATEGORY=wrapper"
  echo "FAILURE_SUMMARY=$1"
  echo "LOG_FILE="
  echo "SUGGESTED_ACTION=$2"
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "${option}"
}

analyze_log() {
  local log_file="$1"
  local max_lines="$2"

  python3 - "$log_file" "$max_lines" <<'PY'
import re
import sys

log_file = sys.argv[1]
max_lines = int(sys.argv[2])

with open(log_file, "r", encoding="utf-8", errors="replace") as fh:
    lines = fh.readlines()

tail = lines[-max_lines:]
text = "".join(tail)
lower = text.lower()

checks = [
    ("authentication", [r"authentication failed", r"authorization failed", r"401 unauthorized", r"403 forbidden", r"permission denied"], "Check Jenkins credentials and access permissions."),
    ("missing_parameter", [r"missing parameter", r"required parameter", r"no such parameter"], "Check required Jenkins build parameters."),
    ("git_checkout", [r"could not read from remote repository", r"git checkout failed", r"repository not found", r"fatal:.*not a git repository"], "Check Git repository URL, branch, and credentials."),
    ("dependency_resolution", [r"could not resolve dependencies", r"dependency resolution", r"failed to collect dependencies", r"could not find artifact"], "Check dependency coordinates and repository availability."),
    ("test_failure", [r"there are test failures", r"test failures?", r"failed tests?", r"surefire-reports", r"tests run:.*failures: [1-9]"], "Inspect failing tests and fix them before rebuilding."),
    ("compilation", [r"compilation failure", r"compilation error", r"cannot find symbol", r"package .* does not exist", r"\[ERROR\].*COMPILATION ERROR"], "Fix compilation errors in the source branch."),
    ("docker_registry", [r"docker", r"registry", r"denied: requested access", r"unauthorized: authentication required"], "Check Docker build/push and registry credentials."),
    ("nexus", [r"nexus", r"artifact transfer failed", r"return code is: 5\d\d", r"return code is: 4\d\d"], "Check Nexus availability, credentials, and artifact permissions."),
    ("timeout_cancelled", [r"aborted", r"timeout", r"timed out", r"cancelled"], "Check build timeout/cancellation reason before retrying."),
]

category = "unknown"
summary = "Jenkins build failed. Review the console log tail."
action = "Inspect LOG_FILE and fix the failing build input before retrying."

for candidate, patterns, suggested in checks:
    for pattern in patterns:
        match = re.search(pattern, lower, re.MULTILINE)
        if match:
            category = candidate
            action = suggested
            for line in tail:
                if re.search(pattern, line.lower()):
                    summary = line.strip()[:240] or summary
                    break
            break
    if category != "unknown":
        break

summary = summary.replace("\n", " ").replace("\r", " ")
action = action.replace("\n", " ").replace("\r", " ")
print(f"FAILURE_CATEGORY={category}")
print(f"FAILURE_SUMMARY={summary}")
print(f"SUGGESTED_ACTION={action}")
PY
}

BUILD_URL=""
MAX_LINES=400

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-url)
      require_value "$1" "${2:-}"
      BUILD_URL="$2"
      shift 2
      ;;
    --max-lines)
      require_value "$1" "${2:-}"
      MAX_LINES="$2"
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

[[ -n "$BUILD_URL" ]] || error_exit "Missing required argument: --build-url" "build URL"
[[ "$MAX_LINES" =~ ^[0-9]+$ ]] || error_exit "--max-lines must be a number" "max lines"
[[ -n "${JENKINS_USER:-}" ]] || error_exit "Missing required environment variable: JENKINS_USER" "JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || error_exit "Missing required environment variable: JENKINS_TOKEN" "JENKINS_TOKEN"
command -v curl >/dev/null 2>&1 || error_exit "curl is required but was not found" "curl"
command -v python3 >/dev/null 2>&1 || error_exit "python3 is required but was not found" "python3"

LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/jenkins-console.XXXXXX.log")"
ERROR_FILE="$(mktemp "${TMPDIR:-/tmp}/jenkins-console-curl.XXXXXX.err")"

if ! curl --silent --show-error --fail --user "${JENKINS_USER}:${JENKINS_TOKEN}" --output "$LOG_FILE" "${BUILD_URL%/}/consoleText" 2>"$ERROR_FILE"; then
  message="$(tr '\n' ' ' <"$ERROR_FILE" | sed 's/[[:space:]]\+/ /g')"
  rm -f "$ERROR_FILE"
  error_exit "Failed to download Jenkins console log: ${message}" "Jenkins access"
fi

rm -f "$ERROR_FILE"

echo "STATUS=ERROR"
analyze_log "$LOG_FILE" "$MAX_LINES"
echo "LOG_FILE=${LOG_FILE}"
