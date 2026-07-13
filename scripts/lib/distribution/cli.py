#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[2]


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
        "build": "jenkins-build.sh",
        "deploy": "distribution-delivery.sh",
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
    return run_wrapper(wrapper, argv)


if __name__ == "__main__":
    raise SystemExit(main())

