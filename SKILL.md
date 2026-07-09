---
name: jenkins-distribution-build
description: Use when the user wants to find/create a Jenkins job by project name and run a Jenkins distributive build.
---

# Jenkins Distribution Build Skill

## Goal

Run Jenkins build for the current project using wrapper scripts.

The only supported Jenkins execution paths are:

`scripts/jenkins-lookup.sh`

`scripts/jenkins-build.sh`

## Non-Goals

This skill must not:
- call Jenkins API directly
- generate curl commands
- run Maven
- run Gradle
- run Docker
- inspect distributive/pom.xml
- inspect assembly/distributive.xml
- read README
- read AGENTS.md
- search git history
- search Jenkinsfile
- create Jenkinsfile

## Execution Policy

If user asks to build through Jenkins:
1. Resolve Jenkins URL.
2. Resolve project name.
3. Resolve branch.
4. Before running build, always run read-only lookup: `scripts/jenkins-lookup.sh`.
5. If lookup returns `STATUS=OK` and `EXISTS=true`, then run `scripts/jenkins-build.sh`.
6. If lookup returns `STATUS=OK`, `EXISTS=false`, and `TEMPLATE_JOB` is present, then run `scripts/jenkins-build.sh` with `--template-job`.
7. If lookup returns `STATUS=ERROR` and `ACTION=blocked`, stop immediately and report the exact `NEXT_REQUIRED_INPUT`.

Do not run `scripts/jenkins-build.sh` unless lookup succeeded with `EXISTS=true`, or lookup succeeded with `EXISTS=false` and template job was explicitly provided.
If lookup returns `NEXT_REQUIRED_INPUT=template job`, stop and ask the user for the exact Jenkins job name or template job name.
If the user provides exact Jenkins job name, pass it as `--job-name` to both lookup and build scripts.
Do not produce a plan unless explicitly asked.
Never inspect repository after lookup failure.
Never search Jenkinsfile.
Never create Jenkinsfile.
Never suggest local Maven build.
Never infer Jenkins job name from Jenkinsfile, Maven module, README, AGENTS.md, or git history.

## Script Execution Policy

For read-only Jenkins checks, always use:

`scripts/jenkins-lookup.sh`

For Jenkins actions that may change state or trigger work, always use:

`scripts/jenkins-build.sh`

If either script is not found in the current repository, use the script with the same relative path from this skill directory.

Never construct ad-hoc shell commands for Jenkins.
Never construct curl commands.
Never perform Jenkins API requests directly from the agent.

## Input Resolution

Resolve project name from:
1. current repository directory name
2. root pom.xml artifactId
3. user input

Resolve branch from:
1. user input
2. current git branch

Ask only for missing:
- Jenkins URL
- branch
- exact Jenkins job name or template job, if lookup reports template job is required
- credentials, if env vars are missing

## Validation

For safe real Jenkins validation, run lookup first:

```bash
JENKINS_USER="<user>" JENKINS_TOKEN="<token>" \
bash scripts/jenkins-lookup.sh \
  --jenkins-url "https://aipay.ci.jenkins.sberbank.ru/job/aipay/job/SberAiPay_CI" \
  --project-name "ai-payments-merchant-registry"
```

Expected good result:

```text
STATUS=OK
ACTION=lookup
EXISTS=true
JOB_NAME=...
JOB_URL=...
```

If lookup returns `STATUS=ERROR` and `NEXT_REQUIRED_INPUT=template job`, do not run build. Ask for the exact Jenkins job name and retry lookup with `--job-name`, or ask for a template job name.

## Stop Conditions

Stop immediately if a wrapper script reports:
- missing Jenkins URL
- missing credentials
- Jenkins access denied
- security policy block
- template job required
- Jenkins unavailable

After stopping:
- do not inspect repository
- do not search Jenkinsfile
- do not create Jenkinsfile
- do not suggest local Maven build
- report exact `NEXT_REQUIRED_INPUT`

## Output Format

Report:
- Project
- Branch
- Jenkins URL
- Job name
- Action
- Queue URL
- Build URL
- Result
- Next required input, only if blocked
