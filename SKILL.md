---
name: jenkins-distribution-build
description: Use when the user wants to build a distributive through Jenkins and optionally deliver it to a test or release environment through GitOps and Argo CD wrappers.
---

# Jenkins Distribution Build Skill

## Goal

Run the full managed distributive workflow only through wrapper scripts.

For new work, the preferred entrypoint is:

`scripts/distribution`

For a full user request such as "build a test distributive and deploy it to the test stand", execute:

`scripts/distribution deploy`

For a safe end-to-end validation without external mutations, use:

`scripts/distribution preflight`

The wrapper scripts are the source of truth for lookup, build, versioning, failure analysis, GitOps configuration, Argo CD operations, and deployment state decisions.

Configuration and credentials are loaded by wrappers from the skill root `.env` file when present. The skill must not read or print `.env`.

## CLI Policy

The only preferred entrypoint is:

`scripts/distribution`

Legacy wrapper scripts exist for backward compatibility and implementation compatibility.

Use these commands:
- read-only validation: `scripts/distribution preflight`
- full delivery: `scripts/distribution deploy`
- Jenkins-only build: `scripts/distribution build`
- version resolution: `scripts/distribution version`
- failure analysis: `scripts/distribution analyze`
- GitOps read-only check: `scripts/distribution gitops-check`
- GitOps mutation stage: `scripts/distribution gitops-update`
- Argo CD read-only check: `scripts/distribution argocd-check`
- Argo CD sync stage: `scripts/distribution argocd-sync`

The skill must not reproduce CLI business logic.

The skill must not call `curl`, `git`, or `argocd` directly.

The skill must pass arguments to the CLI and report machine output.

## Jenkins Build Policy

`scripts/distribution build` runs the Jenkins-only orchestrated flow.

It uses:
- `scripts/jenkins-lookup.sh`
- `scripts/version-resolver.sh`
- `scripts/jenkins-build.sh --job-name <resolved> --skip-lookup`
- `scripts/jenkins-analyze-failure.sh` when a completed Jenkins build is not `SUCCESS`

It must not run:
- GitOps checks
- GitOps updates
- Argo CD checks
- Argo CD create/update/sync
- Kubernetes operations

`scripts/jenkins-build.sh` is a low-level compatibility wrapper. The skill should not use it directly unless the user explicitly asks for the low-level wrapper.

## Full Workflow

`scripts/distribution deploy` owns this workflow:

Jenkins lookup
-> version resolution
-> Jenkins build with `--wait`
-> Jenkins result handling
-> failure analysis when build result is not `SUCCESS`
-> GitOps and Argo CD checks
-> GitOps configuration create/update
-> Argo CD application create/update
-> Argo CD sync and health wait
-> final machine-readable output

The skill must not perform any workflow step directly.

## Distribution Type Policy

Canonical distribution types:
- `ift` for test distributives
- `release` for release distributives

Aliases are normalized by wrappers:
- `test` -> `ift`
- `testing` -> `ift`
- `ift` -> `ift`
- `release` -> `release`
- `prod` -> `release`
- `production` -> `release`

If the user asks for a test distributive, pass:

`--distribution-type ift`

If the user asks for a release distributive, pass:

`--distribution-type release`

If the user asks only to build a distributive and the type cannot be determined from the current request, ask for exactly one value:

`ift` or `release`

Do not offer arbitrary distribution type values.

Do not use `snapshot`.

## Version Policy

The agent must never calculate distributive versions.

Version resolution belongs to `scripts/distribution version`, which delegates to `scripts/version-resolver.sh`.

Full delivery invokes version resolution before Jenkins build and passes the resolved `--version` to the build wrapper.

If the user provides an explicit version, pass it as:

`--version <version>`

If the user does not provide a version, do not ask for it. Allow the wrapper to resolve it automatically.

IFT versions:
- format: `IFT-X.Y.Z`
- start from `IFT-0.0.1`
- increment only the last numeric segment
- ignore release versions

Release versions:
- format: `D-XX.YYY.ZZ`
- start from `D-00.000.01`
- increment only the last numeric segment preserving padding
- ignore IFT versions

## Execution Policy

For full delivery requests, execute `scripts/distribution deploy`.

For preflight requests, execute `scripts/distribution preflight`.

Real preflight, Jenkins build, GitOps, and Argo CD operations require:

`--execution-environment corporate`

Outside the corporate network, run only local validation commands.

For "build distributive" requests, include `--wait`.

Do not stop after Jenkins queueing. The wrapper must wait for the final Jenkins result.

Do not ask for confirmation before Jenkins build. The user request to build is confirmation.

Do not call `scripts/jenkins-lookup.sh`, `scripts/jenkins-build.sh`, `scripts/deployment-lookup.sh`, `scripts/argocd-deploy.sh`, or `scripts/jenkins-analyze-failure.sh` directly for the full workflow unless the user explicitly requests that lower-level wrapper.

Do not create your own execution plan.

Do not explain what you are going to do before wrapper execution.

Execute wrappers directly.

## Corporate Environment Policy

This skill is designed to run inside the corporate network.

Real Jenkins, Bitbucket, Argo CD, and Kubernetes operations must only be executed from an environment with corporate network access.

Outside the corporate environment, run only:
- syntax checks
- self-tests
- fixture tests
- dry-run
- local template rendering validation

Do not treat DNS, TLS, proxy, VPN, or network failures outside the corporate environment as wrapper implementation defects.

If corporate services are unreachable:
- stop immediately
- report that corporate network access is required
- do not diagnose VPN, proxy, certificates, or hostnames
- do not modify wrappers
- do not retry with insecure options

Do not:
- change Jenkins URL
- change proxy settings
- change `NO_PROXY`
- disable TLS verification
- use `curl -k`
- import certificates
- change trust stores
- search for corporate access workarounds

Never automatically infer `corporate` mode from DNS, TLS, or host reachability.

## Validation Policy

Local validation is the default.

Local validation uses:

`scripts/distribution deploy --self-test`

It checks only:
- syntax
- version logic
- aliases
- template rendering
- path safety
- deployment-state fixtures
- parameter mapping fixtures

Local validation must not access:
- Jenkins
- corporate Bitbucket
- Argo CD
- Kubernetes

Corporate preflight uses:

`scripts/distribution preflight --execution-environment corporate`

Corporate preflight is only for environments inside the corporate network and checks:
- Jenkins
- Bitbucket through Git SSH
- Argo CD
- deployment state

If wrappers return `STATE=corporate_environment_required` or `STATE=corporate_network_unavailable`, stop immediately and report:
- `REASON`
- `NEXT_REQUIRED_INPUT`

Do not run network diagnostics such as `nslookup`, `nc`, `openssl s_client`, proxy inspection, certificate inspection, or hostname substitution.

## Preflight Policy

Preflight is read-only and must run through:

`scripts/distribution preflight`

The preflight wrapper collects independent Jenkins, GitOps, and Argo CD stage results.

Preflight must not:
- start a Jenkins build
- create a Jenkins job
- commit to GitOps
- push to GitOps
- create an Argo CD Application
- sync Argo CD
- modify the cluster

Do not stop after the first failed stage if other read-only stages can still run.

Do not interpret, duplicate, or reproduce preflight logic in the agent.

Report the wrapper's full stage summary.

`scripts/preflight.sh` and `scripts/distribution-delivery.sh --preflight` are compatibility paths. The preferred CLI path is `scripts/distribution preflight`.

## Delivery Policy

Full build and deployment runs only through:

`scripts/distribution deploy`

`scripts/distribution-delivery.sh` is the legacy delivery wrapper behind the CLI.

The delivery wrapper must not contain duplicated preflight implementation.

Delivery flow is:

Jenkins build
-> wait
-> failure analysis or success
-> GitOps update/create
-> Argo CD create/update/sync

## Failure Policy

If Jenkins result is `FAILURE`, `UNSTABLE`, or `ABORTED`, the orchestrator runs:

`scripts/jenkins-analyze-failure.sh`

The skill must report wrapper output:
- `FAILURE_CATEGORY`
- `FAILURE_SUMMARY`
- `LOG_FILE`
- `SUGGESTED_ACTION`

The skill must not:
- read Jenkins console log directly
- analyze build errors itself
- edit project files automatically
- commit changes
- rerun Jenkins automatically

Wait for a separate user request before changing source code or rerunning a build after failure.

## Deployment Policy

First deployment is decided only by wrapper output:

`FIRST_DEPLOYMENT=true`

only when:
- GitOps config path does not exist
- Argo CD Application does not exist

If one exists and the other does not, wrappers return inconsistent state and the skill must stop.

The skill must not edit GitOps configuration directly.

The skill must not call Argo CD directly.

GitOps uses standard Git over SSH.

Do not ask for Bitbucket login/token when the repository URL uses SSH. SSH agent, SSH key, or standard Git credential mechanisms must be used by Git.

Operations that change GitOps repository or Argo CD must follow the environment approval policy implemented by wrappers.

The wrapper requires `--config-template-path` for approved first-deployment configuration creation. The skill must pass only the user-provided approved template path and must not generate Kubernetes or Argo CD YAML.

Project-specific values are rendered by wrappers from `PROJECT_NAME`.

The skill must not manually construct:
- config path
- charts path
- config template path
- Argo CD application name

For an existing Argo CD Application, wrappers read authoritative application settings from Argo CD and compare them with rendered/default values.

For a first deployment, if rendered config path is missing and template path equals config path, wrappers stop and request a separate approved config template path.

If the user asks only to build a distributive, do not pass `--approve-deployment`.

If the user explicitly asks to build and deploy to a stand, pass `--approve-deployment`.

Before deployment-stage changes, wrappers print:
- `VERSION`
- `CONFIG_REPO`
- `CONFIG_PATH`
- `ARGOCD_APP_NAME`
- `ENVIRONMENT`

Do not request confirmation for read-only checks.

## Preflight Reporting

Report `scripts/distribution preflight` machine output only.

If a stage returns `*_NEXT_REQUIRED_INPUT`, ask only for that exact missing input.

## Credential Policy

Never display credential values.

Never repeat a command containing real credentials.

Credentials must be passed only through environment variables already configured in the execution environment.

Do not print `JENKINS_TOKEN` or `ARGOCD_AUTH_TOKEN`.

Do not print `.env`.

Do not read credential values manually.


## Wrapper Error Policy

If any wrapper returns `STATUS=ERROR`:
- stop immediately
- report `REASON`
- report `NEXT_REQUIRED_INPUT`
- do not read wrapper source
- do not inspect wrapper usage
- do not retry with different arguments
- do not infer wrapper arguments
- do not check env manually
- do not run `echo JENKINS_USER`
- do not run `echo JENKINS_TOKEN`
- do not inspect repository
- do not switch to curl
- do not suggest Maven, Gradle, Docker, or local build

## Hard Restrictions

The skill must not:
- calculate versions
- read Jenkins console logs directly
- analyze Jenkins failures without `scripts/jenkins-analyze-failure.sh`
- edit GitOps config directly
- call Argo CD directly
- generate curl commands
- call Jenkins API directly
- call Argo CD API directly
- run Maven
- run Gradle
- run Docker
- create Git repositories
- create Jenkinsfiles
- inspect distributive modules
- inspect Jenkinsfiles
- search git history

All decisions belong to wrapper scripts.

The skill is only an orchestrator launcher and output reporter.

## Output Policy

Report wrapper output fields only.

For successful delivery, report:
- project
- branch
- distribution type
- previous version
- version
- Jenkins build URL
- Jenkins result
- GitOps action
- Argo CD application
- Argo CD sync status
- Argo CD health status

For blocked or failed delivery, report:
- reason
- next required input
- failure category
- failure summary
- suggested action
