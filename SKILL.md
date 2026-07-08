---
name: jenkins-distribution-build
description: Use when the user wants to find/create a Jenkins job by project name and run a Jenkins distributive build.
---

# Jenkins Distribution Build Skill

## Goal

Run a Jenkins distributive build for the current project.

This skill supports exactly one workflow:

1. Resolve project name.
2. Resolve branch.
3. Run `scripts/jenkins-distribution-build.sh`.
4. Report Jenkins job/build result.

Do not perform local builds.

## Non-Goals

This skill must not:

- create Jenkinsfile;
- generate Jenkins pipeline code;
- run local Maven/Gradle/Docker;
- inspect source code/tests/docs;
- replace Jenkins operations with repository analysis;
- search git history for Jenkins configuration;
- produce long implementation plans.

## Execution Policy

If the user asks to build through Jenkins:

- execute the wrapper script;
- do not produce a plan unless explicitly asked;
- do not ask unnecessary questions if project name and branch are known;
- Jenkins operation cannot be substituted with repository inspection.

## Script Execution Policy

Use only:

`scripts/jenkins-distribution-build.sh`

Never construct custom curl commands directly.
Never run local Maven/Gradle/Docker commands.
Never create Jenkinsfile.

The wrapper script is responsible for:

- checking whether the Jenkins job exists;
- creating a missing job from an approved template/example;
- starting the build;
- printing job URL, queue URL, or build URL when available.

## Jenkins Access Failure Policy

If Jenkins access fails because:

- command is blocked by security policy;
- network access is unavailable;
- credentials are missing;
- Jenkins returns 401/403;
- script exits with permission/access error;

then:

- stop immediately;
- report the exact reason;
- do not inspect repository further;
- do not inspect git history after Jenkins access fails;
- do not search for Jenkinsfile;
- do not create Jenkinsfile;
- do not suggest local Maven build.

## Repository Inspection Policy

Only inspect repository when project name cannot be determined.

Allowed:

- current directory name;
- root `pom.xml` artifactId;
- `.git/config` remote URL.

Not allowed unless explicitly requested:

- README;
- AGENTS.md;
- source code;
- tests;
- distributive module;
- git history;
- Jenkinsfile search.

## Required Inputs

Required:

- Jenkins base URL;
- branch;
- project name.

Infer project name from:

1. current repository directory name;
2. root `pom.xml` artifactId;
3. user input.

If branch is not provided:

- use current git branch if available;
- otherwise ask.

If Jenkins URL is not provided:

- ask.

If job does not exist and template is required:

- ask for template job name.

## Output Format

Show:

```text
Project: <project name>
Branch: <branch>
Jenkins URL: <jenkins url>
Job name: <job name>
Action: reused existing job | created new job | blocked
Queue URL / Build URL: <url or not returned>
Status: <queued | blocked | failed>
Next required input: <only if blocked>
```

Do not include long plans, local build output, Jenkinsfile suggestions, or repository analysis.
