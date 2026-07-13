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
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


FACTORY_DIGEST_TITLE = "Factory Digest"
CLEANUP_MARKER = "<!-- v1-cleanup:1065 -->"
CLOSE_COMMENT = (
    "Superseded by Agent Factory v2 (docs/development/agent-factory-v2-plan.md): "
    "Discussions are no longer the factory's decision surface, and this thread is "
    "being closed as part of the v1 cleanup (#1065). Anything here that still "
    "matters re-enters via the feedback box or a GitHub issue.\n\n"
    f"{CLEANUP_MARKER}"
)
MAX_MUTATION_ATTEMPTS = 3
INTER_DISCUSSION_DELAY_SECONDS = 1.0
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
RECENT_COMMENTS_QUERY = """
query($discussion_id: ID!) {
  node(id: $discussion_id) {
    ... on Discussion {
      comments(last: 20) {
        nodes { body }
      }
    }
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


@dataclass(frozen=True)
class DiscussionFailure:
    discussion: Discussion
    operation: str
    detail: str


class DiscussionCleanupError(RuntimeError):
    """Raised when discussion cleanup cannot be planned or applied safely."""


class GraphQLRequestError(DiscussionCleanupError):
    """A GraphQL failure annotated with whether a mutation may be retried."""

    def __init__(self, message: str, *, transient: bool) -> None:
        super().__init__(message)
        self.transient = transient


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
    parser.add_argument(
        "--skip-digest-check",
        action="store_true",
        help=(
            "DANGEROUS: bypass the exactly-one Factory Digest precondition; "
            "applying with no digest closes every open discussion."
        ),
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
    try:
        result = run_checked(cmd, env=env)
    except DiscussionCleanupError as error:
        raise GraphQLRequestError(
            str(error), transient=is_transient_graphql_error(str(error))
        ) from error
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise DiscussionCleanupError(f"invalid JSON from GitHub GraphQL: {error}") from error
    if response.get("errors"):
        detail = json.dumps(response["errors"], sort_keys=True)
        raise GraphQLRequestError(
            f"GitHub GraphQL errors: {detail}",
            transient=is_transient_graphql_error(detail),
        )
    return response


def is_transient_graphql_error(detail: str) -> bool:
    normalized = detail.casefold()
    if re.search(r"\bhttp(?: status)?[ :=]*(5\d\d)\b", normalized):
        return True
    if re.search(r"\bstatus(?: code)?[ :=]*(5\d\d)\b", normalized):
        return True
    return any(
        phrase in normalized
        for phrase in (
            "secondary rate limit",
            "abuse detection",
            "something went wrong while executing your query",
            "internal error",
            "internal server error",
            "service unavailable",
            "temporarily unavailable",
            "timed out",
            "timeout",
            '"type": "internal"',
            '"type": "service_unavailable"',
        )
    )


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


def digest_precondition_message(plan: DiscussionPlan) -> str:
    count = plan.skipped_digest_count
    noun = "discussion" if count == 1 else "discussions"
    return (
        f"found {count} open {noun} titled exactly "
        f"{FACTORY_DIGEST_TITLE!r} (expected exactly 1)"
    )


def enforce_digest_precondition(
    plan: DiscussionPlan,
    *,
    skip_digest_check: bool,
) -> None:
    if plan.skipped_digest_count == 1 or skip_digest_check:
        return
    raise DiscussionCleanupError(
        f"refusing --apply: {digest_precondition_message(plan)}. "
        "No mutations were attempted. Restore a single Factory Digest or use "
        "the dangerous --skip-digest-check override; applying with no digest "
        "closes every open discussion."
    )


def print_digest_precondition(
    plan: DiscussionPlan,
    *,
    mode: str,
    skip_digest_check: bool,
) -> None:
    passed = plan.skipped_digest_count == 1
    result = "PASS" if passed else "FAIL"
    override = " (dangerous override requested)" if skip_digest_check else ""
    print(
        f"[{mode}] Digest precondition: {result}{override}; "
        f"{digest_precondition_message(plan)}"
    )


def print_dry_run(plan: DiscussionPlan, *, skip_digest_check: bool) -> None:
    print_digest_precondition(
        plan,
        mode="dry-run",
        skip_digest_check=skip_digest_check,
    )
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


def recent_comments_contain_marker(response: dict[str, Any]) -> bool:
    comments = response["data"]["node"]["comments"]["nodes"]
    return any(CLEANUP_MARKER in comment["body"] for comment in comments)


def mutate_with_retry(
    query: str,
    env: dict[str, str],
    *,
    operation: str,
    graphql_fn: Callable[..., dict[str, Any]],
    sleep_fn: Callable[[float], None],
    **variables: Any,
) -> dict[str, Any]:
    for attempt in range(1, MAX_MUTATION_ATTEMPTS + 1):
        try:
            return graphql_fn(query, env, **variables)
        except Exception as error:
            transient = getattr(error, "transient", None)
            if transient is None:
                transient = is_transient_graphql_error(str(error))
            if not transient or attempt == MAX_MUTATION_ATTEMPTS:
                raise
            delay = float(2 ** (attempt - 1))
            print(
                f"[apply] {operation} failed transiently; retrying "
                f"in {delay:g}s ({attempt + 1}/{MAX_MUTATION_ATTEMPTS})",
                file=sys.stderr,
            )
            sleep_fn(delay)
    raise AssertionError("mutation retry loop exhausted without returning or raising")


def apply_plan(
    plan: DiscussionPlan,
    env: dict[str, str],
    *,
    graphql_fn: Callable[..., dict[str, Any]],
    sleep_fn: Callable[[float], None] = time.sleep,
) -> list[DiscussionFailure]:
    failures: list[DiscussionFailure] = []
    succeeded = 0
    for index, discussion in enumerate(plan.items):
        operation = "fetch recent comments"
        try:
            comments_response = graphql_fn(
                RECENT_COMMENTS_QUERY,
                env,
                discussion_id=discussion.id,
            )
            already_commented = recent_comments_contain_marker(comments_response)
            if not already_commented:
                operation = "post disposition comment"
                mutate_with_retry(
                    ADD_COMMENT_MUTATION,
                    env,
                    operation=f"#{discussion.number} comment",
                    graphql_fn=graphql_fn,
                    sleep_fn=sleep_fn,
                    discussion_id=discussion.id,
                    body=CLOSE_COMMENT,
                )
            operation = "close as OUTDATED"
            mutate_with_retry(
                CLOSE_DISCUSSION_MUTATION,
                env,
                operation=f"#{discussion.number} close",
                graphql_fn=graphql_fn,
                sleep_fn=sleep_fn,
                discussion_id=discussion.id,
                reason="OUTDATED",
            )
            succeeded += 1
            comment_result = (
                "comment already present" if already_commented else "commented"
            )
            print(
                f"[apply] #{discussion.number} {discussion.title}: "
                f"{comment_result}, then closed as OUTDATED"
            )
        except Exception as error:
            failures.append(
                DiscussionFailure(
                    discussion=discussion,
                    operation=operation,
                    detail=str(error),
                )
            )
            print(
                f"[apply] #{discussion.number} {discussion.title}: FAILED during "
                f"{operation}: {error}",
                file=sys.stderr,
            )
        if index + 1 < len(plan.items):
            sleep_fn(INTER_DISCUSSION_DELAY_SECONDS)
    print(
        f"[apply] Processed {succeeded} discussion(s); failed {len(failures)}; "
        f"skipped {plan.skipped_digest_count} Factory Digest; "
        f"omitted {plan.omitted_by_limit_count} due to --limit"
    )
    if failures:
        print("[apply] Persistent failures:", file=sys.stderr)
        for failure in failures:
            print(
                f"  - #{failure.discussion.number} {failure.discussion.title}: "
                f"{failure.operation}: {failure.detail}",
                file=sys.stderr,
            )
    return failures


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
            print_digest_precondition(
                plan,
                mode="apply",
                skip_digest_check=args.skip_digest_check,
            )
            enforce_digest_precondition(
                plan,
                skip_digest_check=args.skip_digest_check,
            )
            failures = apply_plan(plan, env, graphql_fn=graphql)
            if failures:
                return 1
        else:
            print_dry_run(plan, skip_digest_check=args.skip_digest_check)
        return 0
    except (DiscussionCleanupError, KeyError, OSError, TypeError, ValueError) as error:
        print(f"close-v1-discussions: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
