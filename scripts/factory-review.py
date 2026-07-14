#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Admit agent-authored pull requests to the Factory counterpart-review lane."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


AUTHOR_REVIEWERS = {
    "author:april": "plat",
    "author:plat": "april",
}
APPLICATION_DEFAULT_AUTHORS = {
    "author:claude-code",
    "author:codex",
    "author:fable-orchestrator",
}
REVIEWER_BOTS = {
    "april": "april-clearwater[bot]",
    "plat": "workspace-agents[bot]",
}
PLATFORM_PREFIXES = (".github/", "infra/")
CLOSING_REFERENCE_RE = re.compile(
    r"(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(?P<number>\d+)\b"
)


class FactoryReviewError(RuntimeError):
    """Raised when review admission cannot be evaluated safely."""


class GitHubClient:
    def __init__(self, repository: str, token: str, api_url: str = "https://api.github.com"):
        self.repository = repository
        self.token = token
        self.api_url = api_url.rstrip("/")

    def request(self, path: str) -> Any:
        request = urllib.request.Request(
            f"{self.api_url}{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "workspaces-factory-review",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise FactoryReviewError(
                f"GitHub API GET {path} failed with HTTP {error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise FactoryReviewError(f"GitHub API GET {path} failed: {error.reason}") from error
        return json.loads(body) if body else None

    def pull_request(self, number: int) -> dict[str, Any]:
        return dict(self.request(f"/repos/{self.repository}/pulls/{number}"))

    def pull_request_files(self, number: int) -> list[dict[str, Any]]:
        return self._paginated(f"/repos/{self.repository}/pulls/{number}/files")

    def pull_request_reviews(self, number: int) -> list[dict[str, Any]]:
        return self._paginated(f"/repos/{self.repository}/pulls/{number}/reviews")

    def _paginated(self, path: str) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        page = 1
        while True:
            separator = "&" if "?" in path else "?"
            batch = list(self.request(f"{path}{separator}per_page=100&page={page}"))
            items.extend(dict(item) for item in batch)
            if len(batch) < 100:
                return items
            page += 1


@dataclass(frozen=True)
class ReviewDecision:
    action: str
    reason: str
    reviewer: str = ""


def label_names(pull_request: dict[str, Any]) -> set[str]:
    return {
        str(label.get("name", ""))
        for label in pull_request.get("labels", []) or []
        if isinstance(label, dict) and label.get("name")
    }


def author_label(pull_request: dict[str, Any]) -> str | None:
    labels = sorted(label for label in label_names(pull_request) if label.startswith("author:"))
    if len(labels) != 1:
        return None
    return labels[0]


def mostly_platform_files(files: list[dict[str, Any]]) -> bool:
    paths = [str(item.get("filename") or "") for item in files]
    if not paths:
        return False
    platform_count = sum(path.startswith(PLATFORM_PREFIXES) for path in paths)
    return platform_count > len(paths) / 2


def counterpart_reviewer(author: str, files: list[dict[str, Any]]) -> str | None:
    if author in AUTHOR_REVIEWERS:
        return AUTHOR_REVIEWERS[author]
    if author in APPLICATION_DEFAULT_AUTHORS:
        return "plat" if mostly_platform_files(files) else "april"
    return None


def reviewed_head(
    reviews: list[dict[str, Any]],
    *,
    reviewer: str,
    head_sha: str,
) -> bool:
    expected_login = REVIEWER_BOTS[reviewer].casefold()
    return any(
        str((review.get("user") or {}).get("login") or "").casefold() == expected_login
        and str(review.get("commit_id") or "") == head_sha
        for review in reviews
    )


def linked_issue_number(pull_request: dict[str, Any]) -> int | None:
    match = CLOSING_REFERENCE_RE.search(str(pull_request.get("body") or ""))
    return int(match.group("number")) if match else None


def evaluate_review(
    pull_request: dict[str, Any],
    files: list[dict[str, Any]],
    reviews: list[dict[str, Any]],
    *,
    force: bool,
) -> ReviewDecision:
    if str(pull_request.get("state") or "").casefold() != "open":
        return ReviewDecision("skip", "pull request is not open")
    if bool(pull_request.get("draft")):
        return ReviewDecision("skip", "pull request is a draft")
    author = author_label(pull_request)
    if author is None:
        return ReviewDecision("skip", "pull request does not carry exactly one author label")
    reviewer = counterpart_reviewer(author, files)
    if reviewer is None:
        return ReviewDecision("skip", f"author label {author} has no counterpart route")
    pull_request_author = str((pull_request.get("user") or {}).get("login") or "").casefold()
    if pull_request_author == REVIEWER_BOTS[reviewer].casefold():
        return ReviewDecision("skip", f"{reviewer} cannot review its own pull request")
    head_sha = str((pull_request.get("head") or {}).get("sha") or "")
    if not head_sha:
        return ReviewDecision("skip", "pull request has no head SHA")
    if not force and reviewed_head(reviews, reviewer=reviewer, head_sha=head_sha):
        return ReviewDecision("skip", f"{reviewer} already reviewed head {head_sha}")
    return ReviewDecision("review", f"route {author} to {reviewer}", reviewer)


def write_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")
    else:
        print(f"{name}={value}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--expected-head", default="")
    parser.add_argument("--expected-reviewer", choices=sorted(REVIEWER_BOTS))
    return parser.parse_args()


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise FactoryReviewError(f"{name} is required")
    return value


def main() -> int:
    args = parse_args()
    client = GitHubClient(
        require_env("GITHUB_REPOSITORY"),
        require_env("GH_TOKEN"),
        os.environ.get("GITHUB_API_URL", "https://api.github.com"),
    )
    pull_request = client.pull_request(args.pr)
    files = client.pull_request_files(args.pr)
    reviews = client.pull_request_reviews(args.pr)
    decision = evaluate_review(pull_request, files, reviews, force=args.force)
    head_sha = str((pull_request.get("head") or {}).get("sha") or "")
    if args.expected_head and args.expected_head != head_sha:
        decision = ReviewDecision("skip", "pull request head changed after admission")
    if (
        args.expected_reviewer
        and decision.action == "review"
        and args.expected_reviewer != decision.reviewer
    ):
        decision = ReviewDecision("skip", "counterpart route changed after admission")
    print(f"Factory review decision for #{args.pr}: {decision.action} ({decision.reason})")
    write_output("matched", "true" if decision.action == "review" else "false")
    write_output("pr_number", str(args.pr))
    write_output("reviewer", decision.reviewer)
    write_output("head_sha", head_sha)
    write_output("linked_issue", str(linked_issue_number(pull_request) or ""))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FactoryReviewError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
