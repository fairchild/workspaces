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
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


CONTRIBUTOR_SCRIPTS = (
    Path(__file__).resolve().parents[1]
    / ".agents"
    / "skills"
    / "cofounder-contributor"
    / "scripts"
)
if str(CONTRIBUTOR_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(CONTRIBUTOR_SCRIPTS))

from patch_policy import (  # noqa: E402
    issue_body_path_candidates,
    issue_scope_digest,
    sensitive_agent_patch_paths,
)


FACTORY_WIP_CAP = 2
PRIVILEGED_PATCH_LABEL = "privileged-agent-patch"
API_ATTEMPTS = 3
API_BACKOFF_SECONDS = 1.0
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
        body = b""
        for attempt in range(1, API_ATTEMPTS + 1):
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
                break
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", errors="replace")
                transient = error.code == 429 or 500 <= error.code < 600
                if not transient or attempt == API_ATTEMPTS:
                    raise FactoryImplementError(
                        f"GitHub API {method} {path} failed with HTTP "
                        f"{error.code}: {detail}"
                    ) from error
            except urllib.error.URLError as error:
                if attempt == API_ATTEMPTS:
                    raise FactoryImplementError(
                        f"GitHub API {method} {path} failed: {error.reason}"
                    ) from error
            delay = API_BACKOFF_SECONDS * (2 ** (attempt - 1))
            print(
                f"Retrying GitHub API {method} {path} after {delay:.1f}s",
                file=sys.stderr,
            )
            time.sleep(delay)
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
        comments: list[dict[str, Any]] = []
        page = 1
        while True:
            batch = list(
                self.request(
                    "GET",
                    f"/repos/{self.repository}/issues/{number}/comments"
                    f"?per_page=100&page={page}",
                )
            )
            comments.extend(dict(comment) for comment in batch)
            if len(batch) < 100:
                return comments
            page += 1

    def claimed_issues(self) -> list[dict[str, Any]]:
        labels = urllib.parse.quote("agent,task,claimed")
        items = self.request(
            "GET",
            f"/repos/{self.repository}/issues?state=open&labels={labels}&per_page=100",
        )
        return [dict(item) for item in items if "pull_request" not in item]

    def ready_issues(self) -> list[dict[str, Any]]:
        labels = urllib.parse.quote("agent,task,ready")
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

    def dispatch_issue(self, number: int) -> None:
        self.request(
            "POST",
            f"/repos/{self.repository}/actions/workflows/"
            "factory-implement.yml/dispatches",
            {"ref": "main", "inputs": {"issue_number": str(number)}},
        )


def label_names(issue: dict[str, Any]) -> set[str]:
    return {
        str(label.get("name", ""))
        for label in issue.get("labels", []) or []
        if isinstance(label, dict)
    }


def privileged_scope(issue: dict[str, Any]) -> bool:
    if PRIVILEGED_PATCH_LABEL in label_names(issue):
        return True
    candidates = issue_body_path_candidates(str(issue.get("body") or ""))
    return bool(sensitive_agent_patch_paths(candidates))


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


def claim_payload(issue: dict[str, Any], assignee: str) -> dict[str, Any]:
    labels = sorted((label_names(issue) - {"ready", "claimed"}) | {"claimed"})
    assignees = {
        str(assignee.get("login", ""))
        for assignee in issue.get("assignees", []) or []
        if isinstance(assignee, dict) and assignee.get("login")
    }
    assignees.add(assignee)
    return {"labels": labels, "assignees": sorted(assignees)}


def rollback_payload(issue: dict[str, Any], assignee: str) -> dict[str, Any]:
    labels = sorted((label_names(issue) - {"claimed", "ready"}) | {"ready"})
    claim_assignee = assignee.casefold()
    assignees = sorted(
        str(assignee.get("login"))
        for assignee in issue.get("assignees", []) or []
        if isinstance(assignee, dict)
        and assignee.get("login")
        and str(assignee["login"]).casefold() != claim_assignee
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


def slugify(value: str, *, max_length: int = 48) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    return (slug[:max_length].rstrip("-") or "task")


def claim_branch(issue: dict[str, Any]) -> str:
    number = int(issue["number"])
    title = slugify(str(issue.get("title") or f"issue-{number}"))
    return f"codex/april-clearwater-issue-{number}-{title}"


def claim_comment(issue: dict[str, Any], run_url: str) -> str:
    number = int(issue["number"])
    branch = claim_branch(issue)
    marker = (
        f"<!-- contributor:issue={number};status=claimed;"
        f"agent=april-clearwater;branch={branch} -->"
    )
    return (
        "*April Clearwater, Application Lead*\n\n"
        f"Claiming this issue for execution on `{branch}`.\n\n"
        f"Workflow run: {run_url}\n\n{marker}"
    )


def latest_factory_claim_run(comments: list[dict[str, Any]]) -> str | None:
    prefix = "Workflow run: "
    for comment in reversed(comments):
        body = str(comment.get("body") or "")
        if "agent=april-clearwater;branch=" not in body:
            continue
        line = next((line for line in body.splitlines() if line.startswith(prefix)), "")
        return line.removeprefix(prefix).strip() or None
    return None


def claim(
    client: GitHubClient,
    issue_number: int,
    run_url: str,
    assignee: str,
) -> None:
    issue = client.issue(issue_number)
    claimed_count = len(client.claimed_issues())
    decision = evaluate_claim(issue, claimed_count)
    print(f"Factory implement decision for #{issue_number}: {decision.action} ({decision.reason})")
    write_output("issue_number", str(issue_number))
    write_output("matched", "false")
    write_output("issue_scope_digest", issue_scope_digest(issue))
    if decision.action == "privileged":
        comment_once(client, issue_number, PRIVILEGED_COMMENT)
        return
    if decision.action == "wip":
        comment_once(client, issue_number, WIP_COMMENT)
        return
    if decision.action == "skip":
        return

    client.update_issue(issue_number, claim_payload(issue, assignee))
    client.comment(issue_number, claim_comment(issue, run_url))
    write_output("matched", "true")


def rollback(
    client: GitHubClient,
    issue_number: int,
    run_url: str,
    assignee: str,
) -> None:
    issue = client.issue(issue_number)
    if "claimed" not in label_names(issue):
        print(f"Factory implement rollback for #{issue_number}: claim is no longer active")
        return
    if latest_factory_claim_run(client.comments(issue_number)) != run_url:
        print(f"Factory implement rollback for #{issue_number}: claim belongs to another run")
        return
    client.update_issue(issue_number, rollback_payload(issue, assignee))
    comment_once(
        client,
        issue_number,
        f"Factory implementation run failed and restored ready: {run_url}",
    )


def ready_dispatch_numbers(
    ready_issues: list[dict[str, Any]],
    claimed_count: int,
) -> list[int]:
    capacity = max(0, FACTORY_WIP_CAP - claimed_count)
    eligible = [issue for issue in ready_issues if not privileged_scope(issue)]
    return sorted(int(issue["number"]) for issue in eligible)[:capacity]


def dispatch_ready(client: GitHubClient, *, dry_run: bool) -> None:
    claimed_count = len(client.claimed_issues())
    numbers = ready_dispatch_numbers(client.ready_issues(), claimed_count)
    for number in numbers:
        print(f"Factory implement recovery dispatch for ready issue #{number}")
        if not dry_run:
            client.dispatch_issue(number)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("claim", "rollback"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--issue", type=int, required=True)
        subparser.add_argument("--run-url", required=True)
    dispatch = subparsers.add_parser("dispatch-ready")
    dispatch.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise FactoryImplementError(f"{name} is required")
    return value


def main() -> int:
    args = parse_args()
    client = GitHubClient(require_env("GITHUB_REPOSITORY"), require_env("GH_TOKEN"))
    if args.command == "claim":
        assignee = require_env("FACTORY_CLAIM_ASSIGNEE")
        claim(client, args.issue, args.run_url, assignee)
    elif args.command == "rollback":
        assignee = require_env("FACTORY_CLAIM_ASSIGNEE")
        rollback(client, args.issue, args.run_url, assignee)
    else:
        dispatch_ready(client, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FactoryImplementError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
