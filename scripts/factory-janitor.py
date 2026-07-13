#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Reconcile Agent Factory issue lifecycle state during the daily monitor.

The janitor derives expected labels from issue, claim, and pull-request state.
It is dry-run by default; only an explicit ``--apply`` mutates GitHub.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


FIXTURE_REQUIRED_FILES = ("state.json",)
GITHUB_GRAPHQL_URL = "https://api.github.com/graphql"
STALE_CLAIM_HOURS = 24
MANAGED_STATES = frozenset({"ready", "claimed", "review"})
STATE_PRIORITY = ("review", "claimed", "ready")
DIGEST_MARKER = "<!-- " + "-".join(("factory", "digest:v1")) + " -->"
CLAIM_MARKER_RE = re.compile(
    r"<!-- contributor:issue=(?P<number>\d+);status=(?P<status>[a-z_]+);"
    r"agent=(?P<agent>[a-z0-9-]+);branch=(?P<branch>[^>\n]+) -->"
)
CLOSING_REFERENCE_RE = re.compile(
    r"(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(?P<number>\d+)\b"
)
TRUSTED_AUTHOR_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
TRUSTED_AUTOMATION_LOGINS = {
    "april-clearwater[bot]",
    "claude[bot]",
    "github-actions[bot]",
    "plat-ironwood[bot]",
    "workspace-agents",
    "workspace-agents[bot]",
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
        timelineItems(last: 100, itemTypes: [LABELED_EVENT, ASSIGNED_EVENT]) {
          nodes {
            __typename
            ... on LabeledEvent {
              createdAt
              label { name }
            }
            ... on AssignedEvent { createdAt }
          }
        }
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
        number body url state updatedAt closedAt mergedAt
        closingIssuesReferences(first: 50) { nodes { number } }
      }
    }
  }
}
"""


class FactoryJanitorError(RuntimeError):
    """Raised when reconciliation cannot be planned or applied safely."""


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


@dataclass(frozen=True)
class Transition:
    issue_id: str
    issue_number: int
    title: str
    current_states: tuple[str, ...]
    desired_state: str
    reason: str
    current_label_ids: dict[str, str]
    assignees: tuple[tuple[str, str], ...] = ()
    comment: str | None = None


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
        raise FactoryJanitorError(
            f"GitHub GraphQL HTTP {error.code}: {detail}"
        ) from error
    except urllib.error.URLError as error:
        raise FactoryJanitorError(
            f"GitHub GraphQL request failed: {error.reason}"
        ) from error
    except json.JSONDecodeError as error:
        raise FactoryJanitorError("GitHub GraphQL returned invalid JSON") from error
    if payload.get("errors"):
        messages = "; ".join(
            str(item.get("message", item)) for item in payload["errors"]
        )
        raise FactoryJanitorError(f"GitHub GraphQL error: {messages}")
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

    return JanitorInputs(
        repo=RepoInfo(owner, name, repository_id, label_ids),
        issues=issues,
        pulls=pulls,
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
    if "factory" in labels or body_has_digest_marker(issue.get("body")):
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
    candidates: list[tuple[datetime, str]] = []
    for comment in issue.get("comments", []) or []:
        if not isinstance(comment, dict) or not trusted_comment_author(comment):
            continue
        match = CLAIM_MARKER_RE.search(str(comment.get("body", "")))
        if match is None or int(match.group("number")) != issue_number:
            continue
        try:
            candidates.append(
                (parse_datetime(str(comment["createdAt"])), "claim comment")
            )
        except (FactoryJanitorError, KeyError):
            continue

    for event in issue.get("timelineItems", []) or []:
        if not isinstance(event, dict) or event.get("__typename") != "AssignedEvent":
            continue
        try:
            candidates.append(
                (parse_datetime(str(event["createdAt"])), "assignee event")
            )
        except (FactoryJanitorError, KeyError):
            continue

    if candidates:
        return max(candidates, key=lambda item: item[0])

    label_events: list[tuple[datetime, str]] = []
    for event in issue.get("timelineItems", []) or []:
        if not isinstance(event, dict) or event.get("__typename") != "LabeledEvent":
            continue
        label = event.get("label") or {}
        if not isinstance(label, dict) or label.get("name") != "claimed":
            continue
        try:
            label_events.append(
                (parse_datetime(str(event["createdAt"])), "claimed label event")
            )
        except (FactoryJanitorError, KeyError):
            continue
    return max(label_events, key=lambda item: item[0]) if label_events else None


def referenced_issue_numbers(pull: dict[str, Any]) -> set[int]:
    numbers = {
        int(reference["number"])
        for reference in pull.get("closingIssuesReferences", []) or []
        if reference.get("number") is not None
    }
    numbers.update(
        int(match.group("number"))
        for match in CLOSING_REFERENCE_RE.finditer(str(pull.get("body", "")))
    )
    return numbers


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
        bucket = buckets.get(str(pull.get("state", "")).upper())
        if bucket is None:
            continue
        for issue_number in referenced_issue_numbers(pull):
            bucket.setdefault(issue_number, []).append(pull)
    return open_pulls, closed_pulls, merged_pulls


def _transition(
    issue: dict[str, Any],
    desired_state: str,
    reason: str,
    *,
    unassign: bool = False,
    comment: str | None = None,
) -> Transition | None:
    states = current_states(issue)
    if states == (desired_state,):
        return None
    if comment is not None and "\n" in comment:
        raise FactoryJanitorError("janitor comments must be exactly one line")
    assignees = tuple(
        (str(assignee["id"]), str(assignee["login"]))
        for assignee in issue.get("assignees", []) or []
        if unassign and assignee.get("id") and assignee.get("login")
    )
    return Transition(
        issue_id=str(issue["id"]),
        issue_number=int(issue["number"]),
        title=str(issue.get("title", "")),
        current_states=states,
        desired_state=desired_state,
        reason=reason,
        current_label_ids=current_label_ids(issue),
        assignees=assignees,
        comment=comment,
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
            if len(states) > 1:
                transition = _transition(
                    issue,
                    states[0],
                    f"keep highest-priority lifecycle state {states[0]}",
                )
                if transition is not None:
                    transitions.append(transition)
            continue

        if "review" in states:
            if issue_closed_pulls:
                pull = _newest_pull(issue_closed_pulls)
                pull_number = int(pull["number"])
                comment = (
                    "Factory janitor restored ready because "
                    f"PR #{pull_number} closed without merging."
                )
                transition = _transition(
                    issue,
                    "ready",
                    f"PR #{pull_number} closed without merging",
                    comment=comment,
                )
                if transition is not None:
                    transitions.append(transition)
            else:
                anomalies.append(Anomaly(number, "review has no known referencing PR"))
                if len(states) > 1:
                    transition = _transition(
                        issue,
                        "review",
                        "keep highest-priority lifecycle state review",
                    )
                    if transition is not None:
                        transitions.append(transition)
            continue

        if not states:
            continue

        desired_state = states[0]
        if desired_state == "claimed":
            claim = claim_timestamp(issue)
            if claim is None:
                anomalies.append(
                    Anomaly(number, "claimed state has no derivable claim timestamp")
                )
            else:
                claimed_at, source = claim
                age = now - claimed_at
                if age >= timedelta(hours=STALE_CLAIM_HOURS):
                    age_hours = age.total_seconds() / 3600
                    comment = (
                        "Factory janitor restored ready because the claim expired after "
                        "24 hours without an open PR."
                    )
                    transition = _transition(
                        issue,
                        "ready",
                        f"claim is stale at {age_hours:.1f}h ({source})",
                        unassign=True,
                        comment=comment,
                    )
                    if transition is not None:
                        transitions.append(transition)
                    continue

        reason = f"keep highest-priority lifecycle state {desired_state}"
        transition = _transition(issue, desired_state, reason)
        if transition is not None:
            transitions.append(transition)

    return ReconciliationPlan(tuple(transitions), tuple(anomalies))


def _format_states(states: tuple[str, ...]) -> str:
    return "+".join(states) if states else "none"


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
        if transition.comment:
            extras.append(f"comment={json.dumps(transition.comment)}")
        suffix = f"; {'; '.join(extras)}" if extras else ""
        print(
            f"[transition] #{transition.issue_number}: "
            f"{_format_states(transition.current_states)} -> {transition.desired_state} "
            f"({transition.reason}){suffix}"
        )
    for anomaly in plan.anomalies:
        print(f"[anomaly] #{anomaly.issue_number}: {anomaly.detail}")


def _mutation_for_transition(
    transition: Transition,
    label_ids: dict[str, str],
) -> tuple[str, dict[str, Any]]:
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
    desired_label_id = label_ids.get(transition.desired_state)
    if desired_label_id is None:
        raise FactoryJanitorError(
            f"required label {transition.desired_state!r} does not exist"
        )
    variable_definitions: list[str] = []
    fields: list[str] = []
    variables: dict[str, Any] = {}
    if transition.desired_state not in transition.current_states:
        variable_definitions.append("$addInput: AddLabelsToLabelableInput!")
        fields.append(
            "addState: addLabelsToLabelable(input: $addInput) { clientMutationId }"
        )
        variables["addInput"] = {
            "labelableId": transition.issue_id,
            "labelIds": [desired_label_id],
        }

    remove_ids = [
        label_id
        for state, label_id in transition.current_label_ids.items()
        if state != transition.desired_state
    ]
    if remove_ids:
        variable_definitions.append("$removeInput: RemoveLabelsFromLabelableInput!")
        fields.append(
            "removeStates: removeLabelsFromLabelable(input: $removeInput) { clientMutationId }"
        )
        variables["removeInput"] = {
            "labelableId": transition.issue_id,
            "labelIds": sorted(remove_ids),
        }

    if transition.assignees:
        variable_definitions.append(
            "$unassignInput: RemoveAssigneesFromAssignableInput!"
        )
        fields.append(
            "unassign: removeAssigneesFromAssignable(input: $unassignInput) { clientMutationId }"
        )
        variables["unassignInput"] = {
            "assignableId": transition.issue_id,
            "assigneeIds": sorted(
                assignee_id for assignee_id, _ in transition.assignees
            ),
        }

    if transition.comment:
        variable_definitions.append("$commentInput: AddCommentInput!")
        fields.append("comment: addComment(input: $commentInput) { clientMutationId }")
        variables["commentInput"] = {
            "subjectId": transition.issue_id,
            "body": transition.comment,
        }

    if not fields:
        raise FactoryJanitorError(
            f"issue #{transition.issue_number} transition has no mutation operations"
        )
    query = (
        "mutation FactoryJanitorApply("
        + ", ".join(variable_definitions)
        + ") {\n  "
        + "\n  ".join(fields)
        + "\n}"
    )
    return query, variables


def apply_plan(plan: ReconciliationPlan, inputs: JanitorInputs, token: str) -> None:
    for transition in plan.transitions:
        query, variables = _mutation_for_transition(transition, inputs.repo.label_ids)
        graphql(token, query, variables)
        print(f"[applied] #{transition.issue_number}: {transition.desired_state}")


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
