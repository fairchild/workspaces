#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Reconcile Agent Factory issue lifecycle state during the daily monitor.

The janitor derives expected labels from issue, claim, and pull-request state,
and strips stale lifecycle labels from closed issues. It is dry-run by
default; only an explicit ``--apply`` mutates GitHub.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


FIXTURE_REQUIRED_FILES = ("state.json",)
GITHUB_GRAPHQL_URL = "https://api.github.com/graphql"
STALE_CLAIM_HOURS = 24
MUTATION_ATTEMPTS = 3
MUTATION_BACKOFF_SECONDS = 1.0
MANAGED_STATES = frozenset({"ready", "claimed", "review"})
STATE_PRIORITY = ("review", "claimed", "ready")
# Lifecycle labels describe open work; on a closed issue every one of them —
# the managed trio plus the additive `mergeable` review signal — is stale.
# The janitor only removes these from closed issues; applying `ready` remains
# Owner-only, so the release-gate invariant is untouched.
CLOSED_LIFECYCLE_LABELS = STATE_PRIORITY + ("mergeable",)
DIGEST_MARKER = "<!-- " + "-".join(("factory", "digest:v1")) + " -->"
JANITOR_MARKER_PREFIX = "factory-janitor"
CLAIM_MARKER_RE = re.compile(
    r"<!-- contributor:issue=(?P<number>\d+);status=(?P<status>[a-z_]+);"
    r"agent=(?P<agent>[a-z0-9-]+);branch=(?P<branch>[^>\n]+) -->"
)
TRUSTED_AUTHOR_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
TRUSTED_AUTOMATION_LOGINS = {
    "april-clearwater[bot]",
    "claude[bot]",
    "github-actions[bot]",
    "plat-ironwood[bot]",
    "workspace-agents",
    "workspace-agents[bot]",
    "workspaces-factory[bot]",
}


ISSUES_QUERY = """
query FactoryJanitorIssues($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    id
    readyLabel: label(name: "ready") { id name }
    claimedLabel: label(name: "claimed") { id name }
    reviewLabel: label(name: "review") { id name }
    issues(first: 100, after: $after, states: OPEN, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id number title body url state
        labels(first: 50) { nodes { id name } }
        assignees(first: 50) { nodes { id login } }
        comments(last: 100) {
          nodes {
            body createdAt authorAssociation
            author { login }
          }
        }
        timelineItems(last: 100, itemTypes: [LABELED_EVENT]) {
          nodes {
            __typename
            ... on LabeledEvent {
              createdAt
              label { name }
            }
          }
        }
      }
    }
  }
}
"""


CLOSED_ISSUES_QUERY = """
query FactoryJanitorClosedIssues($owner: String!, $name: String!, $label: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    issues(
      first: 100
      after: $after
      states: CLOSED
      labels: [$label]
      orderBy: {field: UPDATED_AT, direction: DESC}
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id number title state
        labels(first: 50) { nodes { id name } }
      }
    }
  }
}
"""


PULLS_QUERY = """
query FactoryJanitorPulls($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(
      first: 100
      after: $after
      states: [OPEN, CLOSED, MERGED]
      orderBy: {field: UPDATED_AT, direction: DESC}
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number url state isDraft updatedAt closedAt mergedAt
        closingIssuesReferences(first: 50) { nodes { number } }
      }
    }
  }
}
"""


class FactoryJanitorError(RuntimeError):
    """Raised when reconciliation cannot be planned or applied safely."""


class GitHubRequestError(FactoryJanitorError):
    """A classified GitHub failure, optionally safe to retry."""

    def __init__(self, message: str, *, transient: bool = False):
        super().__init__(message)
        self.transient = transient


@dataclass(frozen=True)
class RepoInfo:
    owner: str
    name: str
    repository_id: str
    label_ids: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class JanitorInputs:
    repo: RepoInfo
    issues: list[dict[str, Any]]
    pulls: list[dict[str, Any]]
    closed_issues: list[dict[str, Any]] = field(default_factory=list)


@dataclass(frozen=True)
class Transition:
    issue_id: str
    issue_number: int
    title: str
    current_states: tuple[str, ...]
    desired_state: str | None
    reason: str
    current_label_ids: dict[str, str]
    assignees: tuple[tuple[str, str], ...] = ()
    preserved_assignees: tuple[str, ...] = ()
    comment: str | None = None


@dataclass(frozen=True)
class MutationOperation:
    name: str
    query: str
    variables: dict[str, Any]


@dataclass(frozen=True)
class Anomaly:
    issue_number: int
    detail: str


@dataclass(frozen=True)
class ReconciliationPlan:
    transitions: tuple[Transition, ...]
    anomalies: tuple[Anomaly, ...]


def graphql(token: str, query: str, variables: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        GITHUB_GRAPHQL_URL,
        data=json.dumps({"query": query, "variables": variables}).encode("utf-8"),
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "workspaces-factory-janitor",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        headers = error.headers or {}
        rate_limited = error.code == 429 or (
            error.code == 403
            and (
                headers.get("X-RateLimit-Remaining") == "0"
                or "rate limit" in detail.casefold()
            )
        )
        raise GitHubRequestError(
            f"GitHub GraphQL HTTP {error.code}: {detail}",
            transient=rate_limited or 500 <= error.code < 600,
        ) from error
    except urllib.error.URLError as error:
        raise GitHubRequestError(
            f"GitHub GraphQL request failed: {error.reason}", transient=True
        ) from error
    except json.JSONDecodeError as error:
        raise GitHubRequestError(
            "GitHub GraphQL returned invalid JSON", transient=True
        ) from error
    if payload.get("errors"):
        messages = "; ".join(
            str(item.get("message", item)) for item in payload["errors"]
        )
        classifications = " ".join(
            str(item.get("type", "")) for item in payload["errors"]
        ).casefold()
        transient = "rate_limited" in classifications or any(
            phrase in messages.casefold()
            for phrase in (
                "rate limit",
                "service unavailable",
                "something went wrong",
                "timed out",
                "timeout",
            )
        )
        raise GitHubRequestError(
            f"GitHub GraphQL error: {messages}", transient=transient
        )
    return payload


def split_repo_slug(slug: str) -> tuple[str, str]:
    parts = slug.strip().split("/", 1)
    if len(parts) != 2 or not all(parts):
        raise FactoryJanitorError("GITHUB_REPOSITORY must be set to owner/name")
    return parts[0], parts[1]


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise FactoryJanitorError(f"required environment variable {name} is not set")
    return value


def _flatten_issue(node: dict[str, Any]) -> dict[str, Any]:
    return {
        **node,
        "labels": list(node.get("labels", {}).get("nodes", [])),
        "assignees": list(node.get("assignees", {}).get("nodes", [])),
        "comments": list(node.get("comments", {}).get("nodes", [])),
        "timelineItems": list(node.get("timelineItems", {}).get("nodes", [])),
    }


def _flatten_pull(node: dict[str, Any]) -> dict[str, Any]:
    return {
        **node,
        "closingIssuesReferences": list(
            node.get("closingIssuesReferences", {}).get("nodes", [])
        ),
    }


def fetch_live_inputs(repo_slug: str, token: str) -> JanitorInputs:
    owner, name = split_repo_slug(repo_slug)
    common_variables: dict[str, Any] = {"owner": owner, "name": name}
    issues: list[dict[str, Any]] = []
    label_ids: dict[str, str] = {}
    repository_id = ""
    cursor: str | None = None
    while True:
        payload = graphql(token, ISSUES_QUERY, {**common_variables, "after": cursor})
        repository = payload.get("data", {}).get("repository")
        if repository is None:
            raise FactoryJanitorError(f"repository {repo_slug} was not found")
        repository_id = str(repository["id"])
        for state in STATE_PRIORITY:
            label = repository.get(f"{state}Label")
            if label is not None:
                label_ids[state] = str(label["id"])
        connection = repository["issues"]
        issues.extend(_flatten_issue(node) for node in connection["nodes"])
        if not connection["pageInfo"]["hasNextPage"]:
            break
        cursor = connection["pageInfo"]["endCursor"]

    pulls: list[dict[str, Any]] = []
    cursor = None
    while True:
        payload = graphql(token, PULLS_QUERY, {**common_variables, "after": cursor})
        repository = payload.get("data", {}).get("repository")
        if repository is None:
            raise FactoryJanitorError(f"repository {repo_slug} was not found")
        connection = repository["pullRequests"]
        pulls.extend(_flatten_pull(node) for node in connection["nodes"])
        if not connection["pageInfo"]["hasNextPage"]:
            break
        cursor = connection["pageInfo"]["endCursor"]

    closed_issues: list[dict[str, Any]] = []
    seen_closed: set[int] = set()
    for label_name in CLOSED_LIFECYCLE_LABELS:
        cursor = None
        while True:
            payload = graphql(
                token,
                CLOSED_ISSUES_QUERY,
                {**common_variables, "label": label_name, "after": cursor},
            )
            repository = payload.get("data", {}).get("repository")
            if repository is None:
                raise FactoryJanitorError(f"repository {repo_slug} was not found")
            connection = repository["issues"]
            for node in connection["nodes"]:
                number = int(node["number"])
                if number in seen_closed:
                    continue
                seen_closed.add(number)
                closed_issues.append(
                    {**node, "labels": list(node.get("labels", {}).get("nodes", []))}
                )
            if not connection["pageInfo"]["hasNextPage"]:
                break
            cursor = connection["pageInfo"]["endCursor"]

    return JanitorInputs(
        repo=RepoInfo(owner, name, repository_id, label_ids),
        issues=issues,
        pulls=pulls,
        closed_issues=closed_issues,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="plan only (the default)")
    mode.add_argument(
        "--apply", action="store_true", help="apply planned GitHub mutations"
    )
    parser.add_argument(
        "--fixtures-dir",
        type=Path,
        help="read checked-in state instead of querying GitHub",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.fixtures_dir is not None and args.apply:
        raise FactoryJanitorError("--fixtures-dir cannot be combined with --apply")


def load_json_file(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FactoryJanitorError(f"missing required file: {path}") from error
    except json.JSONDecodeError as error:
        raise FactoryJanitorError(f"invalid JSON in {path}: {error}") from error


def load_fixture_inputs(fixtures_dir: Path) -> tuple[JanitorInputs, datetime]:
    if not fixtures_dir.is_dir():
        raise FactoryJanitorError(f"fixture pack not found: {fixtures_dir}")
    missing = [
        name for name in FIXTURE_REQUIRED_FILES if not (fixtures_dir / name).is_file()
    ]
    if missing:
        raise FactoryJanitorError(
            f"fixture pack {fixtures_dir} is missing required files: {', '.join(missing)}"
        )
    payload = load_json_file(fixtures_dir / "state.json")
    repo = payload["repo"]
    inputs = JanitorInputs(
        repo=RepoInfo(
            owner=str(repo["owner"]),
            name=str(repo["name"]),
            repository_id=str(repo["id"]),
            label_ids={str(key): str(value) for key, value in repo["labelIds"].items()},
        ),
        issues=list(payload["issues"]),
        pulls=list(payload["pulls"]),
        closed_issues=list(payload.get("closedIssues", [])),
    )
    return inputs, parse_datetime(str(payload["now"]))


def parse_datetime(value: str) -> datetime:
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise FactoryJanitorError(f"invalid timestamp {value!r}") from error
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def label_names(issue: dict[str, Any]) -> set[str]:
    return {
        str(label.get("name", "")).strip()
        for label in issue.get("labels", []) or []
        if str(label.get("name", "")).strip()
    }


def current_label_ids(issue: dict[str, Any]) -> dict[str, str]:
    return {
        str(label["name"]): str(label["id"])
        for label in issue.get("labels", []) or []
        if label.get("name") in MANAGED_STATES and label.get("id")
    }


def current_states(issue: dict[str, Any]) -> tuple[str, ...]:
    labels = label_names(issue)
    return tuple(state for state in STATE_PRIORITY if state in labels)


def body_has_digest_marker(body: Any) -> bool:
    return str(body or "").lstrip().startswith(DIGEST_MARKER)


def is_managed_issue(issue: dict[str, Any]) -> bool:
    labels = label_names(issue)
    if str(issue.get("state", "")).upper() != "OPEN":
        return False
    if (
        "human" in labels
        or "factory" in labels
        or body_has_digest_marker(issue.get("body"))
    ):
        return False
    return {"agent", "task"}.issubset(labels)


def trusted_comment_author(comment: dict[str, Any]) -> bool:
    if str(comment.get("authorAssociation", "")).upper() in TRUSTED_AUTHOR_ASSOCIATIONS:
        return True
    author = comment.get("author") or {}
    login = str(author.get("login", "")).casefold() if isinstance(author, dict) else ""
    return bool(
        login and login in {item.casefold() for item in TRUSTED_AUTOMATION_LOGINS}
    )


def claim_timestamp(issue: dict[str, Any]) -> tuple[datetime, str] | None:
    issue_number = int(issue["number"])
    label_events: list[dict[str, Any]] = []
    for event in issue.get("timelineItems", []) or []:
        if not isinstance(event, dict) or event.get("__typename") != "LabeledEvent":
            continue
        label = event.get("label") or {}
        if not isinstance(label, dict) or label.get("name") != "claimed":
            continue
        label_events.append(event)

    if label_events:
        event = label_events[-1]
        try:
            return parse_datetime(str(event["createdAt"])), "claimed label event"
        except (FactoryJanitorError, KeyError) as error:
            raise FactoryJanitorError(
                "latest claimed label event has malformed or missing timestamp"
            ) from error

    claim_comments: list[dict[str, Any]] = []
    for comment in issue.get("comments", []) or []:
        if not isinstance(comment, dict) or not trusted_comment_author(comment):
            continue
        match = CLAIM_MARKER_RE.search(str(comment.get("body", "")))
        if match is None or int(match.group("number")) != issue_number:
            continue
        claim_comments.append(comment)

    if claim_comments:
        comment = claim_comments[-1]
        try:
            return parse_datetime(str(comment["createdAt"])), "claim comment"
        except (FactoryJanitorError, KeyError) as error:
            raise FactoryJanitorError(
                "latest claim comment has malformed or missing timestamp"
            ) from error

    return None


def has_labeled_event(issue: dict[str, Any], label_name: str) -> bool:
    return any(
        isinstance(event, dict)
        and event.get("__typename") == "LabeledEvent"
        and isinstance(event.get("label"), dict)
        and event["label"].get("name") == label_name
        for event in issue.get("timelineItems", []) or []
    )


def referenced_issue_numbers(pull: dict[str, Any]) -> set[int]:
    return {
        int(reference["number"])
        for reference in pull.get("closingIssuesReferences", []) or []
        if reference.get("number") is not None
    }


def pulls_by_issue(
    pulls: list[dict[str, Any]],
) -> tuple[
    dict[int, list[dict[str, Any]]],
    dict[int, list[dict[str, Any]]],
    dict[int, list[dict[str, Any]]],
]:
    open_pulls: dict[int, list[dict[str, Any]]] = {}
    closed_pulls: dict[int, list[dict[str, Any]]] = {}
    merged_pulls: dict[int, list[dict[str, Any]]] = {}
    buckets = {"OPEN": open_pulls, "CLOSED": closed_pulls, "MERGED": merged_pulls}
    for pull in pulls:
        if bool(pull.get("isDraft")):
            continue
        bucket = buckets.get(str(pull.get("state", "")).upper())
        if bucket is None:
            continue
        for issue_number in referenced_issue_numbers(pull):
            bucket.setdefault(issue_number, []).append(pull)
    return open_pulls, closed_pulls, merged_pulls


def _transition(
    issue: dict[str, Any],
    desired_state: str | None,
    reason: str,
    *,
    unassign: bool = False,
    comment: str | None = None,
    comment_key: str | None = None,
) -> Transition | None:
    states = current_states(issue)
    if (desired_state is None and not states) or states == (desired_state,):
        return None
    assignees = tuple(
        (str(assignee["id"]), str(assignee["login"]))
        for assignee in issue.get("assignees", []) or []
        if unassign
        and assignee.get("id")
        and assignee.get("login")
        and str(assignee["login"]).casefold().endswith("[bot]")
    )
    preserved_assignees = tuple(
        str(assignee["login"])
        for assignee in issue.get("assignees", []) or []
        if unassign
        and assignee.get("login")
        and not str(assignee["login"]).casefold().endswith("[bot]")
    )
    marked_comment = None
    if comment is not None:
        if comment_key is None:
            raise FactoryJanitorError("janitor comment requires a transition key")
        if preserved_assignees:
            rendered = ", ".join(f"@{login}" for login in preserved_assignees)
            comment = f"{comment} Human assignees left in place: {rendered}."
        marker = f"<!-- {JANITOR_MARKER_PREFIX} transition={comment_key} -->"
        if not any(
            isinstance(existing, dict)
            and trusted_comment_author(existing)
            and marker in str(existing.get("body", ""))
            for existing in issue.get("comments", []) or []
        ):
            marked_comment = f"{comment} {marker}"
    if marked_comment is not None and "\n" in marked_comment:
        raise FactoryJanitorError("janitor comments must be exactly one line")
    return Transition(
        issue_id=str(issue["id"]),
        issue_number=int(issue["number"]),
        title=str(issue.get("title", "")),
        current_states=states,
        desired_state=desired_state,
        reason=reason,
        current_label_ids=current_label_ids(issue),
        assignees=assignees,
        preserved_assignees=preserved_assignees,
        comment=marked_comment,
    )


def closed_lifecycle_transition(issue: dict[str, Any]) -> Transition | None:
    if str(issue.get("state", "")).upper() != "CLOSED":
        return None
    label_ids = {
        str(label["name"]): str(label["id"])
        for label in issue.get("labels", []) or []
        if label.get("name") in CLOSED_LIFECYCLE_LABELS and label.get("id")
    }
    if not label_ids:
        return None
    return Transition(
        issue_id=str(issue["id"]),
        issue_number=int(issue["number"]),
        title=str(issue.get("title", "")),
        current_states=tuple(
            state for state in CLOSED_LIFECYCLE_LABELS if state in label_ids
        ),
        desired_state=None,
        reason="issue is closed",
        current_label_ids=label_ids,
    )


def _newest_pull(pulls: list[dict[str, Any]]) -> dict[str, Any]:
    return max(
        pulls,
        key=lambda pull: str(
            pull.get("closedAt") or pull.get("mergedAt") or pull.get("updatedAt") or ""
        ),
    )


def build_plan(inputs: JanitorInputs, *, now: datetime) -> ReconciliationPlan:
    transitions: list[Transition] = []
    anomalies: list[Anomaly] = []
    open_pulls, closed_pulls, merged_pulls = pulls_by_issue(inputs.pulls)

    for issue in sorted(inputs.issues, key=lambda item: int(item["number"])):
        if not is_managed_issue(issue):
            continue
        number = int(issue["number"])
        states = current_states(issue)

        # The Owner release gate is total. Nothing downstream may infer lifecycle
        # state for an issue that the Owner has not released into a managed lane.
        if not states:
            continue

        issue_open_pulls = open_pulls.get(number, [])
        issue_closed_pulls = closed_pulls.get(number, [])
        issue_merged_pulls = merged_pulls.get(number, [])

        if issue_open_pulls:
            pull_numbers = sorted(int(pull["number"]) for pull in issue_open_pulls)
            if len(pull_numbers) > 1:
                rendered = ", ".join(f"#{pull_number}" for pull_number in pull_numbers)
                anomalies.append(
                    Anomaly(
                        number, f"multiple open PRs reference the issue: {rendered}"
                    )
                )
            reason = (
                f"open PR #{pull_numbers[0]} references the issue"
                if len(pull_numbers) == 1
                else "open PRs reference the issue"
            )
            transition = _transition(issue, "review", reason)
            if transition is not None:
                transitions.append(transition)
            continue

        if issue_merged_pulls:
            pull_numbers = sorted(int(pull["number"]) for pull in issue_merged_pulls)
            rendered = ", ".join(f"#{pull_number}" for pull_number in pull_numbers)
            anomalies.append(
                Anomaly(
                    number, f"open issue has merged closing PR reference: {rendered}"
                )
            )
            if "review" not in states and len(states) > 1:
                transition = _transition(
                    issue,
                    states[0],
                    f"keep highest-priority lifecycle state {states[0]}",
                )
                if transition is not None:
                    transitions.append(transition)
            if "review" not in states:
                continue

        if "review" in states:
            desired_state = "ready" if has_labeled_event(issue, "ready") else None
            desired_name = desired_state or "awaiting-release"
            if issue_closed_pulls:
                pull = _newest_pull(issue_closed_pulls)
                pull_number = int(pull["number"])
                outcome = (
                    "restored ready"
                    if desired_state == "ready"
                    else "returned to awaiting release"
                )
                comment = (
                    f"Factory janitor {outcome} because PR #{pull_number} "
                    "closed without merging."
                )
                transition = _transition(
                    issue,
                    desired_state,
                    f"PR #{pull_number} closed without merging",
                    comment=comment,
                    comment_key=f"review-pr-{pull_number}-to-{desired_name}",
                )
            else:
                outcome = (
                    "restored ready"
                    if desired_state == "ready"
                    else "returned to awaiting release"
                )
                transition = _transition(
                    issue,
                    desired_state,
                    "review has no open PR",
                    comment=f"Factory janitor {outcome} because review has no open PR.",
                    comment_key=f"review-no-open-pr-to-{desired_name}",
                )
            if transition is not None:
                transitions.append(transition)
            continue

        desired_state = states[0]
        if desired_state == "claimed":
            try:
                claim = claim_timestamp(issue)
            except FactoryJanitorError as error:
                anomalies.append(Anomaly(number, str(error)))
                continue
            if claim is None:
                anomalies.append(
                    Anomaly(number, "claimed state has no derivable claim timestamp")
                )
            else:
                claimed_at, source = claim
                age = now - claimed_at
                if age >= timedelta(hours=STALE_CLAIM_HOURS):
                    age_hours = age.total_seconds() / 3600
                    release_state = (
                        "ready" if has_labeled_event(issue, "ready") else None
                    )
                    desired_name = release_state or "awaiting-release"
                    outcome = (
                        "restored ready"
                        if release_state == "ready"
                        else "returned to awaiting release"
                    )
                    comment = (
                        f"Factory janitor {outcome} because the claim expired after "
                        f"{STALE_CLAIM_HOURS} hours without an open PR."
                    )
                    transition = _transition(
                        issue,
                        release_state,
                        f"claim is stale at {age_hours:.1f}h ({source})",
                        unassign=True,
                        comment=comment,
                        comment_key=(
                            f"stale-claim-{claimed_at.isoformat()}-to-{desired_name}"
                        ),
                    )
                    if transition is not None:
                        transitions.append(transition)
                    continue

        reason = f"keep highest-priority lifecycle state {desired_state}"
        transition = _transition(issue, desired_state, reason)
        if transition is not None:
            transitions.append(transition)

    for issue in sorted(inputs.closed_issues, key=lambda item: int(item["number"])):
        transition = closed_lifecycle_transition(issue)
        if transition is not None:
            transitions.append(transition)

    return ReconciliationPlan(tuple(transitions), tuple(anomalies))


def _format_states(states: tuple[str, ...]) -> str:
    return "+".join(states) if states else "none"


def _format_desired_state(state: str | None) -> str:
    return state or "none"


def validate_plan(plan: ReconciliationPlan) -> None:
    violations = [
        transition for transition in plan.transitions if not transition.current_states
    ]
    if violations:
        rendered = ", ".join(
            f"#{transition.issue_number} none->{_format_desired_state(transition.desired_state)}"
            for transition in violations
        )
        raise FactoryJanitorError(
            f"Owner release gate forbids every none->* transition: {rendered}"
        )


def _format_anomaly_count(count: int) -> str:
    noun = "anomaly" if count == 1 else "anomalies"
    return f"{count} {noun}"


def print_plan(plan: ReconciliationPlan) -> None:
    for transition in plan.transitions:
        extras: list[str] = []
        if transition.assignees:
            extras.append(
                "unassign=" + ",".join(login for _, login in transition.assignees)
            )
        if transition.preserved_assignees:
            extras.append("preserve=" + ",".join(transition.preserved_assignees))
        if transition.comment:
            extras.append(f"comment={json.dumps(transition.comment)}")
        suffix = f"; {'; '.join(extras)}" if extras else ""
        print(
            f"[transition] #{transition.issue_number}: "
            f"{_format_states(transition.current_states)} -> "
            f"{_format_desired_state(transition.desired_state)} "
            f"({transition.reason}){suffix}"
        )
    for anomaly in plan.anomalies:
        print(f"[anomaly] #{anomaly.issue_number}: {anomaly.detail}")


def _mutations_for_transition(
    transition: Transition,
    label_ids: dict[str, str],
) -> tuple[MutationOperation, ...]:
    missing_current_ids = [
        state
        for state in transition.current_states
        if state != transition.desired_state
        and state not in transition.current_label_ids
    ]
    if missing_current_ids:
        rendered = ", ".join(missing_current_ids)
        raise FactoryJanitorError(
            f"issue #{transition.issue_number} is missing label IDs for: {rendered}"
        )
    operations: list[MutationOperation] = []
    mutation_id_prefix = f"factory-janitor-{transition.issue_number}"
    if (
        transition.desired_state is not None
        and transition.desired_state not in transition.current_states
    ):
        desired_label_id = label_ids.get(transition.desired_state)
        if desired_label_id is None:
            raise FactoryJanitorError(
                f"required label {transition.desired_state!r} does not exist"
            )
        operations.append(
            MutationOperation(
                "add-label",
                """mutation FactoryJanitorAddLabel($input: AddLabelsToLabelableInput!) {
  result: addLabelsToLabelable(input: $input) { clientMutationId }
}""",
                {
                    "input": {
                        "labelableId": transition.issue_id,
                        "labelIds": [desired_label_id],
                        "clientMutationId": f"{mutation_id_prefix}-add-label",
                    }
                },
            )
        )

    remove_ids = [
        label_id
        for state, label_id in transition.current_label_ids.items()
        if state != transition.desired_state
    ]
    if remove_ids:
        operations.append(
            MutationOperation(
                "remove-labels",
                """mutation FactoryJanitorRemoveLabels($input: RemoveLabelsFromLabelableInput!) {
  result: removeLabelsFromLabelable(input: $input) { clientMutationId }
}""",
                {
                    "input": {
                        "labelableId": transition.issue_id,
                        "labelIds": sorted(remove_ids),
                        "clientMutationId": f"{mutation_id_prefix}-remove-labels",
                    }
                },
            )
        )

    if transition.assignees:
        operations.append(
            MutationOperation(
                "unassign-bots",
                """mutation FactoryJanitorUnassign($input: RemoveAssigneesFromAssignableInput!) {
  result: removeAssigneesFromAssignable(input: $input) { clientMutationId }
}""",
                {
                    "input": {
                        "assignableId": transition.issue_id,
                        "assigneeIds": sorted(
                            assignee_id for assignee_id, _ in transition.assignees
                        ),
                        "clientMutationId": f"{mutation_id_prefix}-unassign-bots",
                    }
                },
            )
        )

    if transition.comment:
        operations.append(
            MutationOperation(
                "comment",
                """mutation FactoryJanitorComment($input: AddCommentInput!) {
  result: addComment(input: $input) { clientMutationId }
}""",
                {
                    "input": {
                        "subjectId": transition.issue_id,
                        "body": transition.comment,
                        "clientMutationId": f"{mutation_id_prefix}-comment",
                    }
                },
            )
        )

    if not operations:
        raise FactoryJanitorError(
            f"issue #{transition.issue_number} transition has no mutation operations"
        )
    return tuple(operations)


def _apply_mutation_with_retry(token: str, operation: MutationOperation) -> None:
    for attempt in range(1, MUTATION_ATTEMPTS + 1):
        try:
            graphql(token, operation.query, operation.variables)
            return
        except GitHubRequestError as error:
            if not error.transient or attempt == MUTATION_ATTEMPTS:
                raise
            delay = MUTATION_BACKOFF_SECONDS * (2 ** (attempt - 1))
            print(
                f"[retry] {operation.name}: transient failure; "
                f"attempt {attempt + 1}/{MUTATION_ATTEMPTS} in {delay:.1f}s",
                file=sys.stderr,
            )
            time.sleep(delay)


def apply_plan(plan: ReconciliationPlan, inputs: JanitorInputs, token: str) -> None:
    failures: list[tuple[int, str]] = []
    for transition in plan.transitions:
        try:
            operations = _mutations_for_transition(transition, inputs.repo.label_ids)
            for operation in operations:
                _apply_mutation_with_retry(token, operation)
        except FactoryJanitorError as error:
            failures.append((transition.issue_number, str(error)))
            print(f"[failed] #{transition.issue_number}: {error}", file=sys.stderr)
            continue
        print(
            f"[applied] #{transition.issue_number}: "
            f"{_format_desired_state(transition.desired_state)}"
        )

    if failures:
        rendered = "; ".join(f"#{number}: {detail}" for number, detail in failures)
        raise FactoryJanitorError(f"persistent per-issue failures: {rendered}")


def main() -> int:
    args = parse_args()
    validate_args(args)
    if args.fixtures_dir is not None:
        inputs, now = load_fixture_inputs(args.fixtures_dir)
        token = ""
    else:
        token = require_env("GH_TOKEN")
        inputs = fetch_live_inputs(require_env("GITHUB_REPOSITORY"), token)
        now = datetime.now(UTC)

    plan = build_plan(inputs, now=now)
    validate_plan(plan)
    print_plan(plan)
    if args.apply:
        apply_plan(plan, inputs, token)
        print(
            f"Applied {len(plan.transitions)} transition(s); "
            f"reported {_format_anomaly_count(len(plan.anomalies))}."
        )
    else:
        print(
            f"Dry run: {len(plan.transitions)} transition(s), "
            f"{_format_anomaly_count(len(plan.anomalies))}; no writes."
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FactoryJanitorError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
