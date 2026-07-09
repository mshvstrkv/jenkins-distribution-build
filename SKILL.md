---
name: jenkins-distribution-build
description: Use when the user wants to run a Jenkins build through the repository-provided wrapper scripts.
---

# Jenkins Distribution Build Skill

## Goal

Run Jenkins lookup and build through wrapper scripts only.

The only supported execution paths are:

`scripts/jenkins-lookup.sh`

`scripts/jenkins-build.sh`

## Wrapper First Policy

The wrapper scripts are the only source of truth.

Do not duplicate any logic implemented by the wrappers.

Do not implement lookup yourself.

Do not implement validation yourself.

Do not infer Jenkins jobs yourself.

Do not inspect the repository before executing the lookup wrapper.

## Execution Policy

If the user asks to build through Jenkins:
1. Resolve wrapper location.
2. Immediately execute `scripts/jenkins-lookup.sh`.
3. Nothing else is allowed before this step.

Do not create your own execution plan.

Do not explain what you are going to do.

Do not perform repository analysis.

Execute wrappers directly.

## Build Execution

Only if lookup returns `STATUS=OK` and `EXISTS=true`, execute:

`scripts/jenkins-build.sh`

If lookup returns `EXISTS=false` and `NEXT_REQUIRED_INPUT=template job`, ask only for the exact template job.

Nothing else.

Do not run `scripts/jenkins-build.sh` unless lookup succeeded with `EXISTS=true`, or lookup succeeded with `EXISTS=false` and template job was explicitly provided.

If the user provides an exact Jenkins job name, pass it as `--job-name` to both lookup and build scripts.

## Repository Inspection Restriction

Repository inspection is forbidden before lookup succeeds.

Do not read:
- `pom.xml`
- `README`
- `AGENTS.md`
- `Jenkinsfile`
- `assembly/*`
- `distributive/*`
- `build.gradle`
- `settings.gradle`

unless the wrapper explicitly requests additional information.

Never infer Jenkins job name from Jenkinsfile, Maven module, README, AGENTS.md, or git history.

## Wrapper Owns Validation

The wrapper validates:
- credentials
- Jenkins URL
- project name
- job existence
- template requirement

The skill must never validate these independently.

## Script Execution Policy

For read-only Jenkins checks, always use:

`scripts/jenkins-lookup.sh`

For Jenkins actions that may change state or trigger work, always use:

`scripts/jenkins-build.sh`

If either script is not found in the current repository, use the script with the same relative path from this skill directory.

Never construct ad-hoc shell commands for Jenkins.

Never construct curl commands.

Never perform Jenkins API requests directly from the agent.

## Stop Conditions

If lookup returns `STATUS=ERROR`, stop immediately.

Only report `NEXT_REQUIRED_INPUT`.

Never attempt alternative strategies.

Never inspect the repository.

Never construct Jenkins URLs.

Never search Jenkins.

If a wrapper script reports any blocked state, stop immediately and report the exact `NEXT_REQUIRED_INPUT`.

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
- inspect the project
- understand the project
- analyze build files
- verify Maven
- determine build type
- determine modules
- determine distributive structure

## Output Format

Report wrapper output fields only:
- Project
- Branch
- Jenkins URL
- Job name
- Action
- Queue URL
- Build URL
- Result
- Next required input, only if blocked

## Hard Requirements

The first executable action after resolving wrapper location MUST be:

`scripts/jenkins-lookup.sh`

No repository inspection is allowed before lookup.

No shell commands except wrapper execution are allowed.

No curl commands are allowed.

No Jenkins API calls are allowed.

No Maven commands are allowed.

No Gradle commands are allowed.

The wrappers are the authoritative implementation.

The skill is only an orchestrator.
