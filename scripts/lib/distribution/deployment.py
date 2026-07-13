from __future__ import annotations

from dataclasses import dataclass


def determine_deployment_mode(config_exists: bool | None, argocd_app_exists: bool | None) -> str:
    if config_exists is None or argocd_app_exists is None:
        return "unknown"
    if not config_exists and not argocd_app_exists:
        return "create"
    if config_exists and argocd_app_exists:
        return "update"
    return "inconsistent"


@dataclass(frozen=True)
class PreflightResult:
    status: str
    result: str


def aggregate_preflight_status(
    jenkins_status: str,
    gitops_status: str,
    argo_status: str,
) -> PreflightResult:
    statuses = [jenkins_status, gitops_status, argo_status]
    if all(status == "OK" for status in statuses):
        return PreflightResult("OK", "SUCCESS")
    if all(status == "NOT_RUN" for status in statuses):
        return PreflightResult("ERROR", "NOT_RUN")
    return PreflightResult("PARTIAL", "FAILED")

