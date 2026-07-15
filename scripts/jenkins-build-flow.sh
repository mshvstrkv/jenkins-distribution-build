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
    [--jenkins-url <url>] \
    [--project-name <name>] \
    [--project-dir <path>] \
    [--branch <branch>] \
    [--template-job <job-name>] \
    [--repository-url <url>] \
    --distribution-type <ift|release|test|testing|prod|production> \
    [--job-name <exact-job-name>] \
    [--version <explicit-version>] \
    [--jenkins-branch-param <name>] \
    [--jenkins-version-param <name>] \
    [--jenkins-distribution-type-param <name>] \
    [--wait] \
    [--recovery-window-seconds <number>] \
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
  echo "TRIGGER_URL=${TRIGGER_URL:-}"
  echo "QUEUE_URL=${QUEUE_URL:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-}"
  echo "RESULT=${RESULT:-}"
  echo "BUILDING=${BUILDING:-}"
  echo "STATUS_VERIFIED=${STATUS_VERIFIED:-false}"
  echo "STATUS_VERIFIED_AT=${STATUS_VERIFIED_AT:-}"
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
  local tmp log output rc project_repo skill_root
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  project_repo="$tmp/application-service"
  skill_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$project_repo"
  git -C "$project_repo" init >/dev/null
  git -C "$project_repo" config user.email test@example.com
  git -C "$project_repo" config user.name 'Test User'
  printf 'app\n' >"$project_repo/README.md"
  git -C "$project_repo" add README.md
  git -C "$project_repo" commit -m initial >/dev/null
  git -C "$project_repo" checkout -b feature/context >/dev/null
  git -C "$project_repo" remote add origin ssh://git@example.org/team/application-service.git

  PROJECT_DIR="$project_repo"
  PROJECT_NAME=""
  BRANCH=""
  REPOSITORY_URL=""
  resolve_project_name
  resolve_branch
  resolve_repository_url
  [[ "$PROJECT_NAME" == "application-service" ]] || { echo "FAIL project name resolver"; exit 1; }
  [[ "$BRANCH" == "feature/context" ]] || { echo "FAIL branch resolver"; exit 1; }
  [[ "$REPOSITORY_URL" == "ssh://git@example.org/team/application-service.git" ]] || { echo "FAIL repository resolver"; exit 1; }
  PROJECT_NAME=""
  BRANCH=""
  REPOSITORY_URL=""

  cat >"$tmp/lookup.sh" <<'EOF'
#!/usr/bin/env bash
printf 'lookup %s\n' "$*" >>"$JENKINS_BUILD_FLOW_TEST_LOG"
case " $* " in
  *" --project-name application-service "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=wrong project name"; exit 1 ;;
esac
case " $* " in
  *" --project-dir $PROJECT_REPO "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=wrong project dir"; exit 1 ;;
esac
case " $* " in
  *" --branch feature/context "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=wrong branch"; exit 1 ;;
esac
echo "STATUS=OK"
echo "ACTION=lookup"
echo "PROJECT_NAME=application-service"
echo "BRANCH=feature/context"
echo "JOB_NAME=application-service-build"
echo "JOB_URL=https://example.invalid/job/folder/job/application-service-build"
echo "JENKINS_URL=https://example.invalid/job/folder"
echo "EXISTS=${JENKINS_BUILD_FLOW_LOOKUP_EXISTS:-true}"
echo "NEXT_REQUIRED_INPUT="
EOF

  cat >"$tmp/version.sh" <<'EOF'
#!/usr/bin/env bash
printf 'version %s\n' "$*" >>"$JENKINS_BUILD_FLOW_TEST_LOG"
case " $* " in
  *" --project-name application-service "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=project name not propagated to version"; exit 1 ;;
esac
case " $* " in
  *" --project-dir $PROJECT_REPO "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=project dir not propagated to version"; exit 1 ;;
esac
echo "STATUS=OK"
echo "ACTION=resolve-version"
echo "PROJECT_NAME=application-service"
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
if [[ "${JENKINS_BUILD_FLOW_LOOKUP_EXISTS:-true}" == "true" ]]; then
  case " $* " in
    *" --existing-job "*) ;;
    *) echo "STATUS=ERROR"; echo "REASON=missing --existing-job"; exit 1 ;;
  esac
  case " $* " in
    *" --template-job "*) echo "STATUS=ERROR"; echo "REASON=template passed for existing job"; exit 1 ;;
  esac
else
  case " $* " in
    *" --create-if-missing "*) ;;
    *) echo "STATUS=ERROR"; echo "REASON=missing --create-if-missing"; exit 1 ;;
  esac
  case " $* " in
    *" --template-job template-job "*) ;;
    *) echo "STATUS=ERROR"; echo "REASON=missing template for create"; exit 1 ;;
  esac
fi
case " $* " in
  *" --project-name application-service "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=project name not propagated to build"; exit 1 ;;
esac
case " $* " in
  *" --project-dir $PROJECT_REPO "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=project dir not propagated to build"; exit 1 ;;
esac
case " $* " in
  *" --branch feature/context "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=branch not propagated to build"; exit 1 ;;
esac
case " $* " in
  *" --job-name application-service-build "*) ;;
  *) echo "STATUS=ERROR"; echo "REASON=job name not propagated to build"; exit 1 ;;
esac
echo "STATUS=OK"
echo "ACTION=reused"
echo "PROJECT_NAME=application-service"
echo "BRANCH=feature/context"
echo "JENKINS_URL=https://example.invalid/job/folder"
echo "JOB_NAME=application-service-build"
echo "JOB_URL=https://example.invalid/job/folder/job/application-service-build"
echo "DISTRIBUTION_TYPE=ift"
echo "PREVIOUS_VERSION="
echo "VERSION=IFT-0.0.1"
echo "VERSION_SOURCE=default"
echo "TRIGGER_URL=https://example.invalid/job/folder/job/application-service-build/buildWithParameters"
echo "QUEUE_URL=https://example.invalid/queue/item/1/"
echo "BUILD_URL=https://example.invalid/job/folder/job/application-service-build/1/"
echo "RESULT=SUCCESS"
echo "NEXT_REQUIRED_INPUT="
EOF

  chmod +x "$tmp/lookup.sh" "$tmp/version.sh" "$tmp/build.sh"

  set +e
  output="$(
    cd "$skill_root" && \
    ENV_FILE=/dev/null \
    PROJECT_REPO="$project_repo" \
    JENKINS_BUILD_FLOW_TEST_LOG="$log" \
    JENKINS_BUILD_FLOW_LOOKUP_WRAPPER="$tmp/lookup.sh" \
    JENKINS_BUILD_FLOW_VERSION_WRAPPER="$tmp/version.sh" \
	    JENKINS_BUILD_FLOW_BUILD_WRAPPER="$tmp/build.sh" \
	    JENKINS_TEMPLATE_JOB=template-job \
	    JENKINS_USER=dummy \
    JENKINS_TOKEN=dummy \
    bash "$0" \
      --jenkins-url "https://example.invalid/job/folder" \
      --project-dir "$project_repo" \
      --distribution-type ift \
      --recovery-window-seconds 120 \
      --wait
  )"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || { printf '%s\n' "$output"; exit 1; }
  [[ "$(sed -n '1s/ .*//p' "$log")" == "lookup" ]] || { echo "FAIL call sequence lookup"; exit 1; }
  [[ "$(sed -n '2s/ .*//p' "$log")" == "version" ]] || { echo "FAIL call sequence version"; exit 1; }
  [[ "$(sed -n '3s/ .*//p' "$log")" == "build" ]] || { echo "FAIL call sequence build"; exit 1; }
  grep -q -- "--skip-lookup" "$log" || { echo "FAIL build missing --skip-lookup"; exit 1; }
  grep -q -- "--recovery-window-seconds 120" "$log" || { echo "FAIL build missing recovery window"; exit 1; }
	  grep -q "PROJECT_NAME=application-service" <<<"$output" || { echo "FAIL project name from project dir"; exit 1; }
	  grep -q "BRANCH=feature/context" <<<"$output" || { echo "FAIL branch from project dir"; exit 1; }
	  grep -q "JOB_NAME=application-service-build" <<<"$output" || { echo "FAIL job name from project"; exit 1; }

	  : >"$log"
	  set +e
	  output="$(
	    cd "$skill_root" && \
	    ENV_FILE=/dev/null \
	    PROJECT_REPO="$project_repo" \
	    JENKINS_BUILD_FLOW_LOOKUP_EXISTS=false \
	    JENKINS_BUILD_FLOW_TEST_LOG="$log" \
	    JENKINS_BUILD_FLOW_LOOKUP_WRAPPER="$tmp/lookup.sh" \
	    JENKINS_BUILD_FLOW_VERSION_WRAPPER="$tmp/version.sh" \
	    JENKINS_BUILD_FLOW_BUILD_WRAPPER="$tmp/build.sh" \
	    JENKINS_TEMPLATE_JOB=template-job \
	    JENKINS_USER=dummy \
	    JENKINS_TOKEN=dummy \
	    bash "$0" \
	      --jenkins-url "https://example.invalid/job/folder" \
	      --project-dir "$project_repo" \
	      --distribution-type ift \
	      --recovery-window-seconds 120 \
	      --wait
	  )"
	  rc=$?
	  set -e
	  [[ $rc -eq 0 ]] || { printf '%s\n' "$output"; exit 1; }
	  grep -q -- "--create-if-missing" "$log" || { echo "FAIL missing job build missing --create-if-missing"; exit 1; }
	  grep -q -- "--template-job template-job" "$log" || { echo "FAIL missing job build missing template"; exit 1; }

  set +e
  output="$(ENV_FILE=/dev/null bash "$0" --jenkins-url "https://example.invalid/job/folder" --distribution-type ift --dry-run 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL missing project-dir succeeded"; exit 1; }
  grep -q "STATE=project_directory_required" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL missing project-dir state"; exit 1; }

  echo "PROJECT_CONTEXT_PROPAGATED=OK"
  echo "PROJECT_NAME_FROM_PROJECT_DIR=OK"
  echo "REPOSITORY_FROM_PROJECT_DIR=OK"
  echo "SKILL_DIRECTORY_NEVER_USED_AS_PROJECT=OK"
  echo "JENKINS_JOB_FROM_PROJECT=OK"
  echo "JENKINS_BUILD_FLOW_SELF_TESTS=OK"
}


load_skill_env

JENKINS_URL="${JENKINS_URL:-}"
PROJECT_NAME=""
PROJECT_DIR="${PROJECT_DIR:-}"
BRANCH=""
JOB_NAME_ARG=""
TEMPLATE_JOB="${JENKINS_TEMPLATE_JOB:-}"
REPOSITORY_URL=""
DISTRIBUTION_TYPE=""
VERSION=""
JENKINS_BRANCH_PARAM="BRANCH"
JENKINS_VERSION_PARAM="VERSION"
JENKINS_DISTRIBUTION_TYPE_PARAM="DISTRIBUTION_TYPE"
WAIT=false
TIMEOUT_SECONDS=1800
RECOVERY_WINDOW_SECONDS=3600
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_flow_self_tests; exit 0 ;;
    --jenkins-url) require_value "$1" "${2:-}"; JENKINS_URL="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --project-dir) require_value "$1" "${2:-}"; PROJECT_DIR="$2"; shift 2 ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME_ARG="$2"; shift 2 ;;
    --template-job) require_value "$1" "${2:-}"; TEMPLATE_JOB="$2"; shift 2 ;;
    --repository-url) require_value "$1" "${2:-}"; REPOSITORY_URL="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --jenkins-branch-param) require_value "$1" "${2:-}"; JENKINS_BRANCH_PARAM="$2"; shift 2 ;;
    --jenkins-version-param) require_value "$1" "${2:-}"; JENKINS_VERSION_PARAM="$2"; shift 2 ;;
    --jenkins-distribution-type-param) require_value "$1" "${2:-}"; JENKINS_DISTRIBUTION_TYPE_PARAM="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    --recovery-window-seconds) require_value "$1" "${2:-}"; RECOVERY_WINDOW_SECONDS="$2"; shift 2 ;;
    --timeout-seconds) require_value "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) flow_error "Unknown argument: $1" "$1" ;;
  esac
done

resolve_jenkins_url
require_project_dir
resolve_project_name
resolve_branch
[[ -n "$DISTRIBUTION_TYPE" ]] || flow_error "Missing required argument: --distribution-type" "distribution type"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || flow_error "--timeout-seconds must be a number" "timeout seconds"
[[ "$RECOVERY_WINDOW_SECONDS" =~ ^[0-9]+$ ]] || flow_error "--recovery-window-seconds must be a number" "recovery window seconds"
if ! DISTRIBUTION_TYPE="$(normalize_type_with_python "$DISTRIBUTION_TYPE")"; then
  flow_error "Unsupported distribution type" "ift or release"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$DRY_RUN" == "true" ]]; then
  JOB_NAME="${JOB_NAME_ARG:-${PROJECT_NAME}-build}"
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

LOOKUP_OUTPUT="$WORK_DIR/jenkins-lookup.out"
lookup_args=(
  "$LOOKUP_WRAPPER"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --project-dir "$PROJECT_DIR"
  --branch "$BRANCH"
)
[[ -n "$JOB_NAME_ARG" ]] && lookup_args+=(--job-name "$JOB_NAME_ARG")
[[ -n "$TEMPLATE_JOB" ]] && lookup_args+=(--template-job "$TEMPLATE_JOB")
run_and_capture "$LOOKUP_OUTPUT" bash "${lookup_args[@]}" || exit 1
	JOB_NAME="$(value_from_output JOB_NAME "$LOOKUP_OUTPUT")"
	JOB_URL="$(value_from_output JOB_URL "$LOOKUP_OUTPUT")"
	LOOKUP_EXISTS="$(value_from_output EXISTS "$LOOKUP_OUTPUT")"

VERSION_OUTPUT="$WORK_DIR/version.out"
if [[ "$LOOKUP_EXISTS" == "false" && -z "$VERSION" ]]; then
  PREVIOUS_VERSION=""
  VERSION="$(default_version_with_python "$DISTRIBUTION_TYPE")"
  VERSION_SOURCE="default"
else
  version_args=(
    "$VERSION_WRAPPER"
    --jenkins-url "$JENKINS_URL"
    --project-name "$PROJECT_NAME"
    --project-dir "$PROJECT_DIR"
    --job-name "$JOB_NAME"
    --distribution-type "$DISTRIBUTION_TYPE"
  )
  [[ -n "$VERSION" ]] && version_args+=(--version "$VERSION")
  run_and_capture "$VERSION_OUTPUT" bash "${version_args[@]}" || exit 1
  DISTRIBUTION_TYPE="$(value_from_output DISTRIBUTION_TYPE "$VERSION_OUTPUT")"
  PREVIOUS_VERSION="$(value_from_output PREVIOUS_VERSION "$VERSION_OUTPUT")"
  VERSION="$(value_from_output VERSION "$VERSION_OUTPUT")"
  VERSION_SOURCE="$(value_from_output VERSION_SOURCE "$VERSION_OUTPUT")"
fi

BUILD_OUTPUT="$WORK_DIR/jenkins-build.out"
build_args=(
  "$BUILD_WRAPPER"
  --jenkins-url "$JENKINS_URL"
  --project-name "$PROJECT_NAME"
  --project-dir "$PROJECT_DIR"
  --branch "$BRANCH"
	  --job-name "$JOB_NAME"
	  --job-url "$JOB_URL"
	  --skip-lookup
	  --distribution-type "$DISTRIBUTION_TYPE"
  --version "$VERSION"
  --jenkins-branch-param "$JENKINS_BRANCH_PARAM"
  --jenkins-version-param "$JENKINS_VERSION_PARAM"
  --jenkins-distribution-type-param "$JENKINS_DISTRIBUTION_TYPE_PARAM"
  --recovery-window-seconds "$RECOVERY_WINDOW_SECONDS"
  --timeout-seconds "$TIMEOUT_SECONDS"
	)
	if [[ "$LOOKUP_EXISTS" == "false" ]]; then
	  [[ -n "$TEMPLATE_JOB" ]] || flow_error "Template job is required to create missing Jenkins job" "template job"
	  build_args+=(--template-job "$TEMPLATE_JOB" --create-if-missing)
	  [[ -n "$REPOSITORY_URL" ]] && build_args+=(--repository-url "$REPOSITORY_URL")
	else
	  build_args+=(--existing-job)
	fi
[[ "$WAIT" == "true" ]] && build_args+=(--wait)
run_and_capture "$BUILD_OUTPUT" bash "${build_args[@]}" || exit 1

STATUS="$(value_from_output STATUS "$BUILD_OUTPUT")"
JOB_URL="$(value_from_output JOB_URL "$BUILD_OUTPUT")"
TRIGGER_URL="$(value_from_output TRIGGER_URL "$BUILD_OUTPUT")"
QUEUE_URL="$(value_from_output QUEUE_URL "$BUILD_OUTPUT")"
BUILD_URL="$(value_from_output BUILD_URL "$BUILD_OUTPUT")"
BUILD_NUMBER="$(value_from_output BUILD_NUMBER "$BUILD_OUTPUT")"
RESULT="$(value_from_output RESULT "$BUILD_OUTPUT")"
BUILDING="$(value_from_output BUILDING "$BUILD_OUTPUT")"
STATUS_VERIFIED="$(value_from_output STATUS_VERIFIED "$BUILD_OUTPUT")"
STATUS_VERIFIED_AT="$(value_from_output STATUS_VERIFIED_AT "$BUILD_OUTPUT")"
VERSION="$(value_from_output VERSION "$BUILD_OUTPUT")"
VERSION_SOURCE="$(value_from_output VERSION_SOURCE "$BUILD_OUTPUT")"
PREVIOUS_VERSION="$(value_from_output PREVIOUS_VERSION "$BUILD_OUTPUT")"
MUTATIONS_PERFORMED=true

case "$RESULT" in
  ""|SUCCESS|dry-run)
    ;;
  FAILURE|UNSTABLE|ABORTED)
    ANALYZE_OUTPUT="$WORK_DIR/jenkins-analyze.out"
    run_and_capture "$ANALYZE_OUTPUT" bash "$ANALYZE_WRAPPER" --build-url "$BUILD_URL" --max-lines 400 || true
    FAILURE_CATEGORY="$(value_from_output FAILURE_CATEGORY "$ANALYZE_OUTPUT")"
    FAILURE_SUMMARY="$(value_from_output FAILURE_SUMMARY "$ANALYZE_OUTPUT")"
    SUGGESTED_ACTION="$(value_from_output SUGGESTED_ACTION "$ANALYZE_OUTPUT")"
    STATUS="ERROR"
    emit_flow_output
    exit 1
    ;;
esac

emit_flow_output
