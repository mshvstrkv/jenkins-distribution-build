#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/jenkins-render-job-config.sh \
    --template-config <file> \
    --project-name <name> \
    --job-name <name> \
    --repository-url <url> \
    --branch <branch> \
    [--output <file>] \
    [--scan-config <file> --template-project-name <name> --template-repository-url <url>] \
    [--compare-config <rendered-file> --created-config <created-file>] \
    [--self-test]

Renders an approved Jenkins template config.xml for a new project job.
The script uses an XML parser and updates only approved project-specific fields.
EOF
}

error_exit() {
  echo "STATUS=ERROR"
  echo "ACTION=render-job-config"
  echo "STATE=${2:-}"
  echo "REASON=$1"
  echo "NEXT_REQUIRED_INPUT=${3:-}"
  echo "MUTATIONS_PERFORMED=false"
  exit 1
}

compare_config() {
  python3 - "$COMPARE_CONFIG" "$CREATED_CONFIG" <<'PY'
import sys
import xml.etree.ElementTree as ET

rendered_file, created_file = sys.argv[1:]
allowed_generated_paths = {
    "/project/actions",
    "/flow-definition/actions",
}

def lname(elem):
    return elem.tag.rsplit("}", 1)[-1]

def path_join(parent, elem):
    return f"{parent}/{lname(elem)}"

def parse(path):
    try:
        return ET.parse(path).getroot()
    except Exception as exc:
        print("STATUS=ERROR")
        print("ACTION=compare-job-config")
        print("STATE=jenkins_created_job_config_mismatch")
        print(f"REASON=Unable to parse Jenkins config XML: {exc}")
        print("CONFIG_DIFF_PATHS=")
        print("NEXT_REQUIRED_INPUT=review created Jenkins job configuration")
        print("MUTATIONS_PERFORMED=false")
        sys.exit(1)

def normalized_text(value):
    if value is None:
        return ""
    return " ".join(value.split())

def normalize(elem, path=""):
    current = path_join(path, elem)
    if current in allowed_generated_paths:
        return None
    children = []
    for child in list(elem):
        normalized = normalize(child, current)
        if normalized is not None:
            children.append(normalized)
    attrs = tuple(sorted((k, normalized_text(v)) for k, v in elem.attrib.items()))
    text = normalized_text(elem.text)
    return (lname(elem), attrs, text, tuple(children))

def collect_paths(elem, out, path=""):
    current = path_join(path, elem)
    if current in allowed_generated_paths:
        return
    out.add(current)
    for attr in elem.attrib:
        out.add(f"{current}/@{attr}")
    for child in list(elem):
        collect_paths(child, out, current)

rendered_root = parse(rendered_file)
created_root = parse(created_file)
if normalize(rendered_root) == normalize(created_root):
    print("STATUS=OK")
    print("ACTION=compare-job-config")
    print("CONFIG_DIFF_PATHS=")
    print("MUTATIONS_PERFORMED=false")
    sys.exit(0)

rendered_paths = set()
created_paths = set()
collect_paths(rendered_root, rendered_paths)
collect_paths(created_root, created_paths)
diff_paths = sorted(rendered_paths.symmetric_difference(created_paths))
if not diff_paths:
    diff_paths = ["/" + lname(rendered_root)]

print("STATUS=ERROR")
print("ACTION=compare-job-config")
print("STATE=jenkins_created_job_config_mismatch")
print("REASON=Created Jenkins job config differs from rendered config")
print(f"CONFIG_DIFF_PATHS={','.join(diff_paths[:50])}")
print("NEXT_REQUIRED_INPUT=review created Jenkins job configuration")
print("MUTATIONS_PERFORMED=false")
sys.exit(1)
PY
}

scan_config() {
  python3 - "$SCAN_CONFIG" "$TEMPLATE_PROJECT_NAME" "$TEMPLATE_REPOSITORY_URL" "$PROJECT_NAME" "$REPOSITORY_URL" <<'PY'
import sys
import xml.etree.ElementTree as ET

config_file, template_project_name, template_repo_url, project_name, repository_url = sys.argv[1:]

def lname(elem):
    return elem.tag.rsplit("}", 1)[-1]

def fail(paths):
    safe_paths = sorted(set(paths))
    print("STATUS=ERROR")
    print("ACTION=scan-job-config-template-references")
    print("STATE=jenkins_template_requires_review")
    print("REASON=Template contains project-specific references outside approved fields")
    print(f"TEMPLATE_REFERENCE_COUNT={len(safe_paths)}")
    print(f"TEMPLATE_REFERENCE_PATHS={','.join(safe_paths)}")
    print("NEXT_REQUIRED_INPUT=review Jenkins template project-specific fields")
    print("MUTATIONS_PERFORMED=false")
    sys.exit(1)

def path_join(parent, elem):
    return f"{parent}/{lname(elem)}"

references = []
if template_project_name and template_project_name != project_name:
    references.append(template_project_name)
if template_repo_url and template_repo_url != repository_url:
    references.append(template_repo_url)

try:
    root = ET.parse(config_file).getroot()
except Exception as exc:
    print("STATUS=ERROR")
    print("ACTION=scan-job-config-template-references")
    print("STATE=jenkins_template_requires_review")
    print(f"REASON=Unable to parse rendered config.xml: {exc}")
    print("TEMPLATE_REFERENCE_COUNT=0")
    print("TEMPLATE_REFERENCE_PATHS=")
    print("NEXT_REQUIRED_INPUT=review Jenkins template project-specific fields")
    print("MUTATIONS_PERFORMED=false")
    sys.exit(1)

paths = []

def inspect_value(value, path):
    if not value:
        return
    for reference in references:
        if reference and reference in value:
            paths.append(path)
            return

def walk(elem, path):
    current = path_join(path, elem)
    inspect_value(elem.text or "", current)
    for attr, value in elem.attrib.items():
        inspect_value(value, f"{current}/@{attr}")
    for child in list(elem):
        walk(child, current)

walk(root, "")
if paths:
    fail(paths)

print("STATUS=OK")
print("ACTION=scan-job-config-template-references")
print("TEMPLATE_REFERENCE_COUNT=0")
print("TEMPLATE_REFERENCE_PATHS=")
print("MUTATIONS_PERFORMED=false")
PY
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || error_exit "Missing value for ${option}" "" "${option}"
}

render_config() {
  python3 - "$TEMPLATE_CONFIG" "$PROJECT_NAME" "$JOB_NAME" "$REPOSITORY_URL" "$BRANCH" "$OUTPUT_FILE" <<'PY'
import os
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

template_config, project_name, job_name, repository_url, branch, output_file = sys.argv[1:]
required_params = {"BRANCH", "VERSION"}
optional_params = {"DISTRIBUTION_TYPE"}

def csv(values):
    return ",".join(sorted(values))

def emit_parameter_metadata(supported_params=None, missing_required=None):
    supported_params = set(supported_params or [])
    missing_required = sorted(missing_required or [])
    print(f"REQUIRED_PARAMETERS={csv(required_params)}")
    print(f"SUPPORTED_PARAMETERS={csv(supported_params)}")
    print(f"OPTIONAL_PARAMETERS={csv(optional_params)}")
    print(f"MISSING_REQUIRED_PARAMETERS={','.join(missing_required)}")
    print(f"DISTRIBUTION_TYPE_PARAMETER_SUPPORTED={'true' if 'DISTRIBUTION_TYPE' in supported_params else 'false'}")

def fail(state, reason, next_input="", missing="", unsupported="", supported_params=None):
    print("STATUS=ERROR")
    print("ACTION=render-job-config")
    print(f"STATE={state}")
    print(f"REASON={reason}")
    if missing:
        print(f"MISSING_PARAMETERS={missing}")
    emit_parameter_metadata(supported_params, missing.split(",") if missing else [])
    if unsupported:
        print(f"UNSUPPORTED_FIELDS={unsupported}")
    print("TEMPLATE_REFERENCE_COUNT=0")
    print("TEMPLATE_REFERENCE_PATHS=")
    print(f"NEXT_REQUIRED_INPUT={next_input}")
    print("MUTATIONS_PERFORMED=false")
    sys.exit(1)

def lname(elem):
    return elem.tag.rsplit("}", 1)[-1]

def text(elem):
    return elem.text or ""

def looks_like_repo_url(value):
    value = value.strip()
    return bool(
        value
        and (
            value.startswith(("ssh://", "git@", "http://", "https://"))
            or ".git" in value
            or "bitbucket" in value.lower()
        )
    )

def slug_from_repo(value):
    parsed = urllib.parse.urlparse(value)
    path = parsed.path if parsed.scheme else value
    path = path.rstrip("/")
    if ":" in path and "/" in path and not parsed.scheme:
        path = path.split(":", 1)[-1]
    base = path.rsplit("/", 1)[-1]
    if base.endswith(".git"):
        base = base[:-4]
    return base

def parameter_definitions(root):
    for container in root.iter():
        if lname(container) != "parameterDefinitions":
            continue
        for param in list(container):
            name = ""
            for child in list(param):
                if lname(child) == "name":
                    name = text(child).strip()
                    break
            if name:
                yield name, param

def set_default_value(param, value):
    for child in list(param):
        if lname(child) == "defaultValue":
            child.text = value
            return

def xml_path(parent, elem):
    return f"{parent}/{lname(elem)}"

def render_properties_content(value, mapping):
    if value is None:
        return value
    rendered = []
    for line in value.splitlines():
        key, sep, current = line.partition("=")
        if sep and key.strip() in mapping:
            rendered.append(f"{key}={mapping[key.strip()]}")
        else:
            rendered.append(line)
    return "\n".join(rendered)

def set_direct_child_text(elem, child_name, value):
    for child in list(elem):
        if lname(child) == child_name:
            child.text = value

def properties_content_value(value, key):
    for line in (value or "").splitlines():
        current_key, sep, current_value = line.partition("=")
        if sep and current_key.strip() == key:
            return current_value.strip()
    return ""

def branch_parameter_remote_url(params):
    param = params.get("BRANCH")
    if param is None:
        return ""
    for child in list(param):
        if lname(child) == "remoteURL":
            return text(child).strip()
    return ""

def env_repo_url(root):
    for elem in root.iter():
        if lname(elem) == "propertiesContent":
            value = properties_content_value(elem.text or "", "REPO_URL")
            if value:
                return value
    return ""

def pipeline_definition(root):
    for elem in root.iter():
        if lname(elem) == "definition":
            return elem
    return None

def first_repo_url(root):
    for elem in root.iter():
        if lname(elem).lower() in {"url", "remote", "remoteurl", "repositoryurl", "repository"}:
            value = text(elem).strip()
            if looks_like_repo_url(value):
                return value
    return ""

def first_branch_spec(root):
    for elem in root.iter():
        if not lname(elem).endswith("BranchSpec"):
            continue
        for child in list(elem):
            if lname(child) == "name":
                return text(child).strip()
    return ""

def first_script_path(root):
    for elem in root.iter():
        if lname(elem) == "scriptPath":
            return text(elem).strip()
    return ""

try:
    tree = ET.parse(template_config)
except Exception as exc:
    fail("jenkins_template_incompatible", f"Unable to parse template config.xml: {exc}", "compatible Jenkins template")

root = tree.getroot()
params = dict(parameter_definitions(root))
supported_params = set(params)
missing = sorted(required_params - supported_params)
if missing:
    fail(
        "jenkins_template_incompatible",
        "Jenkins template is missing required build parameters",
        "compatible Jenkins template",
        ",".join(missing),
        supported_params=supported_params,
    )

template_env_repo_url = env_repo_url(root)
template_branch_remote_url = branch_parameter_remote_url(params)
if not template_env_repo_url or not template_branch_remote_url:
    fail(
        "jenkins_template_incompatible",
        "Jenkins template does not contain supported application repository fields",
        "compatible Jenkins template",
        unsupported="EnvInject REPO_URL or BRANCH remoteURL",
        supported_params=supported_params,
    )

template_repo_url = template_env_repo_url
template_project_slug = slug_from_repo(template_repo_url)
if not repository_url:
    fail("repository_url_required", "Repository URL is required to render Jenkins job config", "repository URL")

env_key_mapping = {
    "REPO_URL": repository_url,
    "SONAR_PROJECT_KEY": f"com.sber.aipay:{project_name}",
}
for elem in root.iter():
    if lname(elem) == "propertiesContent":
        elem.text = render_properties_content(elem.text or "", env_key_mapping)

approved_text_fields = {"displayName", "description", "defaultValue"}
for elem in root.iter():
    if lname(elem) not in approved_text_fields or elem.text is None:
        continue
    value = elem.text
    if template_project_slug and template_project_slug != project_name:
        value = value.replace(template_project_slug, project_name)
    value = value.replace("{{PROJECT_NAME}}", project_name)
    value = value.replace("{{JOB_NAME}}", job_name)
    value = value.replace("{{BRANCH}}", branch)
    elem.text = value

for name, param in params.items():
    if name == "BRANCH":
        set_default_value(param, branch)
        set_direct_child_text(param, "remoteURL", repository_url)
    elif name in {"PROJECT_NAME", "PROJECT", "SERVICE_NAME", "APP_NAME", "APPLICATION_NAME"}:
        set_default_value(param, project_name)
    elif name == "JOB_NAME":
        set_default_value(param, job_name)

references = []
if template_project_slug and template_project_slug != project_name:
    references.append(template_project_slug)
if template_repo_url and template_repo_url != repository_url:
    references.append(template_repo_url)

reference_paths = []

def inspect_reference(value, path):
    if not value:
        return
    for reference in references:
        if reference and reference in value:
            reference_paths.append(path)
            return

def scan_rendered(elem, path):
    current = xml_path(path, elem)
    inspect_reference(elem.text or "", current)
    for attr, value in elem.attrib.items():
        inspect_reference(value, f"{current}/@{attr}")
    for child in list(elem):
        scan_rendered(child, current)

scan_rendered(root, "")
if reference_paths:
    safe_paths = sorted(set(reference_paths))
    print("STATUS=ERROR")
    print("ACTION=render-job-config")
    print("STATE=jenkins_template_requires_review")
    print("REASON=Template contains project-specific references outside approved fields")
    emit_parameter_metadata(supported_params, [])
    print(f"TEMPLATE_REFERENCE_COUNT={len(safe_paths)}")
    print(f"TEMPLATE_REFERENCE_PATHS={','.join(safe_paths)}")
    print("NEXT_REQUIRED_INPUT=review Jenkins template project-specific fields")
    print("MUTATIONS_PERFORMED=false")
    sys.exit(1)

env_repo_rendered = env_repo_url(root)
branch_remote_rendered = branch_parameter_remote_url(params)
pipeline_root = pipeline_definition(root)
pipeline_repo_url = first_repo_url(pipeline_root) if pipeline_root is not None else ""
pipeline_branch_spec = first_branch_spec(pipeline_root) if pipeline_root is not None else ""
pipeline_script_path = first_script_path(pipeline_root) if pipeline_root is not None else ""

if output_file:
    os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)
    tree.write(output_file, encoding="utf-8", xml_declaration=True)
else:
    sys.stdout.buffer.write(ET.tostring(root, encoding="utf-8", xml_declaration=True))
    sys.stdout.write("\n")

print("STATUS=OK")
print("ACTION=render-job-config")
print(f"PROJECT_NAME={project_name}")
print(f"JOB_NAME={job_name}")
print(f"REPOSITORY_URL={repository_url}")
print(f"APPLICATION_REPOSITORY_URL={repository_url}")
print(f"ENV_REPO_URL={env_repo_rendered}")
print(f"BRANCH_PARAMETER_REPOSITORY_URL={branch_remote_rendered}")
print(f"PIPELINE_REPOSITORY_URL={pipeline_repo_url}")
print(f"PIPELINE_BRANCH_SPEC={pipeline_branch_spec}")
print(f"PIPELINE_SCRIPT_PATH={pipeline_script_path}")
print("MISSING_PARAMETERS=")
emit_parameter_metadata(supported_params, [])
print("UNSUPPORTED_FIELDS=")
print("TEMPLATE_REFERENCE_COUNT=0")
print("TEMPLATE_REFERENCE_PATHS=")
print(f"OUTPUT_FILE={output_file}")
print("MUTATIONS_PERFORMED=false")
PY
}

run_self_tests() {
  local tmp template rendered output rc bad_template missing_branch_template no_dtype_template no_dtype_rendered hidden_shell downstream notification bad_properties created_metadata created_hidden
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  template="$tmp/template.xml"
  rendered="$tmp/rendered.xml"
  bad_template="$tmp/bad-template.xml"
  missing_branch_template="$tmp/missing-branch-template.xml"
  no_dtype_template="$tmp/no-distribution-type-template.xml"
  no_dtype_rendered="$tmp/no-distribution-type-rendered.xml"
  hidden_shell="$tmp/hidden-shell.xml"
  downstream="$tmp/downstream.xml"
  notification="$tmp/notification.xml"
  bad_properties="$tmp/bad-properties.xml"
  created_metadata="$tmp/created-metadata.xml"
  created_hidden="$tmp/created-hidden.xml"

  cat >"$template" <<'XML'
<project>
  <displayName>ai-payments-merchant-registry</displayName>
  <description>Build ai-payments-merchant-registry</description>
  <scm class="hudson.plugins.git.GitSCM">
    <userRemoteConfigs>
      <hudson.plugins.git.UserRemoteConfig>
        <url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url>
      </hudson.plugins.git.UserRemoteConfig>
    </userRemoteConfigs>
  </scm>
  <properties>
    <EnvInjectJobProperty>
      <info>
        <propertiesContent>REPO_URL=ssh://git@example.org/team/ai-payments-merchant-registry.git
SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-merchant-registry
STATIC_VALUE=keep</propertiesContent>
      </info>
    </EnvInjectJobProperty>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>BRANCH</name>
          <defaultValue>develop-corp</defaultValue>
          <remoteURL>ssh://git@example.org/team/ai-payments-merchant-registry.git</remoteURL>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>VERSION</name>
          <defaultValue>IFT-0.0.1</defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>DISTRIBUTION_TYPE</name>
          <defaultValue>ift</defaultValue>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition>
    <scm>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>2.0</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>pipeline/csdo/universal-sbrf-nexus-deploy.groovy</scriptPath>
  </definition>
</project>
XML

  bash "$0" \
    --template-config "$template" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test \
    --output "$rendered" >"$tmp/render.out"

  grep -q "ssh://git@example.org/team/ai-payments-auth.git" "$rendered" || { echo "FAIL repository replacement"; exit 1; }
  ! grep -q "ai-payments-merchant-registry" "$rendered" || { echo "FAIL template project reference remains"; exit 1; }
  grep -q "<defaultValue>feature/test</defaultValue>" "$rendered" || { echo "FAIL branch default replacement"; exit 1; }
  grep -q "REPO_URL=ssh://git@example.org/team/ai-payments-auth.git" "$rendered" || { echo "FAIL EnvInject REPO_URL replacement"; exit 1; }
  grep -q "SONAR_PROJECT_KEY=com.sber.aipay:ai-payments-auth" "$rendered" || { echo "FAIL SONAR_PROJECT_KEY replacement"; exit 1; }
  grep -q "<remoteURL>ssh://git@example.org/team/ai-payments-auth.git</remoteURL>" "$rendered" || { echo "FAIL BRANCH remoteURL replacement"; exit 1; }
  grep -q "ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git" "$rendered" || { echo "FAIL pipeline repository changed"; exit 1; }
  grep -q "<name>2.0</name>" "$rendered" || { echo "FAIL BranchSpec changed"; exit 1; }
  grep -q "<scriptPath>pipeline/csdo/universal-sbrf-nexus-deploy.groovy</scriptPath>" "$rendered" || { echo "FAIL scriptPath changed"; exit 1; }
  grep -q "APPLICATION_REPOSITORY_URL=ssh://git@example.org/team/ai-payments-auth.git" "$tmp/render.out" || { echo "FAIL application repository output"; exit 1; }
  grep -q "ENV_REPO_URL=ssh://git@example.org/team/ai-payments-auth.git" "$tmp/render.out" || { echo "FAIL env repo output"; exit 1; }
  grep -q "BRANCH_PARAMETER_REPOSITORY_URL=ssh://git@example.org/team/ai-payments-auth.git" "$tmp/render.out" || { echo "FAIL branch repo output"; exit 1; }
  grep -q "PIPELINE_REPOSITORY_URL=ssh://sc@api.sc-cd.sber.ru:7998/CI00708274/ci00682834_cs-pipeline.git" "$tmp/render.out" || { echo "FAIL pipeline repository output"; exit 1; }
  grep -q "PIPELINE_BRANCH_SPEC=2.0" "$tmp/render.out" || { echo "FAIL pipeline branch output"; exit 1; }
  grep -q "PIPELINE_SCRIPT_PATH=pipeline/csdo/universal-sbrf-nexus-deploy.groovy" "$tmp/render.out" || { echo "FAIL pipeline script output"; exit 1; }
  grep -q "DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=true" "$tmp/render.out" || { echo "FAIL distribution type supported output"; exit 1; }

  grep -v '<name>DISTRIBUTION_TYPE</name>' "$template" >"$no_dtype_template"
  bash "$0" \
    --template-config "$no_dtype_template" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test \
    --output "$no_dtype_rendered" >"$tmp/no-dtype-render.out"
  grep -q "STATUS=OK" "$tmp/no-dtype-render.out" || { echo "FAIL no distribution type accepted"; exit 1; }
  grep -q "DISTRIBUTION_TYPE_PARAMETER_SUPPORTED=false" "$tmp/no-dtype-render.out" || { echo "FAIL no distribution type support output"; exit 1; }

  python3 - "$rendered" "$created_metadata" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("<project>", "<project><actions><hudson.model.CauseAction /></actions>", 1)
open(target, "w", encoding="utf-8").write(text)
PY
  bash "$0" --compare-config "$rendered" --created-config "$created_metadata" >"$tmp/compare-metadata.out"
  grep -q "STATUS=OK" "$tmp/compare-metadata.out" || { echo "FAIL harmless metadata compare"; exit 1; }

  python3 - "$rendered" "$created_hidden" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("</project>", "<builders><hudson.tasks.Shell><command>custom hidden change</command></hudson.tasks.Shell></builders></project>")
open(target, "w", encoding="utf-8").write(text)
PY
  set +e
  output="$(bash "$0" --compare-config "$rendered" --created-config "$created_hidden" 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL hidden config difference accepted"; exit 1; }
  grep -q "STATE=jenkins_created_job_config_mismatch" <<<"$output" || { echo "FAIL config mismatch state"; exit 1; }
  grep -q "CONFIG_DIFF_PATHS=.*builders" <<<"$output" || { echo "FAIL config diff paths"; exit 1; }

  python3 - "$template" "$hidden_shell" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("</project>", "<builders><hudson.tasks.Shell><command>build ai-payments-merchant-registry</command></hudson.tasks.Shell></builders></project>")
open(target, "w", encoding="utf-8").write(text)
PY
  set +e
  output="$(bash "$0" \
    --template-config "$hidden_shell" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL hidden shell reference accepted"; exit 1; }
  grep -q "STATE=jenkins_template_requires_review" <<<"$output" || { echo "FAIL hidden shell state"; exit 1; }
  grep -q "/project/builders/hudson.tasks.Shell/command" <<<"$output" || { echo "FAIL hidden shell path"; exit 1; }

  python3 - "$template" "$downstream" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("</project>", "<publishers><hudson.tasks.BuildTrigger><childProjects>ai-payments-merchant-registry-publish</childProjects></hudson.tasks.BuildTrigger></publishers></project>")
open(target, "w", encoding="utf-8").write(text)
PY
  set +e
  output="$(bash "$0" \
    --template-config "$downstream" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL downstream reference accepted"; exit 1; }
  grep -q "STATE=jenkins_template_requires_review" <<<"$output" || { echo "FAIL downstream state"; exit 1; }
  grep -q "/project/publishers/hudson.tasks.BuildTrigger/childProjects" <<<"$output" || { echo "FAIL downstream path"; exit 1; }

  python3 - "$template" "$notification" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("</project>", "<publishers><hudson.tasks.Mailer><recipients>ai-payments-merchant-registry@example.org</recipients></hudson.tasks.Mailer></publishers></project>")
open(target, "w", encoding="utf-8").write(text)
PY
  set +e
  output="$(bash "$0" \
    --template-config "$notification" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL notification reference accepted"; exit 1; }
  grep -q "STATE=jenkins_template_requires_review" <<<"$output" || { echo "FAIL notification state"; exit 1; }
  grep -q "/project/publishers/hudson.tasks.Mailer/recipients" <<<"$output" || { echo "FAIL notification path"; exit 1; }

  python3 - "$template" "$bad_properties" <<'PY'
import sys
source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
text = text.replace("STATIC_VALUE=keep", "CUSTOM_PROJECT=ai-payments-merchant-registry")
open(target, "w", encoding="utf-8").write(text)
PY
  set +e
  output="$(bash "$0" \
    --template-config "$bad_properties" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL hidden propertiesContent reference accepted"; exit 1; }
  grep -q "STATE=jenkins_template_requires_review" <<<"$output" || { echo "FAIL propertiesContent reference state"; exit 1; }
  grep -q "/project/properties/EnvInjectJobProperty/info/propertiesContent" <<<"$output" || { echo "FAIL propertiesContent reference path"; exit 1; }

  grep -v '<name>VERSION</name>' "$template" >"$bad_template"
  set +e
  output="$(bash "$0" \
    --template-config "$bad_template" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL incompatible template accepted"; exit 1; }
  grep -q "STATE=jenkins_template_incompatible" <<<"$output" || { echo "FAIL incompatible template state"; exit 1; }
  grep -q "MISSING_REQUIRED_PARAMETERS=VERSION" <<<"$output" || { echo "FAIL missing version parameter"; exit 1; }

  grep -v '<name>BRANCH</name>' "$template" >"$missing_branch_template"
  set +e
  output="$(bash "$0" \
    --template-config "$missing_branch_template" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url ssh://git@example.org/team/ai-payments-auth.git \
    --branch feature/test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL missing branch template accepted"; exit 1; }
  grep -q "STATE=jenkins_template_incompatible" <<<"$output" || { echo "FAIL missing branch template state"; exit 1; }
  grep -q "MISSING_REQUIRED_PARAMETERS=BRANCH" <<<"$output" || { echo "FAIL missing branch parameter"; exit 1; }

  set +e
  output="$(bash "$0" \
    --template-config "$template" \
    --project-name ai-payments-auth \
    --job-name ai-payments-auth-build \
    --repository-url "" \
    --branch feature/test 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || { echo "FAIL missing repository URL accepted"; exit 1; }
  grep -q "STATE=repository_url_required" <<<"$output" || { echo "FAIL repository_url_required state"; exit 1; }

  echo "JENKINS_RENDER_JOB_CONFIG_SELF_TESTS=OK"
}

TEMPLATE_CONFIG=""
SCAN_CONFIG=""
COMPARE_CONFIG=""
CREATED_CONFIG=""
TEMPLATE_PROJECT_NAME=""
TEMPLATE_REPOSITORY_URL=""
PROJECT_NAME=""
JOB_NAME=""
REPOSITORY_URL=""
BRANCH=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) run_self_tests; exit 0 ;;
    --template-config) require_value "$1" "${2:-}"; TEMPLATE_CONFIG="$2"; shift 2 ;;
    --scan-config) require_value "$1" "${2:-}"; SCAN_CONFIG="$2"; shift 2 ;;
    --compare-config) require_value "$1" "${2:-}"; COMPARE_CONFIG="$2"; shift 2 ;;
    --created-config) require_value "$1" "${2:-}"; CREATED_CONFIG="$2"; shift 2 ;;
    --template-project-name) require_value "$1" "${2:-}"; TEMPLATE_PROJECT_NAME="$2"; shift 2 ;;
    --template-repository-url) require_value "$1" "${2:-}"; TEMPLATE_REPOSITORY_URL="$2"; shift 2 ;;
    --project-name) require_value "$1" "${2:-}"; PROJECT_NAME="$2"; shift 2 ;;
    --job-name) require_value "$1" "${2:-}"; JOB_NAME="$2"; shift 2 ;;
    --repository-url)
      [[ $# -ge 2 ]] || error_exit "Missing value for --repository-url" "" "--repository-url"
      REPOSITORY_URL="${2:-}"
      shift 2
      ;;
    --branch) require_value "$1" "${2:-}"; BRANCH="$2"; shift 2 ;;
    --output) require_value "$1" "${2:-}"; OUTPUT_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) error_exit "Unknown argument: $1" "" "$1" ;;
  esac
done

if [[ -n "$SCAN_CONFIG" ]]; then
  [[ -f "$SCAN_CONFIG" ]] || error_exit "Scan config does not exist" "jenkins_template_requires_review" "config.xml"
  scan_config
  exit 0
fi

if [[ -n "$COMPARE_CONFIG" || -n "$CREATED_CONFIG" ]]; then
  [[ -n "$COMPARE_CONFIG" ]] || error_exit "Missing rendered config for comparison" "jenkins_created_job_config_mismatch" "rendered config"
  [[ -n "$CREATED_CONFIG" ]] || error_exit "Missing created config for comparison" "jenkins_created_job_config_mismatch" "created config"
  [[ -f "$COMPARE_CONFIG" ]] || error_exit "Rendered config does not exist" "jenkins_created_job_config_mismatch" "rendered config"
  [[ -f "$CREATED_CONFIG" ]] || error_exit "Created config does not exist" "jenkins_created_job_config_mismatch" "created config"
  compare_config
  exit 0
fi

[[ -n "$TEMPLATE_CONFIG" ]] || error_exit "Missing template config" "" "template config"
[[ -f "$TEMPLATE_CONFIG" ]] || error_exit "Template config does not exist" "jenkins_template_incompatible" "template config"
[[ -n "$PROJECT_NAME" ]] || error_exit "Missing project name" "" "project name"
[[ -n "$JOB_NAME" ]] || error_exit "Missing job name" "" "job name"
[[ -n "$BRANCH" ]] || error_exit "Missing branch" "" "branch"

render_config
