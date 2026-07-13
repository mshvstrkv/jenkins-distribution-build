from __future__ import annotations

import json
from typing import Any

from .versioning import extract_version_candidates


VERSION_PARAMETER_NAMES = {"VERSION", "DISTRIBUTIVE_VERSION", "DISTRIBUTION_VERSION"}


def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def parameter_names(payload: dict[str, Any]) -> list[str]:
    names: list[str] = []
    for prop in payload.get("property") or []:
        for definition in prop.get("parameterDefinitions") or []:
            name = definition.get("name")
            if name:
                names.append(str(name))
    return names


def map_parameters(names: list[str], branch: str, version: str, distribution_type: str) -> dict[str, str]:
    available = set(names)
    return {
        "branch": branch if branch in available else "",
        "version": version if version in available else "",
        "distribution_type": distribution_type if distribution_type in available else "",
    }


def version_texts_from_builds(payload: dict[str, Any]) -> list[str]:
    texts: list[str] = []
    for build in payload.get("builds") or []:
        for field in ("displayName", "description"):
            value = build.get(field)
            if value:
                texts.append(str(value))
        for action in build.get("actions") or []:
            for param in action.get("parameters") or []:
                if param.get("name") in VERSION_PARAMETER_NAMES and param.get("value"):
                    texts.append(str(param.get("value")))
    return texts


def version_candidates_from_builds(payload: dict[str, Any], distribution_type: str) -> list[str]:
    return extract_version_candidates(distribution_type, version_texts_from_builds(payload))

