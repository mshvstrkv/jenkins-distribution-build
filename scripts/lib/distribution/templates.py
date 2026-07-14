from __future__ import annotations

import re


ALLOWED_PLACEHOLDERS = {
    "PROJECT_NAME",
    "ENVIRONMENT",
    "DISTRIBUTION_TYPE",
    "VERSION",
    "NAMESPACE",
    "ARGOCD_APP_NAME",
    "CONFIG_PATH",
    "CHARTS_PATH",
    "IMAGE_DIGEST",
}


class TemplateError(ValueError):
    pass


def render_template(template: str, values: dict[str, str]) -> str:
    rendered = template
    for key in ALLOWED_PLACEHOLDERS:
        rendered = rendered.replace("{{" + key + "}}", values.get(key, ""))
    unknown = re.search(r"\{\{([^{}]+)\}\}", rendered)
    if unknown:
        raise TemplateError(f"Unknown placeholder: {unknown.group(1)}")
    if "{{" in rendered or "}}" in rendered:
        raise TemplateError("Unknown placeholder syntax")
    return rendered


def validate_relative_path(path: str) -> None:
    if not path:
        raise TemplateError("empty path")
    if path.startswith("/"):
        raise TemplateError("absolute path is not allowed")
    if "\n" in path or "\r" in path or "\0" in path:
        raise TemplateError("control characters are not allowed")
    if re.search(r"\{\{[^{}]+\}\}", path):
        raise TemplateError("unresolved placeholder remains")
    if any(segment == ".." for segment in path.split("/")):
        raise TemplateError("parent directory segment is not allowed")


def render_path(template: str, values: dict[str, str]) -> str:
    rendered = render_template(template, values)
    validate_relative_path(rendered)
    return rendered
