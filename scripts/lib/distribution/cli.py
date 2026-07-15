#!/usr/bin/env python3
from __future__ import annotations

import datetime as _datetime
import os
import re
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[2]
SKILL_ROOT = SCRIPT_DIR.parent
CLI_PATH = SCRIPT_DIR / "distribution"
SKILL_NAME = "jenkins-distribution-build"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
PUBLIC_VERSIONED_COMMANDS = {"build", "deploy", "deploy-existing", "preflight"}


def requires_project_dir(command: str, args: list[str]) -> bool:
    if "--self-test" in args or "--help" in args or "-h" in args:
        return False
    return command in {"build", "deploy", "preflight", "deploy-existing"}


def has_project_dir(args: list[str]) -> bool:
    return "--project-dir" in args


def project_dir_required() -> int:
    print("STATUS=ERROR")
    print("ACTION=blocked")
    print("STATE=project_directory_required")
    print("REASON=Missing required argument: --project-dir")
    print("NEXT_REQUIRED_INPUT=project directory")
    print("MUTATIONS_PERFORMED=false")
    return 1


INTERNAL_PUBLIC_FLAGS = {
    "--skip-lookup",
    "–skip-lookup",
    "--existing-job",
    "–existing-job",
    "--create-if-missing",
    "–create-if-missing",
}


def unsupported_public_argument(argument: str) -> int:
    print("STATUS=ERROR")
    print("ACTION=blocked")
    print("STATE=unsupported_public_argument")
    print(f"REASON=Unsupported public CLI argument: {argument}")
    print("NEXT_REQUIRED_INPUT=documented public argument")
    print("MUTATIONS_PERFORMED=false")
    return 1


def find_internal_public_argument(args: list[str]) -> str | None:
    for arg in args:
        if arg in INTERNAL_PUBLIC_FLAGS:
            return arg
    return None


def run_wrapper(name: str, args: list[str]) -> int:
    return subprocess.call([str(SCRIPT_DIR / name), *args])


def read_skill_version() -> str:
    version_file = SKILL_ROOT / "VERSION"
    if not version_file.exists():
        return ""
    return version_file.read_text(encoding="utf-8").strip()


def version_format_valid(version: str) -> bool:
    return bool(VERSION_RE.fullmatch(version))


def git_output(*args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(SKILL_ROOT), *args],
            check=False,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def git_commit() -> str:
    return git_output("rev-parse", "--short", "HEAD")


def worktree_dir() -> str:
    return git_output("rev-parse", "--show-toplevel") or str(SKILL_ROOT)


def git_status() -> str:
    status = git_output("status", "--porcelain")
    if status == "":
        inside = git_output("rev-parse", "--is-inside-work-tree")
        if inside == "true":
            return "clean"
        return "unknown"
    return "dirty"


def version_changelog_changed_together() -> tuple[bool, str]:
    status = git_output("status", "--porcelain", "--", "VERSION", "CHANGELOG.md")
    if status == "":
        inside = git_output("rev-parse", "--is-inside-work-tree")
        if inside != "true":
            return True, ""
        return True, ""

    changed = set()
    for line in status.splitlines():
        path = line[3:].strip()
        if " -> " in path:
            path = path.rsplit(" -> ", 1)[-1]
        if path in {"VERSION", "CHANGELOG.md"}:
            changed.add(path)

    if changed == {"VERSION", "CHANGELOG.md"}:
        return True, ""
    if changed == {"VERSION"}:
        return False, "VERSION changed without CHANGELOG.md"
    if changed == {"CHANGELOG.md"}:
        return False, "CHANGELOG.md changed without VERSION"
    return True, ""


def emit_version_changelog_error(reason: str) -> int:
    print("STATUS=ERROR")
    print("ACTION=blocked")
    print("STATE=version_changelog_mismatch")
    print(f"REASON={reason}")
    print("NEXT_REQUIRED_INPUT=update VERSION and CHANGELOG.md together")
    print("MUTATIONS_PERFORMED=false")
    return 1


def validate_version_changelog_self_test(emit_success: bool = True) -> int:
    ok, reason = version_changelog_changed_together()
    if not ok:
        return emit_version_changelog_error(reason)
    if emit_success:
        print("VERSION_CHANGELOG_SELF_TESTS=OK")
    return 0


def emit_skill_version_prefix(command: str) -> int:
    if command not in PUBLIC_VERSIONED_COMMANDS:
        return 0
    version = read_skill_version()
    print(f"SKILL_VERSION={version}", flush=True)
    if not version:
        print("STATUS=ERROR")
        print("ACTION=blocked")
        print("STATE=skill_version_missing")
        print("REASON=VERSION file is missing or empty")
        print("NEXT_REQUIRED_INPUT=VERSION")
        print("MUTATIONS_PERFORMED=false")
        return 1
    if not version_format_valid(version):
        print("STATUS=ERROR")
        print("ACTION=blocked")
        print("STATE=skill_version_invalid")
        print("REASON=VERSION must use MAJOR.MINOR.PATCH")
        print("NEXT_REQUIRED_INPUT=valid VERSION")
        print("MUTATIONS_PERFORMED=false")
        return 1
    return 0


def command_version(_: list[str]) -> int:
    version = read_skill_version()
    status = "OK" if version and version_format_valid(version) else "ERROR"
    print(f"STATUS={status}")
    print(f"SKILL_NAME={SKILL_NAME}")
    print(f"VERSION={version}")
    print(f"BUILD_DATE={_datetime.date.today().isoformat()}")
    print(f"GIT_COMMIT={git_commit()}")
    print(f"GIT_STATUS={git_status()}")
    print(f"WORKTREE_DIR={worktree_dir()}")
    if status != "OK":
        print("STATE=skill_version_invalid")
        print("NEXT_REQUIRED_INPUT=valid VERSION")
        return 1
    return 0


def changelog_entries(limit: int = 10) -> list[str]:
    path = SKILL_ROOT / "CHANGELOG.md"
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    starts = [index for index, line in enumerate(lines) if line.startswith("## ")]
    entries = []
    for position, start in enumerate(starts[:limit]):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        entries.append("\n".join(lines[start:end]).strip())
    return [entry for entry in entries if entry]


def command_changelog(_: list[str]) -> int:
    path = SKILL_ROOT / "CHANGELOG.md"
    if not path.exists():
        print("STATUS=ERROR")
        print("ACTION=changelog")
        print("STATE=changelog_missing")
        print("REASON=CHANGELOG.md is missing")
        print("NEXT_REQUIRED_INPUT=CHANGELOG.md")
        print("MUTATIONS_PERFORMED=false")
        return 1
    entries = changelog_entries()
    print("STATUS=OK")
    print("ACTION=changelog")
    print(f"CHANGELOG_ENTRIES={len(entries)}")
    for entry in entries:
        print(entry)
    return 0


def command_doctor(args: list[str]) -> int:
    if "--self-test" in args:
        return validate_version_changelog_self_test(emit_success=True)

    version = read_skill_version()
    version_exists = (SKILL_ROOT / "VERSION").exists()
    changelog_exists = (SKILL_ROOT / "CHANGELOG.md").exists()
    skill_md_exists = (SKILL_ROOT / "SKILL.md").exists()
    version_valid = version_format_valid(version)
    ok, reason = version_changelog_changed_together()
    status = "OK" if version_exists and changelog_exists and skill_md_exists and version_valid and ok else "ERROR"

    print(f"STATUS={status}")
    print("ACTION=doctor")
    print(f"VERSION={version}")
    print(f"GIT_COMMIT={git_commit()}")
    print(f"GIT_STATUS={git_status()}")
    print(f"WORKTREE={worktree_dir()}")
    print(f"SKILL_ROOT={SKILL_ROOT}")
    print(f"CLI_PATH={CLI_PATH}")
    print(f"PYTHON_VERSION={sys.version.split()[0]}")
    print(f"VERSION_FILE_EXISTS={str(version_exists).lower()}")
    print(f"VERSION_FORMAT_VALID={str(version_valid).lower()}")
    print(f"CHANGELOG_EXISTS={str(changelog_exists).lower()}")
    print(f"SKILL_MD_EXISTS={str(skill_md_exists).lower()}")
    print(f"VERSION_CHANGELOG_IN_SYNC={str(ok).lower()}")
    if not ok:
        print("STATE=version_changelog_mismatch")
        print(f"REASON={reason}")
        print("NEXT_REQUIRED_INPUT=update VERSION and CHANGELOG.md together")
        return 1
    if status != "OK":
        print("STATE=skill_installation_invalid")
        print("NEXT_REQUIRED_INPUT=required skill files")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print("STATUS=ERROR")
        print("REASON=Missing command")
        print("NEXT_REQUIRED_INPUT=command")
        return 1
    command = argv.pop(0)
    if "--self-test" in argv and command != "doctor":
        self_test_code = validate_version_changelog_self_test(emit_success=False)
        if self_test_code != 0:
            return self_test_code

    builtins = {
        "version": command_version,
        "changelog": command_changelog,
        "doctor": command_doctor,
    }
    builtin = builtins.get(command)
    if builtin:
        return builtin(argv)

    version_prefix_code = emit_skill_version_prefix(command)
    if version_prefix_code != 0:
        return version_prefix_code

    mapping = {
        "preflight": "preflight.sh",
        "resolve-version": "version-resolver.sh",
        "build": "jenkins-build-flow.sh",
        "deploy": "distribution-delivery.sh",
        "deploy-existing": "distribution-existing-build.sh",
        "status": "jenkins-status.sh",
        "digest": "jenkins-resolve-digest.sh",
        "analyze": "jenkins-analyze-failure.sh",
        "gitops-check": "gitops-check.sh",
        "gitops-update": "gitops-update.sh",
        "argocd-check": "argocd-check.sh",
        "argocd-sync": "argocd-sync.sh",
    }
    wrapper = mapping.get(command)
    if not wrapper:
        print("STATUS=ERROR")
        print(f"REASON=Unknown command: {command}")
        print("NEXT_REQUIRED_INPUT=valid command")
        return 1
    internal_arg = find_internal_public_argument(argv)
    if internal_arg:
        return unsupported_public_argument(internal_arg)
    if requires_project_dir(command, argv) and not has_project_dir(argv):
        return project_dir_required()
    return run_wrapper(wrapper, argv)


if __name__ == "__main__":
    raise SystemExit(main())
