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
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
# Lanes that were decommissioned. `tart-ui` per
# docs/decisions/perf-measurement-laptop-optin.md, `lume-macos` per the #1288
# follow-up. A workflow reaching for either is targeting hardware that is gone.
RETIRED_RUNNER_LABELS = {"lume-macos", "tart-ui"}
# OS and architecture qualifiers, not lanes: they narrow which self-hosted
# machine takes the job, they do not name a purpose.
RUNNER_QUALIFIER_LABELS = {"self-hosted", "macos", "linux", "windows", "arm64", "x64", "x86"}
RUNS_ON = re.compile(r"^(\s*)runs-on:\s*(.*?)\s*$")
EXPECTED_ENVIRONMENTS = {"release"}
EXPECTED_REPO_SECRETS = {
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


def runs_on_targets(text: str) -> tuple[list[list[str]], int]:
    """Every `runs-on:` label set in a workflow, plus a count of unresolvable ones.

    Handles the four shapes GitHub accepts — scalar, flow sequence, block
    sequence, and a `${{ }}` expression — because a matcher that only knows the
    two-element flow form reports "nothing self-hosted here" for
    `[self-hosted, macOS, ARM64]`, which is the failure it exists to catch.
    Expressions resolve at run time and are counted, never assumed empty.
    """
    targets: list[list[str]] = []
    dynamic = 0
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = RUNS_ON.match(line)
        if not match:
            continue
        indent, value = match.group(1), match.group(2)
        if "${{" in value:
            dynamic += 1
            continue
        if value.startswith("[") and value.endswith("]"):
            value = value[1:-1]
        elif not value:
            # Block sequence: consume the more-indented `- label` lines below.
            items = []
            for follow in lines[index + 1 :]:
                stripped = follow.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if not stripped.startswith("- ") or len(follow) - len(follow.lstrip()) <= len(indent):
                    break
                items.append(stripped[2:])
            value = ",".join(items)
        labels = [item.strip().strip("\"'") for item in value.split(",")]
        targets.append([label for label in labels if label])
    return targets, dynamic


def self_hosted_lanes(workflow_dir: Path) -> tuple[dict[str, set[str]], int]:
    """Self-hosted lane label -> workflows targeting it, read from the workflows.

    Derived rather than hardcoded: the previous fixed expectation outlived the
    lanes it named and kept asserting a release runner the workflows had already
    stopped using. Returns the unresolvable-`runs-on` count alongside, so callers
    can say what they could not check instead of reporting a clean bill.
    """
    lanes: dict[str, set[str]] = {}
    unresolved = 0
    for path in sorted(workflow_dir.glob("*.yml")):
        targets, dynamic = runs_on_targets(path.read_text(encoding="utf-8"))
        unresolved += dynamic
        for labels in targets:
            lowered = {label.lower() for label in labels}
            if "self-hosted" not in lowered:
                continue
            # A bare `[self-hosted, macOS, ARM64]` names no lane; record it under
            # its own key so it is visible rather than silently dropped.
            named = [label for label in labels if label.lower() not in RUNNER_QUALIFIER_LABELS]
            for label in named or ["self-hosted (unqualified)"]:
                lanes.setdefault(label, set()).add(path.name)
    return lanes, unresolved


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
            "pass" if "runs-on: macos-15" in release else "fail",
            "release workflow runs on a hosted image",
            "macos-15" if "runs-on: macos-15" in release else "no hosted runs-on found",
        )
    )

    lanes, unresolved = self_hosted_lanes(workflow_dir)
    retired = sorted(
        f"{label} ({', '.join(sorted(lanes[label]))})"
        for label in lanes.keys() & RETIRED_RUNNER_LABELS
    )
    caveat = f"; {unresolved} runs-on expression(s) not statically resolvable" if unresolved else ""
    checks.append(
        Check(
            "fail" if retired else "pass",
            "no workflow targets a retired runner lane",
            ("; ".join(retired) if retired else "none targeted") + caveat,
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
    lanes, unresolved = self_hosted_lanes(REPO_ROOT / ".github/workflows")
    required = set(lanes)
    missing_required = sorted(required - labels)
    if not required:
        detail = (
            f"no workflow targets a self-hosted lane; {len(runners)} runner(s) still registered"
            if runners
            else "no workflow targets a self-hosted lane; none registered"
        )
        if unresolved:
            detail += f"; {unresolved} runs-on expression(s) not statically resolvable"
        return [Check("pass", "self-hosted lanes workflows depend on", detail)]
    return [
        Check(
            "fail" if missing_required else "pass",
            "self-hosted lanes workflows depend on",
            f"missing: {', '.join(missing_required)}"
            if missing_required
            else f"present: {', '.join(sorted(required))}",
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


def remote_checks(repo: str) -> list[Check]:
    if not shutil.which("gh"):
        return [Check("warn", "GitHub remote audit", "gh CLI is not installed")]
    checks: list[Check] = []
    for collect in (
        remote_environment_checks,
        remote_runner_checks,
        remote_secret_checks,
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
