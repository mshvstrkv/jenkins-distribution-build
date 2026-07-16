# Changelog

All notable changes to this skill are documented in this file.

The format follows Keep a Changelog, and this skill uses semantic versioning.

## 1.0.4 - 2026-07-15

### Changed
- Forbid agent inference about Jenkins availability, credential validity, DNS, TLS, proxy, firewall, or VPN causes unless those statements come directly from wrapper machine output.

## 1.0.3 - 2026-07-15

### Fixed
- Follow approved Jenkins alias redirects during trigger POST without treating intermediate `buildWithParameters` redirects as queue URLs.
- Recover matching Jenkins queue/build state after ambiguous trigger responses to avoid duplicate build creation.
- Return `jenkins_queue_location_unknown` when a possible trigger lacks a final queue item `Location`.

### Changed
- Removed environment classification language from agent policy.
- Required wrapper errors to be reported without agent-added network explanations.
- Added HTTP 405 regression policy as HTTP method or URL usage only.

## 1.0.2 - 2026-07-15

### Fixed
- Made Jenkins failure analyzer temporary console log creation portable on macOS and Linux.
- Added analyzer self-tests for unique temp files, empty consoleText, and mktemp failure.

### Changed
- Simplified Jenkins job URL handling so only configured-host `JOB_URL` is emitted.
- Kept Jenkins API redirects internal to HTTP helpers without exposing redirected hosts in machine output.
- Removed canonical Jenkins API URL output from public wrapper results.

## 1.0.1 - 2026-07-15

### Fixed
- Preserved shared Pipeline Script SCM repository, branch, and scriptPath when rendering Jenkins jobs from templates.
- Limited application repository rendering to EnvInject `REPO_URL`, BRANCH parameter `remoteURL`, and `SONAR_PROJECT_KEY`.
- Blocked post-create/read-back jobs whose Pipeline SCM was rewritten to the application repository.
- Preserved configured user-facing Jenkins `JOB_URL` when read-only API calls redirect to the canonical Jenkins host.
- Required successful Jenkins trigger responses to include a valid `/queue/item/<id>/` `Location` before reporting `BUILD_TRIGGERED=true`.
- Classified invalid queue URLs and missing queue `Location` as wrapper errors before polling.
- Prevented polling of `buildWithParameters` or `/build` URLs.

## 1.0.0 - 2026-07-15

### Added
- Added `VERSION` as the single source of truth for the skill version.
- Added `scripts/distribution version` for machine-readable skill version output.
- Added `scripts/distribution changelog` to show the latest changelog entries.
- Added `scripts/distribution doctor` for local skill installation diagnostics.
- Added `SKILL_VERSION` emission for public `build`, `deploy`, `deploy-existing`, and `preflight` entrypoints.
- Added self-test enforcement that `VERSION` and `CHANGELOG.md` change together.

### Changed
- Reserved `scripts/distribution version` for skill version reporting.
- Added `scripts/distribution resolve-version` as the distributive version resolver compatibility command.
