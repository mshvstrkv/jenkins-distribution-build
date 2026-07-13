from __future__ import annotations

import json
from typing import Any


def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def app_fields(payload: dict[str, Any]) -> dict[str, str]:
    spec = payload.get("spec") or {}
    source = spec.get("source") or {}
    dest = spec.get("destination") or {}
    status = payload.get("status") or {}
    sync = status.get("sync") or {}
    health = status.get("health") or {}
    metadata = payload.get("metadata") or {}
    return {
        "app_name": str(metadata.get("name") or ""),
        "project": str(spec.get("project") or ""),
        "repo_url": str(source.get("repoURL") or ""),
        "target_revision": str(source.get("targetRevision") or ""),
        "source_path": str(source.get("path") or ""),
        "destination_server": str(dest.get("server") or ""),
        "destination_namespace": str(dest.get("namespace") or ""),
        "sync_status": str(sync.get("status") or ""),
        "health_status": str(health.get("status") or ""),
    }

