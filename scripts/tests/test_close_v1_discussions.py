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
from contextlib import redirect_stdout
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
        self.assertEqual([discussion.number for discussion in discussions], [41, 42, 43, 44])

    def test_apply_comments_before_closing_as_outdated(self) -> None:
        discussion = close_v1_discussions.Discussion(
            id="D_kwDOFirst",
            number=41,
            title="First v1 thread",
            url="https://github.com/fairchild/workspaces/discussions/41",
        )
        calls: list[tuple[str, dict[str, object]]] = []

        def graphql_fixture(query, _env, **variables):
            operation = (
                "comment" if "addDiscussionComment" in query else "close"
            )
            calls.append((operation, variables))
            return {"data": {}}

        with redirect_stdout(io.StringIO()):
            close_v1_discussions.apply_plan(
                close_v1_discussions.DiscussionPlan(
                    items=[discussion],
                    skipped_digest_count=0,
                    omitted_by_limit_count=0,
                ),
                {},
                graphql_fn=graphql_fixture,
            )

        self.assertEqual([operation for operation, _ in calls], ["comment", "close"])
        self.assertEqual(calls[0][1]["discussion_id"], discussion.id)
        self.assertEqual(
            calls[0][1]["body"],
            "Superseded by Agent Factory v2 "
            "(docs/development/agent-factory-v2-plan.md): Discussions are no "
            "longer the factory's decision surface, and this thread is being "
            "closed as part of the v1 cleanup (#1065). Anything here that still "
            "matters re-enters via the feedback box or a GitHub issue.",
        )
        self.assertEqual(calls[1][1]["reason"], "OUTDATED")


if __name__ == "__main__":
    unittest.main()
