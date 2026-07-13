from __future__ import annotations

import os
import shutil
from pathlib import Path

from .templates import render_template, validate_relative_path


def ensure_inside(root: str, relative_path: str) -> Path:
    validate_relative_path(relative_path)
    root_path = Path(root).resolve()
    target = (root_path / relative_path).resolve()
    if root_path != target and root_path not in target.parents:
        raise ValueError("path escapes repository root")
    return target


def render_tree(root: str, values: dict[str, str]) -> None:
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            path = Path(dirpath) / name
            try:
                data = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            path.write_text(render_template(data, values), encoding="utf-8")


def copy_template(template_path: str, target_path: str) -> None:
    template = Path(template_path)
    target = Path(target_path)
    if template.is_dir():
        shutil.copytree(template, target)
    else:
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(template, target / template.name)


def changed_files_inside(changed_files: list[str], config_path: str) -> bool:
    validate_relative_path(config_path)
    prefix = config_path.rstrip("/") + "/"
    return all(path == config_path or path.startswith(prefix) for path in changed_files)

