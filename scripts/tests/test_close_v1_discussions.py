#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fixture tests for the v1 discussion cleanup script.

Intent: protect dry-run planning with checked-in GraphQL pages so the cleanup
can be verified without mutating GitHub discussions.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES_DIR = REPO_ROOT / "fixtures" / "close-v1-discussions"
SCRIPT_PATH = REPO_ROOT / "scripts" / "close-v1-discussions.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


close_v1_discussions = load_module("close_v1_discussions", SCRIPT_PATH)


class CloseV1DiscussionsTests(unittest.TestCase):
    def test_fixture_plan_skips_factory_digest_across_pages(self) -> None:
        discussions = close_v1_discussions.load_fixture_discussions(FIXTURES_DIR)

        plan = close_v1_discussions.plan_discussions(discussions, limit=None)

        self.assertEqual(
            [(item.number, item.title) for item in plan.items],
            [
                (41, "First v1 thread"),
                (43, "Second v1 thread"),
                (44, "Third v1 thread"),
            ],
        )
        self.assertEqual(plan.skipped_digest_count, 1)
        self.assertEqual(plan.omitted_by_limit_count, 0)

    def test_fixture_cli_dry_run_reports_actions_without_token(self) -> None:
        env = os.environ.copy()
        env.pop("GH_TOKEN", None)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fixtures-dir",
                str(FIXTURES_DIR),
                "--limit",
                "2",
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "[dry-run] Digest precondition: PASS; found 1 open discussion "
            "titled exactly 'Factory Digest' (expected exactly 1)",
            result.stdout,
        )
        self.assertIn(
            "[dry-run] #41 First v1 thread: would comment, then close as OUTDATED",
            result.stdout,
        )
        self.assertIn(
            "[dry-run] #43 Second v1 thread: would comment, then close as OUTDATED",
            result.stdout,
        )
        self.assertNotIn("#44 Third v1 thread", result.stdout)
        self.assertIn(
            "[dry-run] Planned 2 discussion(s); skipped 1 Factory Digest; "
            "omitted 1 due to --limit",
            result.stdout,
        )

    def test_live_loader_follows_graphql_page_cursors(self) -> None:
        pages = json.loads(
            (FIXTURES_DIR / "discussions.json").read_text(encoding="utf-8")
        )
        cursors: list[str | None] = []

        def graphql_fixture(_query, _env, **variables):
            cursors.append(variables["cursor"])
            return pages[len(cursors) - 1]

        discussions = close_v1_discussions.fetch_open_discussions(
            "fairchild",
            "workspaces",
            {},
            graphql_fn=graphql_fixture,
        )

        self.assertEqual(cursors, [None, "cursor-1"])
        self.assertEqual(
            [discussion.number for discussion in discussions],
            [41, 42, 43, 44],
        )

    def test_dry_run_reports_failed_digest_precondition_without_aborting(self) -> None:
        output = io.StringIO()

        with redirect_stdout(output):
            close_v1_discussions.print_dry_run(
                close_v1_discussions.DiscussionPlan(
                    items=[],
                    skipped_digest_count=0,
                    omitted_by_limit_count=0,
                ),
                skip_digest_check=False,
            )

        self.assertIn(
            "[dry-run] Digest precondition: FAIL; found 0 open discussions",
            output.getvalue(),
        )

    def test_help_calls_digest_override_dangerous_and_names_consequence(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--help"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DANGEROUS", result.stdout)
        self.assertIn(
            "applying with no digest closes every open discussion",
            " ".join(result.stdout.split()),
        )

    def test_apply_comments_before_closing_as_outdated(self) -> None:
        discussion = close_v1_discussions.Discussion(
            id="D_kwDOFirst",
            number=41,
            title="First v1 thread",
            url="https://github.com/fairchild/workspaces/discussions/41",
        )
        calls: list[tuple[str, dict[str, object]]] = []

        def graphql_fixture(query, _env, **variables):
            if "comments(last: 20)" in query:
                operation = "recent_comments"
                response = {"data": {"node": {"comments": {"nodes": []}}}}
            elif "addDiscussionComment" in query:
                operation = "comment"
                response = {"data": {}}
            else:
                operation = "close"
                response = {"data": {}}
            calls.append((operation, variables))
            return response

        with redirect_stdout(io.StringIO()):
            close_v1_discussions.apply_plan(
                close_v1_discussions.DiscussionPlan(
                    items=[discussion],
                    skipped_digest_count=0,
                    omitted_by_limit_count=0,
                ),
                {},
                graphql_fn=graphql_fixture,
                sleep_fn=lambda _delay: None,
            )

        self.assertEqual(
            [operation for operation, _ in calls],
            ["recent_comments", "comment", "close"],
        )
        self.assertEqual(calls[1][1]["discussion_id"], discussion.id)
        self.assertEqual(
            calls[1][1]["body"],
            "Superseded by Agent Factory v2 "
            "(docs/development/agent-factory-v2-plan.md): Discussions are no "
            "longer the factory's decision surface, and this thread is being "
            "closed as part of the v1 cleanup (#1065). Anything here that still "
            "matters re-enters via the feedback box or a GitHub issue.\n\n"
            "<!-- v1-cleanup:1065 -->",
        )
        self.assertEqual(calls[2][1]["reason"], "OUTDATED")

    def test_apply_requires_exactly_one_factory_digest_unless_overridden(self) -> None:
        for digest_count in (0, 2):
            with self.subTest(digest_count=digest_count):
                plan = close_v1_discussions.DiscussionPlan(
                    items=[],
                    skipped_digest_count=digest_count,
                    omitted_by_limit_count=0,
                )

                with self.assertRaisesRegex(
                    close_v1_discussions.DiscussionCleanupError,
                    r"refusing --apply: found .*expected exactly 1.*No mutations",
                ):
                    close_v1_discussions.enforce_digest_precondition(
                        plan,
                        skip_digest_check=False,
                    )

                close_v1_discussions.enforce_digest_precondition(
                    plan,
                    skip_digest_check=True,
                )

    def test_apply_skips_comment_when_cleanup_marker_is_recent(self) -> None:
        discussion = close_v1_discussions.Discussion(
            id="D_kwDOFirst",
            number=41,
            title="First v1 thread",
            url="https://github.com/fairchild/workspaces/discussions/41",
        )
        calls: list[str] = []

        def graphql_fixture(query, _env, **_variables):
            if "comments(last: 20)" in query:
                calls.append("recent_comments")
                return {
                    "data": {
                        "node": {
                            "comments": {
                                "nodes": [
                                    {
                                        "body": "done "
                                        f"{close_v1_discussions.CLEANUP_MARKER}"
                                    }
                                ]
                            }
                        }
                    }
                }
            calls.append("close" if "closeDiscussion" in query else "comment")
            return {"data": {}}

        with redirect_stdout(io.StringIO()):
            failures = close_v1_discussions.apply_plan(
                close_v1_discussions.DiscussionPlan(
                    items=[discussion],
                    skipped_digest_count=1,
                    omitted_by_limit_count=0,
                ),
                {},
                graphql_fn=graphql_fixture,
                sleep_fn=lambda _delay: None,
            )

        self.assertEqual(failures, [])
        self.assertEqual(calls, ["recent_comments", "close"])

    def test_transient_mutation_retries_three_total_attempts_with_backoff(self) -> None:
        attempts = 0
        sleeps: list[float] = []

        def graphql_fixture(_query, _env, **_variables):
            nonlocal attempts
            attempts += 1
            if attempts < 3:
                raise close_v1_discussions.GraphQLRequestError(
                    "HTTP 502 from GitHub",
                    transient=True,
                )
            return {"data": {}}

        with redirect_stderr(io.StringIO()):
            close_v1_discussions.mutate_with_retry(
                close_v1_discussions.CLOSE_DISCUSSION_MUTATION,
                {},
                operation="#41 close",
                graphql_fn=graphql_fixture,
                sleep_fn=sleeps.append,
                discussion_id="D_kwDOFirst",
                reason="OUTDATED",
            )

        self.assertEqual(attempts, 3)
        self.assertEqual(sleeps, [1.0, 2.0])

    def test_transient_classifier_covers_required_failure_classes(self) -> None:
        transient_details = [
            "GitHub returned HTTP 503",
            "You have exceeded a secondary rate limit",
            "Something went wrong while executing your query",
        ]

        for detail in transient_details:
            with self.subTest(detail=detail):
                self.assertTrue(
                    close_v1_discussions.is_transient_graphql_error(detail)
                )
        self.assertFalse(
            close_v1_discussions.is_transient_graphql_error("GraphQL: NOT_FOUND")
        )

    def test_persistent_failure_continues_to_next_discussion(self) -> None:
        discussions = [
            close_v1_discussions.Discussion(
                id="D_kwDOFirst",
                number=41,
                title="First v1 thread",
                url="https://github.com/fairchild/workspaces/discussions/41",
            ),
            close_v1_discussions.Discussion(
                id="D_kwDOSecond",
                number=43,
                title="Second v1 thread",
                url="https://github.com/fairchild/workspaces/discussions/43",
            ),
        ]
        close_attempts: list[str] = []
        sleeps: list[float] = []

        def graphql_fixture(query, _env, **variables):
            if "comments(last: 20)" in query:
                return {"data": {"node": {"comments": {"nodes": []}}}}
            if "addDiscussionComment" in query:
                return {"data": {}}
            close_attempts.append(variables["discussion_id"])
            if variables["discussion_id"] == "D_kwDOFirst":
                raise close_v1_discussions.GraphQLRequestError(
                    "secondary rate limit persisted",
                    transient=True,
                )
            return {"data": {}}

        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            failures = close_v1_discussions.apply_plan(
                close_v1_discussions.DiscussionPlan(
                    items=discussions,
                    skipped_digest_count=1,
                    omitted_by_limit_count=0,
                ),
                {},
                graphql_fn=graphql_fixture,
                sleep_fn=sleeps.append,
            )

        self.assertEqual(close_attempts, ["D_kwDOFirst"] * 3 + ["D_kwDOSecond"])
        self.assertEqual([failure.discussion.number for failure in failures], [41])
        self.assertEqual(sleeps, [1.0, 2.0, 1.0])


if __name__ == "__main__":
    unittest.main()
