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

temp_file_error() {
  echo "STATUS=ERROR"
  echo "FAILURE_CATEGORY=wrapper"
  echo "FAILURE_SUMMARY=Failed to create temporary console log file"
  echo "LOG_FILE="
  echo "SUGGESTED_ACTION=check temporary directory access"
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "${option}"
}

create_temp_file() {
  local prefix="$1"
  local temp_root="${TMPDIR:-/tmp}"
  mktemp "${temp_root%/}/${prefix}.XXXXXX" 2>/dev/null || mktemp -t "$prefix" 2>/dev/null
}

create_temp_log() {
  create_temp_file "jenkins-console"
}

sanitize_error() {
  local file="$1"
  tr '\n' ' ' <"$file" | sed 's/[[:space:]]\+/ /g'
}

url_host() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.urlparse(sys.argv[1]).hostname or "")
PY
}

resolve_location() {
  python3 - "$1" "$2" <<'PY'
import sys
import urllib.parse

print(urllib.parse.urljoin(sys.argv[1], sys.argv[2]))
PY
}

is_approved_jenkins_host() {
  case "$(url_host "$1")" in
    aipay.ci.jenkins.sberbank.ru|ci.jenkins.sberbank.ru)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

header_value() {
  local header_file="$1"
  local header_name="$2"
  awk -v name="$header_name" '
    BEGIN { IGNORECASE = 1 }
    index($0, name ":") == 1 {
      sub(/\r$/, "")
      sub("^[^:]+:[[:space:]]*", "")
      print
      exit
    }
  ' "$header_file"
}

download_console_text() {
  local url="$1"
  local output_file="$2"
  local header_file="$3"
  local error_file="$4"
  local current_url="$url"
  local redirects=0
  local http_status

  while :; do
    : >"$output_file"
    : >"$header_file"
    : >"$error_file"

    set +e
    http_status="$(
      curl --silent --show-error --globoff \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        --dump-header "$header_file" \
        --output "$output_file" \
        --write-out "%{http_code}" \
        "$current_url" 2>"$error_file"
    )"
    local curl_rc=$?
    set -e

    if [[ $curl_rc -ne 0 ]]; then
      CURL_HTTP_STATUS="${http_status:-000}"
      CURL_ERROR="$(sanitize_error "$error_file")"
      return 1
    fi

    case "$http_status" in
      301|302|303|307|308)
        redirects=$((redirects + 1))
        if (( redirects > 5 )); then
          CURL_HTTP_STATUS="$http_status"
          CURL_ERROR="Jenkins redirect limit exceeded"
          return 1
        fi
        local location
        location="$(header_value "$header_file" "Location")"
        if [[ -z "$location" ]]; then
          CURL_HTTP_STATUS="$http_status"
          CURL_ERROR="Jenkins redirect response did not include Location"
          return 1
        fi
        current_url="$(resolve_location "$current_url" "$location")"
        if ! is_approved_jenkins_host "$current_url"; then
          CURL_HTTP_STATUS="$http_status"
          CURL_ERROR="Jenkins redirect target is not approved"
          return 1
        fi
        continue
        ;;
      200)
        CURL_HTTP_STATUS="$http_status"
        CURL_ERROR=""
        return 0
        ;;
      *)
        CURL_HTTP_STATUS="$http_status"
        CURL_ERROR=""
        return 1
        ;;
    esac
  done
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

run_self_tests() {
  local tmp bin mock_curl mock_mktemp log1 log2 output rc old_file
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  mkdir -p "$bin" "$tmp/var/folders/s9/test/T"
  mock_curl="$bin/curl"
  mock_mktemp="$bin/mktemp"
  old_file="$tmp/var/folders/s9/test/T/jenkins-console.ABCDEF"
  printf 'old log\n' >"$old_file"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
output=""
headers=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --user) shift 2 ;;
    --silent|--show-error|--globoff) shift ;;
    *) url="$1"; shift ;;
  esac
done

: >"$headers"
mkdir -p "$(dirname "$output")"
case "${JENKINS_ANALYZE_FAILURE_TEST_SCENARIO:-success}" in
  empty)
    : >"$output"
    printf '200'
    exit 0
    ;;
  success)
    if [[ "$url" == https://aipay.ci.jenkins.sberbank.ru/* ]]; then
      printf 'Location: https://ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-build/1/consoleText\r\n' >"$headers"
      : >"$output"
      printf '302'
      exit 0
    fi
    cat >"$output" <<'LOG'
[INFO] Build started
[ERROR] COMPILATION ERROR
[ERROR] cannot find symbol
LOG
    printf '200'
    exit 0
    ;;
esac

printf 'unexpected scenario' >&2
printf '500'
exit 0
EOF

  chmod +x "$mock_curl"

  run_success() {
    PATH="$bin:$PATH" \
    ENV_FILE=/tmp/nonexistent-jenkins-skill-env \
    TMPDIR="$tmp/var/folders/s9/test/T/" \
    JENKINS_USER=dummy \
    JENKINS_TOKEN=dummy \
    JENKINS_ANALYZE_FAILURE_TEST_SCENARIO=success \
    bash "$0" --build-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-build/1" --max-lines 20
  }

  output="$(run_success)"
  grep -q "STATUS=ERROR" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL success status"; exit 1; }
  grep -q "FAILURE_CATEGORY=compilation" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL compilation category"; exit 1; }
  log1="$(sed -n 's/^LOG_FILE=//p' <<<"$output" | tail -n 1)"
  [[ -n "$log1" && -s "$log1" ]] || { printf '%s\n' "$output"; echo "FAIL log file missing"; exit 1; }
  [[ "$log1" != *.log ]] || { printf '%s\n' "$output"; echo "FAIL log file suffix"; exit 1; }

  output="$(run_success)"
  log2="$(sed -n 's/^LOG_FILE=//p' <<<"$output" | tail -n 1)"
  [[ -n "$log2" && -s "$log2" ]] || { printf '%s\n' "$output"; echo "FAIL second log file missing"; exit 1; }
  [[ "$log1" != "$log2" ]] || { echo "FAIL log files are not unique"; exit 1; }
  [[ -f "$old_file" ]] || { echo "FAIL old temp file removed"; exit 1; }

  set +e
  output="$(
    PATH="$bin:$PATH" \
    ENV_FILE=/tmp/nonexistent-jenkins-skill-env \
    TMPDIR="$tmp/var/folders/s9/test/T/" \
    JENKINS_USER=dummy \
    JENKINS_TOKEN=dummy \
    JENKINS_ANALYZE_FAILURE_TEST_SCENARIO=empty \
    bash "$0" --build-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-build/1"
  )"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { printf '%s\n' "$output"; echo "FAIL empty console accepted"; exit 1; }
  grep -q "FAILURE_SUMMARY=Jenkins console log is empty" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL empty console summary"; exit 1; }

  cat >"$mock_mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$mock_mktemp"
  set +e
  output="$(
    PATH="$bin:$PATH" \
    ENV_FILE=/tmp/nonexistent-jenkins-skill-env \
    TMPDIR="$tmp/var/folders/s9/test/T/" \
    JENKINS_USER=dummy \
    JENKINS_TOKEN=dummy \
    bash "$0" --build-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI/job/test-build/1"
  )"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { printf '%s\n' "$output"; echo "FAIL mktemp failure accepted"; exit 1; }
  grep -q "FAILURE_SUMMARY=Failed to create temporary console log file" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL mktemp failure summary"; exit 1; }

  echo "JENKINS_ANALYZE_FAILURE_SELF_TESTS=OK"
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
    --self-test)
      run_self_tests
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

LOG_FILE="$(create_temp_log)" || temp_file_error
HEADER_FILE="$(create_temp_file "jenkins-console-headers")" || temp_file_error
ERROR_FILE="$(create_temp_file "jenkins-console-curl")" || temp_file_error

if ! download_console_text "${BUILD_URL%/}/consoleText" "$LOG_FILE" "$HEADER_FILE" "$ERROR_FILE"; then
  rm -f "$HEADER_FILE" "$ERROR_FILE"
  if [[ -n "${CURL_ERROR:-}" ]]; then
    error_exit "Failed to download Jenkins console log: ${CURL_ERROR}" "Jenkins console access"
  fi
  error_exit "Failed to download Jenkins console log: HTTP ${CURL_HTTP_STATUS:-}" "Jenkins console access"
fi

rm -f "$HEADER_FILE" "$ERROR_FILE"

if [[ ! -s "$LOG_FILE" ]]; then
  echo "STATUS=ERROR"
  echo "FAILURE_CATEGORY=wrapper"
  echo "FAILURE_SUMMARY=Jenkins console log is empty"
  echo "LOG_FILE=${LOG_FILE}"
  echo "SUGGESTED_ACTION=check Jenkins consoleText access"
  exit 1
fi

echo "STATUS=ERROR"
analyze_log "$LOG_FILE" "$MAX_LINES"
echo "LOG_FILE=${LOG_FILE}"
