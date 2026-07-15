---
name: jenkins-distribution-build
description: >
  Use immediately whenever the user asks to build a new project version,
  build a distributive, run a Jenkins build, publish or deploy a version,
  or install an application on a test/release stand.
  Russian triggers include: "собери новую версию", "собери дистрибутив",
  "собери через Jenkins", "поставь на тестовый стенд",
  "задеплой на тест", "выложи новую версию", "собери релиз".
  This skill must be loaded before inspecting pom.xml, modules, Jenkinsfiles,
  README, repository scripts, or attempting Maven/Gradle/Docker builds.
---

# Jenkins Distribution Build Skill

## Immediate Activation Policy

Load and apply this skill immediately when the user asks to:

- build a new version
- build a distributive
- run a Jenkins build
- deploy or install a version on a test stand
- deploy or install a release
- build and deploy in one request

These requests do not need to contain the word "Jenkins".

Russian examples:

- собери новую версию текущего проекта
- собери дистрибутив
- собери и поставь на тестовый стенд
- задеплой новую версию на тест
- собери релиз
- запусти сборку

Do not inspect the repository before loading and applying this skill.

## User Intent Mapping

Map user intent directly to the wrapper CLI:

- "собери новую версию" -> `scripts/distribution build --project-dir "$PWD"`
- "собери дистрибутив" -> `scripts/distribution build --project-dir "$PWD"`
- "собери и поставь на тестовый стенд" -> `scripts/distribution deploy --project-dir "$PWD" --approve-deployment`
- "поставь существующую версию на тест" -> deployment flow without inventing a new build, if the CLI supports that mode; otherwise report the exact wrapper error
- "собери релиз" -> pass `--distribution-type release`
- "тестовая версия" or "тестовый стенд" -> pass `--distribution-type ift`

If the user asks for build plus deploy, do not ask separately whether deployment is needed. The original request is the deployment confirmation.

## First Executable Action Policy

After loading this skill, the first executable command must be one of:

- `scripts/distribution build --project-dir "$PWD"`
- `scripts/distribution deploy --project-dir "$PWD"`
- `scripts/distribution preflight --project-dir "$PWD"`

Choose the command based only on the user request.

The wrapper path must be resolved relative to the skill `<base_dir>`, not relative to the current application repository.

Before the first wrapper invocation, the agent must not:

- read `pom.xml`
- read `distributive/pom.xml`
- read `assembly/*`
- glob or read `Jenkinsfile`
- glob or inspect repository `scripts/*`
- search for Maven wrapper
- run Maven, Gradle, or Docker
- create task files, plan files, or todo lists
- check whether `scripts/distribution` exists inside the application repository
- read implementation wrapper files
- independently determine network availability

## Skill Path Policy

`scripts/distribution` belongs to the skill directory.

It is not expected to exist in the current application repository.

Resolve it relative to skill `<base_dir>` and execute it from there while preserving the current project directory as the project context.

Never search the application repository for this wrapper.

If wrapper execution requires changing directory to the skill root, pass the current application repository explicitly as:

`--project-dir <current-application-repository>`

Project name and branch resolution belong to wrappers. The agent must not derive them from the skill directory.

First build command shape:

```bash
SKILL_DIR="<skill-base-dir>"
bash "$SKILL_DIR/scripts/distribution" build \
  --project-dir "$PWD" \
  --distribution-type ift \
  --wait
```

First deploy command shape:

```bash
SKILL_DIR="<skill-base-dir>"
bash "$SKILL_DIR/scripts/distribution" deploy \
  --project-dir "$PWD" \
  --distribution-type ift \
  --approve-deployment
```

Do not run `cd "$SKILL_DIR"` before wrapper execution unless `--project-dir "$PWD"` has already captured the application repository.

`$PWD` must be the application repository.

Wrapper path comes from the skill directory.

Project context comes from `--project-dir`.

Перед первым вызовом `scripts/distribution` агент ОБЯЗАН передать `--project-dir`, равный текущему открытому репозиторию пользователя.

Запуск wrappers без `--project-dir` запрещён.

Never determine project name, branch, or repository URL from the skill directory.

## Regression Examples

Example A:

User:
"собери новую версию текущего проекта"

Expected first executable action:
`scripts/distribution build --project-dir "$PWD" ... --wait`

Forbidden:
reading `pom.xml` or running Maven.

Example B:

User:
"собери новую версию и поставь на тестовый стенд"

Expected first executable action:
`scripts/distribution deploy --project-dir "$PWD" ... --distribution-type ift --approve-deployment`

Forbidden:
repository exploration before wrapper execution.

Example C:

User:
"собери релизный дистрибутив"

Expected first executable action:
`scripts/distribution build --project-dir "$PWD" ... --distribution-type release --wait`

## Goal

Run the full managed distributive workflow only through wrapper scripts.

For new work, the preferred entrypoint is:

`scripts/distribution`

For a full user request such as "build a test distributive and deploy it to the test stand", execute:

`scripts/distribution deploy --project-dir "$PWD"`

For a safe end-to-end validation without external mutations, use:

`scripts/distribution preflight --project-dir "$PWD"`

The wrapper scripts are the source of truth for lookup, build, versioning, failure analysis, GitOps configuration, Argo CD operations, and deployment state decisions.

Configuration and credentials are loaded by wrappers from the skill root `.env` file when present. The skill must not read or print `.env`.

## CLI Policy

The only preferred entrypoint is:

`scripts/distribution`

Legacy wrapper scripts exist for backward compatibility and implementation compatibility.

Use these commands:
- read-only validation: `scripts/distribution preflight --project-dir "$PWD"`
- full delivery: `scripts/distribution deploy --project-dir "$PWD"`
- delivery of an already completed Jenkins build: `scripts/distribution deploy-existing --project-dir "$PWD"`
- Jenkins-only build: `scripts/distribution build --project-dir "$PWD"`
- exact Jenkins build status: `scripts/distribution status`
- exact Jenkins image digest resolution: `scripts/distribution digest`
- version resolution: `scripts/distribution version`
- failure analysis: `scripts/distribution analyze`
- GitOps read-only check: `scripts/distribution gitops-check`
- GitOps mutation stage: `scripts/distribution gitops-update`
- Argo CD read-only check: `scripts/distribution argocd-check`
- Argo CD sync stage: `scripts/distribution argocd-sync`

The skill must not reproduce CLI business logic.

The skill must not call `curl`, `git`, or `argocd` directly.

The skill must pass arguments to the CLI and report machine output.

## No-Question Execution Policy

When all required build inputs are present in the user request, execute:

`scripts/distribution build --project-dir "$PWD"`

immediately.

Do not:
- create a plan file
- create todo items
- ask for confirmation
- ask again for distribution type
- ask again for execution environment
- ask again for Jenkins URL
- ask again for project name
- ask again for branch
- ask for job name when lookup can resolve it
- ask for recovery window when a default exists
- inspect environment variables manually
- read `.env`
- print `.env`
- extract credentials from `.env` into a shell command

The wrappers load skill-root `.env` themselves.

The agent must execute exactly one CLI command and report its final machine output.

If the user says "проверь через 10 минут", do not interpret it as a recovery-window value. It means wait before checking status, not change `--recovery-window-seconds`.

Do not create `.gigacode/plans/*` for a simple build request.

For a request such as:

"собери новую версию текущего проекта и поставь ее на тестовый стенд"

execute the deploy flow immediately if defaults and wrapper-loaded `.env` allow the wrapper to resolve parameters.

Do not ask:
- where the wrapper is
- whether `scripts/` exists in the project
- whether the execution environment is correct
- for Jenkins URL, if wrappers can load it from skill `.env`
- for project name, if wrappers can use the current project context
- for branch, if wrappers can resolve it from the current project context
- for version
- for job name
- for deployment confirmation

## Jenkins Build Policy

`scripts/distribution build --project-dir "$PWD"` runs the Jenkins-only orchestrated flow.

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

## First Jenkins Job Policy

Wrappers may use these non-secret defaults from skill `.env` or `.env.example`:

- `JENKINS_URL=https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI`
- `JENKINS_TEMPLATE_JOB=ai-payments-merchant-registry-build`

The approved default example/template job is:

`ai-payments-merchant-registry-build`

This is an example of job structure only. It is not a source of project-specific repository, branch, project name, or configuration values.

When wrappers create a missing Jenkins job from a template, they must render and verify project-specific config before triggering any build.

The agent must not assume a template job is valid for the current project merely because the Jenkins job name changed.

For first-job creation, wrappers resolve repository URL from:

`--repository-url > git remote origin in --project-dir > wrapper error`

If the wrapper returns `STATE=repository_url_required`, ask only for the repository URL.

If the wrapper returns `STATE=jenkins_template_incompatible` or `STATE=jenkins_created_job_mismatch`, stop and report wrapper output. Do not start a build, do not retry with another job name, and do not modify Jenkins manually.

## Existing Build Delivery Policy

Use `scripts/distribution deploy-existing --project-dir "$PWD"` when the user selects an already completed Jenkins build, build URL, build number, or exact existing version to deploy.

`deploy-existing` is authoritative for this flow:

exact Jenkins build status
-> exact image digest resolution
-> GitOps check/update
-> Argo CD check/sync

It must not:
- invoke `scripts/distribution build --project-dir "$PWD"`
- invoke `scripts/distribution deploy --project-dir "$PWD"`
- run `scripts/version-resolver.sh`
- run `scripts/jenkins-build.sh`
- trigger a new Jenkins build
- create a Jenkins queue item
- calculate the next version

Explicit `--version` does not mean "reuse existing build" for normal `build` or `deploy`. To deploy an already built version, use:

`scripts/distribution deploy-existing --project-dir "$PWD"`

A finished successful build is not stale merely because a newer version can be calculated.

An explicit user-selected build/version is authoritative for `deploy-existing`.

Do not request a rebuild after status, digest, or polling errors unless the user explicitly asks to rebuild.

Use `scripts/distribution status` for read-only status checks of an exact existing Jenkins build.

Use `scripts/distribution digest` for read-only image digest resolution of an exact existing Jenkins build.

## Repeat Deployment Policy

For an existing deployment, updating `VERSION` and `IMAGE_DIGEST` is mandatory and does not require additional confirmation.

Repeat deployment is determined only by wrapper output:

`CONFIG_EXISTS=true`
`ARGOCD_APP_EXISTS=true`
`DEPLOYMENT_MODE=update`

The original user request to build and deploy is sufficient approval for:
- GitOps version update
- GitOps digest update
- Git commit and push
- Argo CD sync

Before mutation, ask at most one scope question:

"Кроме версии и digest, нужно изменить что-то ещё в конфигурации стенда?"

This is not a confirmation prompt.

If the user already said any of the following, do not ask again:
- "ничего больше менять не нужно"
- "только версия и digest"
- "просто обнови версию"
- "обычный деплой"

In that case continue immediately with:

`scripts/distribution deploy-existing --project-dir "$PWD" ... --no-extra-config-changes`

If the user says no to the scope question, continue immediately with:

`scripts/distribution deploy-existing --project-dir "$PWD" ... --no-extra-config-changes`

If the user says yes, pause and ask only for exact additional GitOps configuration changes.

Never start another Jenkins build while waiting for this answer.

Never recalculate the next version while waiting for this answer.

Never search for a different Jenkins build while waiting for this answer.

Use the same exact `BUILD_URL`, `VERSION`, and `IMAGE_DIGEST` when resuming.

Resume after `STATUS=PAUSED` must use:

`scripts/distribution deploy-existing --project-dir "$PWD" ... --resume --build-url <exact-url> --version <exact-version> --digest <exact-digest> --no-extra-config-changes`

Resume must not call Jenkins build, version resolver, or a digest resolver for another build.

For additional changes, use only the supported wrapper contract:

`scripts/distribution deploy-existing --project-dir "$PWD" ... --additional-config-changes-file <approved-patch-file>`

The agent must not edit GitOps YAML directly.

## Full Workflow

`scripts/distribution deploy --project-dir "$PWD"` owns this workflow:

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

For full delivery requests, execute `scripts/distribution deploy --project-dir "$PWD"`.

For preflight requests, execute `scripts/distribution preflight --project-dir "$PWD"`.

For "build distributive" requests, include `--wait`.

Do not stop after Jenkins queueing. The wrapper must wait for the final Jenkins result.

Do not ask for confirmation before Jenkins build. The user request to build is confirmation.

Do not call `scripts/jenkins-lookup.sh`, `scripts/jenkins-build.sh`, `scripts/deployment-lookup.sh`, `scripts/argocd-deploy.sh`, or `scripts/jenkins-analyze-failure.sh` directly for the full workflow unless the user explicitly requests that lower-level wrapper.

Do not create your own execution plan.

Do not explain what you are going to do before wrapper execution.

Execute wrappers directly.

## Network Policy

This skill is intended to run where Jenkins, GitOps, and Argo CD are reachable.

The agent must not determine network availability independently.

Do not run custom network checks.

Do not ask the user to classify the network.

If a wrapper reports that Jenkins is unreachable, stop and report wrapper output:
- `STATE`
- `REASON`
- `NEXT_REQUIRED_INPUT`

Do not diagnose proxy settings, certificates, hostnames, or trust stores.

Do not retry with insecure options such as `curl -k`.

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
- Bitbucket
- Argo CD
- Kubernetes

Preflight uses:

`scripts/distribution preflight --project-dir "$PWD"`

Preflight checks:
- Jenkins
- Bitbucket through Git SSH
- Argo CD
- deployment state

If wrappers return `STATUS=ERROR`, stop immediately and report:
- `REASON`
- `NEXT_REQUIRED_INPUT`

Do not run network diagnostics such as `nslookup`, `nc`, `openssl s_client`, proxy inspection, certificate inspection, or hostname substitution.

## Preflight Policy

Preflight is read-only and must run through:

`scripts/distribution preflight --project-dir "$PWD"`

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

`scripts/preflight.sh` and `scripts/distribution-delivery.sh --preflight` are compatibility paths. The preferred CLI path is `scripts/distribution preflight --project-dir "$PWD"`.

## Delivery Policy

Full build and deployment runs only through:

`scripts/distribution deploy --project-dir "$PWD"`

Delivery of an already existing Jenkins build runs only through:

`scripts/distribution deploy-existing --project-dir "$PWD"`

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

Report `scripts/distribution preflight --project-dir "$PWD"` machine output only.

If a stage returns `*_NEXT_REQUIRED_INPUT`, ask only for that exact missing input.

## Credential Policy

Never display credential values.

Never repeat a command containing real credentials.

Credentials must be passed only through environment variables already configured in the execution environment.

Do not print `JENKINS_TOKEN` or `ARGOCD_AUTH_TOKEN`.

Do not print `.env`.

Do not read credential values manually.

Do not open, cat, grep, or read `.env`.

The agent must never inspect `.env` to locate Argo CD settings.

Wrappers load `.env` internally.

If Argo authentication fails, report only wrapper `REASON` and `NEXT_REQUIRED_INPUT`.


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
