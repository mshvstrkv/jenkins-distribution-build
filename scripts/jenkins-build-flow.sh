#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

LOOKUP_WRAPPER="${JENKINS_BUILD_FLOW_LOOKUP_WRAPPER:-$SCRIPT_DIR/jenkins-lookup.sh}"
VERSION_WRAPPER="${JENKINS_BUILD_FLOW_VERSION_WRAPPER:-$SCRIPT_DIR/version-resolver.sh}"
BUILD_WRAPPER="${JENKINS_BUILD_FLOW_BUILD_WRAPPER:-$SCRIPT_DIR/jenkins-build.sh}"
ANALYZE_WRAPPER="${JENKINS_BUILD_FLOW_ANALYZE_WRAPPER:-$SCRIPT_DIR/jenkins-analyze-failure.sh}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/jenkins-build-flow.sh \
    --execution-environment <local|corporate> \
    --jenkins-url <url> \
    --project-name <name> \
    --branch <branch> \
    --distribution-type <ift|release|test|testing|prod|production> \
    [--job-name <exact-job-name>] \
    [--version <explicit-version>] \
    [--jenkins-branch-param <name>] \
    [--jenkins-version-param <name>] \
    [--jenkins-distribution-type-param <name>] \
    [--wait] \
    [--timeout-seconds <number>] \
    [--dry-run] \
    [--self-test]
EOF
}

emit_flow_output() {
  echo "STATUS=${STATUS:-}"
  echo "ACTION=build"
  echo "PROJECT_NAME=${PROJECT_NAME:-}"
  echo "BRANCH=${BRANCH:-}"
  echo "JENKINS_URL=${JENKINS_URL:-}"
  echo "JOB_NAME=${JOB_NAME:-}"
  echo "JOB_URL=${JOB_URL:-}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE:-}"
  echo "PREVIOUS_VERSION=${PREVIOUS_VERSION:-}"
  echo "VERSION=${VERSION:-}"
  echo "VERSION_SOURCE=${VERSION_SOURCE:-}"
  echo "QUEUE_URL=${QUEUE_URL:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "RESULT=${RESULT:-}"
  echo "FAILURE_CATEGORY=${FAILURE_CATEGORY:-}"
  echo "FAILURE_SUMMARY=${FAILURE_SUMMARY:-}"
  echo "SUGGESTED_ACTION=${SUGGESTED_ACTION:-}"
  echo "NEXT_REQUIRED_INPUT=${NEXT_REQUIRED_INPUT:-}"
  echo "MUTATIONS_PERFORMED=${MUTATIONS_PERFORMED:-false}"
}

flow_error() {
  STATUS="ERROR"
  NEXT_REQUIRED_INPUT="${2:-}"
  FAILURE_CATEGORY="wrapper"
  FAILURE_SUMMARY="$1"
  SUGGESTED_ACTION="${3:-Fix wrapper input and retry.}"
  MUTATIONS_PERFORMED=false
  emit_flow_output
  exit 1
}

normalize_type_with_python() {
  PYTHONPATH="$SKILL_ROOT" python3 - "$1" <<'PY'
import sys
from scripts.lib.distribution.versioning import normalize_distribution_type
print(normalize_distribution_type(sys.argv[1]))
PY
}

default_version_with_python() {
  PYTHONPATH="$SKILL_ROOT" python3 - "$1" <<'PY'
import sys
from scripts.lib.distribution.versioning import resolve_version
print(resolve_version(sys.argv[1], []).version)
PY
}

run_flow_self_tests() {
  local tmp log output rc
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/lookup.sh" <<'EOF'
#!/usr/bin/env bash
printf 'lookup %s\n' "$*" >>"$JENKINS_BUILD_FLOW_TEST_LOG"
echo "STATUS=OK"
echo "ACTION=lookup"
echo "PROJECT_NAME=test-project"
echo "BRANCH=develop"
echo "JOB_NAME=test-project-build"
echo "JOB_URL=https://example.invalid/job/folder/job/test-project-build"
echo "JENKINS_URL=https://example.invalid/job/folder"
echo "EXISTS=true"
echo "NEXT_REQUIRED_INPUT="
EOF

  cat >"$tmp/version.sh" <<'EOF'
#!/usr/bin/env bash
printf 'version %s\n' "$*" >>"$JENKINS_BUILD_FLOW_TEST_LOG"
echo "STATUS=OK"
echo "ACTION=resolve-version"
echo "PROJECT_NAME=test-project"
echo "DISTRIBUTION_TYPE=ift"
echo "PREVIOUS_VERSION="
echo "VERSION=IFT-0.0.1"
echo "VERSION_SOURCE=default"
echo "NEXT_REQUIRED_INPUT="
echo "MUTATIONS_PERFORMED=false"
EOF

  cat >"$tmp/build.sh" <<'EOF'
#!/usr/bin/env bash
printf 'build %s\n' "$*" >>"$JENKINS_BUILD_FLOW_TEST_LOG"
case " $* " in
  *" --skip-lookup "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=missing --skip-lookup"; exit 1 ;;
esac
echo "STATUS=OK"
echo "ACTION=reused"
echo "PROJECT_NAME=test-project"
echo "BRANCH=develop"
echo "JENKINS_URL=https://example.invalid/job/folder"
echo "JOB_NAME=test-project-build"
echo "JOB_URL=https://example.invalid/job/folder/job/test-project-build"
echo "DISTRIBUTION_TYPE=ift"
echo "PREVIOUS_VERSION="
echo "VERSION=IFT-0.0.1"
echo "VERSION_SOURCE=default"
echo "QUEUE_URL=https://example.invalid/queue/item/1/"
echo "BUILD_URL=https://example.invalid/job/folder/job/test-project-build/1/"
echo "RESULT=SUCCESS"
echo "NEXT_REQUIRED_INPUT="
EOF

  chmod +x "$tmp/lookup.sh" "$tmp/version.sh" "$tmp/build.sh"

  set +e
  output="$(
    JENKINS_BUILD_FLOW_TEST_LOG="$log" \
    JENKINS_BUILD_FLOW_LOOKUP_WRAPPER="$tmp/lookup.sh" \
    JENKINS_BUILD_FLOW_VERSION_WRAPPER="$tmp/version.sh" \
    JENKINS_BUILD_FLOW_BUILD_WRAPPER="$tmp/build.sh" \
    JENKINS_USER=dummy \
    JENKINS_TOKEN=dummy \
    bash "$0" \
      --execution-environment corporate \
      --jenkins-url "https://example.invalid/job/folder" \
      --project-name test-project \
      --branch develop \
      --distribution-type ift \
      --job-name test-project-build \
      --wait
  )"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || { printf '%s\n' "$output"; exit 1; }
  [[ "$(sed -n '1s/ .*//p' "$log")" == "lookup" ]] || { echo "FAIL call sequence lookup"; exit 1; }
  [[ "$(sed -n '2s/ .*//p' "$log")" == "version" ]] || { echo "FAIL call sequence version"; exit 1; }
  [[ "$(sed -n '3s/ .*//p' "$log")" == "build" ]] || { echo "FAIL call sequence build"; exit 1; }
  grep -q -- "--skip-lookup" "$log" || { echo "FAIL build missing --skip-lookup"; exit 1; }
  grep -q "STATUS=OK" <<<"$output" || { echo "FAIL flow output status"; exit 1; }
  echo "JENKINS_BUILD_FLOW_SELF_TESTS=OK"
}

load_skill_env

EXECUTION_ENVIRONMENT="${EXECUTION_ENVIRONMENT:-local}"
EXECUTION_ENVIRONMENT_CLI=""
JENKINS_URL=""
PROJECT_NAME=""
BRANCH=""
JOB_NAME_ARG=""
DISTRIBUTION_TYPE=""
VERSION=""
JENKINS_BRANCH_PARAM="BRANCH"
JENKINS_VERSION_PARAM="VERSION"
JENKINS_DISTRIBUTION_TYPE_PARAM="DISTRIBUTION_TYPE"
WAIT=false
TIMEOUT_SECONDS=1800
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_flow_self_tests; exit 0 ;;
    --execution-environment) require_value "$1" "${2:-}"; EXECUTION_ENVIRONMENT_CLI="$2"; shift 2 ;;
    --jenkins-url) require_value "$1" "${2:-}"; JENKINS_URL="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME_ARG="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --jenkins-branch-param) require_value "$1" "${2:-}"; JENKINS_BRANCH_PARAM="$2"; shift 2 ;;
    --jenkins-version-param) require_value "$1" "${2:-}"; JENKINS_VERSION_PARAM="$2"; shift 2 ;;
    --jenkins-distribution-type-param) require_value "$1" "${2:-}"; JENKINS_DISTRIBUTION_TYPE_PARAM="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    --timeout-seconds) require_value "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) flow_error "Unknown argument: $1" "$1" ;;
  esac
done

if [[ -n "$EXECUTION_ENVIRONMENT_CLI" ]]; then
  EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT_CLI"
fi
case "$EXECUTION_ENVIRONMENT" in
  local|corporate) ;;
  *) flow_error "Unsupported execution environment: ${EXECUTION_ENVIRONMENT}" "local or corporate" ;;
esac
[[ -n "$JENKINS_URL" ]] || flow_error "Missing required argument: --jenkins-url" "Jenkins URL"
[[ -n "$PROJECT_NAME" ]] || flow_error "Missing required argument: --project-name" "project name"
[[ -n "$BRANCH" ]] || flow_error "Missing required argument: --branch" "branch"
[[ -n "$DISTRIBUTION_TYPE" ]] || flow_error "Missing required argument: --distribution-type" "distribution type"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || flow_error "--timeout-seconds must be a number" "timeout seconds"
if ! DISTRIBUTION_TYPE="$(normalize_type_with_python "$DISTRIBUTION_TYPE")"; then
  flow_error "Unsupported distribution type" "ift or release"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$DRY_RUN" == "true" ]]; then
  JOB_NAME="${JOB_NAME_ARG:-$PROJECT_NAME}"
  JOB_URL="${JENKINS_URL%/}/job/${JOB_NAME}"
  if [[ -n "$VERSION" ]]; then
    VERSION_SOURCE="manual"
  else
    VERSION="$(default_version_with_python "$DISTRIBUTION_TYPE")"
    VERSION_SOURCE="default"
  fi
  STATUS="OK"
  RESULT="dry-run"
  MUTATIONS_PERFORMED=false
  emit_flow_output
  exit 0
fi

if [[ "$EXECUTION_ENVIRONMENT" != "corporate" ]]; then
  STATUS="ERROR"
  NEXT_REQUIRED_INPUT="run inside corporate network"
  FAILURE_CATEGORY="environment"
  FAILURE_SUMMARY="This operation requires corporate network access"
  SUGGESTED_ACTION="Run inside corporate network."
  MUTATIONS_PERFORMED=false
  emit_flow_output
  exit 1
fi

LOOKUP_OUTPUT="$WORK_DIR/jenkins-lookup.out"
lookup_args=(
  "$LOOKUP_WRAPPER"
  --execution-environment "$EXECUTION_ENVIRONMENT"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --branch "$BRANCH"
)
[[ -n "$JOB_NAME_ARG" ]] && lookup_args+=(--job-name "$JOB_NAME_ARG")
run_and_capture "$LOOKUP_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${lookup_args[@]}" || exit 1
JOB_NAME="$(value_from_output JOB_NAME "$LOOKUP_OUTPUT")"
JOB_URL="$(value_from_output JOB_URL "$LOOKUP_OUTPUT")"

VERSION_OUTPUT="$WORK_DIR/version.out"
version_args=(
  "$VERSION_WRAPPER"
  --execution-environment "$EXECUTION_ENVIRONMENT"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --job-name "$JOB_NAME"
  --distribution-type "$DISTRIBUTION_TYPE"
)
[[ -n "$VERSION" ]] && version_args+=(--version "$VERSION")
run_and_capture "$VERSION_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${version_args[@]}" || exit 1
DISTRIBUTION_TYPE="$(value_from_output DISTRIBUTION_TYPE "$VERSION_OUTPUT")"
PREVIOUS_VERSION="$(value_from_output PREVIOUS_VERSION "$VERSION_OUTPUT")"
VERSION="$(value_from_output VERSION "$VERSION_OUTPUT")"
VERSION_SOURCE="$(value_from_output VERSION_SOURCE "$VERSION_OUTPUT")"

BUILD_OUTPUT="$WORK_DIR/jenkins-build.out"
build_args=(
  "$BUILD_WRAPPER"
  --execution-environment "$EXECUTION_ENVIRONMENT"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --branch "$BRANCH"
  --job-name "$JOB_NAME"
  --skip-lookup
  --distribution-type "$DISTRIBUTION_TYPE"
  --version "$VERSION"
  --jenkins-branch-param "$JENKINS_BRANCH_PARAM"
  --jenkins-version-param "$JENKINS_VERSION_PARAM"
  --jenkins-distribution-type-param "$JENKINS_DISTRIBUTION_TYPE_PARAM"
  --timeout-seconds "$TIMEOUT_SECONDS"
)
[[ "$WAIT" == "true" ]] && build_args+=(--wait)
run_and_capture "$BUILD_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "${build_args[@]}" || exit 1

STATUS="$(value_from_output STATUS "$BUILD_OUTPUT")"
JOB_URL="$(value_from_output JOB_URL "$BUILD_OUTPUT")"
QUEUE_URL="$(value_from_output QUEUE_URL "$BUILD_OUTPUT")"
BUILD_URL="$(value_from_output BUILD_URL "$BUILD_OUTPUT")"
RESULT="$(value_from_output RESULT "$BUILD_OUTPUT")"
VERSION="$(value_from_output VERSION "$BUILD_OUTPUT")"
VERSION_SOURCE="$(value_from_output VERSION_SOURCE "$BUILD_OUTPUT")"
PREVIOUS_VERSION="$(value_from_output PREVIOUS_VERSION "$BUILD_OUTPUT")"
MUTATIONS_PERFORMED=true

case "$RESULT" in
  ""|SUCCESS|dry-run)
    ;;
  FAILURE|UNSTABLE|ABORTED)
    ANALYZE_OUTPUT="$WORK_DIR/jenkins-analyze.out"
    run_and_capture "$ANALYZE_OUTPUT" env EXECUTION_ENVIRONMENT="$EXECUTION_ENVIRONMENT" bash "$ANALYZE_WRAPPER" --build-url "$BUILD_URL" --max-lines 400 || true
    FAILURE_CATEGORY="$(value_from_output FAILURE_CATEGORY "$ANALYZE_OUTPUT")"
    FAILURE_SUMMARY="$(value_from_output FAILURE_SUMMARY "$ANALYZE_OUTPUT")"
    SUGGESTED_ACTION="$(value_from_output SUGGESTED_ACTION "$ANALYZE_OUTPUT")"
    STATUS="ERROR"
    emit_flow_output
    exit 1
    ;;
esac

emit_flow_output
