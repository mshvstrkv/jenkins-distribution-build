#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/jenkins-resolve-digest.sh \
    --build-url <exact Jenkins build URL> \
    --expected-version <version> \
    [--self-test]
EOF
}

build_number_from_url() {
  python3 - "$1" <<'PY'
import re, sys
m = re.search(r"/(\d+)/?$", sys.argv[1].rstrip("/"))
print(m.group(1) if m else "")
PY
}

emit_digest() {
  echo "STATUS=${STATUS:-}"
  echo "ACTION=resolve-digest"
  echo "STATE=${STATE:-}"
  echo "BUILD_URL=${BUILD_URL:-}"
  echo "BUILD_NUMBER=${BUILD_NUMBER:-}"
  echo "VERSION=${VERSION:-}"
  echo "IMAGE_DIGEST=${IMAGE_DIGEST:-}"
  echo "DIGEST_SOURCE=${DIGEST_SOURCE:-}"
  echo "DIGEST_URL=${DIGEST_URL:-}"
  echo "DIGEST_BUILD_IDENTITY_VERIFIED=${DIGEST_BUILD_IDENTITY_VERIFIED:-false}"
  echo "NEXT_REQUIRED_INPUT=${NEXT_REQUIRED_INPUT:-}"
  echo "MUTATIONS_PERFORMED=false"
}

fail_digest() {
  STATUS=ERROR
  STATE="$1"
  NEXT_REQUIRED_INPUT="${2:-}"
  emit_digest
  exit 1
}

extract_digest_file() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
matches = {m.lower() for m in re.findall(r"(?:sha256:)?([a-fA-F0-9]{64})", text)}
if len(matches) == 1:
    print(next(iter(matches)))
elif len(matches) > 1:
    sys.exit(2)
else:
    sys.exit(1)
PY
}

extract_digest_from_console() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
patterns = [
    r"(?i)(?:image digest|digest|jib-image\.digest|built and pushed image as digest)[^\n\r]{0,160}(?:sha256:)?([a-f0-9]{64})",
    r"(?i)(?:sha256:)([a-f0-9]{64})[^\n\r]{0,160}(?:image digest|digest|jib-image\.digest)",
]
matches = set()
for pattern in patterns:
    for match in re.findall(pattern, text):
        matches.add(match.lower())
if len(matches) == 1:
    print(next(iter(matches)))
elif len(matches) > 1:
    sys.exit(2)
else:
    sys.exit(1)
PY
}

parse_build_metadata() {
  python3 - "$1" "$BUILD_URL" "$EXPECTED_VERSION" <<'PY'
import json, re, sys
path, expected_url, expected_version = sys.argv[1:]
payload = json.load(open(path, encoding="utf-8"))
api_url = (payload.get("url") or "").rstrip("/")
api_number = "" if payload.get("number") is None else str(payload.get("number"))
expected_number = ""
m = re.search(r"/(\d+)/?$", expected_url.rstrip("/"))
if m:
    expected_number = m.group(1)

def param(name):
    for action in payload.get("actions") or []:
        for item in action.get("parameters") or []:
            if item.get("name") == name:
                value = item.get("value")
                return "" if value is None else str(value)
    return ""

version = param("VERSION") or param("DISTRIBUTIVE_VERSION") or param("DISTRIBUTION_VERSION")
building = payload.get("building")
result = payload.get("result")
print(f"API_BUILD_URL={api_url}")
print(f"API_BUILD_NUMBER={api_number}")
print(f"VERSION={version}")
print(f"BUILDING={'true' if building is True else 'false' if building is False else 'invalid'}")
print(f"RESULT={'' if result is None else result}")
for artifact in payload.get("artifacts") or []:
    print(f"ARTIFACT={artifact.get('fileName','')}|{artifact.get('relativePath','')}")
if api_url != expected_url.rstrip("/") or not expected_number or api_number != expected_number:
    print("STATE=jenkins_build_identity_mismatch")
    sys.exit(10)
if version != expected_version:
    print("STATE=jenkins_build_identity_mismatch")
    sys.exit(10)
if building is True:
    print("STATE=jenkins_build_not_finished")
    sys.exit(11)
if result != "SUCCESS":
    print("STATE=jenkins_build_not_successful")
    sys.exit(12)
PY
}

run_self_tests() {
  local tmp digest_file console zip_file out rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  digest_file="$tmp/jib-image.digest"
  echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$digest_file"
  [[ "$(extract_digest_file "$digest_file")" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] || { echo "DIGEST_SELF_TESTS=FAIL"; exit 1; }
  console="$tmp/console.txt"
  echo "image digest sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >"$console"
  [[ "$(extract_digest_from_console "$console")" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]] || { echo "DIGEST_SELF_TESTS=FAIL"; exit 1; }
  echo "digest sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc and image digest sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" >"$console"
  set +e
  out="$(extract_digest_from_console "$console")"
  rc=$?
  set -e
  [[ $rc -eq 2 ]] || { echo "DIGEST_SELF_TESTS=FAIL"; exit 1; }
  zip_file="$tmp/dist.zip"
  python3 - "$zip_file" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("nested/jib-image.digest", "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
PY
  python3 - "$zip_file" "$tmp/extracted" <<'PY'
import sys, zipfile
zip_path, out_path = sys.argv[1:]
with zipfile.ZipFile(zip_path) as zf:
    names = [n for n in zf.namelist() if n.endswith("jib-image.digest")]
    assert names == ["nested/jib-image.digest"]
    open(out_path, "wb").write(zf.read(names[0]))
PY
  [[ "$(extract_digest_file "$tmp/extracted")" == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" ]] || { echo "DIGEST_SELF_TESTS=FAIL"; exit 1; }
  echo "DIGEST_SELF_TESTS=OK"
}

load_skill_env

BUILD_URL=""
EXPECTED_VERSION=""
BUILD_NUMBER=""
VERSION=""
IMAGE_DIGEST=""
DIGEST_SOURCE=""
DIGEST_URL=""
DIGEST_BUILD_IDENTITY_VERIFIED=false
STATE=""
NEXT_REQUIRED_INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --build-url) require_value "$1" "${2:-}"; BUILD_URL="${2%/}"; shift 2 ;;
    --expected-version) require_value "$1" "${2:-}"; EXPECTED_VERSION="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "$1" ;;
  esac
done

[[ -n "$BUILD_URL" ]] || error_exit "Missing required argument: --build-url" "build URL"
[[ -n "$EXPECTED_VERSION" ]] || error_exit "Missing required argument: --expected-version" "version"
BUILD_NUMBER="$(build_number_from_url "$BUILD_URL")"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || error_exit "Invalid build URL" "build URL"
[[ -n "${JENKINS_USER:-}" ]] || error_exit "Missing required environment variable: JENKINS_USER" "JENKINS_USER"
[[ -n "${JENKINS_TOKEN:-}" ]] || error_exit "Missing required environment variable: JENKINS_TOKEN" "JENKINS_TOKEN"
command -v curl >/dev/null 2>&1 || error_exit "curl is required but was not found" "curl"
command -v python3 >/dev/null 2>&1 || error_exit "python3 is required but was not found" "python3"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
body="$WORK_DIR/build.json"
headers="$WORK_DIR/headers"
err="$WORK_DIR/curl.err"
status="$(curl --silent --show-error --location --globoff --output "$body" --dump-header "$headers" --write-out '%{http_code}' --user "${JENKINS_USER}:${JENKINS_TOKEN}" "${BUILD_URL}/api/json?tree=number,url,result,building,actions[parameters[name,value]],artifacts[fileName,relativePath]" 2>"$err" || true)"
[[ "$status" == "200" ]] || fail_digest "jenkins_build_status_unavailable" "Jenkins build status access"

set +e
metadata="$(parse_build_metadata "$body")"
rc=$?
set -e
VERSION="$(sed -n 's/^VERSION=//p' <<<"$metadata" | tail -n 1)"
case "$rc" in
  0) DIGEST_BUILD_IDENTITY_VERIFIED=true ;;
  10) fail_digest "jenkins_build_identity_mismatch" "matching Jenkins build" ;;
  11) fail_digest "jenkins_build_not_finished" "wait for Jenkins build completion" ;;
  12) fail_digest "jenkins_build_not_successful" "successful Jenkins build" ;;
  *) fail_digest "jenkins_build_status_unavailable" "Jenkins build status access" ;;
esac

artifact_lines="$(sed -n 's/^ARTIFACT=//p' <<<"$metadata")"
digest_path="$(awk -F'|' '$1=="jib-image.digest"{print $2; exit}' <<<"$artifact_lines")"
if [[ -n "$digest_path" ]]; then
  digest_file="$WORK_DIR/jib-image.digest"
  DIGEST_URL="${BUILD_URL}/artifact/${digest_path}"
  curl --silent --show-error --fail --location --output "$digest_file" --user "${JENKINS_USER}:${JENKINS_TOKEN}" "$DIGEST_URL" 2>"$err" || fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log"
  set +e
  IMAGE_DIGEST="$(extract_digest_file "$digest_file")"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) fail_digest "ambiguous_image_digest" "select Jenkins image digest" ;;
    *) fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log" ;;
  esac
  DIGEST_SOURCE="artifact:jib-image.digest"
else
  zip_path="$(awk -F'|' 'tolower($1) ~ /\.zip$/{print $2; exit}' <<<"$artifact_lines")"
  if [[ -n "$zip_path" ]]; then
    zip_file="$WORK_DIR/artifact.zip"
    extracted="$WORK_DIR/jib-image.digest"
    DIGEST_URL="${BUILD_URL}/artifact/${zip_path}"
    curl --silent --show-error --fail --location --output "$zip_file" --user "${JENKINS_USER}:${JENKINS_TOKEN}" "$DIGEST_URL" 2>"$err" || fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log"
    python3 - "$zip_file" "$extracted" <<'PY' || fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log"
import sys, zipfile
zip_path, out_path = sys.argv[1:]
with zipfile.ZipFile(zip_path) as zf:
    matches = [n for n in zf.namelist() if n.endswith("jib-image.digest")]
    if len(matches) != 1:
        sys.exit(1)
    open(out_path, "wb").write(zf.read(matches[0]))
PY
    set +e
    IMAGE_DIGEST="$(extract_digest_file "$extracted")"
    rc=$?
    set -e
    case "$rc" in
      0) ;;
      2) fail_digest "ambiguous_image_digest" "select Jenkins image digest" ;;
      *) fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log" ;;
    esac
    DIGEST_SOURCE="artifact:zip"
  else
    console="$WORK_DIR/consoleText"
    DIGEST_URL="${BUILD_URL}/consoleText"
    curl --silent --show-error --fail --location --output "$console" --user "${JENKINS_USER}:${JENKINS_TOKEN}" "$DIGEST_URL" 2>"$err" || fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log"
    set +e
    IMAGE_DIGEST="$(extract_digest_from_console "$console")"
    rc=$?
    set -e
    case "$rc" in
      0) ;;
      2) fail_digest "ambiguous_image_digest" "select Jenkins image digest" ;;
      *) fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log" ;;
    esac
    DIGEST_SOURCE="consoleText"
  fi
fi

[[ "$IMAGE_DIGEST" =~ ^[a-f0-9]{64}$ ]] || fail_digest "image_digest_not_found" "archive jib-image.digest or expose digest in Jenkins log"
STATUS=OK
emit_digest
