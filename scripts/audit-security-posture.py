#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
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

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
# Lanes that were decommissioned. `tart-ui` per
# docs/decisions/perf-measurement-laptop-optin.md, `lume-macos` per the #1288
# follow-up. A workflow reaching for either is targeting hardware that is gone.
RETIRED_RUNNER_LABELS = {"lume-macos", "tart-ui"}
# OS and architecture qualifiers, not lanes: they narrow which self-hosted
# machine takes the job, they do not name a purpose.
RUNNER_QUALIFIER_LABELS = {"self-hosted", "macos", "linux", "windows", "arm64", "x64", "x86"}
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


@dataclass(frozen=True)
class JobTarget:
    workflow: str
    job: str
    labels: tuple[str, ...]
    dynamic: bool

    @property
    def self_hosted(self) -> bool:
        return "self-hosted" in {label.lower() for label in self.labels}

    @property
    def lanes(self) -> list[str]:
        """Purpose labels, with OS/arch qualifiers dropped.

        A target of `[self-hosted, macOS, ARM64]` names no lane but is still
        self-hosted, so it reports under its own name rather than disappearing
        once the qualifiers are filtered out.
        """
        named = [label for label in self.labels if label.lower() not in RUNNER_QUALIFIER_LABELS]
        return named or ["self-hosted (unqualified)"]


def workflow_paths(workflow_dir: Path) -> list[Path]:
    return sorted([*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")])


def job_targets(workflow_dir: Path) -> list[JobTarget]:
    """Every job's `runs-on`, parsed as YAML rather than matched as text.

    `runs-on` accepts a scalar, a sequence, a `group`/`labels` mapping, or an
    expression, and any of them can carry comments or quoting. A line matcher
    reads several of those as "nothing self-hosted here" — the exact false PASS
    this check exists to prevent — so the structure is parsed, and anything that
    only resolves at run time is marked `dynamic` instead of assumed empty.
    """
    targets: list[JobTarget] = []
    for path in workflow_paths(workflow_dir):
        try:
            document = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError:
            targets.append(JobTarget(path.name, "<unparseable>", (), True))
            continue
        if not isinstance(document, dict):
            continue
        jobs = document.get("jobs")
        if not isinstance(jobs, dict):
            continue
        for name, job in jobs.items():
            if not isinstance(job, dict) or "runs-on" not in job:
                continue  # reusable-workflow call: `uses:`, no runner of its own
            targets.append(_target(path.name, str(name), job["runs-on"]))
    return targets


def _target(workflow: str, job: str, runs_on: object) -> JobTarget:
    if isinstance(runs_on, dict):  # {group: ..., labels: [...]}
        raw = [runs_on.get("group"), *(runs_on.get("labels") or [])]
    elif isinstance(runs_on, (list, tuple)):
        raw = list(runs_on)
    else:
        raw = [runs_on]
    labels = [str(item) for item in raw if item is not None]
    return JobTarget(workflow, job, tuple(labels), any("${{" in label for label in labels))


def self_hosted_lanes(workflow_dir: Path) -> dict[str, set[str]]:
    """Self-hosted lane label -> workflows targeting it, read from the workflows.

    Derived rather than hardcoded: the previous fixed expectation outlived the
    lanes it named and kept asserting a release runner the workflows had already
    stopped using.
    """
    lanes: dict[str, set[str]] = {}
    for target in job_targets(workflow_dir):
        if not target.self_hosted:
            continue
        for lane in target.lanes:
            lanes.setdefault(lane, set()).add(target.workflow)
    return lanes


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
    targets = job_targets(workflow_dir)

    # Every release job, not "some job somewhere is hosted": reverting only the
    # signing job to self-hosted leaves the other jobs hosted, so a check that
    # merely finds one hosted `runs-on` passes the regression it guards against.
    release_self_hosted = sorted(
        f"{target.job} ({', '.join(target.labels)})"
        for target in targets
        if target.workflow == "release.yml" and target.self_hosted
    )
    checks.append(
        Check(
            "fail" if release_self_hosted else "pass",
            "every release job runs on a hosted image",
            "; ".join(release_self_hosted)
            if release_self_hosted
            else "no release job targets a self-hosted runner",
        )
    )

    retired = sorted(
        f"{target.workflow}:{target.job} ({', '.join(target.labels)})"
        for target in targets
        if {label.lower() for label in target.labels} & RETIRED_RUNNER_LABELS
    )
    checks.append(
        Check(
            "fail" if retired else "pass",
            "no workflow targets a retired runner lane",
            "; ".join(retired) if retired else "none targeted",
        )
    )

    # Separate check, because "found no retired lane" and "could read every
    # target" are different claims and a run-time expression only supports the
    # first. Folding them together reports a clean bill for a lane the audit
    # never actually saw.
    unresolved = sorted(
        f"{target.workflow}:{target.job}" for target in targets if target.dynamic
    )
    checks.append(
        Check(
            "fail" if unresolved else "pass",
            "every runs-on is statically verifiable",
            "resolves only at run time: " + ", ".join(unresolved)
            if unresolved
            else "no expression-valued runs-on",
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
    required = set(self_hosted_lanes(REPO_ROOT / ".github/workflows"))
    missing_required = sorted(required - labels)
    if not required:
        detail = (
            f"no workflow targets a self-hosted lane; {len(runners)} runner(s) still registered"
            if runners
            else "no workflow targets a self-hosted lane; none registered"
        )
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
