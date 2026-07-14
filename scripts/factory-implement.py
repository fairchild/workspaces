#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claim and recover Agent Factory implementation dispatches.

The workflow-facing CLI keeps issue admission, WIP enforcement, and lifecycle
mutations deterministic before the contributor runtime receives credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any


FACTORY_WIP_CAP = 2
PRIVILEGED_PATCH_LABEL = "privileged-agent-patch"
PRIVILEGED_PATH_PREFIXES = (".github/", ".agents/")
PRIVILEGED_RELEASE_PATHS = {
    "scripts/build-release.sh",
    "scripts/notarize.sh",
    "scripts/prepare-release.sh",
    "scripts/release-preflight.sh",
    "scripts/release-version.sh",
    "scripts/setup-release-secrets.sh",
    "scripts/signing-config.sh.template",
    "scripts/validate-release-changes.py",
    "scripts/verify-app-keychain-signing.sh",
    "scripts/verify-release-bundle.sh",
}
PRIVILEGED_NAME_MARKERS = ("auth", "credential", "secret", "sandbox", "token")
PRIVILEGED_COMMENT = (
    "Factory implementation skipped: this issue indicates privileged-path scope "
    "and requires the orchestrator lane."
)
WIP_COMMENT = (
    f"Factory implementation is waiting: the {FACTORY_WIP_CAP}-issue factory WIP "
    "cap is full; leaving this issue ready."
)


class FactoryImplementError(RuntimeError):
    """Raised when a dispatch cannot be evaluated or mutated safely."""


@dataclass(frozen=True)
class ClaimDecision:
    action: str
    reason: str


class GitHubClient:
    def __init__(self, repository: str, token: str) -> None:
        if len(repository.split("/", 1)) != 2:
            raise FactoryImplementError("GITHUB_REPOSITORY must be set to owner/name")
        self.repository = repository
        self.token = token
        self.api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> Any:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{self.api_url}{path}",
            data=data,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "workspaces-factory-implement",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise FactoryImplementError(
                f"GitHub API {method} {path} failed with HTTP {error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise FactoryImplementError(
                f"GitHub API {method} {path} failed: {error.reason}"
            ) from error
        if not body:
            return None
        try:
            return json.loads(body)
        except json.JSONDecodeError as error:
            raise FactoryImplementError(
                f"GitHub API {method} {path} returned invalid JSON"
            ) from error

    def issue(self, number: int) -> dict[str, Any]:
        return dict(self.request("GET", f"/repos/{self.repository}/issues/{number}"))

    def comments(self, number: int) -> list[dict[str, Any]]:
        return list(
            self.request(
                "GET",
                f"/repos/{self.repository}/issues/{number}/comments?per_page=100",
            )
        )

    def claimed_issues(self) -> list[dict[str, Any]]:
        labels = urllib.parse.quote("agent,task,claimed")
        items = self.request(
            "GET",
            f"/repos/{self.repository}/issues?state=open&labels={labels}&per_page=100",
        )
        return [dict(item) for item in items if "pull_request" not in item]

    def update_issue(self, number: int, payload: dict[str, Any]) -> None:
        self.request("PATCH", f"/repos/{self.repository}/issues/{number}", payload)

    def comment(self, number: int, body: str) -> None:
        self.request(
            "POST",
            f"/repos/{self.repository}/issues/{number}/comments",
            {"body": body},
        )


def label_names(issue: dict[str, Any]) -> set[str]:
    return {
        str(label.get("name", ""))
        for label in issue.get("labels", []) or []
        if isinstance(label, dict)
    }


def _path_candidates(body: str) -> list[str]:
    candidates: list[str] = []
    for token in re.split(r"\s+", body):
        normalized = token.strip("`'\"()[]{}<>,:;!?").replace("\\", "/")
        normalized = normalized.removeprefix("./").casefold()
        if "/" in normalized:
            candidates.append(normalized)
    return candidates


def privileged_scope(issue: dict[str, Any]) -> bool:
    if PRIVILEGED_PATCH_LABEL in label_names(issue):
        return True
    for path in _path_candidates(str(issue.get("body") or "")):
        parts = PurePosixPath(path).parts
        if path in PRIVILEGED_RELEASE_PATHS:
            return True
        if any(
            path == prefix.rstrip("/") or path.startswith(prefix)
            for prefix in PRIVILEGED_PATH_PREFIXES
        ):
            return True
        if any(marker in part for part in parts for marker in PRIVILEGED_NAME_MARKERS):
            return True
        if path.startswith("infra/") and any(
            marker in part
            for part in parts
            for marker in ("credential", "secret", "token", "key")
        ):
            return True
    return False


def evaluate_claim(issue: dict[str, Any], claimed_count: int) -> ClaimDecision:
    labels = label_names(issue)
    if str(issue.get("state", "")).casefold() != "open":
        return ClaimDecision("skip", "issue is not open")
    missing = {"agent", "task", "ready"} - labels
    if missing:
        return ClaimDecision("skip", f"issue is missing labels: {', '.join(sorted(missing))}")
    if privileged_scope(issue):
        return ClaimDecision("privileged", "issue indicates privileged-path scope")
    if claimed_count >= FACTORY_WIP_CAP:
        return ClaimDecision("wip", f"factory WIP cap of {FACTORY_WIP_CAP} is full")
    return ClaimDecision("claim", "issue is eligible for unattended implementation")


def claim_payload(issue: dict[str, Any], app_slug: str) -> dict[str, Any]:
    labels = sorted((label_names(issue) - {"ready", "claimed"}) | {"claimed"})
    assignees = {
        str(assignee.get("login", ""))
        for assignee in issue.get("assignees", []) or []
        if isinstance(assignee, dict) and assignee.get("login")
    }
    assignees.add(f"{app_slug}[bot]")
    return {"labels": labels, "assignees": sorted(assignees)}


def rollback_payload(issue: dict[str, Any], app_slug: str) -> dict[str, Any]:
    labels = sorted((label_names(issue) - {"claimed", "ready"}) | {"ready"})
    bot_login = f"{app_slug}[bot]".casefold()
    assignees = sorted(
        str(assignee.get("login"))
        for assignee in issue.get("assignees", []) or []
        if isinstance(assignee, dict)
        and assignee.get("login")
        and str(assignee["login"]).casefold() != bot_login
    )
    return {"labels": labels, "assignees": assignees}


def comment_once(client: GitHubClient, issue_number: int, body: str) -> None:
    if any(body in str(comment.get("body", "")) for comment in client.comments(issue_number)):
        return
    client.comment(issue_number, body)


def write_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")
    else:
        print(f"{name}={value}")


def claim(client: GitHubClient, issue_number: int, run_url: str, app_slug: str) -> None:
    issue = client.issue(issue_number)
    claimed_count = len(client.claimed_issues())
    decision = evaluate_claim(issue, claimed_count)
    print(f"Factory implement decision for #{issue_number}: {decision.action} ({decision.reason})")
    write_output("issue_number", str(issue_number))
    write_output("matched", "false")
    if decision.action == "privileged":
        comment_once(client, issue_number, PRIVILEGED_COMMENT)
        return
    if decision.action == "wip":
        comment_once(client, issue_number, WIP_COMMENT)
        return
    if decision.action == "skip":
        return

    client.update_issue(issue_number, claim_payload(issue, app_slug))
    client.comment(issue_number, f"Factory implementation claimed this issue: {run_url}")
    write_output("matched", "true")


def rollback(client: GitHubClient, issue_number: int, run_url: str, app_slug: str) -> None:
    issue = client.issue(issue_number)
    if "claimed" not in label_names(issue):
        print(f"Factory implement rollback for #{issue_number}: claim is no longer active")
        return
    client.update_issue(issue_number, rollback_payload(issue, app_slug))
    comment_once(
        client,
        issue_number,
        f"Factory implementation run failed and restored ready: {run_url}",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("claim", "rollback"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--issue", type=int, required=True)
        subparser.add_argument("--run-url", required=True)
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise FactoryImplementError(f"{name} is required")
    return value


def main() -> int:
    args = parse_args()
    client = GitHubClient(require_env("GITHUB_REPOSITORY"), require_env("GH_TOKEN"))
    app_slug = os.environ.get("GH_APP_SLUG", "april-clearwater").strip()
    if not app_slug:
        raise FactoryImplementError("GH_APP_SLUG must not be empty")
    if args.command == "claim":
        claim(client, args.issue, args.run_url, app_slug)
    else:
        rollback(client, args.issue, args.run_url, app_slug)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FactoryImplementError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
