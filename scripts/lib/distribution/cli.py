#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[2]


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


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print("STATUS=ERROR")
        print("REASON=Missing command")
        print("NEXT_REQUIRED_INPUT=command")
        return 1
    command = argv.pop(0)
    mapping = {
        "preflight": "preflight.sh",
        "version": "version-resolver.sh",
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
