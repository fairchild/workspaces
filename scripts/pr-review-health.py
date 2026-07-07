#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Audit managed PR reviewer GitHub projection drift on recent open PRs.

This is a GitHub-facing projection audit for the WorkSpaces managed PR
reviewer, not the source-of-truth ReviewRun health report and not a general "all
open PRs are mergeable" gate.

Use ``scripts/pr-reviewer-runs.py`` when you need the ReviewRun database view:
trigger rows, executing sessions, projection-due rows, and stored failures. This
script checks the GitHub-facing projection on open PRs.

The script intentionally separates the queue into two buckets:

- Active scope: non-draft open PRs updated within ``--updated-within-hours``.
  These PRs are evaluated strictly for managed-reviewer coverage.
- Skipped / unassessed: draft PRs and older open PRs. These are listed so they
  are visible, but they do not fail the scheduled health job by default. This
  keeps old pre-indicator branches from permanently pinning the monitor red.

Interpretation:

- "Active failures: 0" only means no active-scope PR is missing a required
  managed-reviewer signal.
- Any skipped PRs mean queue coverage is incomplete. They may be fine, stale, or
  intentionally parked, but this script did not assess them as healthy.
- A pending ``WorkSpaces Managed Review`` status is acceptable only until
  ``--pending-timeout-min`` expires. After that it is a failed pickup/completion
  signal.

Operator response:

- Active failures are the immediate break/fix queue.
- Skipped / unassessed PRs are the coverage queue. Investigate them by widening
  ``--updated-within-hours`` or triaging the listed PRs, but do not read them as
  healthy just because the active gate is green.
- A fully healthy reviewer queue has both ``Active failures: 0`` and
  ``Queue coverage: complete``.

Use a narrower ``--updated-within-hours`` for a quiet scheduled monitor and a
larger value when deliberately auditing the whole open PR backlog.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


GITHUB_GRAPHQL_URL = "https://api.github.com/graphql"
EX_TEMPFAIL = 75


class TransientHealthError(RuntimeError):
    """Raised when the audit cannot reach GitHub (timeout/transport failure).

    The scheduled audit treats this as a soft retry (exit `EX_TEMPFAIL`) rather than a
    projection-drift failure, so a network blip does not read as a stuck-pending status.
    """

MANAGED_REVIEWER_LOGINS = {
    "workspace-agents",
    "workspace-agents[bot]",
    "workspaces-claude-pr-reviewer",
    "workspaces-claude-pr-reviewer[bot]",
}
MANAGED_STATUS_CONTEXT = "WorkSpaces Managed Review"
POSTED_REVIEW_STATES = {"APPROVED", "CHANGES_REQUESTED", "COMMENTED"}
FAILURE_STATUS_STATES = {"ERROR", "FAILURE"}


QUERY = """
query ManagedReviewerHealth($owner: String!, $name: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo {
        hasNextPage
        endCursor
      }
      nodes {
        number
        title
        url
        isDraft
        updatedAt
        headRefOid
        mergeStateStatus
        reviews(last: 100) {
          nodes {
            state
            submittedAt
            author {
              login
            }
            commit {
              oid
            }
          }
        }
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              __typename
              ... on StatusContext {
                context
                state
                createdAt
                targetUrl
              }
            }
          }
        }
      }
    }
  }
}
"""


@dataclass(frozen=True)
class PullRequestResult:
    number: int
    title: str
    url: str
    head_sha: str
    merge_state: str
    status_state: str
    review_state: str
    problems: tuple[str, ...]
    notices: tuple[str, ...]
    skipped_reason: str | None = None

    @property
    def ok(self) -> bool:
        return not self.problems

    @property
    def skipped(self) -> bool:
        return self.skipped_reason is not None


@dataclass(frozen=True)
class HealthReport:
    results: tuple[PullRequestResult, ...]

    @property
    def failures(self) -> list[PullRequestResult]:
        return [result for result in self.results if result.problems]

    @property
    def active_results(self) -> list[PullRequestResult]:
        return [result for result in self.results if not result.skipped]

    @property
    def skipped_results(self) -> list[PullRequestResult]:
        return [result for result in self.results if result.skipped]

    @property
    def queue_coverage(self) -> str:
        if self.skipped_results:
            count = len(self.skipped_results)
            plural = "PRs" if count != 1 else "PR"
            return f"incomplete ({count} skipped/unassessed {plural})"
        return "complete"


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def short_sha(value: str | None) -> str:
    return (value or "")[:7] or "-"


def reviewer_login(review: dict[str, Any]) -> str:
    author = review.get("author") or {}
    return str(author.get("login") or "")


def managed_reviews(pr: dict[str, Any]) -> list[dict[str, Any]]:
    nodes = ((pr.get("reviews") or {}).get("nodes") or [])
    reviews = [review for review in nodes if reviewer_login(review) in MANAGED_REVIEWER_LOGINS]
    return sorted(
        reviews,
        key=lambda review: parse_timestamp(review.get("submittedAt")) or datetime.min.replace(tzinfo=UTC),
    )


def managed_status(pr: dict[str, Any]) -> dict[str, Any] | None:
    rollup = pr.get("statusCheckRollup") or {}
    contexts = ((rollup.get("contexts") or {}).get("nodes") or [])
    statuses = [
        context
        for context in contexts
        if context.get("__typename") == "StatusContext"
        and context.get("context") == MANAGED_STATUS_CONTEXT
    ]
    if not statuses:
        return None
    return sorted(
        statuses,
        key=lambda status: status_timestamp(status) or datetime.min.replace(tzinfo=UTC),
    )[-1]


def current_head_review(pr: dict[str, Any]) -> dict[str, Any] | None:
    head_sha = pr.get("headRefOid")
    current_reviews = [
        review
        for review in managed_reviews(pr)
        if ((review.get("commit") or {}).get("oid") == head_sha)
        and review.get("state") in POSTED_REVIEW_STATES
    ]
    return current_reviews[-1] if current_reviews else None


def evaluate_pr(
    pr: dict[str, Any],
    *,
    now: datetime,
    updated_within: timedelta,
    pending_timeout: timedelta,
) -> PullRequestResult:
    updated_at = parse_timestamp(pr.get("updatedAt"))
    head_sha = str(pr.get("headRefOid") or "")
    status = managed_status(pr)
    review = current_head_review(pr)
    status_state = str((status or {}).get("state") or "MISSING").upper()
    review_state = str((review or {}).get("state") or "MISSING").upper()
    notices: list[str] = []
    problems: list[str] = []
    skipped_reason: str | None = None

    if pr.get("isDraft"):
        skipped_reason = "draft"
    elif updated_at and updated_at < now - updated_within:
        skipped_reason = f"not updated within {format_timedelta(updated_within)}"

    if skipped_reason is None:
        if status is None:
            problems.append(f"missing {MANAGED_STATUS_CONTEXT} status on the current head")
        elif status_state in FAILURE_STATUS_STATES:
            problems.append(f"{MANAGED_STATUS_CONTEXT} status is {status_state.lower()}")
        elif status_state == "PENDING":
            started_at = status_timestamp(status)
            if started_at and started_at < now - pending_timeout:
                age = format_timedelta(now - started_at)
                problems.append(f"{MANAGED_STATUS_CONTEXT} has been pending for {age}")
        elif status_state == "SUCCESS" and review is None:
            problems.append("status is success but no current-head managed review was found")

        if status_state != "PENDING" and status_state != "MISSING" and review is None:
            latest_review = managed_reviews(pr)
            if latest_review:
                notices.append(
                    "latest managed review is for "
                    f"{short_sha((latest_review[-1].get('commit') or {}).get('oid'))}, "
                    f"not current head {short_sha(head_sha)}"
                )
            else:
                notices.append("no managed review has been posted yet")

        if review_state == "CHANGES_REQUESTED":
            notices.append("managed reviewer requested changes")

        merge_state = str(pr.get("mergeStateStatus") or "")
        if merge_state in {"BEHIND", "DIRTY", "BLOCKED", "UNKNOWN"}:
            notices.append(f"PR merge state is {merge_state.lower()}")

    return PullRequestResult(
        number=int(pr.get("number") or 0),
        title=str(pr.get("title") or ""),
        url=str(pr.get("url") or ""),
        head_sha=head_sha,
        merge_state=str(pr.get("mergeStateStatus") or "-"),
        status_state=status_state,
        review_state=review_state,
        problems=tuple(problems),
        notices=tuple(notices),
        skipped_reason=skipped_reason,
    )


def evaluate(
    prs: list[dict[str, Any]],
    *,
    now: datetime,
    updated_within: timedelta,
    pending_timeout: timedelta,
) -> HealthReport:
    return HealthReport(
        tuple(
            evaluate_pr(
                pr,
                now=now,
                updated_within=updated_within,
                pending_timeout=pending_timeout,
            )
            for pr in prs
        )
    )


def format_timedelta(delta: timedelta) -> str:
    seconds = max(0, int(delta.total_seconds()))
    if seconds < 60:
        return f"{seconds}s"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m"
    hours = minutes // 60
    if hours < 48:
        return f"{hours}h"
    days = hours // 24
    return f"{days}d"


def status_timestamp(status: dict[str, Any]) -> datetime | None:
    return parse_timestamp(status.get("startedAt") or status.get("createdAt"))


def markdown_escape(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def result_summary(result: PullRequestResult) -> str:
    if result.skipped_reason:
        return f"unassessed: {result.skipped_reason}"
    if result.problems:
        return "; ".join(result.problems)
    if result.status_state == "PENDING":
        parts = ["pending within timeout"]
        parts.extend(result.notices)
        return "; ".join(parts)
    if result.notices:
        return "; ".join(result.notices)
    return "healthy"


def render_markdown(report: HealthReport, *, updated_within: timedelta, pending_timeout: timedelta) -> str:
    lines = [
        "## Managed Reviewer GitHub Projection Audit",
        "",
        "- Source of truth: ReviewRun health comes from `scripts/pr-reviewer-runs.py`",
        "- This audit checks GitHub status/review drift on open PRs",
        f"- Scope: open PRs updated within {format_timedelta(updated_within)}",
        f"- Pending timeout: {format_timedelta(pending_timeout)}",
        f"- Active PRs checked: {len(report.active_results)}",
        f"- Active failures: {len(report.failures)}",
        f"- Skipped/unassessed PRs: {len(report.skipped_results)}",
        f"- Queue coverage: {report.queue_coverage}",
        "",
        "| PR | Head | Status | Review | Result |",
        "| --- | --- | --- | --- | --- |",
    ]
    for result in report.results:
        pr_link = f"[#{result.number}]({result.url})" if result.url else f"#{result.number}"
        lines.append(
            "| "
            + " | ".join(
                [
                    pr_link,
                    short_sha(result.head_sha),
                    markdown_escape(result.status_state.lower()),
                    markdown_escape(result.review_state.lower()),
                    markdown_escape(result_summary(result)),
                ]
            )
            + " |"
        )
    return "\n".join(lines) + "\n"


def emit(report: HealthReport, *, updated_within: timedelta, pending_timeout: timedelta) -> None:
    markdown = render_markdown(
        report,
        updated_within=updated_within,
        pending_timeout=pending_timeout,
    )
    print(markdown)

    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a", encoding="utf-8") as summary:
            summary.write(markdown)

    if os.environ.get("GITHUB_ACTIONS"):
        for failure in report.failures:
            print(f"::error title=Managed reviewer health #{failure.number}::{result_summary(failure)}")
        for result in report.active_results:
            if result.notices and not result.problems:
                print(f"::notice title=Managed reviewer health #{result.number}::{result_summary(result)}")


def get_token() -> str:
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        if token := os.environ.get(name):
            return token

    try:
        result = subprocess.run(
            ["gh", "auth", "token"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip()


def graphql(token: str, variables: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps({"query": QUERY, "variables": variables}).encode()
    request = urllib.request.Request(
        GITHUB_GRAPHQL_URL,
        data=payload,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "workspaces-managed-review-health",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        raise RuntimeError(f"GitHub GraphQL request failed ({error.code}): {body}") from error
    except (TimeoutError, socket.timeout) as error:
        raise TransientHealthError(f"GitHub GraphQL request timed out: {error}") from error
    except urllib.error.URLError as error:
        raise TransientHealthError(f"GitHub GraphQL request failed: {error.reason}") from error

    if data.get("errors"):
        raise RuntimeError(f"GitHub GraphQL returned errors: {json.dumps(data['errors'])}")
    return data


def fetch_open_prs(repo: str, *, token: str, max_prs: int) -> list[dict[str, Any]]:
    if "/" not in repo:
        raise ValueError("--repo must be in owner/name form")
    owner, name = repo.split("/", 1)
    prs: list[dict[str, Any]] = []
    after: str | None = None
    while len(prs) < max_prs:
        page_size = min(100, max_prs - len(prs))
        data = graphql(
            token,
            {
                "owner": owner,
                "name": name,
                "first": page_size,
                "after": after,
            },
        )
        connection = data["data"]["repository"]["pullRequests"]
        prs.extend(connection.get("nodes") or [])
        page_info = connection.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            break
        after = page_info.get("endCursor")
    return prs


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        default=os.environ.get("GITHUB_REPOSITORY", "fairchild/workspaces"),
        help="Repository in owner/name form. Defaults to GITHUB_REPOSITORY.",
    )
    parser.add_argument(
        "--updated-within-hours",
        type=positive_int,
        default=72,
        help="Only fail the health gate for non-draft PRs updated within this many hours.",
    )
    parser.add_argument(
        "--pending-timeout-min",
        type=positive_int,
        default=30,
        help="Fail when a managed review status stays pending longer than this many minutes.",
    )
    parser.add_argument(
        "--max-prs",
        type=positive_int,
        default=100,
        help="Maximum number of open PRs to inspect.",
    )
    parser.add_argument(
        "--fixture",
        help="Read pull request JSON from a fixture file instead of GitHub.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    updated_within = timedelta(hours=args.updated_within_hours)
    pending_timeout = timedelta(minutes=args.pending_timeout_min)

    if args.fixture:
        with Path(args.fixture).open(encoding="utf-8") as fixture:
            prs = json.load(fixture)
    else:
        token = get_token()
        if not token:
            print("GITHUB_TOKEN or GH_TOKEN is required when no --fixture is provided.", file=sys.stderr)
            return 2
        try:
            prs = fetch_open_prs(args.repo, token=token, max_prs=args.max_prs)
        except TransientHealthError as error:
            print(f"::warning::managed review projection audit deferred: {error}", file=sys.stderr)
            return EX_TEMPFAIL

    report = evaluate(
        prs,
        now=datetime.now(UTC),
        updated_within=updated_within,
        pending_timeout=pending_timeout,
    )
    emit(report, updated_within=updated_within, pending_timeout=pending_timeout)
    return 1 if report.failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
