from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable


IFT_RE = re.compile(r"IFT-(\d+)\.(\d+)\.(\d+)")
RELEASE_RE = re.compile(r"D-(\d{2})\.(\d{3})\.(\d{2})(?!\d)")


@dataclass(frozen=True)
class VersionResolution:
    distribution_type: str
    previous_version: str
    version: str
    source: str


def normalize_distribution_type(value: str) -> str:
    if value in {"ift", "test", "testing"}:
        return "ift"
    if value in {"release", "prod", "production"}:
        return "release"
    raise ValueError("unsupported distribution type")


def _pattern(distribution_type: str) -> re.Pattern[str]:
    dtype = normalize_distribution_type(distribution_type)
    return IFT_RE if dtype == "ift" else RELEASE_RE


def validate_version(distribution_type: str, version: str) -> None:
    pattern = _pattern(distribution_type)
    if not pattern.fullmatch(version):
        raise ValueError(f"invalid {normalize_distribution_type(distribution_type)} version format")


def version_key(distribution_type: str, version: str) -> tuple[int, int, int]:
    match = _pattern(distribution_type).fullmatch(version)
    if not match:
        raise ValueError("version does not match distribution type")
    return tuple(int(part) for part in match.groups())


def extract_version_candidates(distribution_type: str, texts: Iterable[str]) -> list[str]:
    pattern = _pattern(distribution_type)
    versions: list[str] = []
    for text in texts:
      if text is None:
          continue
      versions.extend(match.group(0) for match in pattern.finditer(str(text)))
    return versions


def latest_version(distribution_type: str, candidates: Iterable[str]) -> str:
    valid = []
    for candidate in candidates:
        try:
            valid.append((version_key(distribution_type, candidate), candidate))
        except ValueError:
            continue
    if not valid:
        return ""
    valid.sort(key=lambda item: item[0])
    return valid[-1][1]


def increment_version(distribution_type: str, previous_version: str) -> str:
    dtype = normalize_distribution_type(distribution_type)
    if not previous_version:
        return "IFT-0.0.1" if dtype == "ift" else "D-00.000.01"
    a, b, c = version_key(dtype, previous_version)
    if dtype == "ift":
        return f"IFT-{a}.{b}.{c + 1}"
    if c >= 99:
        raise OverflowError("release patch segment overflow")
    return f"D-{a:02d}.{b:03d}.{c + 1:02d}"


def resolve_version(
    distribution_type: str,
    candidates: Iterable[str],
    explicit_version: str | None = None,
) -> VersionResolution:
    dtype = normalize_distribution_type(distribution_type)
    if explicit_version:
        validate_version(dtype, explicit_version)
        return VersionResolution(dtype, "", explicit_version, "manual")
    previous = latest_version(dtype, candidates)
    version = increment_version(dtype, previous)
    source = "auto" if previous else "default"
    return VersionResolution(dtype, previous, version, source)

