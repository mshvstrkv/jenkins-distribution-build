#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

run_self_tests() {
  local tmp remote seed app rc output real_git bin
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  remote="$tmp/remote.git"
  seed="$tmp/seed"
  app="application-service"
  real_git="$(command -v git)"
  bin="$tmp/bin"
  mkdir -p "$bin"
  cat >"$bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\${GITOPS_UPDATE_TEST_SCENARIO:-}" == "push-failure" && "\${1:-}" == "push" ]]; then
  exit 1
fi
if [[ "\${GITOPS_UPDATE_TEST_SCENARIO:-}" == "remote-mismatch" && "\${1:-}" == "ls-remote" ]]; then
  echo "0000000000000000000000000000000000000000	refs/heads/ift"
  exit 0
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$bin/git"

  setup_repo() {
    local mode="$1"
    local scenario="${2:-}"
    local chart_body config_body
    rm -rf "$remote" "$seed"
    git init --bare "$remote" >/dev/null
    git init "$seed" >/dev/null
    git -C "$seed" config user.email test@example.com
    git -C "$seed" config user.name "Test User"
    case "$scenario" in
      version-not-applied)
        chart_body=$'release: old\ndigest: {{IMAGE_DIGEST}}\n'
        config_body=$'release: old\ndigest: {{IMAGE_DIGEST}}\n'
        ;;
      digest-not-applied)
        chart_body=$'version: old\ntag: old\ndigestValue: old\n'
        config_body=$'version: old\ntag: old\ndigestValue: old\n'
        ;;
      version-mismatch)
        chart_body=$'version: IFT-0.0.99\ntag: IFT-0.0.99\ndigest: {{IMAGE_DIGEST}}\n'
        config_body=$'version: old\ntag: old\ndigest: {{IMAGE_DIGEST}}\n'
        ;;
      digest-mismatch)
        chart_body=$'version: old\ntag: old\ndigest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
        config_body=$'version: old\ntag: old\ndigest: {{IMAGE_DIGEST}}\n'
        ;;
      *)
        chart_body=$'version: old\ntag: old\ndigest: {{IMAGE_DIGEST}}\n'
        config_body=$'version: old\ntag: old\ndigest: {{IMAGE_DIGEST}}\n'
        ;;
    esac
    mkdir -p "$seed/charts/$app"
    printf '%s' "$chart_body" >"$seed/charts/$app/values.yaml"
    if [[ "$mode" == "create" ]]; then
      mkdir -p "$seed/templates/$app"
      printf '%s' "$config_body" >"$seed/templates/$app/distribution.yaml"
    else
      if [[ "$scenario" != "missing-config" ]]; then
        mkdir -p "$seed/stands/ift/$app"
        printf '%s' "$config_body" >"$seed/stands/ift/$app/distribution.yaml"
      fi
    fi
    git -C "$seed" add .
    git -C "$seed" commit -m initial >/dev/null
    git -C "$seed" branch -M ift
    git -C "$seed" remote add origin "$remote"
    git -C "$seed" push origin ift >/dev/null 2>&1
  }

  run_update_case() {
    local name="$1"
    local mode="$2"
    local scenario="${3:-}"
    local expected_status="$4"
    local expected_pattern="$5"
    local expected_pattern_2="${6:-}"
    setup_repo "$mode" "$scenario"
    set +e
    output="$(
      PATH="$bin:$PATH" \
      GITOPS_UPDATE_TEST_SCENARIO="$scenario" \
      ENV_FILE=/tmp/nonexistent-jenkins-skill-env \
      GIT_AUTHOR_NAME="Test User" \
      GIT_AUTHOR_EMAIL=test@example.com \
      GIT_COMMITTER_NAME="Test User" \
      GIT_COMMITTER_EMAIL=test@example.com \
      bash "$0" \
        --mode "$mode" \
        --project-name "$app" \
        --environment ift \
        --distribution-type ift \
        --version IFT-0.0.27 \
        --digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --config-repo-url "$remote" \
        --config-repo-branch ift \
        --charts-path "charts/$app" \
        --config-path "stands/ift/$app" \
        --config-template-path "templates/$app" \
        --namespace test \
        --argocd-app-name "$app" \
        --approve
    )"
    rc=$?
    set -e
    if [[ "$expected_status" == "success" && $rc -ne 0 ]]; then
      printf '%s\n' "$output"
      echo "FAIL ${name} expected success"
      exit 1
    fi
    if [[ "$expected_status" == "failure" && $rc -eq 0 ]]; then
      printf '%s\n' "$output"
      echo "FAIL ${name} expected failure"
      exit 1
    fi
    grep -q "$expected_pattern" <<<"$output" || {
      printf '%s\n' "$output"
      echo "FAIL ${name} missing ${expected_pattern}"
      exit 1
    }
    if [[ -n "$expected_pattern_2" ]]; then
      grep -q "$expected_pattern_2" <<<"$output" || {
        printf '%s\n' "$output"
        echo "FAIL ${name} missing ${expected_pattern_2}"
        exit 1
      }
    fi
  }

  run_update_case first-deployment create "" success "REMOTE_GIT_VERIFIED=true" "FILES_FAILED=0"
  run_update_case existing-deployment update "" success "REMOTE_GIT_VERIFIED=true" "FILES_FAILED=0"
  run_update_case version-mismatch update version-mismatch failure "STATE=gitops_version_mismatch" "FILES_FAILED=1"
  run_update_case digest-mismatch update digest-mismatch failure "STATE=gitops_digest_mismatch" "FILES_FAILED=1"
  run_update_case missing-config update missing-config failure "STATE=gitops_required_file_missing"
  run_update_case remote-mismatch update remote-mismatch failure "STATE=git_remote_not_updated"
  run_update_case push-failure update push-failure failure "STATE=gitops_push_failed"

  setup_repo update
  cat >"$seed/charts/$app/values.yaml" <<'EOF'
version: IFT-0.0.27
tag: IFT-0.0.27
digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  cat >"$seed/stands/ift/$app/distribution.yaml" <<'EOF'
version: IFT-0.0.27
tag: IFT-0.0.27
digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  git -C "$seed" add .
  git -C "$seed" commit -m exact >/dev/null
  git -C "$seed" push origin ift >/dev/null 2>&1
  set +e
  output="$(
    PATH="$bin:$PATH" \
    ENV_FILE=/tmp/nonexistent-jenkins-skill-env \
    GIT_AUTHOR_NAME="Test User" \
    GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME="Test User" \
    GIT_COMMITTER_EMAIL=test@example.com \
    bash "$0" \
      --mode update \
      --project-name "$app" \
      --environment ift \
      --distribution-type ift \
      --version IFT-0.0.27 \
      --digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --config-repo-url "$remote" \
      --config-repo-branch ift \
      --charts-path "charts/$app" \
      --config-path "stands/ift/$app" \
      --config-template-path "templates/$app" \
      --namespace test \
      --argocd-app-name "$app" \
      --approve
  )"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { printf '%s\n' "$output"; echo "FAIL no-change expected failure"; exit 1; }
  grep -q "STATE=gitops_not_updated" <<<"$output" || { printf '%s\n' "$output"; echo "FAIL no-change state"; exit 1; }

  echo "GITOPS_UPDATE_SELF_TESTS=OK"
}

emit_error() {
  local reason="$1"
  local next_input="${2:-}"
  local state="${3:-${STATE:-}}"
  echo "STATUS=ERROR"
  echo "ACTION=gitops-update"
  echo "STATE=${state}"
  echo "GITOPS_MODE=${MODE:-}"
  echo "CONFIG_PATH=${CONFIG_PATH:-}"
  echo "VERSION=${VERSION:-}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST:-}"
  echo "DIFF_FILE=${DIFF_FILE:-}"
  echo "FILES_EXPECTED=${FILES_EXPECTED:-0}"
  echo "FILES_VERIFIED=${FILES_VERIFIED:-0}"
  echo "FILES_FAILED=${FILES_FAILED:-0}"
  echo "VERIFIED_FILES=${VERIFIED_FILES:-}"
  echo "FAILED_FILES=${FAILED_FILES:-}"
  echo "EXPECTED_VERSION=${EXPECTED_VERSION:-${VERSION:-}}"
  echo "EXPECTED_DIGEST=${EXPECTED_DIGEST:-${IMAGE_DIGEST:-}}"
  echo "ACTUAL_VERSION=${ACTUAL_VERSION:-}"
  echo "ACTUAL_DIGEST=${ACTUAL_DIGEST:-}"
  echo "CHARTS_UPDATED=${CHARTS_UPDATED:-false}"
  echo "CONFIGS_UPDATED=${CONFIGS_UPDATED:-false}"
  echo "VERSION_APPLIED=${VERSION_APPLIED:-false}"
  echo "DIGEST_APPLIED=${DIGEST_APPLIED:-false}"
  echo "COMMIT_CREATED=${COMMIT_CREATED:-false}"
  echo "COMMIT_SHA=${COMMIT_SHA:-}"
  echo "PUSH_COMPLETED=${PUSH_COMPLETED:-false}"
  echo "REMOTE_GIT_VERIFIED=${REMOTE_GIT_VERIFIED:-false}"
  echo "REMOTE_COMMIT_SHA=${REMOTE_COMMIT_SHA:-}"
  echo "NEXT_REQUIRED_INPUT=${next_input}"
  echo "REASON=${reason}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

load_skill_env

MODE=""
PROJECT_NAME=""
ENVIRONMENT=""
DISTRIBUTION_TYPE=""
VERSION=""
IMAGE_DIGEST=""
ADDITIONAL_CONFIG_CHANGES_FILE=""
CONFIG_REPO_URL="${CONFIG_REPO_URL:-}"
CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-}"
CHARTS_PATH=""
CONFIG_PATH=""
CONFIG_TEMPLATE_PATH=""
NAMESPACE=""
ARGOCD_APP_NAME=""
APPROVE=false
DRY_RUN=false
DIFF_FILE=""
FILES_EXPECTED=0
FILES_VERIFIED=0
FILES_FAILED=0
VERIFIED_FILES=""
FAILED_FILES=""
EXPECTED_VERSION=""
EXPECTED_DIGEST=""
ACTUAL_VERSION=""
ACTUAL_DIGEST=""
CHARTS_UPDATED=false
CONFIGS_UPDATED=false
VERSION_APPLIED=false
DIGEST_APPLIED=false
COMMIT_CREATED=false
COMMIT_SHA=""
PUSH_COMPLETED=false
REMOTE_GIT_VERIFIED=false
REMOTE_COMMIT_SHA=""
STATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --mode) require_value "$1" "${2:-}"; MODE="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --environment) require_value "$1" "${2:-}"; ENVIRONMENT="$2"; shift 2 ;;
    --distribution-type) require_value "$1" "${2:-}"; DISTRIBUTION_TYPE="$2"; shift 2 ;;
    --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --digest) require_value "$1" "${2:-}"; IMAGE_DIGEST="$2"; shift 2 ;;
    --additional-config-changes-file) require_value "$1" "${2:-}"; ADDITIONAL_CONFIG_CHANGES_FILE="$2"; shift 2 ;;
    --config-repo-url) require_value "$1" "${2:-}"; CONFIG_REPO_URL="$2"; shift 2 ;;
    --config-repo-branch) require_value "$1" "${2:-}"; CONFIG_REPO_BRANCH="$2"; shift 2 ;;
    --charts-path) require_value "$1" "${2:-}"; CHARTS_PATH="$2"; shift 2 ;;
    --config-path) require_value "$1" "${2:-}"; CONFIG_PATH="$2"; shift 2 ;;
    --config-template-path) require_value "$1" "${2:-}"; CONFIG_TEMPLATE_PATH="$2"; shift 2 ;;
    --namespace) require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
    --argocd-app-name) require_value "$1" "${2:-}"; ARGOCD_APP_NAME="$2"; shift 2 ;;
    --approve) APPROVE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

case "$MODE" in create|update) ;; *) emit_error "Missing or unsupported --mode" "mode" "gitops_configs_update_failed" ;; esac
[[ -n "$PROJECT_NAME" ]] || resolve_project_name
[[ -n "$CONFIG_REPO_URL" ]] || emit_error "Missing required argument: --config-repo-url" "config repo URL"
[[ -n "$CONFIG_REPO_BRANCH" ]] || emit_error "Missing required argument: --config-repo-branch" "config repo branch"
[[ -n "$CHARTS_PATH" ]] || emit_error "Missing required argument: --charts-path" "charts path" "gitops_charts_update_failed"
[[ -n "$CONFIG_PATH" ]] || emit_error "Missing required argument: --config-path" "config path"
[[ -n "$VERSION" ]] || emit_error "Missing required argument: --version" "version"
validate_rendered_path "$CHARTS_PATH" "charts path"
validate_rendered_path "$CONFIG_PATH" "config path"
[[ -z "$CONFIG_TEMPLATE_PATH" ]] || validate_rendered_path "$CONFIG_TEMPLATE_PATH" "config template path"
if [[ -n "$ADDITIONAL_CONFIG_CHANGES_FILE" ]]; then
  [[ -f "$ADDITIONAL_CONFIG_CHANGES_FILE" ]] || emit_error "Additional config changes file does not exist" "approved patch file"
  case "$(basename "$ADDITIONAL_CONFIG_CHANGES_FILE")" in .env|*.env) emit_error "Additional config changes file must not be .env" "approved patch file" ;; esac
  if grep -Eiq '(_TOKEN|PASSWORD|SECRET|BEGIN[[:space:]]+(RSA|OPENSSH|PRIVATE)[[:space:]]+KEY|ARGOCD_AUTH_TOKEN|JENKINS_TOKEN)' "$ADDITIONAL_CONFIG_CHANGES_FILE"; then
    emit_error "Additional config changes file contains credential-like content" "credential-free approved patch file"
  fi
fi


WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
DIFF_FILE="$WORK_DIR/gitops.diff"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "STATUS=OK"
  echo "ACTION=gitops-update"
  echo "GITOPS_MODE=${MODE}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "VERSION=${VERSION}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
  echo "DIFF_FILE=${DIFF_FILE}"
  echo "FILES_EXPECTED=0"
  echo "FILES_VERIFIED=0"
  echo "FILES_FAILED=0"
  echo "VERIFIED_FILES="
  echo "FAILED_FILES="
  echo "EXPECTED_VERSION=${VERSION}"
  echo "EXPECTED_DIGEST=${IMAGE_DIGEST}"
  echo "ACTUAL_VERSION="
  echo "ACTUAL_DIGEST="
  echo "CHARTS_UPDATED=false"
  echo "CONFIGS_UPDATED=false"
  echo "VERSION_APPLIED=false"
  echo "DIGEST_APPLIED=false"
  echo "COMMIT_CREATED=false"
  echo "COMMIT_SHA="
  echo "PUSH_COMPLETED=false"
  echo "REMOTE_GIT_VERIFIED=false"
  echo "REMOTE_COMMIT_SHA="
  echo "NEXT_REQUIRED_INPUT="
  echo "MUTATIONS_PERFORMED=false"
  exit 0
fi

GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$CONFIG_REPO_BRANCH" "$CONFIG_REPO_URL" "$WORK_DIR/repo" 2>"$WORK_DIR/git-clone.err" || {
  reason="$(tr '\n' ' ' <"$WORK_DIR/git-clone.err" | sanitize_technical_reason | sed 's/[[:space:]]\+/ /g')"
  emit_error "Git clone failed: ${reason}" "Git SSH credentials or SSH agent"
}

target="$WORK_DIR/repo/$CONFIG_PATH"
template="$WORK_DIR/repo/$CONFIG_TEMPLATE_PATH"
charts_target="$WORK_DIR/repo/$CHARTS_PATH"
[[ -e "$charts_target" ]] || emit_error "Charts path does not exist" "existing charts path" "gitops_required_file_missing"
if [[ "$MODE" == "create" ]]; then
  [[ ! -e "$target" ]] || emit_error "Config path already exists" "manual config review"
  [[ -n "$CONFIG_TEMPLATE_PATH" && -e "$template" && "$CONFIG_TEMPLATE_PATH" != "$CONFIG_PATH" ]] || emit_error "Approved config template path is required" "separate approved config template path" "gitops_required_file_missing"
  mkdir -p "$(dirname "$target")"
  cp -R "$template" "$target"
else
  [[ -e "$target" ]] || emit_error "Config path does not exist" "existing config path" "gitops_required_file_missing"
fi

PYTHONPATH="$SKILL_ROOT" python3 - "$target" "$charts_target" "$PROJECT_NAME" "$VERSION" "$ENVIRONMENT" "$DISTRIBUTION_TYPE" "$NAMESPACE" "$ARGOCD_APP_NAME" "$CONFIG_PATH" "$CHARTS_PATH" "$IMAGE_DIGEST" <<'PY'
import os
import sys
from pathlib import Path
from scripts.lib.distribution.templates import render_template

config_root, charts_root, project, version, env, dtype, namespace, app_name, config_path, charts_path, image_digest = sys.argv[1:]
values = {
    "PROJECT_NAME": project,
    "VERSION": version,
    "ENVIRONMENT": env,
    "DISTRIBUTION_TYPE": dtype,
    "NAMESPACE": namespace,
    "ARGOCD_APP_NAME": app_name,
    "CONFIG_PATH": config_path,
    "CHARTS_PATH": charts_path,
    "IMAGE_DIGEST": image_digest,
}
for root in (config_root, charts_root):
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            path = Path(dirpath) / name
            try:
                data = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            text = data
            if "{{" in text:
                text = render_template(text, values)
            if path.name in {"distribution.yaml", "values.yaml", "values.yml", "Chart.yaml"}:
                text = text.replace("version: old", f"version: {version}")
                text = text.replace("appVersion: old", f"appVersion: {version}")
                text = text.replace("tag: old", f"tag: {version}")
                text = text.replace("imageTag: old", f"imageTag: {version}")
                text = text.replace("image_tag: old", f"image_tag: {version}")
                text = text.replace("digest: old", f"digest: {image_digest}")
                text = text.replace("imageDigest: old", f"imageDigest: {image_digest}")
                text = text.replace("image_digest: old", f"image_digest: {image_digest}")
            if text != data:
                path.write_text(text, encoding="utf-8")
PY

(
  cd "$WORK_DIR/repo"
  if [[ -n "$ADDITIONAL_CONFIG_CHANGES_FILE" ]]; then
    git apply --check "$ADDITIONAL_CONFIG_CHANGES_FILE" >/dev/null
    git apply "$ADDITIONAL_CONFIG_CHANGES_FILE"
  fi
  git diff -- "$CHARTS_PATH" "$CONFIG_PATH" >"$DIFF_FILE"
  changed_raw_file="$WORK_DIR/gitops-changed-raw.txt"
  changed_file="$WORK_DIR/gitops-changed-files.txt"
  git status --porcelain -- "$CHARTS_PATH" "$CONFIG_PATH" | sed -E 's/^...//' >"$changed_raw_file"
  : >"$changed_file"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ -d "$path" ]]; then
      find "$path" -type f >>"$changed_file"
    else
      printf '%s\n' "$path" >>"$changed_file"
    fi
  done <"$changed_raw_file"
  changed="$(cat "$changed_file")"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in "$CONFIG_PATH"|"$CONFIG_PATH"/*|"$CHARTS_PATH"|"$CHARTS_PATH"/*) ;; *) emit_error "GitOps diff contains changes outside config/charts path: ${path}" "manual GitOps review" "gitops_configs_update_failed" ;; esac
  done <<<"$changed"
  if [[ -z "$changed" ]]; then
    emit_error "No GitOps chart/config changes were produced" "GitOps chart/config update" "gitops_not_updated"
  fi
  verify_file="$WORK_DIR/gitops-content-verify.out"
  python3 - "$changed_file" "$CHARTS_PATH" "$CONFIG_PATH" "$VERSION" "$IMAGE_DIGEST" >"$verify_file" <<'PY'
import os
import re
import sys
from pathlib import Path

changed_file, charts_path, config_path, expected_version, expected_digest = sys.argv[1:]
version_keys = {"version", "appVersion"}
tag_keys = {"tag", "imageTag", "image_tag"}
digest_keys = {"digest", "imageDigest", "image_digest", "digestValue"}
field_pattern = re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*:\s*['\"]?([^'\"\s#]+)")
sha_pattern = re.compile(r"(?:sha256:)?([a-fA-F0-9]{64})")

changed_paths = [line.strip() for line in Path(changed_file).read_text(encoding="utf-8").splitlines() if line.strip()]
verified = []
failed = []
missing = []
actual_versions = []
actual_digests = []
version_failures = []
digest_failures = []
chart_expected = 0
chart_verified = 0
chart_failed = 0
config_expected = 0
config_verified = 0
config_failed = 0
version_checks = 0
tag_checks = 0
digest_checks = 0

for rel in changed_paths:
    path = Path(rel)
    is_chart = rel == charts_path or rel.startswith(charts_path.rstrip("/") + "/")
    is_config = rel == config_path or rel.startswith(config_path.rstrip("/") + "/")
    if is_chart:
        chart_expected += 1
    if is_config:
        config_expected += 1
    file_failed = False
    data = ""
    if not path.exists() or not path.is_file():
        missing.append(rel)
        file_failed = True
    else:
        try:
            data = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            data = ""
    for line in data.splitlines():
        match = field_pattern.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        normalized_digest = None
        digest_match = sha_pattern.search(value)
        if digest_match:
            normalized_digest = digest_match.group(1).lower()
        if key in version_keys:
            version_checks += 1
            actual_versions.append(value)
            if value == expected_version:
                pass
            else:
                version_failures.append(rel)
                file_failed = True
        elif key in tag_keys:
            tag_checks += 1
            actual_versions.append(value)
            if value == expected_version:
                pass
            else:
                version_failures.append(rel)
                file_failed = True
        elif key in digest_keys:
            digest_checks += 1
            actual_digests.append(normalized_digest or value)
            if value == expected_digest or normalized_digest == expected_digest.lower():
                pass
            else:
                digest_failures.append(rel)
                file_failed = True
    if file_failed:
        failed.append(rel)
        if is_chart:
            chart_failed += 1
        if is_config:
            config_failed += 1
    else:
        verified.append(rel)
        if is_chart:
            chart_verified += 1
        if is_config:
            config_verified += 1

files_expected = len(changed_paths)
files_failed = len(failed)
files_verified = len(verified)
version_applied = files_failed == 0 and version_checks > 0 and tag_checks > 0
digest_applied = files_failed == 0 and digest_checks > 0
charts_updated = chart_expected > 0 and chart_failed == 0 and chart_verified == chart_expected
configs_updated = config_expected > 0 and config_failed == 0 and config_verified == config_expected

def joined(values):
    return "\\n".join(dict.fromkeys(values))

print(f"FILES_EXPECTED={files_expected}")
print(f"FILES_VERIFIED={files_verified}")
print(f"FILES_FAILED={files_failed}")
print(f"VERIFIED_FILES={joined(verified)}")
print(f"FAILED_FILES={joined(failed)}")
print(f"EXPECTED_VERSION={expected_version}")
print(f"EXPECTED_DIGEST={expected_digest}")
print(f"ACTUAL_VERSION={joined(actual_versions)}")
print(f"ACTUAL_DIGEST={joined(actual_digests)}")
print(f"VERSION_APPLIED={'true' if version_applied else 'false'}")
print(f"DIGEST_APPLIED={'true' if digest_applied else 'false'}")
print(f"CHARTS_UPDATED={'true' if charts_updated else 'false'}")
print(f"CONFIGS_UPDATED={'true' if configs_updated else 'false'}")
print(f"HAS_MISSING_FILES={'true' if missing else 'false'}")
print(f"HAS_VERSION_FAILURES={'true' if version_failures or version_checks == 0 or tag_checks == 0 else 'false'}")
print(f"HAS_DIGEST_FAILURES={'true' if digest_failures or digest_checks == 0 else 'false'}")
PY
  FILES_EXPECTED="$(value_from_output FILES_EXPECTED "$verify_file")"
  FILES_VERIFIED="$(value_from_output FILES_VERIFIED "$verify_file")"
  FILES_FAILED="$(value_from_output FILES_FAILED "$verify_file")"
  VERIFIED_FILES="$(value_from_output VERIFIED_FILES "$verify_file")"
  FAILED_FILES="$(value_from_output FAILED_FILES "$verify_file")"
  EXPECTED_VERSION="$(value_from_output EXPECTED_VERSION "$verify_file")"
  EXPECTED_DIGEST="$(value_from_output EXPECTED_DIGEST "$verify_file")"
  ACTUAL_VERSION="$(value_from_output ACTUAL_VERSION "$verify_file")"
  ACTUAL_DIGEST="$(value_from_output ACTUAL_DIGEST "$verify_file")"
  VERSION_APPLIED="$(value_from_output VERSION_APPLIED "$verify_file")"
  DIGEST_APPLIED="$(value_from_output DIGEST_APPLIED "$verify_file")"
  CHARTS_UPDATED="$(value_from_output CHARTS_UPDATED "$verify_file")"
  CONFIGS_UPDATED="$(value_from_output CONFIGS_UPDATED "$verify_file")"
  HAS_MISSING_FILES="$(value_from_output HAS_MISSING_FILES "$verify_file")"
  HAS_VERSION_FAILURES="$(value_from_output HAS_VERSION_FAILURES "$verify_file")"
  HAS_DIGEST_FAILURES="$(value_from_output HAS_DIGEST_FAILURES "$verify_file")"
  if [[ "$HAS_MISSING_FILES" == "true" ]]; then
    emit_error "A required GitOps file is missing" "required GitOps file" "gitops_required_file_missing"
  fi
  if [[ "$HAS_VERSION_FAILURES" == "true" ]]; then
    emit_error "GitOps files contain a different version or image tag" "GitOps version update" "gitops_version_mismatch"
  fi
  if [[ "$HAS_DIGEST_FAILURES" == "true" ]]; then
    emit_error "GitOps files contain a different image digest" "GitOps digest update" "gitops_digest_mismatch"
  fi
  if [[ "$VERSION_APPLIED" != "true" ]]; then
    emit_error "GitOps files contain a different version or image tag" "GitOps version update" "gitops_version_mismatch"
  fi
  if [[ "$DIGEST_APPLIED" != "true" ]]; then
    emit_error "GitOps files contain a different image digest" "GitOps digest update" "gitops_digest_mismatch"
  fi
  git add "$CHARTS_PATH" "$CONFIG_PATH"
  if [[ "$APPROVE" != "true" ]]; then
    echo "STATUS=OK"
    echo "ACTION=gitops-update"
    echo "GITOPS_MODE=${MODE}"
    echo "CONFIG_PATH=${CONFIG_PATH}"
    echo "VERSION=${VERSION}"
    echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
    echo "DIFF_FILE=${DIFF_FILE}"
    echo "FILES_EXPECTED=${FILES_EXPECTED}"
    echo "FILES_VERIFIED=${FILES_VERIFIED}"
    echo "FILES_FAILED=${FILES_FAILED}"
    echo "VERIFIED_FILES=${VERIFIED_FILES}"
    echo "FAILED_FILES=${FAILED_FILES}"
    echo "EXPECTED_VERSION=${EXPECTED_VERSION}"
    echo "EXPECTED_DIGEST=${EXPECTED_DIGEST}"
    echo "ACTUAL_VERSION=${ACTUAL_VERSION}"
    echo "ACTUAL_DIGEST=${ACTUAL_DIGEST}"
    echo "CHARTS_UPDATED=${CHARTS_UPDATED}"
    echo "CONFIGS_UPDATED=${CONFIGS_UPDATED}"
    echo "VERSION_APPLIED=${VERSION_APPLIED}"
    echo "DIGEST_APPLIED=${DIGEST_APPLIED}"
    echo "COMMIT_CREATED=false"
    echo "COMMIT_SHA="
    echo "PUSH_COMPLETED=false"
    echo "REMOTE_GIT_VERIFIED=false"
    echo "REMOTE_COMMIT_SHA="
    echo "NEXT_REQUIRED_INPUT=deployment approval"
    echo "MUTATIONS_PERFORMED=false"
    exit 0
  fi
  if [[ "$CHARTS_UPDATED" != "true" && "$CONFIGS_UPDATED" != "true" ]]; then
    emit_error "No GitOps chart/config changes were produced" "GitOps chart/config update" "gitops_commit_not_created"
  fi
  if [[ "$CHARTS_UPDATED" != "true" ]]; then
    emit_error "Charts were not created or updated" "GitOps charts update" "gitops_charts_update_failed"
  fi
  if [[ "$CONFIGS_UPDATED" != "true" ]]; then
    emit_error "Configs were not created or updated" "GitOps configs update" "gitops_configs_update_failed"
  fi
  if git diff --cached --quiet; then
    emit_error "Git commit was not created" "GitOps commit" "gitops_commit_not_created"
  else
    git commit -m "Deploy ${PROJECT_NAME} ${VERSION} to ${ENVIRONMENT}" >/dev/null
    COMMIT_CREATED=true
    COMMIT_SHA="$(git rev-parse HEAD)"
  fi
  if ! git push origin "$CONFIG_REPO_BRANCH" >/dev/null 2>"$WORK_DIR/git-push.err"; then
    PUSH_COMPLETED=false
    emit_error "Git push failed" "Git push" "gitops_push_failed"
  fi
  PUSH_COMPLETED=true
  REMOTE_COMMIT_SHA="$(git ls-remote origin "refs/heads/${CONFIG_REPO_BRANCH}" 2>"$WORK_DIR/git-ls-remote.err" | awk '{print $1}' | tail -n 1)"
  if [[ -n "$COMMIT_SHA" && "$COMMIT_SHA" == "$REMOTE_COMMIT_SHA" ]]; then
    REMOTE_GIT_VERIFIED=true
  else
    REMOTE_GIT_VERIFIED=false
    emit_error "Remote Git branch does not contain local commit" "remote Git verification" "git_remote_not_updated"
  fi
  echo "STATUS=OK"
  echo "ACTION=gitops-update"
  echo "GITOPS_MODE=${MODE}"
  echo "CONFIG_PATH=${CONFIG_PATH}"
  echo "VERSION=${VERSION}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST}"
  echo "DIFF_FILE=${DIFF_FILE}"
  echo "FILES_EXPECTED=${FILES_EXPECTED}"
  echo "FILES_VERIFIED=${FILES_VERIFIED}"
  echo "FILES_FAILED=${FILES_FAILED}"
  echo "VERIFIED_FILES=${VERIFIED_FILES}"
  echo "FAILED_FILES=${FAILED_FILES}"
  echo "EXPECTED_VERSION=${EXPECTED_VERSION}"
  echo "EXPECTED_DIGEST=${EXPECTED_DIGEST}"
  echo "ACTUAL_VERSION=${ACTUAL_VERSION}"
  echo "ACTUAL_DIGEST=${ACTUAL_DIGEST}"
  echo "CHARTS_UPDATED=${CHARTS_UPDATED}"
  echo "CONFIGS_UPDATED=${CONFIGS_UPDATED}"
  echo "VERSION_APPLIED=${VERSION_APPLIED}"
  echo "DIGEST_APPLIED=${DIGEST_APPLIED}"
  echo "COMMIT_CREATED=${COMMIT_CREATED}"
  echo "COMMIT_SHA=${COMMIT_SHA}"
  echo "PUSH_COMPLETED=${PUSH_COMPLETED}"
  echo "REMOTE_GIT_VERIFIED=${REMOTE_GIT_VERIFIED}"
  echo "REMOTE_COMMIT_SHA=${REMOTE_COMMIT_SHA}"
  echo "NEXT_REQUIRED_INPUT="
  echo "MUTATIONS_PERFORMED=true"
)
