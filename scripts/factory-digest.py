#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build and publish the owner's Factory Digest issue.

The digest combines live GitHub gates with the latest monitor summary so one
mobile-friendly surface carries every action and threshold breach.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


FIXTURE_REQUIRED_FILES = ("issues.json", "pulls.json")
DIGEST_TITLE = "Factory Digest"
DIGEST_MARKER = "<!-- factory-digest:v1 -->"
FACTORY_LABEL_COLOR = "BFD4F2"
FACTORY_LABEL_DESCRIPTION = "Agent Factory observability and operations"
DEFAULT_DAILY_IMPLEMENT_CAP = 6
GITHUB_API_URL = "https://api.github.com"
GITHUB_GRAPHQL_URL = "https://api.github.com/graphql"
MAX_TITLE_LENGTH = 80
# Matches factory-implement.py's FACTORY_SWEEP_ACTOR: the actor GitHub assigns
# a workflow_dispatch run triggered with the default GITHUB_TOKEN from inside
# another Actions run (the Monitor's standing-queue sweep).
FACTORY_SWEEP_ACTOR = "github-actions[bot]"
# A ready+agent+task issue surviving past one daily sweep cycle without moving
# to claimed/review means the sweep never got it out — surface that as a fault
# rather than only a passive list entry (#1148).
QUEUE_STALE_HOURS = 24


class FactoryDigestError(RuntimeError):
    """Raised when the digest cannot be rendered or published."""


@dataclass(frozen=True)
class RepoInfo:
    owner: str
    name: str
    repository_id: str
    label_ids: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class DigestInputs:
    repo: RepoInfo
    issues: list[dict[str, Any]]
    pulls: list[dict[str, Any]]


@dataclass(frozen=True)
class FactoryActivity:
    implement_runs: int = 0
    review_verdicts: int = 0
    responder_replies: int = 0
    implement_daily_cap: int = DEFAULT_DAILY_IMPLEMENT_CAP


def graphql(token: str, query: str, variables: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        GITHUB_GRAPHQL_URL,
        data=json.dumps({"query": query, "variables": variables}).encode("utf-8"),
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "workspaces-factory-digest",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise FactoryDigestError(f"GitHub GraphQL HTTP {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise FactoryDigestError(f"GitHub GraphQL request failed: {error.reason}") from error
    except json.JSONDecodeError as error:
        raise FactoryDigestError("GitHub GraphQL returned invalid JSON") from error
    if payload.get("errors"):
        messages = "; ".join(str(item.get("message", item)) for item in payload["errors"])
        raise FactoryDigestError(f"GitHub GraphQL error: {messages}")
    return payload


def fetch_workflow_runs(
    repo_slug: str,
    token: str,
    workflow: str,
    day: str,
    *,
    missing_ok: bool = False,
) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    page = 1
    while True:
        query = urllib.parse.urlencode({"created": day, "per_page": 100, "page": page})
        url = (
            f"{GITHUB_API_URL}/repos/{repo_slug}/actions/workflows/"
            f"{urllib.parse.quote(workflow, safe='')}/runs?{query}"
        )
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "User-Agent": "workspaces-factory-digest",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return []
            detail = error.read().decode("utf-8", errors="replace")
            raise FactoryDigestError(
                f"GitHub workflow runs request for {workflow} failed with HTTP "
                f"{error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise FactoryDigestError(
                f"GitHub workflow runs request for {workflow} failed: {error.reason}"
            ) from error
        except json.JSONDecodeError as error:
            raise FactoryDigestError(
                f"GitHub workflow runs request for {workflow} returned invalid JSON"
            ) from error
        batch = list(payload.get("workflow_runs") or [])
        runs.extend(dict(run) for run in batch)
        if len(batch) < 100:
            return runs
        page += 1


def fetch_run_jobs(
    repo_slug: str,
    token: str,
    run_id: int,
) -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    page = 1
    while True:
        query = urllib.parse.urlencode(
            {"filter": "all", "per_page": 100, "page": page}
        )
        url = (
            f"{GITHUB_API_URL}/repos/{repo_slug}/actions/runs/{run_id}/jobs?{query}"
        )
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "User-Agent": "workspaces-factory-digest",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise FactoryDigestError(
                f"GitHub jobs request for run {run_id} failed with HTTP "
                f"{error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise FactoryDigestError(
                f"GitHub jobs request for run {run_id} failed: {error.reason}"
            ) from error
        except json.JSONDecodeError as error:
            raise FactoryDigestError(
                f"GitHub jobs request for run {run_id} returned invalid JSON"
            ) from error
        batch = list(payload.get("jobs") or [])
        jobs.extend(dict(job) for job in batch)
        if len(batch) < 100:
            return jobs
        page += 1


def count_successful_steps(
    repo_slug: str,
    token: str,
    runs: list[dict[str, Any]],
    step_names: set[str],
) -> int:
    count = 0
    for run in runs:
        if str(run.get("status", "")).casefold() != "completed":
            continue
        run_id = int(run["id"])
        jobs = fetch_run_jobs(repo_slug, token, run_id)
        if any(
            str(step.get("name", "")) in step_names
            and str(step.get("conclusion", "")).casefold() == "success"
            for job in jobs
            for step in job.get("steps") or []
            if isinstance(step, dict)
        ):
            count += 1
    return count


def is_factory_implement_dispatch(
    run: dict[str, Any],
    repository_owner: str,
) -> bool:
    actor = str((run.get("actor") or {}).get("login") or "")
    trusted = {repository_owner.casefold(), FACTORY_SWEEP_ACTOR.casefold()}
    return actor.casefold() in trusted and (
        str(run.get("event", "")) == "workflow_dispatch"
        or str(run.get("display_title", "")).startswith("Factory Implement ready #")
    )


def count_factory_implement_runs(
    runs: list[dict[str, Any]],
    repository_owner: str,
) -> int:
    return sum(
        max(1, int(run.get("run_attempt") or 1))
        for run in runs
        if is_factory_implement_dispatch(run, repository_owner)
    )


def parse_daily_implement_cap(value: str | None) -> int:
    raw = (value or str(DEFAULT_DAILY_IMPLEMENT_CAP)).strip()
    try:
        cap = int(raw)
    except ValueError as error:
        raise FactoryDigestError(
            f"FACTORY_IMPLEMENT_DAILY_CAP must be a positive integer, got {raw!r}"
        ) from error
    if cap <= 0:
        raise FactoryDigestError("FACTORY_IMPLEMENT_DAILY_CAP must be a positive integer")
    return cap


def fetch_factory_activity(
    repo_slug: str,
    token: str,
    current_time: datetime,
    implement_daily_cap: int,
) -> FactoryActivity:
    repository_owner, _repository_name = split_repo_slug(repo_slug)
    day = current_time.astimezone(UTC).date().isoformat()
    implement_runs = fetch_workflow_runs(
        repo_slug,
        token,
        "factory-implement.yml",
        day,
    )
    review_runs = fetch_workflow_runs(
        repo_slug,
        token,
        "factory-review-execute.yml",
        day,
    )
    responder_runs = fetch_workflow_runs(
        repo_slug,
        token,
        "factory-comment-responder.yml",
        day,
        missing_ok=True,
    )

    return FactoryActivity(
        implement_runs=count_factory_implement_runs(
            implement_runs,
            repository_owner,
        ),
        review_verdicts=count_successful_steps(
            repo_slug,
            token,
            review_runs,
            {"Run April counterpart review", "Run Plat counterpart review"},
        ),
        responder_replies=count_successful_steps(
            repo_slug,
            token,
            responder_runs,
            {"Post reply to gated target"},
        ),
        implement_daily_cap=implement_daily_cap,
    )


def split_repo_slug(slug: str) -> tuple[str, str]:
    parts = slug.strip().split("/", 1)
    if len(parts) != 2 or not all(parts):
        raise FactoryDigestError("GITHUB_REPOSITORY must be set to owner/name")
    return parts[0], parts[1]


def fetch_live_inputs(repo_slug: str, token: str) -> DigestInputs:
    owner, name = split_repo_slug(repo_slug)
    common_variables: dict[str, Any] = {"owner": owner, "name": name}
    issue_query = """
query FactoryDigestIssues($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    id
    factoryLabel: label(name: "factory") { id name }
    humanLabel: label(name: "human") { id name }
    issues(first: 100, after: $after, states: [OPEN, CLOSED]) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id number title body url state createdAt updatedAt
        labels(first: 50) { nodes { name } }
        timelineItems(last: 100, itemTypes: [LABELED_EVENT]) {
          nodes {
            __typename
            ... on LabeledEvent { createdAt label { name } }
          }
        }
      }
    }
  }
}
"""
    issues: list[dict[str, Any]] = []
    cursor: str | None = None
    repository_id = ""
    label_ids: dict[str, str] = {}
    while True:
        payload = graphql(token, issue_query, {**common_variables, "after": cursor})
        repository = payload["data"]["repository"]
        if repository is None:
            raise FactoryDigestError(f"repository {repo_slug} was not found")
        repository_id = str(repository["id"])
        label_fields = (("factory", "factoryLabel"), ("human", "humanLabel"))
        for label_name, field_name in label_fields:
            label = repository.get(field_name)
            if label is not None:
                label_ids[label_name] = str(label["id"])
        connection = repository["issues"]
        for node in connection["nodes"]:
            issues.append(
                {
                    **node,
                    "labels": list(node["labels"]["nodes"]),
                    "timelineItems": list(
                        node.get("timelineItems", {}).get("nodes", [])
                    ),
                }
            )
        if not connection["pageInfo"]["hasNextPage"]:
            break
        cursor = connection["pageInfo"]["endCursor"]

    pull_query = """
query FactoryDigestPulls($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 100, after: $after, states: OPEN) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url state isDraft createdAt updatedAt
        closingIssuesReferences(first: 50) { nodes { number } }
      }
    }
  }
}
"""
    pulls: list[dict[str, Any]] = []
    cursor = None
    while True:
        payload = graphql(token, pull_query, {**common_variables, "after": cursor})
        connection = payload["data"]["repository"]["pullRequests"]
        for node in connection["nodes"]:
            pulls.append(
                {
                    **node,
                    "closingIssuesReferences": list(node["closingIssuesReferences"]["nodes"]),
                }
            )
        if not connection["pageInfo"]["hasNextPage"]:
            break
        cursor = connection["pageInfo"]["endCursor"]

    return DigestInputs(
        repo=RepoInfo(owner, name, repository_id, label_ids),
        issues=issues,
        pulls=pulls,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fixtures-dir", type=Path)
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.fixtures_dir is not None and not args.dry_run:
        raise FactoryDigestError("--fixtures-dir requires --dry-run because fixture writes are forbidden")


def load_json_file(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FactoryDigestError(f"missing required file: {path}") from error
    except json.JSONDecodeError as error:
        raise FactoryDigestError(f"invalid JSON in {path}: {error}") from error


def load_fixture_inputs(
    fixtures_dir: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not fixtures_dir.is_dir():
        raise FactoryDigestError(f"fixture pack not found: {fixtures_dir}")
    missing = [name for name in FIXTURE_REQUIRED_FILES if not (fixtures_dir / name).is_file()]
    if missing:
        raise FactoryDigestError(
            f"fixture pack {fixtures_dir} is missing required files: {', '.join(missing)}"
        )
    return (
        list(load_json_file(fixtures_dir / "issues.json")),
        list(load_json_file(fixtures_dir / "pulls.json")),
    )


def parse_datetime(value: str) -> datetime:
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def age_days(value: str, current_time: datetime) -> int:
    return max(0, int((current_time - parse_datetime(value)).total_seconds() // 86_400))


def label_names(item: dict[str, Any]) -> set[str]:
    return {str(label.get("name", "")) for label in item.get("labels", []) or []}


def ready_since(issue: dict[str, Any]) -> str:
    """Timestamp the issue most recently became `ready`.

    Falls back to createdAt, then updatedAt, when no LabeledEvent timeline
    data is available (older callers/fixtures that predate this field).
    """
    for event in reversed(issue.get("timelineItems", []) or []):
        if not isinstance(event, dict) or event.get("__typename") != "LabeledEvent":
            continue
        label = event.get("label")
        if isinstance(label, dict) and label.get("name") == "ready":
            return str(event["createdAt"])
    return str(issue.get("createdAt") or issue.get("updatedAt"))


def render_title(value: Any) -> str:
    sanitized = " ".join(str(value or "").splitlines()).replace("`", "'")
    sanitized = sanitized.replace("<!--", "< !--").replace("-->", "-- >")
    if len(sanitized) > MAX_TITLE_LENGTH:
        sanitized = sanitized[: MAX_TITLE_LENGTH - 1] + "…"
    return f"`{sanitized}`"


def render_item_reference(item: dict[str, Any]) -> str:
    return f"[#{item['number']}]({item.get('url', '')}) {render_title(item.get('title', ''))}"


def render_stats(summary: dict[str, Any]) -> str:
    counts = summary.get("counts") or summary.get("funnel") or {}
    rendered = " · ".join(f"{key} {value}" for key, value in counts.items())
    return f"Stats: {rendered} · generated {summary['generated_at']}"


def render_factory_activity(activity: FactoryActivity) -> str:
    cap_note = ""
    if activity.implement_runs > activity.implement_daily_cap:
        cap_note = " (cap exceeded; dispatches skipped)"
    elif activity.implement_runs == activity.implement_daily_cap:
        cap_note = " (cap reached; further dispatches skipped)"
    return (
        "Factory activity: "
        f"implement runs today {activity.implement_runs}/{activity.implement_daily_cap}"
        f"{cap_note} · review verdicts {activity.review_verdicts} · "
        f"responder replies {activity.responder_replies}"
    )


def body_has_digest_marker(body: Any) -> bool:
    return str(body or "").lstrip().startswith(DIGEST_MARKER)


def select_digest_issue(
    issues: list[dict[str, Any]],
    *,
    warn_on_multiple: bool = False,
) -> dict[str, Any] | None:
    matches = [item for item in issues if body_has_digest_marker(item.get("body"))]
    if not matches:
        return None
    matches.sort(
        key=lambda item: (
            parse_datetime(str(item["createdAt"])),
            int(item["number"]),
        ),
        reverse=True,
    )
    selected = matches[0]
    if warn_on_multiple and len(matches) > 1:
        others = ", ".join(f"#{item['number']}" for item in matches[1:])
        print(
            f"warning: multiple marked Factory Digest issues found; using "
            f"#{selected['number']} and leaving {others} untouched",
            file=sys.stderr,
        )
    return selected


def exclude_digest_issues(
    issues: list[dict[str, Any]],
    digest_issue_number: int | None,
) -> list[dict[str, Any]]:
    return [
        issue
        for issue in issues
        if not body_has_digest_marker(issue.get("body"))
        and (digest_issue_number is None or int(issue["number"]) != digest_issue_number)
    ]


def render_digest(
    issues: list[dict[str, Any]],
    pulls: list[dict[str, Any]],
    summary: dict[str, Any],
    activity: FactoryActivity | None = None,
) -> str:
    digest_issue = select_digest_issue(issues)
    digest_issue_number = int(digest_issue["number"]) if digest_issue is not None else None
    issues = [
        issue
        for issue in exclude_digest_issues(issues, digest_issue_number)
        if str(issue.get("state", "")).upper() == "OPEN"
    ]
    current_time = parse_datetime(str(summary["generated_at"]))
    issues_by_number = {int(issue["number"]): issue for issue in issues}
    pulls_by_issue: dict[int, list[dict[str, Any]]] = {}
    for pull in pulls:
        for reference in pull.get("closingIssuesReferences", []) or []:
            pulls_by_issue.setdefault(int(reference["number"]), []).append(pull)
    merge_lines: list[tuple[bool, datetime, str]] = []

    for pull in pulls:
        if str(pull.get("state", "")).upper() != "OPEN" or pull.get("isDraft"):
            continue
        linked_issues = [
            issues_by_number.get(int(reference["number"]))
            for reference in pull.get("closingIssuesReferences", []) or []
        ]
        mergeable = any(
            issue is not None and "mergeable" in label_names(issue) for issue in linked_issues
        )
        updated_at = str(pull["updatedAt"])
        line = (
            f"- no activity {age_days(updated_at, current_time)}d "
            f"{render_item_reference(pull)}: "
            f"{'merge' if mergeable else 'review'}"
        )
        merge_lines.append((not mergeable, parse_datetime(updated_at), line))

    sections: list[str] = []
    if merge_lines:
        lines = [line for _, _, line in sorted(merge_lines, key=lambda item: (item[0], item[1]))]
        sections.append("## Needs your merge\n\n" + "\n".join(lines))

    release_lines: list[tuple[datetime, str]] = []
    ready_issues: list[dict[str, Any]] = []
    anomalies: list[int] = []
    aging_lines: list[tuple[datetime, str]] = []
    queue_age_breaches: list[tuple[datetime, dict[str, str]]] = []
    for issue in issues:
        labels = label_names(issue)
        updated_at = str(issue["updatedAt"])
        updated_time = parse_datetime(updated_at)
        issue_reference = render_item_reference(issue)
        lifecycle_labels = labels.intersection({"review", "claimed", "ready"})
        if len(lifecycle_labels) > 1:
            anomalies.append(int(issue["number"]))
            continue
        lifecycle = next(
            (state for state in ("review", "claimed", "ready") if state in lifecycle_labels),
            None,
        )

        if "needs-human" in labels:
            release_lines.append(
                (
                    updated_time,
                    f"- no activity {age_days(updated_at, current_time)}d "
                    f"{issue_reference}: decide",
                )
            )
        elif {"agent", "task"}.issubset(labels) and lifecycle is None:
            release_lines.append(
                (
                    updated_time,
                    f"- no activity {age_days(updated_at, current_time)}d "
                    f"{issue_reference}: triage/flip ready",
                )
            )

        if lifecycle == "ready":
            ready_issues.append(issue)
            ready_since_value = ready_since(issue)
            ready_since_time = parse_datetime(ready_since_value)
            if current_time - ready_since_time > timedelta(hours=QUEUE_STALE_HOURS):
                queue_age_breaches.append(
                    (
                        ready_since_time,
                        {
                            "category": "queue-age",
                            "summary": (
                                f"{issue_reference} has been ready "
                                f"{age_days(ready_since_value, current_time)}d without moving "
                                "to claimed or review — check the sweep (or a claim/rollback "
                                "loop) rather than assuming it was never dispatched"
                            ),
                        },
                    )
                )
        elif lifecycle == "review":
            candidates = [
                pull
                for pull in pulls_by_issue.get(int(issue["number"]), [])
                if str(pull.get("state", "")).upper() == "OPEN"
            ]
            if candidates:
                pull = max(candidates, key=lambda item: parse_datetime(str(item["updatedAt"])))
                pull_updated_at = str(pull["updatedAt"])
                pull_updated_time = parse_datetime(pull_updated_at)
                if current_time - pull_updated_time > timedelta(days=3):
                    aging_lines.append(
                        (
                            pull_updated_time,
                            f"- no activity {age_days(pull_updated_at, current_time)}d "
                            f"{render_item_reference(pull)}: nudge",
                        )
                    )
        elif lifecycle == "claimed" and current_time - updated_time > timedelta(hours=24):
            # updatedAt measures inactivity; precise claim age belongs to reconciliation janitor #1064.
            aging_lines.append(
                (
                    updated_time,
                    f"- no activity {age_days(updated_at, current_time)}d "
                    f"{issue_reference}: check",
                )
            )

    if release_lines:
        lines = [line for _, line in sorted(release_lines, key=lambda item: item[0])]
        sections.append("## Awaiting your release\n\n" + "\n".join(lines))
    if ready_issues:
        lines = [
            f"- no activity {age_days(str(issue['updatedAt']), current_time)}d "
            f"{render_item_reference(issue)}: ready for claim"
            for issue in sorted(
                ready_issues,
                key=lambda item: parse_datetime(str(item["updatedAt"])),
            )
        ]
        sections.append("## Ready but unclaimed\n\n" + "\n".join(lines))
    if anomalies:
        numbers = ", ".join(f"#{number}" for number in sorted(anomalies))
        sections.append(f"State anomalies: {numbers} — janitor")
    if aging_lines:
        lines = [line for _, line in sorted(aging_lines, key=lambda item: item[0])]
        sections.append("## Aging\n\n" + "\n".join(lines))

    breaches = list(summary.get("breaches") or []) + [
        breach
        for _, breach in sorted(queue_age_breaches, key=lambda item: item[0])
    ]
    if breaches:
        lines = [f"- **{item['category']}**: {item['summary']}" for item in breaches]
        sections.append("## Threshold breaches\n\n" + "\n".join(lines))

    if not sections:
        sections.append("No open gates. The factory is idle.")
    sections.append(render_factory_activity(activity or FactoryActivity()))
    sections.append(render_stats(summary))
    return "\n\n".join([DIGEST_MARKER, *sections])


def marked_body(body: str) -> str:
    if body_has_digest_marker(body):
        return body.lstrip()
    return f"{DIGEST_MARKER}\n\n{body}"


def publish_digest(
    repo: RepoInfo,
    issues: list[dict[str, Any]],
    body: str,
    token: str,
) -> dict[str, Any]:
    body = marked_body(body)
    selected = select_digest_issue(issues, warn_on_multiple=True)
    if selected is not None:
        if str(selected.get("state", "")).upper() == "CLOSED":
            reopen_mutation = """
mutation ReopenFactoryDigest($input: ReopenIssueInput!) {
  reopenIssue(input: $input) {
    issue { id number url }
  }
}
"""
            graphql(
                token,
                reopen_mutation,
                {"input": {"issueId": selected["id"]}},
            )
        mutation = """
mutation UpdateFactoryDigest($input: UpdateIssueInput!) {
  updateIssue(input: $input) {
    issue { id number url }
  }
}
"""
        data = graphql(
            token,
            mutation,
            {"input": {"id": selected["id"], "body": body}},
        )
        return data["data"]["updateIssue"]["issue"]

    human_label_id = repo.label_ids.get("human")
    if human_label_id is None:
        raise FactoryDigestError('required "human" label does not exist')
    factory_label_id = repo.label_ids.get("factory")
    if factory_label_id is None:
        label_mutation = """
mutation CreateFactoryLabel($input: CreateLabelInput!) {
  createLabel(input: $input) {
    label { id name }
  }
}
"""
        data = graphql(
            token,
            label_mutation,
            {
                "input": {
                    "repositoryId": repo.repository_id,
                    "name": "factory",
                    "color": FACTORY_LABEL_COLOR,
                    "description": FACTORY_LABEL_DESCRIPTION,
                }
            },
        )
        factory_label_id = str(data["data"]["createLabel"]["label"]["id"])

    create_mutation = """
mutation CreateFactoryDigest($input: CreateIssueInput!) {
  createIssue(input: $input) {
    issue { id number url }
  }
}
"""
    data = graphql(
        token,
        create_mutation,
        {
            "input": {
                "repositoryId": repo.repository_id,
                "title": DIGEST_TITLE,
                "body": body,
                "labelIds": [factory_label_id, human_label_id],
            }
        },
    )
    issue = data["data"]["createIssue"]["issue"]

    pin_mutation = """
mutation PinFactoryDigest($input: PinIssueInput!) {
  pinIssue(input: $input) {
    issue { id number url }
  }
}
"""
    try:
        graphql(token, pin_mutation, {"input": {"issueId": issue["id"]}})
    except FactoryDigestError as error:
        print(f"warning: unable to pin Factory Digest: {error}", file=sys.stderr)
    return issue


def main() -> int:
    args = parse_args()
    validate_args(args)
    summary = load_json_file(args.summary)
    if args.fixtures_dir is not None:
        issues, pulls = load_fixture_inputs(args.fixtures_dir)
        print(render_digest(issues, pulls, summary))
        return 0

    repo_slug = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise FactoryDigestError("GH_TOKEN is required for live GitHub access")
    inputs = fetch_live_inputs(repo_slug, token)
    activity = fetch_factory_activity(
        repo_slug,
        token,
        parse_datetime(str(summary["generated_at"])),
        parse_daily_implement_cap(os.environ.get("FACTORY_IMPLEMENT_DAILY_CAP")),
    )
    markdown = render_digest(inputs.issues, inputs.pulls, summary, activity)
    if args.dry_run:
        print(markdown)
        return 0

    issue = publish_digest(inputs.repo, inputs.issues, markdown, token)
    print(f"Factory Digest: {issue['url']}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FactoryDigestError, KeyError, TypeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
