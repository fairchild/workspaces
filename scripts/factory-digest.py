#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build and publish the owner's Factory Digest discussion.

The digest combines live GitHub gates with the latest monitor summary so one
mobile-friendly surface carries every action and threshold breach.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


FIXTURE_REQUIRED_FILES = ("discussions.json", "issues.json", "pulls.json")
DIGEST_TITLE = "Factory Digest"
DIGEST_MARKER = "<!-- factory-digest:v1 -->"
DISCUSSION_WRITE_ACCESS_ERROR = (
    "DIGEST_TOKEN lacks discussion write access — set the PETER_DISCUSSION_TOKEN repo secret "
    "(a PAT with discussions write); the built-in Actions token has historically been unable "
    "to update discussions in this repo."
)
GITHUB_GRAPHQL_URL = "https://api.github.com/graphql"
MAX_TITLE_LENGTH = 80


class FactoryDigestError(RuntimeError):
    """Raised when the digest cannot be rendered or published."""


@dataclass(frozen=True)
class RepoInfo:
    owner: str
    name: str
    repository_id: str
    category_ids: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class DigestInputs:
    repo: RepoInfo
    discussions: list[dict[str, Any]]
    issues: list[dict[str, Any]]
    pulls: list[dict[str, Any]]


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


def split_repo_slug(slug: str) -> tuple[str, str]:
    parts = slug.strip().split("/", 1)
    if len(parts) != 2 or not all(parts):
        raise FactoryDigestError("GITHUB_REPOSITORY must be set to owner/name")
    return parts[0], parts[1]


def fetch_live_inputs(repo_slug: str, token: str) -> DigestInputs:
    owner, name = split_repo_slug(repo_slug)
    common_variables: dict[str, Any] = {"owner": owner, "name": name}
    discussion_query = """
query FactoryDigestDiscussions($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    id
    discussionCategories(first: 25) { nodes { id name } }
    discussions(first: 100, after: $after, states: [OPEN, CLOSED]) {
      pageInfo { hasNextPage endCursor }
      nodes { id number title body url closed createdAt }
    }
  }
}
"""
    discussions: list[dict[str, Any]] = []
    cursor: str | None = None
    repository_id = ""
    category_ids: dict[str, str] = {}
    while True:
        payload = graphql(token, discussion_query, {**common_variables, "after": cursor})
        repository = payload["data"]["repository"]
        if repository is None:
            raise FactoryDigestError(f"repository {repo_slug} was not found")
        repository_id = str(repository["id"])
        category_ids = {
            str(node["name"]).lower(): str(node["id"])
            for node in repository["discussionCategories"]["nodes"]
        }
        connection = repository["discussions"]
        discussions.extend(connection["nodes"])
        if not connection["pageInfo"]["hasNextPage"]:
            break
        cursor = connection["pageInfo"]["endCursor"]

    issue_query = """
query FactoryDigestIssues($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $after, states: OPEN) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url state createdAt updatedAt
        labels(first: 50) { nodes { name } }
      }
    }
  }
}
"""
    issues: list[dict[str, Any]] = []
    cursor = None
    while True:
        payload = graphql(token, issue_query, {**common_variables, "after": cursor})
        connection = payload["data"]["repository"]["issues"]
        for node in connection["nodes"]:
            issues.append({**node, "labels": list(node["labels"]["nodes"])})
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
        repo=RepoInfo(owner, name, repository_id, category_ids),
        discussions=discussions,
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
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    if not fixtures_dir.is_dir():
        raise FactoryDigestError(f"fixture pack not found: {fixtures_dir}")
    missing = [name for name in FIXTURE_REQUIRED_FILES if not (fixtures_dir / name).is_file()]
    if missing:
        raise FactoryDigestError(
            f"fixture pack {fixtures_dir} is missing required files: {', '.join(missing)}"
        )
    return (
        list(load_json_file(fixtures_dir / "discussions.json")),
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


def render_title(value: Any) -> str:
    sanitized = " ".join(str(value or "").splitlines()).replace("`", "'")
    if len(sanitized) > MAX_TITLE_LENGTH:
        sanitized = sanitized[: MAX_TITLE_LENGTH - 1] + "…"
    return f"`{sanitized}`"


def render_item_reference(item: dict[str, Any]) -> str:
    return f"[#{item['number']}]({item.get('url', '')}) {render_title(item.get('title', ''))}"


def render_stats(summary: dict[str, Any]) -> str:
    counts = summary.get("counts") or summary.get("funnel") or {}
    rendered = " · ".join(f"{key} {value}" for key, value in counts.items())
    return f"Stats: {rendered} · generated {summary['generated_at']}"


def render_digest(
    issues: list[dict[str, Any]],
    pulls: list[dict[str, Any]],
    summary: dict[str, Any],
) -> str:
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
    for issue in issues:
        if str(issue.get("state", "")).upper() != "OPEN":
            continue
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
        count = len(ready_issues)
        noun = "issue" if count == 1 else "issues"
        line = f"{count} {noun} ready for claim"
        if count <= 3:
            itemized = ", ".join(
                render_item_reference(issue)
                for issue in sorted(ready_issues, key=lambda item: int(item["number"]))
            )
            line += f": {itemized}"
        sections.append(line)
    if anomalies:
        numbers = ", ".join(f"#{number}" for number in sorted(anomalies))
        sections.append(f"State anomalies: {numbers} — janitor")
    if aging_lines:
        lines = [line for _, line in sorted(aging_lines, key=lambda item: item[0])]
        sections.append("## Aging\n\n" + "\n".join(lines))

    breaches = summary.get("breaches") or []
    if breaches:
        lines = [f"- **{item['category']}**: {item['summary']}" for item in breaches]
        sections.append("## Threshold breaches\n\n" + "\n".join(lines))

    if not sections:
        sections.append("No open gates. The factory is idle.")
    sections.append(render_stats(summary))
    return "\n\n".join([DIGEST_MARKER, *sections])


def is_discussion_access_error(error: FactoryDigestError) -> bool:
    message = str(error).lower()
    indicators = (
        "permission",
        "forbidden",
        "resource not accessible",
        "required scope",
        "insufficient scope",
        "http 401",
        "http 403",
        "unknown argument",
        "unknown type",
        "is not defined",
        "doesn't exist on type",
        "cannot query field",
        "expected type",
        "invalid value",
    )
    return any(indicator in message for indicator in indicators)


def run_discussion_write(
    token: str,
    mutation: str,
    variables: dict[str, Any],
) -> dict[str, Any]:
    try:
        return graphql(token, mutation, variables)
    except FactoryDigestError as error:
        if is_discussion_access_error(error):
            raise FactoryDigestError(DISCUSSION_WRITE_ACCESS_ERROR) from error
        raise


def marked_body(body: str) -> str:
    if body.startswith(DIGEST_MARKER):
        return body
    return f"{DIGEST_MARKER}\n\n{body}"


def publish_digest(
    repo: RepoInfo,
    discussions: list[dict[str, Any]],
    body: str,
    token: str,
) -> dict[str, Any]:
    body = marked_body(body)
    matches = [item for item in discussions if DIGEST_MARKER in str(item.get("body", ""))]
    if matches:
        matches.sort(
            key=lambda item: (
                parse_datetime(str(item["createdAt"])),
                item.get("title") == DIGEST_TITLE,
            ),
            reverse=True,
        )
        selected = matches[0]
        if len(matches) > 1:
            others = ", ".join(f"#{item['number']}" for item in matches[1:])
            print(
                f"warning: multiple marked Factory Digest discussions found; using "
                f"#{selected['number']} and leaving {others} untouched",
                file=sys.stderr,
            )
        if bool(selected.get("closed")):
            reopen_mutation = """
mutation ReopenFactoryDigest($input: ReopenDiscussionInput!) {
  reopenDiscussion(input: $input) {
    discussion { id number url }
  }
}
"""
            run_discussion_write(
                token,
                reopen_mutation,
                {"input": {"discussionId": selected["id"]}},
            )
        mutation = """
mutation UpdateFactoryDigest($input: UpdateDiscussionInput!) {
  updateDiscussion(input: $input) {
    discussion { id number url }
  }
}
"""
        data = run_discussion_write(
            token,
            mutation,
            {"input": {"discussionId": selected["id"], "body": body}},
        )
        return data["data"]["updateDiscussion"]["discussion"]

    category_id = repo.category_ids.get("announcements") or repo.category_ids.get("general")
    if not category_id:
        raise FactoryDigestError(
            'neither the "Announcements" nor "General" discussion category exists'
        )
    create_mutation = """
mutation CreateFactoryDigest($input: CreateDiscussionInput!) {
  createDiscussion(input: $input) {
    discussion { id number url }
  }
}
"""
    data = run_discussion_write(
        token,
        create_mutation,
        {
            "input": {
                "repositoryId": repo.repository_id,
                "categoryId": category_id,
                "title": DIGEST_TITLE,
                "body": body,
            }
        },
    )
    discussion = data["data"]["createDiscussion"]["discussion"]

    pin_mutation = """
mutation PinFactoryDigest($input: PinDiscussionInput!) {
  pinDiscussion(input: $input) {
    discussion { id number url }
  }
}
"""
    try:
        graphql(token, pin_mutation, {"input": {"discussionId": discussion["id"]}})
    except FactoryDigestError as error:
        print(f"warning: unable to pin Factory Digest: {error}", file=sys.stderr)
    return discussion


def main() -> int:
    args = parse_args()
    validate_args(args)
    summary = load_json_file(args.summary)
    if args.fixtures_dir is not None:
        _, issues, pulls = load_fixture_inputs(args.fixtures_dir)
        print(render_digest(issues, pulls, summary))
        return 0

    repo_slug = os.environ.get("GITHUB_REPOSITORY", "")
    read_token = os.environ.get("GH_TOKEN", "")
    if not read_token:
        raise FactoryDigestError("GH_TOKEN is required for live GitHub reads")
    inputs = fetch_live_inputs(repo_slug, read_token)
    markdown = render_digest(inputs.issues, inputs.pulls, summary)
    if args.dry_run:
        print(markdown)
        return 0

    write_token = os.environ.get("DIGEST_TOKEN", "")
    if not write_token:
        raise FactoryDigestError("DIGEST_TOKEN is required to publish the Factory Digest")
    discussion = publish_digest(inputs.repo, inputs.discussions, markdown, write_token)
    print(f"Factory Digest: {discussion['url']}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FactoryDigestError, KeyError, TypeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
