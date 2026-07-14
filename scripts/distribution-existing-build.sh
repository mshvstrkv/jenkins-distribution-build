#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

STATUS_WRAPPER="${DISTRIBUTION_EXISTING_STATUS_WRAPPER:-$SCRIPT_DIR/jenkins-status.sh}"
DIGEST_WRAPPER="${DISTRIBUTION_EXISTING_DIGEST_WRAPPER:-$SCRIPT_DIR/jenkins-resolve-digest.sh}"
GITOPS_CHECK_WRAPPER="${DISTRIBUTION_EXISTING_GITOPS_CHECK_WRAPPER:-$SCRIPT_DIR/gitops-check.sh}"
GITOPS_UPDATE_WRAPPER="${DISTRIBUTION_EXISTING_GITOPS_UPDATE_WRAPPER:-$SCRIPT_DIR/gitops-update.sh}"
ARGO_CHECK_WRAPPER="${DISTRIBUTION_EXISTING_ARGO_CHECK_WRAPPER:-$SCRIPT_DIR/argocd-check.sh}"
ARGO_SYNC_WRAPPER="${DISTRIBUTION_EXISTING_ARGO_SYNC_WRAPPER:-$SCRIPT_DIR/argocd-sync.sh}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/distribution-existing-build.sh \
    (--build-url <url> | --job-name <job> --build-number <number>) \
    --version <exact-version> \
    --distribution-type <ift|release> \
    [--branch <branch>] \
    [--resume] \
    [--digest <exact-image-digest>] \
    [--no-extra-config-changes] \
    [--additional-config-changes-required] \
    [--additional-config-changes-file <approved-patch-file>] \
    [--approve-deployment] \
    [--dry-run] \
    [--self-test]
EOF
}

emit_error() {
  echo "STATUS=ERROR"
  echo "ACTION=deploy-existing"
  echo "STATE=${1:-}"
  echo "REASON=${2:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-}"
  echo "VERSION=${VERSION:-}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST:-}"
  echo "CONFIG_PATH=${CONFIG_PATH:-}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME:-}"
  echo "NEXT_REQUIRED_INPUT=${3:-}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

emit_paused_scope_question() {
  echo "STATUS=PAUSED"
  echo "ACTION=awaiting-config-scope"
  echo "DEPLOYMENT_MODE=${DEPLOYMENT_MODE}"
  echo "STANDARD_GITOPS_UPDATE_REQUIRED=true"
  echo "STANDARD_GITOPS_UPDATE_READY=true"
  echo "STANDARD_GITOPS_UPDATE_APPROVED_BY_REQUEST=true"
  echo "VERSION=${VERSION}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
  echo "BUILD_URL=${BUILD_URL}"
  echo "BUILD_NUMBER=${BUILD_NUMBER}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
  echo "NEXT_REQUIRED_INPUT=additional GitOps changes decision"
  echo "MUTATIONS_PERFORMED=false"
  exit 0
}

emit_paused_additional_changes() {
  echo "STATUS=PAUSED"
  echo "ACTION=awaiting-additional-config-changes"
  echo "STATE=additional_config_changes_required"
  echo "DEPLOYMENT_MODE=${DEPLOYMENT_MODE}"
  echo "STANDARD_GITOPS_UPDATE_READY=true"
  echo "VERSION=${VERSION}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
  echo "BUILD_URL=${BUILD_URL}"
  echo "BUILD_NUMBER=${BUILD_NUMBER}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
  echo "NEXT_REQUIRED_INPUT=exact additional GitOps configuration changes"
  echo "MUTATIONS_PERFORMED=false"
  exit 0
}

emit_success() {
  echo "STATUS=OK"
  echo "ACTION=deploy-existing"
  echo "PROJECT_NAME=${PROJECT_NAME:-}"
  echo "BRANCH=${BRANCH:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-}"
  echo "VERSION=${VERSION:-}"
  echo "DISTRIBUTION_TYPE=${DISTRIBUTION_TYPE:-}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST:-}"
  echo "CONFIG_PATH=${CONFIG_PATH:-}"
  echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME:-}"
  echo "DEPLOYMENT_MODE=${DEPLOYMENT_MODE:-}"
  echo "ADDITIONAL_CONFIG_CHANGES=${ADDITIONAL_CONFIG_CHANGES:-false}"
  echo "STANDARD_GITOPS_UPDATE_APPROVED_BY_REQUEST=${STANDARD_GITOPS_UPDATE_APPROVED_BY_REQUEST:-false}"
  echo "GITOPS_ACTION=${GITOPS_ACTION:-}"
  echo "GITOPS_PUSHED=${GITOPS_PUSHED:-false}"
  echo "ARGOCD_SYNC_STATUS=${ARGOCD_SYNC_STATUS:-}"
  echo "ARGOCD_HEALTH_STATUS=${ARGOCD_HEALTH_STATUS:-}"
  echo "MUTATIONS_PERFORMED=${MUTATIONS_PERFORMED:-false}"
}

apply_defaults() {
  if [[ "$ENVIRONMENT" == "ift" ]]; then
    CONFIG_REPO_URL="${CONFIG_REPO_URL:-ssh://git@sbrf-bitbucket.sigma.sbrf.ru:7999/ci11366566/ci11366566_sberaipay_gitopscd.git}"
    CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-ift}"
    CHARTS_PATH_TEMPLATE="${CHARTS_PATH_TEMPLATE:-charts/{{PROJECT_NAME}}}"
    CONFIG_PATH_TEMPLATE="${CONFIG_PATH_TEMPLATE:-stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}}"
    CONFIG_TEMPLATE_PATH_TEMPLATE="${CONFIG_TEMPLATE_PATH_TEMPLATE:-stands/ift/bdifb2y7-ai-payments/{{PROJECT_NAME}}}"
    ARGOCD_SERVER="${ARGOCD_SERVER:-argocd.apps.bbmwbllt.k8s.sigma.sbrf.ru}"
    ARGOCD_APP_NAME_TEMPLATE="${ARGOCD_APP_NAME_TEMPLATE:-bdifb2y7-{{PROJECT_NAME}}}"
    ARGOCD_PROJECT="${ARGOCD_PROJECT:-bdifb2y7.k8s.delta.sbrf.ru-ci11366566-sberaipay}"
    ARGOCD_DESTINATION_NAMESPACE="${ARGOCD_DESTINATION_NAMESPACE:-ci11366566-sberaipay}"
  fi
  [[ -n "$CHARTS_PATH" ]] || render_template_into CHARTS_PATH "$CHARTS_PATH_TEMPLATE" "charts path"
  [[ -n "$CONFIG_PATH" ]] || render_template_into CONFIG_PATH "$CONFIG_PATH_TEMPLATE" "config path"
  [[ -n "$CONFIG_TEMPLATE_PATH" ]] || render_template_into CONFIG_TEMPLATE_PATH "$CONFIG_TEMPLATE_PATH_TEMPLATE" "config template path"
  [[ -n "$ARGOCD_APP_NAME" ]] || render_template_into ARGOCD_APP_NAME "$ARGOCD_APP_NAME_TEMPLATE" "Argo CD app name"
}

run_self_tests() {
  local tmp log output
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  trap 'rm -rf "$tmp"' RETURN
  cat >"$tmp/status.sh" <<'EOF'
#!/usr/bin/env bash
printf 'status %s\n' "$*" >>"$DISTRIBUTION_EXISTING_TEST_LOG"
echo "STATUS=OK"
echo "ACTION=status"
echo "BUILD_URL=https://ci/job/x/47"
echo "BUILD_NUMBER=47"
echo "BRANCH=develop"
echo "VERSION=IFT-0.0.27"
echo "DISTRIBUTION_TYPE=ift"
echo "BUILDING=false"
echo "RESULT=SUCCESS"
echo "BUILD_STATUS_VERIFIED=true"
EOF
  cat >"$tmp/digest.sh" <<'EOF'
#!/usr/bin/env bash
printf 'digest %s\n' "$*" >>"$DISTRIBUTION_EXISTING_TEST_LOG"
echo "STATUS=OK"
echo "ACTION=resolve-digest"
echo "BUILD_URL=https://ci/job/x/47"
echo "BUILD_NUMBER=47"
echo "VERSION=IFT-0.0.27"
echo "IMAGE_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
echo "DIGEST_BUILD_IDENTITY_VERIFIED=true"
EOF
  for name in gitops-check argo-check; do
    cat >"$tmp/$name.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0" .sh)" "$*" >>"$DISTRIBUTION_EXISTING_TEST_LOG"
case "$(basename "$0")" in
  gitops-check.sh) echo "STATUS=OK"; echo "CONFIG_EXISTS=true"; echo "CONFIG_TEMPLATE_EXISTS=true" ;;
  argo-check.sh) echo "STATUS=OK"; echo "ARGOCD_APP_EXISTS=true"; echo "ARGOCD_DESTINATION_SERVER=https://cluster" ;;
esac
EOF
  done
cat >"$tmp/gitops-update.sh" <<'EOF'
#!/usr/bin/env bash
printf 'gitops-update %s\n' "$*" >>"$DISTRIBUTION_EXISTING_TEST_LOG"
echo "STATUS=OK"
echo "PUSH_COMPLETED=true"
echo "MUTATIONS_PERFORMED=true"
EOF
  cat >"$tmp/argocd-sync.sh" <<'EOF'
#!/usr/bin/env bash
printf 'argocd-sync %s\n' "$*" >>"$DISTRIBUTION_EXISTING_TEST_LOG"
echo "STATUS=OK"
echo "ARGOCD_SYNC_STATUS=Synced"
echo "ARGOCD_HEALTH_STATUS=Healthy"
echo "MUTATIONS_PERFORMED=true"
EOF
  chmod +x "$tmp"/*.sh
  output="$(
    DISTRIBUTION_EXISTING_TEST_LOG="$log" \
    DISTRIBUTION_EXISTING_STATUS_WRAPPER="$tmp/status.sh" \
    DISTRIBUTION_EXISTING_DIGEST_WRAPPER="$tmp/digest.sh" \
    DISTRIBUTION_EXISTING_GITOPS_CHECK_WRAPPER="$tmp/gitops-check.sh" \
    DISTRIBUTION_EXISTING_GITOPS_UPDATE_WRAPPER="$tmp/gitops-update.sh" \
    DISTRIBUTION_EXISTING_ARGO_CHECK_WRAPPER="$tmp/argo-check.sh" \
    DISTRIBUTION_EXISTING_ARGO_SYNC_WRAPPER="$tmp/argocd-sync.sh" \
    bash "$0" --build-url https://ci/job/x/47 --version IFT-0.0.27 --distribution-type ift
  )"
  grep -q "STATUS=PAUSED" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  grep -q "NEXT_REQUIRED_INPUT=additional GitOps changes decision" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  ! grep -q "gitops-update" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }
  ! grep -q "argocd-sync" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }

  : >"$log"
  output="$(
    DISTRIBUTION_EXISTING_TEST_LOG="$log" \
    DISTRIBUTION_EXISTING_STATUS_WRAPPER="$tmp/status.sh" \
    DISTRIBUTION_EXISTING_DIGEST_WRAPPER="$tmp/digest.sh" \
    DISTRIBUTION_EXISTING_GITOPS_CHECK_WRAPPER="$tmp/gitops-check.sh" \
    DISTRIBUTION_EXISTING_GITOPS_UPDATE_WRAPPER="$tmp/gitops-update.sh" \
    DISTRIBUTION_EXISTING_ARGO_CHECK_WRAPPER="$tmp/argo-check.sh" \
    DISTRIBUTION_EXISTING_ARGO_SYNC_WRAPPER="$tmp/argocd-sync.sh" \
    bash "$0" --build-url https://ci/job/x/47 --version IFT-0.0.27 --distribution-type ift --no-extra-config-changes
  )"
  grep -q "STATUS=OK" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  grep -q "ADDITIONAL_CONFIG_CHANGES=false" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  grep -q "GITOPS_PUSHED=true" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  grep -q "ARGOCD_SYNC_STATUS=Synced" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  ! grep -q "jenkins-build" "$log" || { echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }
  grep -q "gitops-update .*--version IFT-0.0.27 .*--digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }
  grep -q "gitops-update .*--approve" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }
  grep -q "argocd-sync .*--approve" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }

  : >"$log"
  output="$(
    DISTRIBUTION_EXISTING_TEST_LOG="$log" \
    DISTRIBUTION_EXISTING_STATUS_WRAPPER="$tmp/status.sh" \
    DISTRIBUTION_EXISTING_DIGEST_WRAPPER="$tmp/digest.sh" \
    DISTRIBUTION_EXISTING_GITOPS_CHECK_WRAPPER="$tmp/gitops-check.sh" \
    DISTRIBUTION_EXISTING_GITOPS_UPDATE_WRAPPER="$tmp/gitops-update.sh" \
    DISTRIBUTION_EXISTING_ARGO_CHECK_WRAPPER="$tmp/argo-check.sh" \
    DISTRIBUTION_EXISTING_ARGO_SYNC_WRAPPER="$tmp/argocd-sync.sh" \
    bash "$0" --build-url https://ci/job/x/47 --version IFT-0.0.27 --distribution-type ift --additional-config-changes-required
  )"
  grep -q "STATUS=PAUSED" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  grep -q "STATE=additional_config_changes_required" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  grep -q "NEXT_REQUIRED_INPUT=exact additional GitOps configuration changes" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  ! grep -q "gitops-update" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }

  : >"$log"
  output="$(
    DISTRIBUTION_EXISTING_TEST_LOG="$log" \
    DISTRIBUTION_EXISTING_STATUS_WRAPPER="$tmp/status.sh" \
    DISTRIBUTION_EXISTING_DIGEST_WRAPPER="$tmp/digest.sh" \
    DISTRIBUTION_EXISTING_GITOPS_CHECK_WRAPPER="$tmp/gitops-check.sh" \
    DISTRIBUTION_EXISTING_GITOPS_UPDATE_WRAPPER="$tmp/gitops-update.sh" \
    DISTRIBUTION_EXISTING_ARGO_CHECK_WRAPPER="$tmp/argo-check.sh" \
    DISTRIBUTION_EXISTING_ARGO_SYNC_WRAPPER="$tmp/argocd-sync.sh" \
    bash "$0" --resume --build-url https://ci/job/x/47 --version IFT-0.0.27 --distribution-type ift --digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --no-extra-config-changes
  )"
  grep -q "STATUS=OK" <<<"$output" || { printf '%s\n' "$output"; exit 1; }
  ! grep -q '^digest ' "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }
  ! grep -q "jenkins-build" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }
  ! grep -q "version-resolver" "$log" || { cat "$log"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }

  cat >"$tmp/argo-check.sh" <<'EOF'
#!/usr/bin/env bash
printf 'argo-check %s\n' "$*" >>"$DISTRIBUTION_EXISTING_TEST_LOG"
echo "STATUS=OK"
echo "ARGOCD_APP_EXISTS=false"
EOF
  chmod +x "$tmp/argo-check.sh"
  set +e
  output="$(
    DISTRIBUTION_EXISTING_TEST_LOG="$log" \
    DISTRIBUTION_EXISTING_STATUS_WRAPPER="$tmp/status.sh" \
    DISTRIBUTION_EXISTING_DIGEST_WRAPPER="$tmp/digest.sh" \
    DISTRIBUTION_EXISTING_GITOPS_CHECK_WRAPPER="$tmp/gitops-check.sh" \
    DISTRIBUTION_EXISTING_ARGO_CHECK_WRAPPER="$tmp/argo-check.sh" \
    bash "$0" --build-url https://ci/job/x/47 --version IFT-0.0.27 --distribution-type ift --no-extra-config-changes
  )"
  rc=$?
  set -e
  [[ $rc -ne 0 && "$output" == *"STATE=inconsistent_deployment_state"* ]] || { printf '%s\n' "$output"; echo "DISTRIBUTION_EXISTING_SELF_TESTS=FAIL"; exit 1; }
  echo "DISTRIBUTION_EXISTING_SELF_TESTS=OK"
}

load_skill_env

BUILD_URL=""
JOB_NAME=""
BUILD_NUMBER=""
VERSION=""
DISTRIBUTION_TYPE=""
BRANCH=""
PROJECT_NAME=""
ENVIRONMENT="ift"
CONFIG_REPO_URL="${CONFIG_REPO_URL:-}"
CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-}"
CHARTS_PATH_TEMPLATE="${CHARTS_PATH_TEMPLATE:-}"
CONFIG_PATH_TEMPLATE="${CONFIG_PATH_TEMPLATE:-}"
CONFIG_TEMPLATE_PATH_TEMPLATE="${CONFIG_TEMPLATE_PATH_TEMPLATE:-}"
ARGOCD_SERVER="${ARGOCD_SERVER:-}"
ARGOCD_APP_NAME_TEMPLATE="${ARGOCD_APP_NAME_TEMPLATE:-}"
ARGOCD_PROJECT="${ARGOCD_PROJECT:-}"
ARGOCD_DESTINATION_SERVER="${ARGOCD_DESTINATION_SERVER:-}"
ARGOCD_DESTINATION_NAMESPACE="${ARGOCD_DESTINATION_NAMESPACE:-}"
CHARTS_PATH=""
CONFIG_PATH=""
CONFIG_TEMPLATE_PATH=""
ARGOCD_APP_NAME=""
APPROVE_DEPLOYMENT=false
NO_EXTRA_CONFIG_CHANGES=false
ADDITIONAL_CONFIG_CHANGES_FILE=""
ADDITIONAL_CONFIG_CHANGES=false
RESUME=false
STANDARD_GITOPS_UPDATE_APPROVED_BY_REQUEST=false
GITOPS_ACTION=""
GITOPS_PUSHED=false
ARGOCD_SYNC_STATUS=""
ARGOCD_HEALTH_STATUS=""
DRY_RUN=false
TIMEOUT_SECONDS=1800

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --build-url) require_value "$1" "${2:-}"; BUILD_URL="${2%/}"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME="$2"; shift 2 ;;
    --build-number) require_value "$1" "${2:-}"; BUILD_NUMBER="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$(normalize_distribution_type "$2")"; shift 2 ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --environment) require_value "$1" "${2:-}"; ENVIRONMENT="$2"; shift 2 ;;
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --config-template-path) require_value "$1" "${2:-}"; CONFIG_TEMPLATE_PATH="$2"; shift 2 ;;
    --argocd-server) require_value "$1" "${2:-}"; ARGOCD_SERVER="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --argocd-project) require_value "$1" "${2:-}"; ARGOCD_PROJECT="$2"; shift 2 ;;
    --argocd-destination-server) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_SERVER="$2"; shift 2 ;;
    --argocd-destination-namespace) require_value "$1" "${2:-}"; ARGOCD_DESTINATION_NAMESPACE="$2"; shift 2 ;;
    --resume) RESUME=true; shift ;;
    --digest) require_value "$1" "${2:-}"; IMAGE_DIGEST="$2"; shift 2 ;;
    --no-extra-config-changes) NO_EXTRA_CONFIG_CHANGES=true; shift ;;
    --additional-config-changes-required) ADDITIONAL_CONFIG_CHANGES=true; shift ;;
    --additional-config-changes-file) require_value "$1" "${2:-}"; ADDITIONAL_CONFIG_CHANGES_FILE="$2"; ADDITIONAL_CONFIG_CHANGES=true; shift 2 ;;
    --approve-deployment) APPROVE_DEPLOYMENT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --timeout-seconds) require_value "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

[[ -n "$VERSION" ]] || emit_error "missing_version" "Missing exact version" "version"
[[ -n "$DISTRIBUTION_TYPE" ]] || emit_error "missing_distribution_type" "Missing distribution type" "distribution type"
resolve_project_name
resolve_branch
apply_defaults

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

status_output="$WORK_DIR/status.out"
status_args=("$STATUS_WRAPPER")
if [[ -n "$BUILD_URL" ]]; then
  status_args+=(--build-url "$BUILD_URL")
else
  [[ -n "$JOB_NAME" && -n "$BUILD_NUMBER" ]] || emit_error "missing_build_identity" "Missing build identity" "build URL or job name and build number"
  status_args+=(--job-name "$JOB_NAME" --build-number "$BUILD_NUMBER")
fi
status_args+=(--version "$VERSION" --distribution-type "$DISTRIBUTION_TYPE" --branch "$BRANCH")
run_and_capture "$status_output" bash "${status_args[@]}" || exit 1
BUILD_URL="$(value_from_output BUILD_URL "$status_output")"
BUILD_NUMBER="$(value_from_output BUILD_NUMBER "$status_output")"
[[ "$(value_from_output BUILD_STATUS_VERIFIED "$status_output")" == "true" ]] || emit_error "jenkins_build_status_unverified" "Jenkins build status was not verified" "verified Jenkins build"

digest_output="$WORK_DIR/digest.out"
if [[ "$RESUME" == "true" ]]; then
  [[ -n "$IMAGE_DIGEST" ]] || emit_error "missing_digest" "Resume requires exact image digest" "digest"
  [[ "$IMAGE_DIGEST" =~ ^[a-f0-9]{64}$ ]] || emit_error "invalid_digest" "Resume digest must be a 64-character lowercase hex digest" "valid digest"
else
  run_and_capture "$digest_output" bash "$DIGEST_WRAPPER" --build-url "$BUILD_URL" --expected-version "$VERSION" || exit 1
  IMAGE_DIGEST="$(value_from_output IMAGE_DIGEST "$digest_output")"
  [[ "$(value_from_output DIGEST_BUILD_IDENTITY_VERIFIED "$digest_output")" == "true" ]] || emit_error "digest_build_identity_unverified" "Digest build identity was not verified" "verified digest"
fi

gitops_check="$WORK_DIR/gitops-check.out"
run_and_capture "$gitops_check" bash "$GITOPS_CHECK_WRAPPER" \
  --project-name "$PROJECT_NAME" \
  --environment "$ENVIRONMENT" \
  --config-repo-url "$CONFIG_REPO_URL" \
  --config-repo-branch "$CONFIG_REPO_BRANCH" \
  --charts-path "$CHARTS_PATH" \
  --config-path "$CONFIG_PATH" \
  --config-template-path "$CONFIG_TEMPLATE_PATH" || exit 1
config_exists="$(value_from_output CONFIG_EXISTS "$gitops_check")"

argo_check="$WORK_DIR/argocd-check.out"
run_and_capture "$argo_check" bash "$ARGO_CHECK_WRAPPER" --argocd-server "$ARGOCD_SERVER" --argocd-app-name "$ARGOCD_APP_NAME" || exit 1
app_exists="$(value_from_output ARGOCD_APP_EXISTS "$argo_check")"
existing_destination_server="$(value_from_output ARGOCD_DESTINATION_SERVER "$argo_check")"
[[ -n "$existing_destination_server" ]] && ARGOCD_DESTINATION_SERVER="$existing_destination_server"

if ! DEPLOYMENT_MODE="$(deployment_mode_for_state "$config_exists" "$app_exists")"; then
  emit_error "inconsistent_deployment_state" "Deployment state is inconsistent" "manual deployment state repair"
fi

if [[ "$DEPLOYMENT_MODE" == "update" ]]; then
  if [[ "$ADDITIONAL_CONFIG_CHANGES" == "true" && -z "$ADDITIONAL_CONFIG_CHANGES_FILE" ]]; then
    emit_paused_additional_changes
  fi
  if [[ "$NO_EXTRA_CONFIG_CHANGES" != "true" && -z "$ADDITIONAL_CONFIG_CHANGES_FILE" ]]; then
    emit_paused_scope_question
  fi
  STANDARD_GITOPS_UPDATE_APPROVED_BY_REQUEST=true
fi

gitops_update="$WORK_DIR/gitops-update.out"
gitops_update_args=(
  "$GITOPS_UPDATE_WRAPPER"
  --mode "$DEPLOYMENT_MODE"
  --project-name "$PROJECT_NAME"
  --environment "$ENVIRONMENT"
  --distribution-type "$DISTRIBUTION_TYPE"
  --version "$VERSION"
  --digest "$IMAGE_DIGEST"
  --config-repo-url "$CONFIG_REPO_URL"
  --config-repo-branch "$CONFIG_REPO_BRANCH"
  --charts-path "$CHARTS_PATH"
  --config-path "$CONFIG_PATH"
  --config-template-path "$CONFIG_TEMPLATE_PATH"
  --namespace "$ARGOCD_DESTINATION_NAMESPACE"
  --argocd-app-name "$ARGOCD_APP_NAME"
)
[[ -n "$ADDITIONAL_CONFIG_CHANGES_FILE" ]] && gitops_update_args+=(--additional-config-changes-file "$ADDITIONAL_CONFIG_CHANGES_FILE")
if [[ "$DRY_RUN" != "true" && ( "$APPROVE_DEPLOYMENT" == "true" || "$DEPLOYMENT_MODE" == "update" ) ]]; then
  gitops_update_args+=(--approve)
else
  gitops_update_args+=(--dry-run)
fi
echo "VERSION=${VERSION}"
echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
echo "BUILD_URL=${BUILD_URL}"
echo "CONFIG_PATH=${CONFIG_PATH}"
echo "ARGOCD_APP_NAME=${ARGOCD_APP_NAME}"
run_and_capture "$gitops_update" bash "${gitops_update_args[@]}" || exit 1
GITOPS_ACTION="updated"
GITOPS_PUSHED="$(value_from_output PUSH_COMPLETED "$gitops_update")"

if [[ "$DRY_RUN" != "true" && ( "$APPROVE_DEPLOYMENT" == "true" || "$DEPLOYMENT_MODE" == "update" ) ]]; then
  [[ -n "$ARGOCD_DESTINATION_SERVER" ]] || emit_error "missing_argocd_destination_server" "Missing Argo CD destination server" "Argo CD destination server"
  argo_sync_output="$WORK_DIR/argocd-sync.out"
  run_and_capture "$argo_sync_output" bash "$ARGO_SYNC_WRAPPER" \
    --mode "$DEPLOYMENT_MODE" \
    --argocd-server "$ARGOCD_SERVER" \
    --argocd-app-name "$ARGOCD_APP_NAME" \
    --argocd-project "$ARGOCD_PROJECT" \
    --repo-url "$CONFIG_REPO_URL" \
    --target-revision "$CONFIG_REPO_BRANCH" \
    --source-path "$CONFIG_PATH" \
    --destination-server "$ARGOCD_DESTINATION_SERVER" \
    --destination-namespace "$ARGOCD_DESTINATION_NAMESPACE" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --approve
  ARGOCD_SYNC_STATUS="$(value_from_output ARGOCD_SYNC_STATUS "$argo_sync_output")"
  ARGOCD_HEALTH_STATUS="$(value_from_output ARGOCD_HEALTH_STATUS "$argo_sync_output")"
fi

MUTATIONS_PERFORMED=false
[[ "$DRY_RUN" != "true" && ( "$APPROVE_DEPLOYMENT" == "true" || "$DEPLOYMENT_MODE" == "update" ) ]] && MUTATIONS_PERFORMED=true
emit_success
