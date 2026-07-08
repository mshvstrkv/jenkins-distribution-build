---
name: jenkins-distribution-build
description: Use when the user wants to find or create a Jenkins job for the current project and run a distributive build.
---

# Jenkins Distribution Build Skill

## Goal

Find a Jenkins job for the current project by project name. If the job does not exist, create it from an approved example/template. Then run the build.

This skill supports only one workflow:

1. Open Jenkins.
2. Search job by project name.
3. Reuse existing job or create missing job.
4. Run build.
5. Report result.

Do not perform local Maven builds unless explicitly requested by the user.

---

# Required Configuration

The workflow requires:

- Jenkins base URL
- project name
- job template or example job, if the job does not exist
- credentials or an already authenticated Jenkins session

If Jenkins URL is not known, ask the user for it.

If project name cannot be determined from the repository name or root `pom.xml`, ask the user for it.

If the job does not exist and no template/example is available, ask the user for a template or example job.

---

# Script Execution Policy

For Jenkins distributive builds, use only `scripts/jenkins-distribution-build.sh`.

- Do not run local Maven, Gradle, or Docker commands.
- Do not generate ad-hoc curl commands to Jenkins.
- If `scripts/jenkins-distribution-build.sh` is missing, tell the user.
- If required environment variables are missing, tell the user exactly which ones are missing.
- If the Jenkins job is missing and no template job is provided, stop.
- If the build requires confirmation from the environment, do not bypass it.

---

# Main Workflow

When the user asks to build a distributive:

## Step 1. Resolve project name

Determine project name using this order:

1. Current repository directory name
2. Root `pom.xml` artifactId
3. User-provided project name

Do not read unrelated documentation.

---

## Step 2. Open Jenkins

Go to the configured Jenkins base URL.

Search Jenkins for a job matching the project name.

Valid matches:

- exact job name match
- job name contains project name
- folder path contains project name
- multibranch pipeline contains project name

Searching local repository files is not Jenkins search.

Do not search for `Jenkinsfile` as a replacement for searching Jenkins.

---

## Step 3. If Jenkins job exists

If a matching job exists:

1. Open the job.
2. Check whether it is buildable.
3. Read available parameters.
4. Reuse previous successful build parameters when available.
5. Show resolved parameters.
6. Ask confirmation only if this is a production/release build.
7. Trigger the build.

---

## Step 4. If Jenkins job does not exist

If no matching job exists:

1. Find approved template or example job.
2. Create a new Jenkins job using that template.
3. Name the job using the project name.
4. Configure repository URL, branch, and build parameters.
5. Show created job configuration.
6. Ask for confirmation before saving/creating.
7. Save the job.
8. Trigger a non-production build.

Never create a job from scratch if a template/example exists.

Never create duplicate jobs.

---

## Step 5. Build execution

Trigger the Jenkins build.

If the job has parameters:

1. Fill parameters from previous successful build.
2. Fill missing parameters from project config.
3. Ask the user only for parameters that cannot be determined.

Do not replace Jenkins build with local shell build.

Do not run `mvn`, `./mvnw`, Gradle, Docker, or local scripts unless the user explicitly asks for a local build.

---

## Step 6. Monitoring

After build starts:

1. Report Jenkins build URL.
2. Monitor build status.
3. If build succeeds, report artifact links if available.
4. If build fails, summarize the failed stage and relevant error from the Jenkins log.

---

# Confirmation Rules

Do not ask for confirmation for normal non-production builds.

Ask for confirmation before:

- creating a new Jenkins job;
- triggering production builds;
- triggering release builds;
- deploying artifacts;
- changing existing Jenkins job configuration.

---

# Safety Rules

Never bypass Jenkins authentication or approval gates.

Never invent:

- Jenkins URL
- credentials
- job name
- repository URL
- branch
- version
- artifact path

Never create duplicate jobs.

Never modify an existing Jenkins job unless explicitly required.

---

# Minimal Repository Inspection

Only inspect repository files if needed to determine project name or repository URL.

Allowed files:

- root `pom.xml`
- `build.gradle`
- `settings.gradle`
- `.git/config`

Do not read README, docs, source code, tests, or unrelated modules for this workflow.

---

# Output Format

After resolving the job, show:

```text
Jenkins job: <job name>
Jenkins URL: <job url>
Project: <project name>
Action: reused existing job | created new job
Build parameters:
- <name>: <value>

Build URL: <build url>
Status: <queued | running | success | failed>
Artifacts:
- <artifact url>
```

If blocked, show:

```text
Blocked:
- missing Jenkins URL | missing credentials | missing template | missing required parameter

Next required input:
- <exact missing value>
```
