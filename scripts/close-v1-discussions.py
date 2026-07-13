#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Close retired v1 agent-team discussions after a reviewable dry run.

The script plans against every open GitHub discussion while preserving the
Factory Digest. Writes require an explicit ``--apply`` after this change lands.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


FACTORY_DIGEST_TITLE = "Factory Digest"
CLOSE_COMMENT = (
    "Superseded by Agent Factory v2 (docs/development/agent-factory-v2-plan.md): "
    "Discussions are no longer the factory's decision surface, and this thread is "
    "being closed as part of the v1 cleanup (#1065). Anything here that still "
    "matters re-enters via the feedback box or a GitHub issue."
)
DISCUSSIONS_QUERY = """
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    discussions(
      first: 100
      after: $cursor
      states: OPEN
      orderBy: {field: CREATED_AT, direction: ASC}
    ) {
      nodes {
        id
        number
        title
        url
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
"""
ADD_COMMENT_MUTATION = """
mutation($discussion_id: ID!, $body: String!) {
  addDiscussionComment(input: {discussionId: $discussion_id, body: $body}) {
    comment { id }
  }
}
"""
CLOSE_DISCUSSION_MUTATION = """
mutation($discussion_id: ID!, $reason: DiscussionCloseReason!) {
  closeDiscussion(input: {discussionId: $discussion_id, reason: $reason}) {
    discussion { id closed }
  }
}
"""


@dataclass(frozen=True)
class Discussion:
    id: str
    number: int
    title: str
    url: str


@dataclass(frozen=True)
class DiscussionPlan:
    items: list[Discussion]
    skipped_digest_count: int
    omitted_by_limit_count: int


class DiscussionCleanupError(RuntimeError):
    """Raised when discussion cleanup cannot be planned or applied safely."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Post the disposition comment and close each planned discussion.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Cap the number of eligible discussions processed in this invocation.",
    )
    parser.add_argument(
        "--fixtures-dir",
        type=Path,
        help="Read checked-in GraphQL pages instead of querying GitHub.",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.limit is not None and args.limit <= 0:
        raise DiscussionCleanupError("--limit must be a positive integer")
    if args.fixtures_dir is not None and args.apply:
        raise DiscussionCleanupError("--fixtures-dir cannot be combined with --apply")


def run_checked(
    cmd: list[str],
    *,
    env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        command = " ".join(cmd[:3])
        detail = (result.stderr or result.stdout).strip() or "unknown error"
        raise DiscussionCleanupError(f"command failed ({command}): {detail}")
    return result


def graphql(query: str, env: dict[str, str], **variables: Any) -> dict[str, Any]:
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is not None:
            cmd.extend(["-f", f"{key}={value}"])
    result = run_checked(cmd, env=env)
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise DiscussionCleanupError(f"invalid JSON from GitHub GraphQL: {error}") from error
    if response.get("errors"):
        raise DiscussionCleanupError(f"GitHub GraphQL errors: {response['errors']}")
    return response


def repository_slug(env: dict[str, str]) -> tuple[str, str]:
    slug = env.get("GITHUB_REPOSITORY", "").strip()
    if not slug:
        result = run_checked(
            [
                "gh",
                "repo",
                "view",
                "--json",
                "nameWithOwner",
                "--jq",
                ".nameWithOwner",
            ],
            env=env,
        )
        slug = result.stdout.strip()
    if slug.count("/") != 1:
        raise DiscussionCleanupError(f"could not determine GitHub repository from {slug!r}")
    owner, name = slug.split("/", 1)
    return owner, name


def discussions_from_page(page: dict[str, Any]) -> list[Discussion]:
    nodes = page["data"]["repository"]["discussions"]["nodes"]
    return [
        Discussion(
            id=node["id"],
            number=node["number"],
            title=node["title"],
            url=node["url"],
        )
        for node in nodes
    ]


def load_fixture_discussions(fixtures_dir: Path) -> list[Discussion]:
    pages = json.loads((fixtures_dir / "discussions.json").read_text(encoding="utf-8"))
    return [discussion for page in pages for discussion in discussions_from_page(page)]


def fetch_open_discussions(
    owner: str,
    name: str,
    env: dict[str, str],
    *,
    graphql_fn: Callable[..., dict[str, Any]],
) -> list[Discussion]:
    discussions: list[Discussion] = []
    cursor: str | None = None
    while True:
        page = graphql_fn(
            DISCUSSIONS_QUERY,
            env,
            owner=owner,
            name=name,
            cursor=cursor,
        )
        discussions.extend(discussions_from_page(page))
        page_info = page["data"]["repository"]["discussions"]["pageInfo"]
        if not page_info["hasNextPage"]:
            return discussions
        cursor = page_info["endCursor"]


def plan_discussions(
    discussions: list[Discussion],
    *,
    limit: int | None,
) -> DiscussionPlan:
    skipped_digest_count = sum(
        discussion.title == FACTORY_DIGEST_TITLE for discussion in discussions
    )
    eligible = [
        discussion
        for discussion in discussions
        if discussion.title != FACTORY_DIGEST_TITLE
    ]
    items = eligible if limit is None else eligible[:limit]
    return DiscussionPlan(
        items=items,
        skipped_digest_count=skipped_digest_count,
        omitted_by_limit_count=len(eligible) - len(items),
    )


def print_dry_run(plan: DiscussionPlan) -> None:
    for discussion in plan.items:
        print(
            f"[dry-run] #{discussion.number} {discussion.title}: "
            "would comment, then close as OUTDATED"
        )
    print(
        f"[dry-run] Planned {len(plan.items)} discussion(s); "
        f"skipped {plan.skipped_digest_count} Factory Digest; "
        f"omitted {plan.omitted_by_limit_count} due to --limit"
    )


def apply_plan(
    plan: DiscussionPlan,
    env: dict[str, str],
    *,
    graphql_fn: Callable[..., dict[str, Any]],
) -> None:
    for discussion in plan.items:
        graphql_fn(
            ADD_COMMENT_MUTATION,
            env,
            discussion_id=discussion.id,
            body=CLOSE_COMMENT,
        )
        graphql_fn(
            CLOSE_DISCUSSION_MUTATION,
            env,
            discussion_id=discussion.id,
            reason="OUTDATED",
        )
        print(
            f"[apply] #{discussion.number} {discussion.title}: "
            "commented, then closed as OUTDATED"
        )
    print(
        f"[apply] Processed {len(plan.items)} discussion(s); "
        f"skipped {plan.skipped_digest_count} Factory Digest; "
        f"omitted {plan.omitted_by_limit_count} due to --limit"
    )


def main() -> int:
    args = parse_args()
    try:
        validate_args(args)
        env = os.environ.copy()
        if args.fixtures_dir is not None:
            discussions = load_fixture_discussions(args.fixtures_dir)
        else:
            if not env.get("GH_TOKEN", "").strip():
                raise DiscussionCleanupError("GH_TOKEN is required for live GitHub access")
            owner, name = repository_slug(env)
            discussions = fetch_open_discussions(
                owner,
                name,
                env,
                graphql_fn=graphql,
            )
        plan = plan_discussions(discussions, limit=args.limit)
        if args.apply:
            apply_plan(plan, env, graphql_fn=graphql)
        else:
            print_dry_run(plan)
        return 0
    except (DiscussionCleanupError, KeyError, OSError, TypeError, ValueError) as error:
        print(f"close-v1-discussions: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
