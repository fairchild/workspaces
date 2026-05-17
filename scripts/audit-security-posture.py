#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Report operational security posture for release and agent automation.

This script is intentionally report-only by default. Use --strict when a
release checklist should fail on missing controls.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
REQUIRED_RUNNER_LABELS = {"signing-host", "lume-macos"}
ADVISORY_RUNNER_LABELS = {"tart-ui"}
EXPECTED_ENVIRONMENTS = {"release", "codespaces-claude-break-glass"}
EXPECTED_REQUIRED_STATUS_CHECKS = {"readiness", "release-change-validation"}
EXPECTED_REPO_SECRETS = {
    "APRIL_APP_ID",
    "APRIL_PRIVATE_KEY",
    "APPLE_API_ISSUER_ID",
    "APPLE_API_KEY_BASE64",
    "APPLE_API_KEY_ID",
    "APPLE_DEVELOPER_ID_CERT_BASE64",
    "APPLE_DEVELOPER_ID_CERT_PASSWORD",
    "APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLOUDFLARE_ACCOUNT_ID",
    "CLOUDFLARE_API_TOKEN",
    "EVIDENCE_UPLOAD_TOKEN",
    "SPARKLE_PRIVATE_KEY",
    "VERCEL_ORG_ID",
    "VERCEL_PROJECT_ID",
    "VERCEL_TOKEN",
    "WORKSPACE_AGENTS_APP_ID",
    "WORKSPACE_AGENTS_PRIVATE_KEY",
}
LEGACY_REPO_SECRETS = {"APPLE_APP_PASSWORD"}


@dataclass(frozen=True)
class Check:
    status: str
    name: str
    detail: str


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def gh_json(args: list[str]) -> object:
    result = run(["gh", *args])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "gh command failed")
    return json.loads(result.stdout)


def bool_enabled(value: object) -> bool:
    return isinstance(value, dict) and value.get("enabled") is True


def workflow_has_top_level_permissions(lines: list[str]) -> bool:
    for line in lines:
        if line.startswith("jobs:"):
            return False
        if line.startswith("permissions:"):
            return True
    return False


def jobs_without_explicit_permissions(lines: list[str]) -> list[str]:
    top_level_permissions = workflow_has_top_level_permissions(lines)
    if top_level_permissions:
        return []

    jobs_index = next((index for index, line in enumerate(lines) if line.startswith("jobs:")), None)
    if jobs_index is None:
        return []

    missing: list[str] = []
    current_job: str | None = None
    current_has_permissions = False
    for line in lines[jobs_index + 1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("  ") and not line.startswith("    ") and line.rstrip().endswith(":"):
            if current_job is not None and not current_has_permissions:
                missing.append(current_job)
            current_job = line.strip()[:-1]
            current_has_permissions = False
            continue
        if current_job is not None and line.startswith("    permissions:"):
            current_has_permissions = True

    if current_job is not None and not current_has_permissions:
        missing.append(current_job)
    return missing


def local_workflow_checks() -> list[Check]:
    checks: list[Check] = []
    workflow_dir = REPO_ROOT / ".github/workflows"
    workflows = sorted(workflow_dir.glob("*.yml"))
    pull_request_target = [
        path.name for path in workflows if "pull_request_target" in path.read_text(encoding="utf-8")
    ]
    checks.append(
        Check(
            "fail" if pull_request_target else "pass",
            "no pull_request_target workflows",
            ", ".join(pull_request_target) if pull_request_target else "none found",
        )
    )

    inherited_permissions = [
        f"{path.name}:{job}"
        for path in workflows
        for job in jobs_without_explicit_permissions(path.read_text(encoding="utf-8").splitlines())
    ]
    checks.append(
        Check(
            "fail" if inherited_permissions else "pass",
            "workflow token permissions are explicit",
            ", ".join(inherited_permissions)
            if inherited_permissions
            else "no jobs inherit repository default token permissions",
        )
    )

    release = (workflow_dir / "release.yml").read_text(encoding="utf-8")
    checks.append(
        Check(
            "pass" if "environment: release" in release else "fail",
            "release workflow uses protected environment",
            "release environment referenced" if "environment: release" in release else "missing",
        )
    )
    checks.append(
        Check(
            "pass" if "runs-on: [self-hosted, signing-host]" in release else "fail",
            "release workflow uses signing-host runner",
            "signing-host label referenced" if "signing-host" in release else "missing",
        )
    )

    codespaces = (workflow_dir / "codespaces-claude-worker.yml").read_text(encoding="utf-8")
    checks.append(
        Check(
            "pass" if "codespaces-claude-break-glass" in codespaces else "fail",
            "Codespaces worker is protected",
            "break-glass environment referenced"
            if "codespaces-claude-break-glass" in codespaces
            else "missing",
        )
    )
    return checks


def resolve_repo(explicit: str | None) -> str:
    if explicit:
        return explicit
    data = gh_json(["repo", "view", "--json", "nameWithOwner"])
    repo = str((data if isinstance(data, dict) else {}).get("nameWithOwner", ""))
    if not repo:
        raise RuntimeError("could not resolve repository; pass --repo owner/name")
    return repo


def remote_environment_checks(repo: str) -> list[Check]:
    checks: list[Check] = []
    for environment in sorted(EXPECTED_ENVIRONMENTS):
        try:
            data = gh_json(["api", f"repos/{repo}/environments/{environment}"])
        except RuntimeError as error:
            checks.append(Check("fail", f"environment {environment}", str(error)))
            continue
        rules = data.get("protection_rules") if isinstance(data, dict) else None
        protected = isinstance(rules, list) and len(rules) > 0
        checks.append(
            Check(
                "pass" if protected else "warn",
                f"environment {environment}",
                "has protection rules" if protected else "exists but has no protection rules",
            )
        )
    return checks


def remote_runner_checks(repo: str) -> list[Check]:
    data = gh_json(["api", f"repos/{repo}/actions/runners?per_page=100"])
    runners = data.get("runners", []) if isinstance(data, dict) else []
    labels = {
        str(label.get("name"))
        for runner in runners
        if isinstance(runner, dict)
        for label in runner.get("labels", [])
        if isinstance(label, dict) and label.get("name")
    }
    missing_required = sorted(REQUIRED_RUNNER_LABELS - labels)
    missing_advisory = sorted(ADVISORY_RUNNER_LABELS - labels)
    return [
        Check(
            "fail" if missing_required else "pass",
            "release/agent runner labels",
            f"missing: {', '.join(missing_required)}"
            if missing_required
            else "required labels present",
        ),
        Check(
            "warn" if missing_advisory else "pass",
            "advisory runner labels",
            f"missing: {', '.join(missing_advisory)}"
            if missing_advisory
            else "advisory labels present",
        ),
    ]


def remote_secret_checks(repo: str) -> list[Check]:
    data = gh_json(["secret", "list", "--repo", repo, "--json", "name"])
    secrets = {
        str(item.get("name"))
        for item in data
        if isinstance(item, dict) and item.get("name")
    }
    missing = sorted(EXPECTED_REPO_SECRETS - secrets)
    legacy = sorted(LEGACY_REPO_SECRETS & secrets)
    return [
        Check(
            "fail" if missing else "pass",
            "expected repository secrets",
            f"missing: {', '.join(missing)}" if missing else "all expected names present",
        ),
        Check(
            "warn" if legacy else "pass",
            "legacy repository secrets",
            f"remove stale names: {', '.join(legacy)}" if legacy else "none found",
        ),
    ]


def remote_actions_permission_checks(repo: str) -> list[Check]:
    data = gh_json(["api", f"repos/{repo}/actions/permissions/workflow"])
    workflow_permissions = data if isinstance(data, dict) else {}
    default_permissions = workflow_permissions.get("default_workflow_permissions")
    can_approve_pr_reviews = workflow_permissions.get("can_approve_pull_request_reviews")
    return [
        Check(
            "pass" if default_permissions == "read" else "fail",
            "default GITHUB_TOKEN permissions",
            f"default_workflow_permissions={default_permissions!r}",
        ),
        Check(
            "pass" if can_approve_pr_reviews is False else "fail",
            "GITHUB_TOKEN PR review approval disabled",
            f"can_approve_pull_request_reviews={can_approve_pr_reviews!r}",
        ),
    ]


def remote_branch_protection_checks(repo: str) -> list[Check]:
    try:
        data = gh_json(["api", f"repos/{repo}/branches/main/protection"])
    except RuntimeError as error:
        return [Check("fail", "main branch protection", str(error))]

    protection = data if isinstance(data, dict) else {}
    status_checks = protection.get("required_status_checks")
    if isinstance(status_checks, dict):
        contexts = {
            str(item)
            for item in status_checks.get("contexts", [])
            if item is not None
        }
        strict = status_checks.get("strict") is True
    else:
        contexts = set()
        strict = False
    missing_contexts = sorted(EXPECTED_REQUIRED_STATUS_CHECKS - contexts)

    pull_request_reviews = protection.get("required_pull_request_reviews")
    return [
        Check("pass", "main branch protection", "enabled"),
        Check(
            "pass" if isinstance(pull_request_reviews, dict) else "fail",
            "main requires pull request gate",
            "required_pull_request_reviews configured"
            if isinstance(pull_request_reviews, dict)
            else "missing required_pull_request_reviews",
        ),
        Check(
            "pass" if strict and not missing_contexts else "fail",
            "main required status checks",
            "strict checks present: " + ", ".join(sorted(EXPECTED_REQUIRED_STATUS_CHECKS))
            if strict and not missing_contexts
            else f"strict={strict}, missing={', '.join(missing_contexts) or 'none'}",
        ),
        Check(
            "pass" if bool_enabled(protection.get("enforce_admins")) else "fail",
            "main protection enforces admins",
            "enabled" if bool_enabled(protection.get("enforce_admins")) else "disabled",
        ),
        Check(
            "pass"
            if not bool_enabled(protection.get("allow_force_pushes"))
            and not bool_enabled(protection.get("allow_deletions"))
            else "fail",
            "main blocks force pushes and deletions",
            (
                f"allow_force_pushes={bool_enabled(protection.get('allow_force_pushes'))}, "
                f"allow_deletions={bool_enabled(protection.get('allow_deletions'))}"
            ),
        ),
        Check(
            "pass" if bool_enabled(protection.get("required_conversation_resolution")) else "fail",
            "main requires conversation resolution",
            "enabled"
            if bool_enabled(protection.get("required_conversation_resolution"))
            else "disabled",
        ),
    ]


def remote_variable_checks(repo: str) -> list[Check]:
    data = gh_json(["variable", "list", "--repo", repo, "--json", "name,value"])
    variables = {
        str(item.get("name")): str(item.get("value"))
        for item in data
        if isinstance(item, dict) and item.get("name")
    } if isinstance(data, list) else {}
    value = variables.get("AGENT_AUTOMATIONS_ENABLED")
    return [
        Check(
            "pass" if value in {"true", "false"} else "fail",
            "agent automation kill switch",
            f"AGENT_AUTOMATIONS_ENABLED={value!r}",
        )
    ]


def remote_checks(repo: str) -> list[Check]:
    if not shutil.which("gh"):
        return [Check("warn", "GitHub remote audit", "gh CLI is not installed")]
    checks: list[Check] = []
    for collect in (
        remote_actions_permission_checks,
        remote_branch_protection_checks,
        remote_environment_checks,
        remote_runner_checks,
        remote_secret_checks,
        remote_variable_checks,
    ):
        try:
            checks.extend(collect(repo))
        except RuntimeError as error:
            checks.append(Check("warn", collect.__name__, str(error)))
    return checks


def print_checks(checks: list[Check]) -> None:
    for check in checks:
        print(f"[{check.status.upper()}] {check.name}: {check.detail}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", help="GitHub repository in owner/name form.")
    parser.add_argument("--local-only", action="store_true", help="Skip gh API checks.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on fail checks.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    checks = local_workflow_checks()
    if not args.local_only:
        try:
            repo = resolve_repo(args.repo)
            checks.extend(remote_checks(repo))
        except RuntimeError as error:
            checks.append(Check("warn", "GitHub remote audit", str(error)))

    print_checks(checks)
    failed = any(check.status == "fail" for check in checks)
    return 1 if args.strict and failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
