#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Contract tests for Agent Factory counterpart-review admission."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "factory-review.py"
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review.yml"
EXECUTOR_PATH = REPO_ROOT / ".github" / "workflows" / "factory-review-execute.yml"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


factory_review = load_module("factory_review", SCRIPT_PATH)


class FactoryReviewTests(unittest.TestCase):
    def pull_request(
        self,
        *,
        label: str = "author:codex",
        draft: bool = False,
        head_sha: str = "abc123",
    ):
        return {
            "state": "open",
            "draft": draft,
            "labels": [{"name": label}],
            "head": {"sha": head_sha},
        }

    def test_fixed_persona_pairs_route_to_counterpart(self) -> None:
        files = [{"filename": "Sources/Feature.swift"}]
        self.assertEqual(factory_review.counterpart_reviewer("author:april", files), "plat")
        self.assertEqual(factory_review.counterpart_reviewer("author:plat", files), "april")

    def test_generalist_authors_route_by_file_majority(self) -> None:
        application_files = [
            {"filename": "Sources/Feature.swift"},
            {"filename": "Tests/FeatureTests.swift"},
            {"filename": ".github/workflows/ci.yml"},
        ]
        platform_files = [
            {"filename": ".github/workflows/ci.yml"},
            {"filename": "infra/worker/index.ts"},
            {"filename": "scripts/helper.py"},
        ]

        for label in ("author:claude-code", "author:codex", "author:fable-orchestrator"):
            with self.subTest(label=label):
                self.assertEqual(
                    factory_review.counterpart_reviewer(label, application_files),
                    "april",
                )
                self.assertEqual(
                    factory_review.counterpart_reviewer(label, platform_files),
                    "plat",
                )

    def test_app_cannot_review_its_own_mislabeled_pull_request(self) -> None:
        pull_request = {
            **self.pull_request(label="author:codex"),
            "user": {"login": "april-clearwater[bot]"},
        }

        decision = factory_review.evaluate_review(
            pull_request,
            [{"filename": "Sources/Feature.swift"}],
            [],
            force=False,
        )

        self.assertEqual(decision.action, "skip")
        self.assertIn("cannot review its own", decision.reason)

    def test_linked_issue_is_derived_from_closing_reference(self) -> None:
        self.assertEqual(
            factory_review.linked_issue_number({"body": "Summary\n\nCloses #1091"}),
            1091,
        )
        self.assertIsNone(factory_review.linked_issue_number({"body": "Related to #1091"}))

    def test_automatic_review_deduplicates_reviewer_and_head_sha(self) -> None:
        reviews = [
            {
                "user": {"login": "april-clearwater[bot]"},
                "commit_id": "abc123",
                "state": "APPROVED",
            }
        ]
        pull_request = self.pull_request()
        files = [{"filename": "Sources/Feature.swift"}]

        automatic = factory_review.evaluate_review(
            pull_request,
            files,
            reviews,
            force=False,
        )
        requested = factory_review.evaluate_review(
            pull_request,
            files,
            reviews,
            force=True,
        )

        self.assertEqual(automatic.action, "skip")
        self.assertEqual(requested.action, "review")
        self.assertEqual(requested.reviewer, "april")

    def test_raw_attempt_count_includes_reruns_and_current_attempt(self) -> None:
        runs = [
            {"id": 100, "run_attempt": 2},
            {"id": 101, "run_attempt": 1},
        ]
        self.assertEqual(factory_review.count_daily_run_attempts(runs, "101"), 3)
        self.assertEqual(factory_review.count_daily_run_attempts(runs, "102", 3), 6)

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "positive integer"):
            factory_review.parse_daily_cap("0")

        api_client = factory_review.GitHubClient("fairchild/workspaces", "token")
        with mock.patch.object(
            api_client,
            "request",
            return_value={"workflow_runs": runs},
        ):
            self.assertEqual(
                api_client.workflow_runs_on("factory-review-execute.yml", "2026-07-14"),
                runs,
            )

    def test_review_was_posted_requires_a_successful_reviewer_job(self) -> None:
        self.assertTrue(
            factory_review.review_was_posted(
                [
                    {"name": "admit", "conclusion": "success"},
                    {"name": "april", "conclusion": "success"},
                ]
            )
        )
        self.assertFalse(
            factory_review.review_was_posted(
                [{"name": "admit", "conclusion": "success"}]
            ),
            "admission alone is not a posted review",
        )
        self.assertFalse(
            factory_review.review_was_posted(
                [{"name": "plat", "conclusion": "failure"}]
            ),
            "a crashed reviewer job did not post a review",
        )

    def test_daily_cap_counts_only_successful_reviews_not_failed_attempts(self) -> None:
        """Retries and crash-loop failures must not inflate the review budget."""
        runs = [
            {"id": 1, "run_attempt": 1, "status": "completed", "conclusion": "success"},
            {"id": 2, "run_attempt": 5, "status": "completed", "conclusion": "failure"},
            {"id": 3, "run_attempt": 1, "status": "completed", "conclusion": "success"},
        ]

        def jobs_for(run_id: int) -> list[dict[str, str]]:
            posted = {1: True, 2: False, 3: True}
            return [{"name": "april", "conclusion": "success" if posted[run_id] else "failure"}]

        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.side_effect = lambda run_id: jobs_for(run_id)

        # Two reviews were posted (runs 1 and 3); run 2 failed after five
        # attempts and posted nothing, so it does not count toward the cap.
        factory_review.authorize_execution(client, daily_cap=3, runaway_cap=30, current_run_id="4", current_run_attempt=1)

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "2 successful reviews"):
            factory_review.authorize_execution(
                client, daily_cap=2, runaway_cap=30, current_run_id="4", current_run_attempt=1
            )

    def test_runaway_guard_trips_on_raw_attempts_even_with_no_successful_reviews(
        self,
    ) -> None:
        """A pure crash loop must still be stopped even though nothing succeeded."""
        runs = [{"id": 1, "run_attempt": 40, "status": "completed", "conclusion": "failure"}]
        client = mock.Mock()
        client.workflow_runs_on.return_value = runs
        client.workflow_run_jobs.return_value = [{"name": "april", "conclusion": "failure"}]

        with self.assertRaisesRegex(factory_review.FactoryReviewError, "runaway guard"):
            factory_review.authorize_execution(
                client, daily_cap=12, runaway_cap=36, current_run_id="1", current_run_attempt=41
            )

    def test_runaway_cap_defaults_to_a_multiple_of_the_daily_cap(self) -> None:
        self.assertEqual(factory_review.parse_runaway_cap(None, 12), 36)
        self.assertEqual(factory_review.parse_runaway_cap("", 12), 36)
        self.assertEqual(factory_review.parse_runaway_cap("100", 12), 100)
        with self.assertRaisesRegex(factory_review.FactoryReviewError, "positive integer"):
            factory_review.parse_runaway_cap("0", 12)

    def test_human_or_draft_pull_request_does_not_enter_review_lane(self) -> None:
        files = [{"filename": "Sources/Feature.swift"}]
        human = self.pull_request(label="quality")
        draft = self.pull_request(draft=True)

        self.assertEqual(
            factory_review.evaluate_review(human, files, [], force=False).action,
            "skip",
        )
        self.assertEqual(
            factory_review.evaluate_review(draft, files, [], force=False).action,
            "skip",
        )

    def test_workflow_uses_isolated_apps_kill_switches_and_no_review_trigger(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        executor = EXECUTOR_PATH.read_text(encoding="utf-8")

        self.assertIn("types: [opened, ready_for_review, synchronize]", workflow)
        self.assertNotIn("pull_request_review:", workflow)
        self.assertIn("vars.AGENT_AUTOMATIONS_ENABLED == 'true'", workflow)
        self.assertIn("vars.FACTORY_REVIEW_ENABLED == 'true'", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn("workflow_run:", executor)
        self.assertIn("secrets.APRIL_APP_ID", executor)
        self.assertIn("secrets.APRIL_PRIVATE_KEY", executor)
        self.assertIn("secrets.WORKSPACE_AGENTS_APP_ID", executor)
        self.assertIn("secrets.WORKSPACE_AGENTS_PRIVATE_KEY", executor)
        self.assertIn("GH_APP_SLUG: april-clearwater", executor)
        self.assertIn("GH_APP_SLUG: workspace-agents", executor)
        self.assertIn("mentioned you in PR #${PR_NUMBER}", executor)
        self.assertIn("ref: ${{ needs.admit.outputs.head_sha }}", executor)
        self.assertIn("--expected-head", executor)
        self.assertIn("FACTORY_EXPECTED_PR_HEAD_SHA", executor)
        self.assertIn("FACTORY_REVIEW_DAILY_CAP", executor)
        self.assertIn("FACTORY_REVIEW_RUNAWAY_CAP", executor)
        self.assertIn("factory-review.py --authorize", executor)


if __name__ == "__main__":
    unittest.main()
